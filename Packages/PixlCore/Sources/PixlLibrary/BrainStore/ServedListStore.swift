// The served log (docs/brain-spec.md, 3.8 `served_list`, 6.4, 6.5): every generated list the app served, kept 60 days.
// Three things read it:
//  - the repetition budget: a recording is not in two mixes built on the same local day, and one served often in the
//    last 30 days costs value in the next list (`Repetition`);
//  - the saved mixes: the newest list of a surface built on today's local day IS today's mix, so a mix is stable for
//    the day and comes back after a restart;
//  - "Regenerate": how many lists a surface already had today.
//
// A port of Android's `ServedListStore.kt` and its `served_list` table. File `served_list.pbl`:
//     `<recId>`  ->  {"builtAt":..,"mix":{...},"modelVersion":..,"nuQ":..,"recId":..,"rids":[..],"seed":..,
//                     "surface":..,"surfaceId":"..","v":1}
// One line per list, a few kilobytes each. The in-memory index holds only the header of a list (its surface, its time
// and its recordings), never the items; today's mix is read from the file when it is asked for. A log that cannot be
// read is an empty log, never a failed mix. A stage 1 install has no such file.

import Foundation

public final class ServedListStore {
    public static let formatVersion = 1
    static let clockSlackMs: Int64 = 10 * 60 * 1000

    struct Header: Equatable {
        var recId: Int64
        var surface: Int32
        var builtAtMs: Int64
        var rids: [Int64]
    }

    /// What is stored; `mix` is skipped when only the header is wanted.
    struct Record: Codable {
        var v: Int
        var recId: Int64
        var surface: Int32
        var surfaceId: String
        var builtAt: Int64
        var seed: Int64
        var modelVersion: Int32
        var nuQ: Int32
        var rids: [Int64]
        var mix: StoredMix?
    }

    private let file: KeyedLogStore
    private var loaded = false
    private var headers: [Int64: Header] = [:]

    public init(directory: URL, compactionFloorBytes: Int = 32 * 1024) {
        file = KeyedLogStore(url: directory.appendingPathComponent("served_list.pbl", isDirectory: false),
                             compactionFloorBytes: compactionFloorBytes)
    }

    private func load() {
        if loaded { return }
        loaded = true
        file.open { _, payload in
            guard let record = try? JSONDecoder().decode(Record.self, from: Data(payload)),
                  record.v >= 1, record.v <= Self.formatVersion else { return }
            self.headers[record.recId] = Header(recId: record.recId, surface: record.surface, builtAtMs: record.builtAt,
                                                rids: record.rids)
        }
    }

    // MARK: Time

    /// The start of the local day `nowMs` is in; a day starts at 04:00 (10.3, rule 12).
    public static func dayStart(nowMs: Int64, tzOffsetMin: Int32) -> Int64 {
        Repetition.mixDay(nowMs, tzOffsetMin: tzOffsetMin) &* Repetition.dayMs &- Int64(tzOffsetMin) &* 60_000 &+ 14_400_000
    }

    /// `(builtAtMs << 8) | (0xA0 + surface)`: unique per build, time-ordered, like an event id.
    public static func recIdOf(builtAtMs: Int64, surface: Int32) -> Int64 {
        (builtAtMs &<< 8) | Int64(0xA0 + surface)
    }

    // MARK: Read

    /// The mix of `surface` built on the local day of `nowMs`, newest build, or nil.
    public func todays(surface: Int32, nowMs: Int64, tzOffsetMin: Int32) -> StoredMix? {
        load()
        let since = Self.dayStart(nowMs: nowMs, tzOffsetMin: tzOffsetMin)
        var best: Header?
        for header in headers.values where header.surface == surface && header.builtAtMs >= since {
            if best == nil || header.builtAtMs > best!.builtAtMs { best = header }
        }
        // A list built on today's day by a clock that was later set back is not today's.
        guard let best, best.builtAtMs <= nowMs + Self.clockSlackMs,
              let payload = file.payload(for: String(best.recId)),
              let record = try? JSONDecoder().decode(Record.self, from: Data(payload)),
              record.v >= 1, record.v <= Self.formatVersion else { return nil }
        guard let mix = record.mix, mix.v >= 1, mix.v <= StoredMix.formatVersion else { return nil }
        return mix
    }

    /// How many lists `surface` already got today: the draw number of the next "Regenerate".
    public func buildsToday(surface: Int32, nowMs: Int64, tzOffsetMin: Int32) -> Int32 {
        load()
        let since = Self.dayStart(nowMs: nowMs, tzOffsetMin: tzOffsetMin)
        var count: Int32 = 0
        for header in headers.values where header.surface == surface && header.builtAtMs >= since { count += 1 }
        return count
    }

    /// Every list of the last `Repetition.retentionMs`, oldest first, as the budget reads them.
    public func recent(nowMs: Int64) -> [Repetition.Served] {
        load()
        let after = Repetition.keepAfter(nowMs)
        return headers.values.filter { $0.builtAtMs >= after }
            .sorted { $0.builtAtMs != $1.builtAtMs ? $0.builtAtMs < $1.builtAtMs : $0.recId < $1.recId }
            .map { Repetition.Served(surface: $0.surface, builtAtMs: $0.builtAtMs, rids: $0.rids) }
    }

    public var count: Int {
        load()
        return headers.count
    }

    // MARK: Write

    /// Stores `mix` under `surface` and forgets what is older than the retention. Returns its `recId`; 0 when the
    /// file could not be written.
    @discardableResult
    public func put(surface: Int32, surfaceId: String, mix: StoredMix, nuQ: Int32, nowMs: Int64,
                    modelVersion: Int32 = Brain.specVersion) -> Int64 {
        load()
        let recId = Self.recIdOf(builtAtMs: mix.builtAtMs, surface: surface)
        let rids = mix.items.map(\.rid)
        let record = Record(v: Self.formatVersion, recId: recId, surface: surface, surfaceId: surfaceId,
                            builtAt: mix.builtAtMs, seed: mix.seed, modelVersion: modelVersion, nuQ: nuQ, rids: rids, mix: mix)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record), file.put(String(recId), [UInt8](data)) else { return 0 }
        headers[recId] = Header(recId: recId, surface: surface, builtAtMs: mix.builtAtMs, rids: rids)
        prune(nowMs: nowMs)
        return recId
    }

    /// Drops the lists older than the retention.
    func prune(nowMs: Int64) {
        let after = Repetition.keepAfter(nowMs)
        let doomed = headers.values.filter { $0.builtAtMs < after }.map(\.recId)
        if doomed.isEmpty { return }
        if file.remove(doomed.map { String($0) }) {
            for id in doomed { headers[id] = nil }
            file.compactIfNeeded()
        }
    }
}
