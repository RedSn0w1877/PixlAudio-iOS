// The event log and the affinity rows on disk (docs/brain-spec.md, 3.8, 4.1), each a `KeyedLogStore` file under
// `Application Support/Brain/`:
//
//   play_event.pbl    eventId -> the event's canonical JSON line (`PlayEvent.encode`)      truth, never trimmed
//   affinity.pbl      storedFamily|key -> [posQ,negQ,lastMs,posRQ,negRQ,lastRMs]          cache of the log
//   brain_state.pbl   name -> text                                                        small values
//   engine_plays.pbl  rid -> [longAtMs,shortAtMs...]                                      cache of the log (6.1)
//   learner_liked.pbl "liked" -> the favourites the last replay used, one value (stage 3 review: its own file, so the learner's
//                     per-play writes never make the file that holds it compact)
//
// Read on first use, never at app start. Not thread-safe: `BrainEngine` (an actor) owns it. The iOS twin of
// Android's `play_event`, `affinity` and `brain_state` tables and its `BrainStore.kt`.

import Foundation

/// The brain's own files: the event log, the affinity rows, and a few named values.
public final class BrainEventLog {
    public static let keyOpenPlay = "open_play"
    public static let keyFirstUseMs = "first_use_ms"
    /// When the first play recorded live started: the legacy history is copied only up to there.
    public static let keyFirstLiveStartMs = "first_live_start_ms"
    public static let keyHistoryMigrated = "history_migrated_ms"
    public static let keySpecVersion = "affinity_spec_version"
    public static let keyImportCount = "import_count"
    /// The switch "Use my Spotify music to shape picks" as of the last rebuild.
    public static let keySpotifyShapes = "spotify_shapes_picks"
    public static let keyRebuiltAtMs = "affinity_rebuilt_at_ms"
    /// The newest plays a Home row may be built around (`HomeAnchors`).
    public static let keyHomeAnchors = "home_anchors_v1"
    /// Set once the ignore tally holds every engine-served play of the log.
    public static let keyIgnoreTally = "ignore_tally_v1"
    /// The learner's saved state (`LearnerCodec`); a value of `brain_state`, no file changed (stage 3).
    public static let keyLearner = "learner_v1"
    /// `LearnReplay.version` of the last replay; absent or different means the learner is rebuilt.
    public static let keyLearnVersion = "learn_version"
    /// The favourites the last replay used, base 36, comma separated.
    public static let keyLearnerLiked = "learner_liked_v1"
    /// The event id at or below which plays are not learned from (set by "Reset what I've learned").
    public static let keyLearnAfter = "learn_after_event_id"
    /// The arm bandit and the novelty appetite (`PosteriorCodec`); a value of `brain_state`, no file changed (stage 3 completion).
    public static let keyPosteriors = "posteriors_v1"

    private let eventFile: KeyedLogStore
    private let affinityFile: KeyedLogStore
    private let stateFile: KeyedLogStore
    private let ignoreFile: KeyedLogStore
    private let likedFile: KeyedLogStore

    private var stateLoaded = false
    private var state: [BrainKey: String] = [:]

    public init(directory: URL, compactionFloorBytes: Int = 32 * 1024) {
        func file(_ name: String) -> KeyedLogStore {
            KeyedLogStore(url: directory.appendingPathComponent(name, isDirectory: false),
                          compactionFloorBytes: compactionFloorBytes)
        }
        eventFile = file("play_event.pbl")
        affinityFile = file("affinity.pbl")
        stateFile = file("brain_state.pbl")
        ignoreFile = file("engine_plays.pbl")
        likedFile = file("learner_liked.pbl")
    }

    private var eventsOpened = false
    private var affinityOpened = false

    /// The files are read on first use. (`KeyedLogStore` opens itself on a read or a write, not on `contains`.)
    private func openEvents() {
        if eventsOpened { return }
        eventsOpened = true
        eventFile.put([])
    }

    private func openAffinity() {
        if affinityOpened { return }
        affinityOpened = true
        affinityFile.put([])
    }

    // MARK: Events (4.1)

    /// True when an event is stored under `eventId`.
    public func hasEvent(_ eventId: Int64) -> Bool {
        openEvents()
        return eventFile.contains(String(eventId))
    }

    /// The identity (`PlayEvent.identityOf`) of the event stored under `eventId`, or nil when the id is free.
    public func eventIdentity(at eventId: Int64) -> String? {
        openEvents()
        guard let payload = eventFile.payload(for: String(eventId)),
              let event = PlayEvent.decode(String(decoding: payload, as: UTF8.self)) else { return nil }
        return PlayEvent.identityOf(origin: event.origin, keyAtWrite: event.keyAtWrite)
    }

    /// Appends the events whose id is not stored yet, in one write. Returns how many were new.
    @discardableResult
    public func insert(_ events: [PlayEvent]) -> Int {
        var records: [(key: String, payload: [UInt8])] = []
        var seen: Set<Int64> = []
        for event in events where !hasEvent(event.eventId) && seen.insert(event.eventId).inserted {
            records.append((String(event.eventId), Array(event.encode().utf8)))
        }
        if records.isEmpty { return 0 }
        return eventFile.put(records) ? records.count : 0
    }

    /// The events that started at or after `sinceMs`, oldest first. An event id is `(startedAtMs << 16) | seq`, so the
    /// keys say which events are wanted and only those are read: the refresh and the mixes look at the last weeks,
    /// never at the whole log.
    public func events(startedSince sinceMs: Int64) -> [PlayEvent] {
        openEvents()
        let floor = sinceMs &<< 16
        var out: [PlayEvent] = []
        for key in eventFile.keys {
            guard let id = Int64(key), id >= floor, let payload = eventFile.payload(for: key),
                  let event = PlayEvent.decode(String(decoding: payload, as: UTF8.self)) else { continue }
            out.append(event)
        }
        out.sort { $0.eventId < $1.eventId }
        return out
    }

    /// Every stored event in ascending `eventId`: the order a replay is defined on. Reads the whole file.
    public func allEvents() -> [PlayEvent] {
        var out: [PlayEvent] = []
        eventsOpened = true
        eventFile.open { _, payload in
            if let event = PlayEvent.decode(String(decoding: payload, as: UTF8.self)) { out.append(event) }
        }
        out.sort { $0.eventId < $1.eventId }
        return out
    }

    /// The bytes of every stored event, in no particular order: the file is read here and nothing is decoded, so the
    /// caller can decode them off the actor that owns the log (`decodeSorted`).
    public func allEventPayloads() -> [[UInt8]] {
        var out: [[UInt8]] = []
        eventsOpened = true
        eventFile.open { _, payload in out.append(Array(payload)) }
        return out
    }

    /// The bytes of the events that started at or after `sinceMs` (see `events(startedSince:)`).
    public func eventPayloads(startedSince sinceMs: Int64) -> [[UInt8]] {
        openEvents()
        let floor = sinceMs &<< 16
        var out: [[UInt8]] = []
        for key in eventFile.keys {
            guard let id = Int64(key), id >= floor, let payload = eventFile.payload(for: key) else { continue }
            out.append(payload)
        }
        return out
    }

    /// The events behind `payloads`, in ascending `eventId` (the order a replay is defined on). Pure: call it anywhere.
    public static func decodeSorted(_ payloads: [[UInt8]]) -> [PlayEvent] {
        var out: [PlayEvent] = []
        out.reserveCapacity(payloads.count)
        for payload in payloads {
            if let event = PlayEvent.decode(String(decoding: payload, as: UTF8.self)) { out.append(event) }
        }
        out.sort { $0.eventId < $1.eventId }
        return out
    }

    /// Sets or clears `flag` on the stored events with these ids, in one write. Returns how many changed.
    @discardableResult
    public func setEventFlag(_ eventIds: [Int64], flag: Int32, on: Bool) -> Int {
        openEvents()
        var records: [(key: String, payload: [UInt8])] = []
        for id in eventIds {
            guard let payload = eventFile.payload(for: String(id)),
                  var event = PlayEvent.decode(String(decoding: payload, as: UTF8.self)),
                  event.has(flag) != on else { continue }
            event.flags = on ? (event.flags | flag) : (event.flags & ~flag)
            records.append((String(id), Array(event.encode().utf8)))
        }
        if records.isEmpty { return 0 }
        return eventFile.put(records) ? records.count : 0
    }

    public var eventCount: Int {
        openEvents()
        return eventFile.count
    }

    /// Every stored event the engine served (it has an arm), in no particular order. Reads the whole file, but
    /// decodes only those lines: a line that says `"arm":9` (none) is skipped on its bytes.
    public func engineServedEvents() -> [PlayEvent] {
        var out: [PlayEvent] = []
        let none = Array("\"arm\":\(Arm.none),".utf8)
        eventsOpened = true
        eventFile.open { _, payload in
            if Self.contains(payload, none) { return }
            if let event = PlayEvent.decode(String(decoding: payload, as: UTF8.self)), event.arm != Arm.none {
                out.append(event)
            }
        }
        return out
    }

    static func contains(_ haystack: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let first = needle[0]
        var i = haystack.startIndex
        let last = haystack.endIndex - needle.count
        while i <= last {
            if haystack[i] == first {
                var j = 1
                while j < needle.count && haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    // MARK: Ignored three times (6.1)

    /// The tally as stored. The first time ever it is built from the log's own engine-served plays, then kept
    /// current by `noteEngineServed`.
    public func loadIgnoreTally(nowMs: Int64) -> IgnoreTally {
        var tally = IgnoreTally()
        ignoreFile.open { key, payload in
            guard let rid = Int64(key), let numbers = Self.decodeNumbers(payload),
                  let row = IgnoreTally.decode(numbers) else { return }
            tally.load(rid: rid, row: row)
        }
        if value(Self.keyIgnoreTally) == nil {
            var records: [(key: String, payload: [UInt8])] = []
            for event in engineServedEvents() {
                if let row = tally.note(event) { records.append((String(event.rid), IgnoreTally.encode(row))) }
            }
            if !records.isEmpty { ignoreFile.put(records) }
            setValue(Self.keyIgnoreTally, "1")
        }
        let expired = tally.expired(nowMs: nowMs)
        if !expired.isEmpty {
            tally.remove(expired)
            ignoreFile.remove(expired.map { String($0) })
            ignoreFile.compactIfNeeded()
        }
        return tally
    }

    public func putIgnoreRow(rid: Int64, _ row: IgnoreTally.Row) {
        ignoreFile.put(String(rid), IgnoreTally.encode(row))
    }

    // MARK: Affinity rows (5.2)

    static func affinityKey(_ family: Int32, _ key: Int64) -> String { "\(family)|\(key)" }

    static func encode(_ k: Affinity.Counter) -> [UInt8] {
        Array("[\(k.posQ),\(k.negQ),\(k.lastMs),\(k.posRQ),\(k.negRQ),\(k.lastRMs)]".utf8)
    }

    static func decodeNumbers(_ payload: ArraySlice<UInt8>) -> [Int64]? {
        guard payload.count >= 2, payload.first == 0x5B, payload.last == 0x5D else { return nil }
        var out: [Int64] = []
        for part in payload.dropFirst().dropLast().split(separator: 0x2C, omittingEmptySubsequences: false) {
            guard let value = Int64(String(decoding: part, as: UTF8.self)) else { return nil }
            out.append(value)
        }
        return out
    }

    /// Loads every stored row into `state`.
    public func loadAffinity(into state: inout Affinity.State) {
        var rows: [Affinity.Row] = []
        affinityOpened = true
        affinityFile.open { key, payload in
            let parts = key.utf8.split(separator: 0x7C, maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let family = Int32(String(decoding: parts[0], as: UTF8.self)),
                  let rowKey = Int64(String(decoding: parts[1], as: UTF8.self)),
                  let n = Self.decodeNumbers(payload), n.count == 6 else { return }
            rows.append(Affinity.Row(family: family, key: rowKey,
                                     counter: Affinity.Counter(posQ: n[0], negQ: n[1], lastMs: n[2], posRQ: n[3],
                                                               negRQ: n[4], lastRMs: n[5])))
        }
        for row in rows {
            let k = row.counter
            state.load(storedFamily: row.family, key: row.key, posQ: k.posQ, negQ: k.negQ, lastMs: k.lastMs,
                       posRQ: k.posRQ, negRQ: k.negRQ, lastRMs: k.lastRMs)
        }
    }

    public func upsertAffinity(_ rows: [Affinity.Row]) {
        if rows.isEmpty { return }
        affinityFile.put(rows.map { (Self.affinityKey($0.family, $0.key), Self.encode($0.counter)) })
    }

    /// Replaces every stored row with `rows` (after a rebuild).
    public func replaceAffinity(_ rows: [Affinity.Row]) {
        openAffinity()
        let keep = Set(rows.map { BrainKey(Self.affinityKey($0.family, $0.key)) })
        let doomed = affinityFile.keys.filter { !keep.contains(BrainKey($0)) }
        if !doomed.isEmpty { affinityFile.remove(doomed) }
        upsertAffinity(rows)
        affinityFile.compactIfNeeded()
    }

    public var affinityRowCount: Int {
        openAffinity()
        return affinityFile.count
    }

    // MARK: The favourites the learner was trained with

    private static let likedKey = "liked"

    /// The favourites the last replay used (base 36, comma separated): from their own file, else from the `brain_state` value an
    /// earlier build wrote.
    public func likedText() -> String? {
        likedFile.open()
        if let payload = likedFile.payload(for: Self.likedKey) { return String(decoding: payload, as: UTF8.self) }
        return value(Self.keyLearnerLiked)
    }

    public func setLikedText(_ text: String) {
        likedFile.open()
        likedFile.put(Self.likedKey, Array(text.utf8))
        setValue(Self.keyLearnerLiked, nil)
    }

    // MARK: Named values

    private func loadState() {
        if stateLoaded { return }
        stateLoaded = true
        stateFile.open { key, payload in self.state[BrainKey(key)] = String(decoding: payload, as: UTF8.self) }
    }

    public func value(_ name: String) -> String? {
        loadState()
        return state[BrainKey(name)]
    }

    /// Stores `value` under `name`; nil removes it. A value is one line of text.
    public func setValue(_ name: String, _ value: String?) {
        loadState()
        if let value {
            if let old = state[BrainKey(name)], BrainKey.sameBytes(old, value) { return }
            state[BrainKey(name)] = value
            stateFile.put(name, Array(value.utf8))
        } else if state[BrainKey(name)] != nil {
            state[BrainKey(name)] = nil
            stateFile.remove([name])
        }
    }
}
