import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel
import SwiftData

// Search history (Android `SearchHistoryDao` + `MusicRepositoryImpl`, main database version 6). Every decision (the
// key, the upsert, the 50-row cap, the private rule, the merge) is `SearchHistoryRules` in PixlCore; this file loads
// the rows (at most 50, so a whole read is cheap), asks the rules, and writes back what changed. Reads happen once
// when Search appears and after a write, never per keystroke: the model keeps the answer and filters it in memory.
extension PersistenceActor {
    // MARK: Mapping

    nonisolated private static func item(_ record: SearchHistoryRecord) -> SearchHistoryItem {
        SearchHistoryItem(id: nil, query: record.query, timestamp: record.timestamp, key: record.key,
                          kind: record.kind.flatMap(SearchHistoryKind.init(rawValue:)), targetId: record.targetId,
                          targetTitle: record.targetTitle, imageUrl: record.imageUrl, count: max(1, record.count))
    }

    nonisolated private static func fill(_ record: SearchHistoryRecord, from item: SearchHistoryItem) {
        record.query = item.query
        record.key = item.key
        record.kind = item.kind?.rawValue
        record.targetId = item.targetId
        record.targetTitle = item.targetTitle
        record.imageUrl = item.imageUrl
        record.timestamp = item.timestamp
        record.count = item.count
    }

    private func records() throws -> [SearchHistoryRecord] {
        try modelContext.fetch(FetchDescriptor<SearchHistoryRecord>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)]))
    }

    /// Makes the stored rows equal `items`: one row per key (a second row of a key goes), rows of other keys go, new
    /// keys are inserted, the rest updated in place. Saves once.
    private func write(_ items: [SearchHistoryItem], over existing: [SearchHistoryRecord]) throws {
        var wanted: [String: SearchHistoryItem] = [:]
        for item in items { wanted[item.key] = item }
        var seen = Set<String>()
        for record in existing {
            if let item = wanted[record.key], seen.insert(record.key).inserted {
                Self.fill(record, from: item)
            } else {
                modelContext.delete(record)
            }
        }
        for item in items where !seen.contains(item.key) {
            let record = SearchHistoryRecord(query: item.query, timestamp: item.timestamp)
            Self.fill(record, from: item)
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    /// Rows saved before version 2 have no key. The first read after the update folds them, merges the ones that
    /// fold alike (counts added) and trims to the cap. One cheap fetch every time until it has run once.
    private func fillSearchHistoryKeys() throws {
        guard !searchHistoryKeysFilled else { return }
        var probe = FetchDescriptor<SearchHistoryRecord>(predicate: #Predicate { $0.key == "" })
        probe.fetchLimit = 1
        if try !modelContext.fetch(probe).isEmpty {
            let all = try records()
            let merged = SearchHistoryRules.merged(all.map(Self.item), with: [], counts: .sum)
            try write(merged, over: all)
        }
        searchHistoryKeysFilled = true
    }

    // MARK: API

    /// The history, newest first, at most 50 rows (Search's one read).
    func searchHistory() throws -> [SearchHistoryItem] {
        try fillSearchHistoryKeys()
        return SearchHistoryRules.capped(try records().map(Self.item))
    }

    /// Records a submitted search or an opened result (no-op during a private session, for a text too short to store).
    /// Returns the history after the write; nil when nothing was written.
    @discardableResult
    func recordSearchHistory(_ input: SearchHistoryInput, isPrivate: Bool,
                             now: Int64 = currentTimeMillis()) throws -> [SearchHistoryItem]? {
        guard SearchHistoryRules.shouldRecord(isPrivate: isPrivate), SearchHistoryRules.normalize(input.query) != nil else {
            return nil
        }
        try fillSearchHistoryKeys()
        let existing = try records()
        let next = SearchHistoryRules.record(into: existing.map(Self.item), input, isPrivate: false, now: now)
        try write(next, over: existing)
        return next
    }

    /// Removes the row of one key; returns the history after.
    @discardableResult
    func removeSearchHistory(key: String) throws -> [SearchHistoryItem] {
        try fillSearchHistoryKeys()
        let existing = try records()
        let next = existing.map(Self.item).filter { $0.key != key }
        try write(next, over: existing)
        return SearchHistoryRules.capped(next)
    }

    /// Android `clearSearchHistory`.
    func clearSearchHistory() throws {
        try modelContext.delete(model: SearchHistoryRecord.self)
        try modelContext.save()
        searchHistoryKeysFilled = true
    }

    /// Puts rows back (Undo of a remove or Clear all) or restores a backup: merged into what is there by key, never
    /// clearing, counts taken as the larger of the two, capped at 50. Returns the history after.
    @discardableResult
    func restoreSearchHistory(_ items: [SearchHistoryItem]) throws -> [SearchHistoryItem] {
        try fillSearchHistoryKeys()
        let existing = try records()
        let next = SearchHistoryRules.merged(existing.map(Self.item), with: items, counts: .max)
        try write(next, over: existing)
        return next
    }
}
