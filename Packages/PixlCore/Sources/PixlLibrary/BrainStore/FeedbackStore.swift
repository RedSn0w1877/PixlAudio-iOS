// Things the listener told the brain that are not a taste adjustment (docs/brain-spec.md, 3.8 `feedback`): "Don't learn
// from this" and the spans of a private session arrive in the next milestone of stage 2. The file is here now so that
// milestone needs no second change to the format. "Not for me" is a `TasteAdjustments` mute, not a record here.
// A port of Android's `feedback` table (`FeedbackEntity`, `FeedbackDao`).
//
// It is truth, not cache: nothing may drop a record of it. File `feedback.pbl`:
//     `<id>`  ->  {"createdAtMs":..,"id":..,"kind":..,"targetId":..,"targetKind":..,"undoneAtMs":..|absent,"v":1}
// Nothing writes a record in stage 2a: the store is created, tested, and read by nobody.

import Foundation

public final class FeedbackStore {
    public static let formatVersion = 1

    public struct Record: Sendable, Hashable, Codable {
        public var v: Int
        public var id: Int64
        public var kind: Int32
        public var targetKind: Int32
        public var targetId: Int64
        public var createdAtMs: Int64
        public var undoneAtMs: Int64?

        public init(id: Int64, kind: Int32, targetKind: Int32, targetId: Int64, createdAtMs: Int64, undoneAtMs: Int64? = nil) {
            v = FeedbackStore.formatVersion
            self.id = id
            self.kind = kind
            self.targetKind = targetKind
            self.targetId = targetId
            self.createdAtMs = createdAtMs
            self.undoneAtMs = undoneAtMs
        }
    }

    private let file: KeyedLogStore
    private var loaded = false
    private var records: [Int64: Record] = [:]

    public init(directory: URL, compactionFloorBytes: Int = 32 * 1024) {
        file = KeyedLogStore(url: directory.appendingPathComponent("feedback.pbl", isDirectory: false),
                             compactionFloorBytes: compactionFloorBytes)
    }

    private func load() {
        if loaded { return }
        loaded = true
        file.open { _, payload in
            // A record of a version this code does not know is left where it is: it is not read and not deleted.
            guard let record = try? JSONDecoder().decode(Record.self, from: Data(payload)),
                  record.v >= 1, record.v <= Self.formatVersion else { return }
            self.records[record.id] = record
        }
    }

    private static func payload(_ record: Record) -> [UInt8]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(record)).map { [UInt8]($0) }
    }

    @discardableResult
    public func insert(_ record: Record) -> Bool {
        load()
        guard let payload = Self.payload(record), file.put(String(record.id), payload) else { return false }
        records[record.id] = record
        return true
    }

    @discardableResult
    public func undo(id: Int64, nowMs: Int64) -> Bool {
        load()
        guard var record = records[id], record.undoneAtMs == nil else { return false }
        record.undoneAtMs = nowMs
        return insert(record)
    }

    /// The records that were not undone, oldest first.
    public func active() -> [Record] {
        load()
        return records.values.filter { $0.undoneAtMs == nil }
            .sorted { $0.createdAtMs != $1.createdAtMs ? $0.createdAtMs < $1.createdAtMs : $0.id < $1.id }
    }

    /// Every record, undone ones too, oldest first (the backup holds them all).
    public func all() -> [Record] {
        load()
        return records.values.sorted { $0.createdAtMs != $1.createdAtMs ? $0.createdAtMs < $1.createdAtMs : $0.id < $1.id }
    }

    /// Puts a whole set of records in place (a restored backup): what was there and is not in `list` goes.
    public func replaceAll(_ list: [Record]) {
        load()
        let keep = Set(list.map(\.id))
        let doomed = records.keys.filter { !keep.contains($0) }
        if !doomed.isEmpty {
            file.remove(doomed.map { String($0) })
            for id in doomed { records[id] = nil }
        }
        for record in list { insert(record) }
    }

    public var count: Int {
        load()
        return records.count
    }
}
