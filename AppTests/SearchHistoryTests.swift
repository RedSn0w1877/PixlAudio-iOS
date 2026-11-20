import PixlBackup
import PixlLibrary
import PixlModel
import SwiftData
import XCTest
@testable import PixlAudio

/// Search history on the app side: the SwiftData layer over `SearchHistoryRules` (the rules themselves are tested in
/// PixlCore), the model's private-session gate, suggestions, Undo, backup and the migration from schema version 1.
@MainActor
final class SearchHistoryTests: XCTestCase {
    private func makePersistence() throws -> PersistenceActor {
        PersistenceActor(modelContainer: try PersistenceActor.makeContainer(inMemory: true))
    }

    private func makeModel(persistence: PersistenceActor?, isPrivate: @escaping @MainActor () -> Bool = { false }) -> SearchModel {
        let model = SearchModel()
        model.attach(providers: [:], persistence: persistence, isPrivate: isPrivate)
        return model
    }

    /// Fire-and-forget writes of the model finish on their own: wait for the condition.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    // MARK: Store

    func testRecordKeepsOneRowPerFoldedQueryNewestFirst() async throws {
        let persistence = try makePersistence()
        try await persistence.recordSearchHistory(SearchHistoryInput(query: "Beyonce"), isPrivate: false, now: 1)
        try await persistence.recordSearchHistory(SearchHistoryInput(query: "night"), isPrivate: false, now: 2)
        let rows = try await persistence.recordSearchHistory(SearchHistoryInput(query: "BEYONCÉ"), isPrivate: false, now: 3)
        XCTAssertEqual(rows?.map(\.query), ["BEYONCÉ", "night"])
        let stored = try await persistence.searchHistory()
        XCTAssertEqual(stored.map(\.key), ["beyonce", "night"])
        XCTAssertEqual(stored.first?.count, 2)
        XCTAssertEqual(stored.first?.timestamp, 3)
    }

    func testResultTapStoresKindAndTarget() async throws {
        let persistence = try makePersistence()
        try await persistence.recordSearchHistory(SearchHistoryInput(query: "luma", kind: .artist, targetId: "7",
                                                                     targetTitle: "Luma", imageUrl: "https://x/y.jpg"),
                                                  isPrivate: false, now: 1)
        let row = try await persistence.searchHistory().first
        XCTAssertEqual(row?.kind, .artist)
        XCTAssertEqual(row?.targetId, "7")
        XCTAssertEqual(row?.targetTitle, "Luma")
        XCTAssertEqual(row?.imageUrl, "https://x/y.jpg")
    }

    func testTheStoreIsCappedAt50() async throws {
        let persistence = try makePersistence()
        for i in 0..<57 {
            try await persistence.recordSearchHistory(SearchHistoryInput(query: "query \(i)"), isPrivate: false, now: Int64(i + 1))
        }
        let rows = try await persistence.searchHistory()
        XCTAssertEqual(rows.count, 50)
        XCTAssertEqual(rows.first?.query, "query 56")
        XCTAssertEqual(rows.last?.query, "query 7")
    }

    func testPrivateRecordWritesNothingAndBumpsNothing() async throws {
        let persistence = try makePersistence()
        try await persistence.recordSearchHistory(SearchHistoryInput(query: "keep"), isPrivate: false, now: 1)
        let result = try await persistence.recordSearchHistory(SearchHistoryInput(query: "keep"), isPrivate: true, now: 9)
        XCTAssertNil(result)
        try await persistence.recordSearchHistory(SearchHistoryInput(query: "secret"), isPrivate: true, now: 9)
        let rows = try await persistence.searchHistory()
        XCTAssertEqual(rows.map(\.query), ["keep"])
        XCTAssertEqual(rows.first?.count, 1)
        XCTAssertEqual(rows.first?.timestamp, 1)
    }

    func testTooShortQueriesAreNotStored() async throws {
        let persistence = try makePersistence()
        let result = try await persistence.recordSearchHistory(SearchHistoryInput(query: " a "), isPrivate: false, now: 1)
        XCTAssertNil(result)
        let rows = try await persistence.searchHistory()
        XCTAssertTrue(rows.isEmpty)
    }

    func testRemoveClearAndRestore() async throws {
        let persistence = try makePersistence()
        for (i, q) in ["alpha", "bravo", "charlie"].enumerated() {
            try await persistence.recordSearchHistory(SearchHistoryInput(query: q), isPrivate: false, now: Int64(i + 1))
        }
        var rows = try await persistence.removeSearchHistory(key: "bravo")
        XCTAssertEqual(rows.map(\.query), ["charlie", "alpha"])
        let all = try await persistence.searchHistory()
        try await persistence.clearSearchHistory()
        rows = try await persistence.searchHistory()
        XCTAssertTrue(rows.isEmpty)
        rows = try await persistence.restoreSearchHistory(all)
        XCTAssertEqual(rows.map(\.query), ["charlie", "alpha"])
    }

    func testRestoreMergesByKeyAndNeverClears() async throws {
        let persistence = try makePersistence()
        try await persistence.recordSearchHistory(SearchHistoryInput(query: "local"), isPrivate: false, now: 100)
        try await persistence.recordSearchHistory(SearchHistoryInput(query: "Beyonce"), isPrivate: false, now: 50)
        let backup = [SearchHistoryItem(query: "BEYONCÉ", timestamp: 40, count: 5), SearchHistoryItem(query: "other", timestamp: 60)]
        let rows = try await persistence.restoreSearchHistory(backup)
        XCTAssertEqual(rows.map(\.query), ["local", "other", "Beyonce"])
        XCTAssertEqual(rows.last?.count, 5)
        let again = try await persistence.restoreSearchHistory(backup)
        XCTAssertEqual(again, rows)
    }

    func testBackupRoundTripAndAnOldAndroidPayload() async throws {
        let persistence = try makePersistence()
        try await persistence.recordSearchHistory(SearchHistoryInput(query: "taylor", kind: .artist, targetId: "42",
                                                                     targetTitle: "Taylor Swift"), isPrivate: false, now: 5)
        let payload = SearchHistoryModule.export(try await persistence.backupSearchHistory())
        let fresh = try makePersistence()
        try await fresh.restoreSearchHistory(try SearchHistoryModule.restore(payload: payload))
        let restored = try await fresh.searchHistory()
        XCTAssertEqual(restored.first?.kind, .artist)
        XCTAssertEqual(restored.first?.targetTitle, "Taylor Swift")
        // What Android wrote before keys existed: id, query, timestamp.
        let old = #"[{"id":1,"query":"Sơn Tùng","timestamp":10},{"id":2,"query":"son tung","timestamp":20}]"#
        try await fresh.restoreSearchHistory(try SearchHistoryModule.restore(payload: old))
        let merged = try await fresh.searchHistory()
        XCTAssertEqual(merged.map(\.key), ["son tung", "taylor"])
        XCTAssertEqual(merged.first?.query, "son tung")
    }

    // MARK: Migration from version 1

    func testRowsOfSchemaV1SurviveTheMigrationAndGetKeys() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("search-history-\(UUID().uuidString).store")
        defer { for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        do {
            let v1 = Schema(versionedSchema: SchemaV1.self)
            let container = try ModelContainer(for: v1, configurations: [ModelConfiguration(schema: v1, url: url)])
            let context = ModelContext(container)
            context.insert(SchemaV1.SearchHistoryRecord(query: "Beyonce", timestamp: 10))
            context.insert(SchemaV1.SearchHistoryRecord(query: "BEYONCÉ", timestamp: 30))
            context.insert(SchemaV1.SearchHistoryRecord(query: "night", timestamp: 20))
            try context.save()
        }
        let persistence = PersistenceActor(modelContainer: try PersistenceActor.makeContainer(inMemory: false, storeURL: url))
        let rows = try await persistence.searchHistory()
        XCTAssertEqual(rows.map(\.query), ["BEYONCÉ", "night"])
        XCTAssertEqual(rows.map(\.key), ["beyonce", "night"])
        XCTAssertEqual(rows.first?.count, 2)
        XCTAssertEqual(rows.first?.timestamp, 30)
        // Writes still work on the migrated store.
        let after = try await persistence.recordSearchHistory(SearchHistoryInput(query: "beyoncé"), isPrivate: false, now: 40)
        XCTAssertEqual(after?.first?.count, 3)
    }

    // MARK: Model

    func testModelSuggestsFromMemoryAndPrivateSessionRecordsNothing() async throws {
        let persistence = try makePersistence()
        var isPrivate = false
        let model = makeModel(persistence: persistence, isPrivate: { isPrivate })
        model.record("Beyonce")
        try await waitUntil { model.history.count == 1 }
        model.record("beyonce knowles")
        try await waitUntil { model.history.count == 2 }
        model.record("night")
        try await waitUntil { model.history.count == 3 }
        model.performSearch("BEY")
        XCTAssertEqual(model.suggestions.map(\.query), ["beyonce knowles", "Beyonce"])
        model.performSearch("zzz")
        XCTAssertTrue(model.suggestions.isEmpty)

        isPrivate = true
        model.record("secret")
        model.record("night")
        try await Task.sleep(for: .milliseconds(200))
        let stored = try await persistence.searchHistory()
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(stored.first { $0.key == "night" }?.count, 1)
    }

    func testModelRemoveClearAllAndUndo() async throws {
        let persistence = try makePersistence()
        let model = makeModel(persistence: persistence)
        for q in ["alpha", "bravo"] {
            model.record(q)
            try await waitUntil { model.history.contains { $0.query == q } }
        }
        let bravo = try XCTUnwrap(model.history.first { $0.query == "bravo" })
        model.remove(bravo)
        XCTAssertEqual(model.history.map(\.query), ["alpha"])
        XCTAssertNotNil(model.undo)
        model.performUndo()
        XCTAssertEqual(Set(model.history.map(\.query)), ["alpha", "bravo"])
        XCTAssertNil(model.undo)
        model.clearAll()
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertNotNil(model.undo)
        model.performUndo()
        XCTAssertEqual(model.history.count, 2)
        try await waitUntil { model.history.count == 2 }
        let stored = try await persistence.searchHistory()
        XCTAssertEqual(stored.count, 2)
    }

    func testTheStripHoldsTheNewestTen() async throws {
        let persistence = try makePersistence()
        let model = makeModel(persistence: persistence)
        for i in 0..<12 {
            model.record("query \(i)")
            try await waitUntil { model.history.count == i + 1 }
        }
        XCTAssertEqual(model.strip.count, 10)
        XCTAssertEqual(model.strip.first?.query, "query 11")
    }
}
