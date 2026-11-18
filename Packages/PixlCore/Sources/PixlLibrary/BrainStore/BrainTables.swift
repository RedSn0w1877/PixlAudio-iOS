// The stage 1 tables of the music brain on iOS (docs/brain-spec.md, 3.8), each one a `KeyedLogStore` file under
// `Application Support/Brain/`:
//
//   track_alias.pbl   key -> [rid, durationMs]            identity (3.1); truth
//   track_merge.pbl   rid -> into                         identity; truth
//   artist_alias.pbl  key -> [aid, 0]                     identity; truth (nothing resolves artists before 1b)
//   radio_list.pbl    seedRid|kind|chip -> list facts     cache
//   radio_rows.pbl    seedRid|kind|chip -> parsed rows    cache (apart from the facts, so a "last used" touch
//                                                          rewrites a hundred bytes, not the rows)
//   playable.pbl      song id -> how an outside track is shown and played (7.2); cache
//
// `play_event` (monthly segments), `affinity` and `brain_state` arrive with the event recorder (milestone 1b): a
// record file needs no schema, so there is nothing to create ahead of time.
//
// Each table is read on first use, never at app start. Not thread-safe: `BrainRepository` (an actor) owns it.

import Foundation
import PixlModel

/// How an outside track is shown and played (`playable`, 7.2). The key is the id the track plays under,
/// `yt:<videoId>`: the same id the YouTube Music importer gives the track when the listener saves it.
public struct PlayableRecord: Sendable, Hashable, Codable {
    public var songId: String
    public var rid: Int64
    public var videoId: String
    public var title: String
    /// Credited artists, primary first; never a joined display string.
    public var artists: [RadioArtistRef]
    public var album: String?
    public var durationMs: Int64
    public var artUrl: String?
    public var lastUsedAt: Int64

    public init(songId: String, rid: Int64, videoId: String, title: String, artists: [RadioArtistRef], album: String?,
                durationMs: Int64, artUrl: String?, lastUsedAt: Int64) {
        self.songId = songId
        self.rid = rid
        self.videoId = videoId
        self.title = title
        self.artists = artists
        self.album = album
        self.durationMs = durationMs
        self.artUrl = artUrl
        self.lastUsedAt = lastUsedAt
    }
}

/// The facts of one stored list, without its rows.
public struct RadioListFacts: Sendable, Hashable, Codable {
    public var seedRid: Int64
    public var kind: Int
    public var chip: String
    public var fetchedAt: Int64
    public var lastUsedAt: Int64
    public var healthy: Bool
    public var chips: [RadioChip]
}

/// One track to resolve: the keys the caller has and the length it knows.
public struct TrackRequest: Sendable {
    public var keys: Ids.TrackKeys
    public var durationMs: Int32

    public init(keys: Ids.TrackKeys, durationMs: Int32) {
        self.keys = keys
        self.durationMs = durationMs
    }
}

/// The stage 1 tables.
public final class BrainTables {
    /// `radio_list` holds at most this many lists; the least recently used go first.
    public static let maxRadioLists = 500
    /// `playable` rows nobody used for this long are deleted, unless the queue or the recent history names them.
    public static let playableRetentionMs: Int64 = 60 * 24 * 60 * 60 * 1000

    public let directory: URL

    private let trackAliasFile: KeyedLogStore
    private let trackMergeFile: KeyedLogStore
    private let artistAliasFile: KeyedLogStore
    private let radioListFile: KeyedLogStore
    private let radioRowsFile: KeyedLogStore
    private let playableFile: KeyedLogStore

    private var identityLoaded = false
    private var trackAlias: [BrainKey: (rid: Int64, durationMs: Int32)] = [:]
    private var trackTaken: Set<Int64> = []
    private var videoIdsByRid: [Int64: [String]] = [:]
    private var merged: [Int64: Int64] = [:]

    private var artistsLoaded = false
    private var artistAlias: [BrainKey: Int64] = [:]
    private var artistTaken: Set<Int64> = []

    private var radiosLoaded = false
    private var radioFacts: [BrainKey: RadioListFacts] = [:]

    private var playableLoaded = false
    private var playable: [BrainKey: PlayableRecord] = [:]

    public init(directory: URL, compactionFloorBytes: Int = 32 * 1024) {
        self.directory = directory
        func file(_ name: String) -> KeyedLogStore {
            KeyedLogStore(url: directory.appendingPathComponent(name, isDirectory: false),
                          compactionFloorBytes: compactionFloorBytes)
        }
        trackAliasFile = file("track_alias.pbl")
        trackMergeFile = file("track_merge.pbl")
        artistAliasFile = file("artist_alias.pbl")
        radioListFile = file("radio_list.pbl")
        radioRowsFile = file("radio_rows.pbl")
        playableFile = file("playable.pbl")
    }

    // MARK: Identity (3.1)

    private func loadIdentity() {
        if identityLoaded { return }
        identityLoaded = true
        trackAliasFile.open { key, payload in
            guard let pair = Self.decodePair(payload) else { return }
            self.remember(alias: key, rid: pair.0, durationMs: Int32(truncatingIfNeeded: pair.1))
        }
        trackMergeFile.open { key, payload in
            guard let from = Int64(key), let into = Int64(String(decoding: payload, as: UTF8.self)) else { return }
            self.merged[from] = into
        }
    }

    private func remember(alias key: String, rid: Int64, durationMs: Int32) {
        trackAlias[BrainKey(key)] = (rid, durationMs)
        trackTaken.insert(rid)
        if key.utf8.starts(with: [0x79, 0x3A]) {
            videoIdsByRid[rid, default: []].append(String(decoding: key.utf8.dropFirst(2), as: UTF8.self))
        }
    }

    private struct TrackLookup: Ids.AliasLookup {
        let tables: BrainTables
        func idOf(_ key: String) -> Int64? { tables.trackAlias[BrainKey(key)]?.rid }
        func isTaken(_ id: Int64) -> Bool { tables.trackTaken.contains(id) }
        func survivorOf(_ id: Int64) -> Int64 { tables.merged[id] ?? id }
        func durationMsOf(_ key: String) -> Int32 { tables.trackAlias[BrainKey(key)]?.durationMs ?? 0 }
    }

    /// Rids for `requests`, in order; 0 for a request with no usable key. What is new is stored in one write.
    public func resolveTracks(_ requests: [TrackRequest]) -> [Int64] {
        loadIdentity()
        var out = [Int64](repeating: 0, count: requests.count)
        var aliasWrites: [(key: String, payload: [UInt8])] = []
        var mergeWrites: [(key: String, payload: [UInt8])] = []
        let lookup = TrackLookup(tables: self)
        for (i, request) in requests.enumerated() {
            guard let resolution = Ids.resolveTrack(request.keys, durationMs: request.durationMs, table: lookup) else {
                continue
            }
            trackTaken.insert(resolution.id)
            for alias in resolution.aliases {
                remember(alias: alias.key, rid: alias.id, durationMs: alias.durationMs)
                aliasWrites.append((alias.key, Self.encodePair(alias.id, Int64(alias.durationMs))))
            }
            for merge in resolution.merges {
                // Flatten at write time: whatever pointed at the merged rid now points at the survivor.
                let target = merged[merge.into] ?? merge.into
                if merge.from == target { continue }
                for (from, into) in merged where into == merge.from {
                    merged[from] = target
                    mergeWrites.append((String(from), Array(String(target).utf8)))
                }
                merged[merge.from] = target
                mergeWrites.append((String(merge.from), Array(String(target).utf8)))
            }
            out[i] = resolution.id
        }
        if !aliasWrites.isEmpty { trackAliasFile.put(aliasWrites) }
        if !mergeWrites.isEmpty { trackMergeFile.put(mergeWrites) }
        return out
    }

    public func resolveTrack(_ keys: Ids.TrackKeys, durationMs: Int32) -> Int64 {
        resolveTracks([TrackRequest(keys: keys, durationMs: durationMs)])[0]
    }

    /// The other YouTube audio ids known for `rid` (never `exceptVideoId`).
    public func otherVideoIds(rid: Int64, exceptVideoId: String?) -> [String] {
        loadIdentity()
        return (videoIdsByRid[rid] ?? []).filter { id in
            guard let exceptVideoId else { return true }
            return !BrainKey.sameBytes(id, exceptVideoId)
        }
    }

    /// Every merged recording and the one it was merged into (already flattened).
    public func trackMerges() -> [Int64: Int64] {
        loadIdentity()
        return merged
    }

    // MARK: Artists (3.1: stage 1 joins artists by folded name)

    private func loadArtists() {
        if artistsLoaded { return }
        artistsLoaded = true
        artistAliasFile.open { key, payload in
            guard let pair = Self.decodePair(payload) else { return }
            self.artistAlias[BrainKey(key)] = pair.0
            self.artistTaken.insert(pair.0)
        }
    }

    private struct ArtistLookup: Ids.AliasLookup {
        let tables: BrainTables
        func idOf(_ key: String) -> Int64? { tables.artistAlias[BrainKey(key)] }
        func isTaken(_ id: Int64) -> Bool { tables.artistTaken.contains(id) }
        func survivorOf(_ id: Int64) -> Int64 { id }
        func durationMsOf(_ key: String) -> Int32 { 0 }
    }

    /// Aids for `names` (ONE artist name each), in order; 0 for a name that folds to nothing. What is new is stored
    /// in one write.
    public func resolveArtistNames(_ names: [String]) -> [Int64] {
        loadArtists()
        var out = [Int64](repeating: 0, count: names.count)
        var writes: [(key: String, payload: [UInt8])] = []
        let lookup = ArtistLookup(tables: self)
        for (i, name) in names.enumerated() {
            guard let resolution = Ids.resolveArtist(Ids.ArtistKeys(name: name), table: lookup) else { continue }
            artistTaken.insert(resolution.id)
            for alias in resolution.aliases {
                artistAlias[BrainKey(alias.key)] = alias.id
                writes.append((alias.key, Self.encodePair(alias.id, 0)))
            }
            out[i] = resolution.id
        }
        if !writes.isEmpty { artistAliasFile.put(writes) }
        return out
    }

    public var trackAliasCount: Int {
        loadIdentity()
        return trackAlias.count
    }

    // MARK: Radio lists (3.8 `radio_list`)

    static func radioKey(_ seedRid: Int64, _ kind: Int, _ chip: String) -> String { "\(seedRid)|\(kind)|\(chip)" }

    private func loadRadios() {
        if radiosLoaded { return }
        radiosLoaded = true
        radioListFile.open { key, payload in
            guard let facts = try? JSONDecoder().decode(RadioListFacts.self, from: Data(payload)) else { return }
            self.radioFacts[BrainKey(key)] = facts
        }
    }

    public func radioFacts(seedRid: Int64, kind: Int, chip: String) -> RadioListFacts? {
        loadRadios()
        return radioFacts[BrainKey(Self.radioKey(seedRid, kind, chip))]
    }

    public func radioRows(seedRid: Int64, kind: Int, chip: String) -> [StoredRadioRow] {
        loadRadios()
        guard let payload = radioRowsFile.payload(for: Self.radioKey(seedRid, kind, chip)) else { return [] }
        return (try? JSONDecoder().decode([StoredRadioRow].self, from: Data(payload))) ?? []
    }

    public func touchRadio(seedRid: Int64, kind: Int, chip: String, nowMs: Int64) {
        loadRadios()
        let key = Self.radioKey(seedRid, kind, chip)
        guard var facts = radioFacts[BrainKey(key)] else { return }
        facts.lastUsedAt = nowMs
        radioFacts[BrainKey(key)] = facts
        if let payload = Self.encode(facts) { radioListFile.put(key, payload) }
    }

    public func upsertRadio(_ list: RadioList) {
        loadRadios()
        let key = Self.radioKey(list.seedRid, list.kind, list.chip)
        let facts = RadioListFacts(seedRid: list.seedRid, kind: list.kind, chip: list.chip, fetchedAt: list.fetchedAt,
                                   lastUsedAt: list.lastUsedAt, healthy: list.healthy, chips: list.chips)
        guard let factsPayload = Self.encode(facts), let rowsPayload = Self.encode(list.rows) else { return }
        radioFacts[BrainKey(key)] = facts
        radioListFile.put(key, factsPayload)
        radioRowsFile.put(key, rowsPayload)
        if radioFacts.count > Self.maxRadioLists { trimRadios(to: Self.maxRadioLists) }
    }

    /// How many lists were fetched at or after `sinceMs` (the daily budget survives a restart through this).
    public func radiosFetchedSince(_ sinceMs: Int64) -> Int {
        loadRadios()
        var count = 0
        for facts in radioFacts.values where facts.fetchedAt >= sinceMs { count += 1 }
        return count
    }

    public var radioCount: Int {
        loadRadios()
        return radioFacts.count
    }

    /// Keeps the `limit` most recently used lists.
    public func trimRadios(to limit: Int) {
        loadRadios()
        if radioFacts.count <= limit { return }
        // Oldest use first; ties by seed, kind and chip bytes, so the order never depends on a dictionary.
        let ordered = radioFacts.values.sorted { a, b in
            if a.lastUsedAt != b.lastUsedAt { return a.lastUsedAt < b.lastUsedAt }
            if a.seedRid != b.seedRid { return a.seedRid < b.seedRid }
            if a.kind != b.kind { return a.kind < b.kind }
            return a.chip.utf8.lexicographicallyPrecedes(b.chip.utf8)
        }
        let doomed = ordered.prefix(radioFacts.count - limit).map { Self.radioKey($0.seedRid, $0.kind, $0.chip) }
        for key in doomed { radioFacts[BrainKey(key)] = nil }
        radioListFile.remove(doomed)
        radioRowsFile.remove(doomed)
    }

    // MARK: Playable (7.2)

    private func loadPlayable() {
        if playableLoaded { return }
        playableLoaded = true
        playableFile.open { key, payload in
            guard let record = try? JSONDecoder().decode(PlayableRecord.self, from: Data(payload)) else { return }
            self.playable[BrainKey(key)] = record
        }
    }

    /// Stores `records` so the tracks can be shown and played after a restart. A record that is already stored with
    /// the same facts only has its "last used" time moved, and only when that is a day old: registering the same
    /// pool again writes nothing.
    public func registerPlayable(_ records: [PlayableRecord]) {
        loadPlayable()
        var writes: [(key: String, payload: [UInt8])] = []
        for record in records {
            let key = BrainKey(record.songId)
            if var existing = playable[key] {
                let fresh = record.lastUsedAt - existing.lastUsedAt < 24 * 60 * 60 * 1000
                existing.lastUsedAt = record.lastUsedAt
                if existing == record && fresh { continue }
            }
            guard let payload = Self.encode(record) else { continue }
            playable[key] = record
            writes.append((record.songId, payload))
        }
        if !writes.isEmpty { playableFile.put(writes) }
    }

    public func playable(songId: String) -> PlayableRecord? {
        loadPlayable()
        return playable[BrainKey(songId)]
    }

    public func allPlayable() -> [PlayableRecord] {
        loadPlayable()
        return Array(playable.values)
    }

    public var playableCount: Int {
        loadPlayable()
        return playable.count
    }

    /// Deletes rows nobody used for `playableRetentionMs`, except the ones in `keepSongIds` (the saved queue and
    /// the recent history). Returns how many went.
    @discardableResult
    public func prunePlayable(keepSongIds: Set<String>, nowMs: Int64) -> Int {
        loadPlayable()
        let keep = Set(keepSongIds.map(BrainKey.init))
        let cutoff = nowMs - Self.playableRetentionMs
        var doomed: [String] = []
        for (key, record) in playable where record.lastUsedAt < cutoff && !keep.contains(key) {
            doomed.append(key.text)
        }
        if doomed.isEmpty { return 0 }
        for key in doomed { playable[BrainKey(key)] = nil }
        playableFile.remove(doomed)
        return doomed.count
    }

    // MARK: Codecs

    static func encode<Value: Encodable>(_ value: Value) -> [UInt8]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return [UInt8](data)
    }

    /// `[a,b]`: the alias row's rid and length.
    static func encodePair(_ a: Int64, _ b: Int64) -> [UInt8] { Array("[\(a),\(b)]".utf8) }

    static func decodePair(_ payload: ArraySlice<UInt8>) -> (Int64, Int64)? {
        guard payload.count >= 5, payload.first == 0x5B, payload.last == 0x5D else { return nil }
        let inner = payload.dropFirst().dropLast()
        guard let comma = inner.firstIndex(of: 0x2C),
              let a = Int64(String(decoding: inner[inner.startIndex..<comma], as: UTF8.self)),
              let b = Int64(String(decoding: inner[(comma + 1)...], as: UTF8.self)) else { return nil }
        return (a, b)
    }
}
