import Foundation
import PixlModel
import SwiftData

// Search history (Android `SearchHistoryDao` + `MusicRepositoryImpl.addSearchHistoryItem` & co.). Android records a
// query when it is submitted or a result is opened; its Search screen doesn't list the history, but backups carry it.
extension PersistenceActor {
    /// `addSearchHistoryItem`: drops earlier rows with the same query, then inserts it with the current time.
    func addSearchHistoryItem(_ query: String, timestamp: Int64 = currentTimeMillis()) throws {
        try modelContext.delete(model: SearchHistoryRecord.self, where: #Predicate { $0.query == query })
        modelContext.insert(SearchHistoryRecord(query: query, timestamp: timestamp))
        try modelContext.save()
    }

    /// `getRecentSearches(limit)`: newest first.
    func recentSearchHistory(limit: Int = 15) throws -> [SearchHistoryItem] {
        var descriptor = FetchDescriptor<SearchHistoryRecord>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map { SearchHistoryItem(id: nil, query: $0.query, timestamp: $0.timestamp) }
    }

    /// `deleteSearchHistoryItemByQuery`.
    func deleteSearchHistoryItem(query: String) throws {
        try modelContext.delete(model: SearchHistoryRecord.self, where: #Predicate { $0.query == query })
        try modelContext.save()
    }

    /// `clearSearchHistory`.
    func clearSearchHistory() throws {
        try modelContext.delete(model: SearchHistoryRecord.self)
        try modelContext.save()
    }
}
