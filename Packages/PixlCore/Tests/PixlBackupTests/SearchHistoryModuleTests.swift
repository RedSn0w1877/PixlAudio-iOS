import PixlLibrary
import PixlModel
import Testing
@testable import PixlBackup

/// The SEARCH_HISTORY module after the search history screen: the new fields travel, a payload from before them still
/// restores (new fields default), the key is recomputed and merged by key, nothing is cleared.
@Suite("Search history backup module")
struct SearchHistoryModuleTests {
    /// What the Android app wrote before the screen: id, query, timestamp, nothing else.
    private let oldPayload = """
    [
      {"id": 4, "query": "Beyonce", "timestamp": 1700000000000},
      {"id": 5, "query": "BEYONCÉ", "timestamp": 1700000005000},
      {"id": 6, "query": "Sơn Tùng", "timestamp": 1700000009000}
    ]
    """

    @Test func anOldPayloadRestoresWithDefaultsAndRecomputedKeys() throws {
        let items = try SearchHistoryModule.restore(payload: oldPayload)
        #expect(items.map(\.query) == ["Beyonce", "BEYONCÉ", "Sơn Tùng"])
        #expect(items.map(\.key) == ["beyonce", "beyonce", "son tung"])
        #expect(items.allSatisfy { $0.count == 1 && $0.kind == nil && $0.targetId == nil && $0.imageUrl == nil })
        // The store merges them by key (the two spellings are one row).
        let merged = SearchHistoryRules.merged([], with: items, counts: .max)
        #expect(merged.map(\.query) == ["Sơn Tùng", "BEYONCÉ"])
    }

    @Test func anOldPayloadRoundTripsWithoutGainingFields() throws {
        let entities = try #require(try AndroidBackup.SearchHistoryEntity.decodeList(oldPayload))
        let written = AndroidBackup.SearchHistoryEntity.encodeList(entities)
        #expect(!written.contains("\"key\"") && !written.contains("\"count\"") && !written.contains("\"kind\""))
        #expect(written.contains("\"query\": \"Beyonce\""))
    }

    @Test func theNewFieldsRoundTripThroughExportAndRestore() throws {
        let rows = [
            SearchHistoryItem(query: "taylor", timestamp: 30, key: "taylor", kind: .artist, targetId: "42",
                              targetTitle: "Taylor Swift", imageUrl: "https://i.example/t.jpg", count: 4),
            SearchHistoryItem(query: "night drive", timestamp: 20, key: "night drive", count: 2),
        ]
        let restored = try SearchHistoryModule.restore(payload: SearchHistoryModule.export(rows))
        #expect(restored == rows)
    }

    @Test func aKeyInThePayloadIsRecomputedNotTrusted() throws {
        let payload = #"[{"id":1,"query":"Đen Vâu","key":"wrong","kind":"album","targetId":"7","targetTitle":"X","timestamp":5,"count":3}]"#
        let item = try #require(try SearchHistoryModule.restore(payload: payload).first)
        #expect(item.key == "den vau" && item.kind == .album && item.targetId == "7" && item.count == 3)
    }

    @Test func anUnknownKindIsDroppedAndACountBelowOneBecomesOne() throws {
        let payload = #"[{"id":1,"query":"abc","kind":"podcast","count":0,"timestamp":5}]"#
        let item = try #require(try SearchHistoryModule.restore(payload: payload).first)
        #expect(item.kind == nil && item.count == 1)
    }

    @Test func extraUnknownFieldsFromAnotherVersionAreIgnored() throws {
        let payload = #"[{"id":1,"query":"abc","timestamp":5,"futureField":{"a":1},"pinned":true}]"#
        #expect(try SearchHistoryModule.restore(payload: payload).map(\.query) == ["abc"])
    }

    @Test func aRowWithoutAQueryStillFailsTheModule() {
        #expect(throws: BackupError.self) { try SearchHistoryModule.restore(payload: #"[{"id":1,"timestamp":5}]"#) }
    }

    @Test func restoringAnOldBackupOnTopOfLocalRowsKeepsBoth() throws {
        let local = [SearchHistoryItem(query: "local only", timestamp: 1_800_000_000_000, key: "local only", count: 5)]
        let backup = try SearchHistoryModule.restore(payload: oldPayload)
        let merged = SearchHistoryRules.merged(local, with: backup, counts: .max)
        #expect(merged.map(\.key) == ["local only", "son tung", "beyonce"])
        #expect(merged[0].count == 5)
    }
}
