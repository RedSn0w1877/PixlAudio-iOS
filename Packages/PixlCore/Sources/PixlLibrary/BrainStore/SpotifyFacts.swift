// The facts the Spotify sync receives with every track and used to drop (docs/brain-spec.md, 13.1, 3.3 B), kept for
// stage 2b's track facts (year, explicit, artist ids), and the switch "Use my Spotify music to shape picks". A port of
// Android's `BrainFactsSink.kt` and `spotify_fact` table.
//
// The facts shape picks (a year, an artist id). Nothing here trains anything (owner question 1). File
// `spotify_fact.pbl`, a cache: it can be dropped and read again at the next library sync:
//     `<spotifyId>`  ->  {"albumId":..,"artistIds":[..],"explicit":..,"isrc":..,"releaseDate":..,"releasePrecision":..,
//                         "seenAtMs":..,"spotifyId":..,"v":1}

import Foundation
import PixlModel

public final class SpotifyFactStore: SpotifyFactsSink, @unchecked Sendable {
    public static let formatVersion = 1
    public static let flushDelayMs: UInt64 = 2_000
    public static let maxBatch = 200
    /// A sync of a very large library is bounded: the rest arrives at the next sync.
    public static let maxPending = 20_000

    public struct Row: Sendable, Hashable, Codable {
        public var v: Int
        public var spotifyId: String
        public var isrc: String?
        public var artistIds: [String]
        public var albumId: String?
        public var releaseDate: String?
        public var releasePrecision: String?
        public var explicit: Bool?
        public var seenAtMs: Int64
    }

    private let file: KeyedLogStore
    private let enabled: @Sendable () -> Bool
    private let clock: @Sendable () -> Int64
    private let lock = NSLock()
    private var pending: [SpotifyFactInput] = []
    private var flushing = false
    private var rows: [String: Row] = [:]
    private var loaded = false

    public init(directory: URL, enabled: @escaping @Sendable () -> Bool,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }, compactionFloorBytes: Int = 32 * 1024) {
        file = KeyedLogStore(url: directory.appendingPathComponent("spotify_fact.pbl", isDirectory: false),
                             compactionFloorBytes: compactionFloorBytes)
        self.enabled = enabled
        self.clock = clock
    }

    /// Queues a track's facts and writes them in a batch a moment later. A track with no id, or while the switch is
    /// off, is dropped. Cheap: nothing is read or written on the caller's path.
    public func record(_ fact: SpotifyFactInput) {
        if BrainText.isBlank(fact.spotifyId) || !enabled() { return }
        lock.lock()
        if pending.count < Self.maxPending { pending.append(fact) }
        let start = !flushing
        if start { flushing = true }
        lock.unlock()
        if start {
            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(nanoseconds: Self.flushDelayMs * 1_000_000)
                self?.drain()
            }
        }
    }

    /// Writes what is queued now. Public for tests; the sink calls it by itself.
    public func drain() {
        while true {
            lock.lock()
            let batch = Array(pending.prefix(Self.maxBatch))
            pending.removeFirst(batch.count)
            if batch.isEmpty { flushing = false }
            lock.unlock()
            if batch.isEmpty { return }
            // Switched off while it waited: what was queued is dropped, not kept.
            if !enabled() { continue }
            write(batch)
        }
    }

    private func write(_ batch: [SpotifyFactInput]) {
        let now = clock()
        var seen: Set<String> = []
        var records: [(key: String, payload: [UInt8])] = []
        var made: [Row] = []
        for fact in batch where seen.insert(fact.spotifyId).inserted {
            let row = Row(v: Self.formatVersion, spotifyId: fact.spotifyId, isrc: fact.isrc, artistIds: fact.artistIds,
                          albumId: fact.albumId, releaseDate: fact.releaseDate, releasePrecision: fact.releasePrecision,
                          explicit: fact.explicit, seenAtMs: now)
            guard let payload = Self.payload(row) else { continue }
            records.append((fact.spotifyId, payload))
            made.append(row)
        }
        if records.isEmpty { return }
        lock.lock()
        defer { lock.unlock() }
        if file.put(records) {
            if loaded { for row in made { rows[row.spotifyId] = row } }
        }
    }

    private static func payload(_ row: Row) -> [UInt8]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(row)).map { [UInt8]($0) }
    }

    private func loadIfNeeded() {
        if loaded { return }
        loaded = true
        file.open { _, payload in
            // A row of a version this code does not know is left where it is.
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(payload)),
                  row.v >= 1, row.v <= Self.formatVersion else { return }
            self.rows[row.spotifyId] = row
        }
    }

    /// The saved facts of these Spotify ids.
    public func get(_ ids: [String]) -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return ids.compactMap { rows[$0] }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return rows.count
    }

    /// The listener switched "Use my Spotify music to shape picks" off: what was queued and kept goes. It is read again
    /// at the next sync if the switch is turned back on.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
        loadIfNeeded()
        let keys = Array(rows.keys)
        if !keys.isEmpty, file.remove(keys) { rows.removeAll() }
    }
}
