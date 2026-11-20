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
        model.record("beyonce knowles")
        model.record("night")
        // The model runs its writes in order and `settled()` waits for all of them: no sleeping, no polling.
        await model.settled()
        XCTAssertEqual(model.history.count, 3)
        model.performSearch("BEY")
        XCTAssertEqual(model.suggestions.map(\.query), ["beyonce knowles", "Beyonce"])
        model.performSearch("zzz")
        XCTAssertTrue(model.suggestions.isEmpty)

        isPrivate = true
        model.record("secret")
        model.record("night")
        // Nothing was queued at all, so there is nothing to wait for: the store still has what it had.
        await model.settled()
        let stored = try await persistence.searchHistory()
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(stored.first { $0.key == "night" }?.count, 1)
    }

    func testModelRemoveClearAllAndUndo() async throws {
        let persistence = try makePersistence()
        let model = makeModel(persistence: persistence)
        model.record("alpha")
        model.record("bravo")
        await model.settled()
        let bravo = try XCTUnwrap(model.history.first { $0.query == "bravo" })
        model.remove(bravo)
        XCTAssertEqual(model.history.map(\.query), ["alpha"])
        XCTAssertNotNil(model.undo)
        model.performUndo()
        XCTAssertEqual(Set(model.history.map(\.query)), ["alpha", "bravo"])
        XCTAssertNil(model.undo)
        model.clearAll()
        XCTAssertTrue(model.history.isEmpty)
        await model.settled()
        XCTAssertEqual(model.undo?.items.count, 2)
        model.performUndo()
        XCTAssertEqual(model.history.count, 2)
        await model.settled()
        let stored = try await persistence.searchHistory()
        XCTAssertEqual(stored.count, 2)
    }

    func testASecondRemovalAddsToTheUndoInsteadOfReplacingIt() async throws {
        let persistence = try makePersistence()
        let model = makeModel(persistence: persistence)
        for q in ["alpha", "bravo", "charlie"] { model.record(q) }
        await model.settled()
        model.remove(try XCTUnwrap(model.history.first { $0.query == "alpha" }))
        model.remove(try XCTUnwrap(model.history.first { $0.query == "bravo" }))
        XCTAssertEqual(Set(model.undo?.items.map(\.query) ?? []), ["alpha", "bravo"])
        model.performUndo()
        await model.settled()
        let stored = try await persistence.searchHistory()
        XCTAssertEqual(Set(stored.map(\.query)), ["alpha", "bravo", "charlie"])
    }

    func testRowsRestoredBehindTheModelsBackShowAfterARefresh() async throws {
        let persistence = try makePersistence()
        let model = makeModel(persistence: persistence)
        await model.refreshHistory()
        XCTAssertTrue(model.history.isEmpty)
        // A backup restore writes through the store, not through the model.
        try await persistence.restoreSearchHistory([SearchHistoryItem(query: "restored", timestamp: 5)])
        XCTAssertTrue(model.history.isEmpty)
        await model.refreshHistory()
        XCTAssertEqual(model.history.map(\.query), ["restored"])
    }

    func testClearAllThenUndoKeepsRowsTheModelHadNotSeenYet() async throws {
        let persistence = try makePersistence()
        let model = makeModel(persistence: persistence)
        model.record("alpha")
        await model.settled()
        // A restore brings in a row while the model still shows only alpha.
        try await persistence.restoreSearchHistory([SearchHistoryItem(query: "restored", timestamp: 5)])
        XCTAssertEqual(model.history.map(\.query), ["alpha"])
        model.clearAll()
        await model.settled()
        XCTAssertEqual(Set(model.undo?.items.map(\.query) ?? []), ["alpha", "restored"])
        model.performUndo()
        await model.settled()
        let stored = try await persistence.searchHistory()
        XCTAssertEqual(Set(stored.map(\.query)), ["alpha", "restored"])
    }

    func testTheStripAndTheListShowOneRowPerOpenedThing() async throws {
        let persistence = try makePersistence()
        let model = makeModel(persistence: persistence)
        model.record("bey", kind: .artist, targetId: "7", targetTitle: "Beyoncé")
        model.record("night")
        model.record("beyonce", kind: .artist, targetId: "7", targetTitle: "Beyoncé")
        await model.settled()
        XCTAssertEqual(model.history.count, 3)
        XCTAssertEqual(model.shownHistory.map(\.query), ["beyonce", "night"])
        XCTAssertEqual(model.strip.map(\.query), ["beyonce", "night"])
    }

    func testAPlainSubmitKeepsTheOpenedResultOfTheSameQuery() async throws {
        let persistence = try makePersistence()
        let model = makeModel(persistence: persistence)
        model.record("taylor", kind: .artist, targetId: "9", targetTitle: "Taylor Swift")
        model.record("Taylor")
        model.record("taylor", kind: .query, targetId: "1")
        await model.settled()
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.count, 3)
        XCTAssertEqual(model.history.first?.kind, .artist)
        XCTAssertEqual(model.history.first?.targetId, "9")
    }

    func testTheStripHoldsTheNewestTen() async throws {
        let persistence = try makePersistence()
        let model = makeModel(persistence: persistence)
        for i in 0..<12 { model.record("query \(i)") }
        await model.settled()
        XCTAssertEqual(model.history.count, 12)
        XCTAssertEqual(model.strip.count, 10)
        XCTAssertEqual(model.strip.first?.query, "query 11")
    }
}
