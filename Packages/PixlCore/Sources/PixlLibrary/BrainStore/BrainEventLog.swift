// The event log and the affinity rows on disk (docs/brain-spec.md, 3.8, 4.1), each a `KeyedLogStore` file under
// `Application Support/Brain/`:
//
//   play_event.pbl    eventId -> the event's canonical JSON line (`PlayEvent.encode`)      truth, never trimmed
//   affinity.pbl      storedFamily|key -> [posQ,negQ,lastMs,posRQ,negRQ,lastRMs]          cache of the log
//   brain_state.pbl   name -> text                                                        small values
//
// Read on first use, never at app start. Not thread-safe: `BrainEngine` (an actor) owns it. The iOS twin of
// Android's `play_event`, `affinity` and `brain_state` tables and its `BrainStore.kt`.

import Foundation

/// The brain's own files: the event log, the affinity rows, and a few named values.
public final class BrainEventLog {
    public static let keyOpenPlay = "open_play"
    public static let keyFirstUseMs = "first_use_ms"
    public static let keyHistoryMigrated = "history_migrated_ms"
    public static let keySpecVersion = "affinity_spec_version"
    public static let keyImportCount = "import_count"
    public static let keyRebuiltAtMs = "affinity_rebuilt_at_ms"

    private let eventFile: KeyedLogStore
    private let affinityFile: KeyedLogStore
    private let stateFile: KeyedLogStore

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

    public var eventCount: Int {
        openEvents()
        return eventFile.count
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
