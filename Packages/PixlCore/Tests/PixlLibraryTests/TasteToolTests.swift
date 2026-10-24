import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

private let now: Int64 = 1_800_000_000_000
private let day: Int64 = 86_400_000

/// `adjust_taste` / `list_taste_adjustments` / `remove_taste_adjustment`: from the tool's input to the report.
@Suite struct TasteToolTests {
    private func songs() -> [Song] {
        [testSong("s1", title: "Get Lucky", artist: "Daft Punk", genre: "Electronic", album: "Random Access Memories"),
         testSong("s2", title: "One More Time", artist: "Daft Punk", genre: "Electronic", album: "Discovery"),
         testSong("s3", title: "Sunset Lover", artist: "Petit Biscuit", genre: "Chill")]
    }

    private func entry(_ action: String, _ type: String, _ target: String, strength: JSONValue? = nil, days: JSONValue? = nil,
                       reason: String = "asked") -> JSONValue {
        var members: [(String, JSONValue)] = [("action", .string(action)), ("target_type", .string(type)), ("target", .string(target)),
                                              ("reason", .string(reason))]
        if let strength { members.append(("strength", strength)) }
        if let days { members.append(("expires_days", days)) }
        return .object(JSONObject(members.map { (key: $0.0, value: $0.1) }))
    }

    private func input(_ entries: [JSONValue]) -> JSONObject {
        JSONObject([(key: "adjustments", value: .array(entries)), (key: "user_asked", value: .bool(true))])
    }

    private func makePlan(_ entries: [JSONValue]) throws -> TasteToolPlanner.Plan {
        try TasteToolPlanner.plan(input: input(entries), songs: songs()).get()
    }

    @Test func entriesBecomeResolvedChangesWithDefaults() throws {
        let plan = try makePlan([entry("boost", "artist", "daft punk"), entry("reduce", "genre", "chill", strength: .integer(3), days: .integer(14)),
                             entry("mute", "song", "s3", strength: .null, days: .null)])
        let changes = plan.changes
        #expect(changes.count == 3)
        #expect(changes[0].action == .boost && changes[0].key == "daftpunk" && changes[0].strength == 2 && changes[0].expiresDays == nil)
        #expect(changes[0].source == .taizo && changes[0].label == "daft punk" && changes[0].reason == "asked")
        #expect(changes[1].strength == 3 && changes[1].expiresDays == 14 && changes[1].label == "Chill")
        #expect(changes[2].targetType == .song && changes[2].key == "petitbiscuit|sunsetlover" && changes[2].label == "Sunset Lover — Petit Biscuit")
        // Out-of-range numbers are clamped.
        let clamped = try makePlan([entry("boost", "artist", "Daft Punk", strength: .integer(9), days: .integer(5_000))]).changes[0]
        #expect(clamped.strength == 3 && clamped.expiresDays == TasteAdjustmentList.maxExpiryDays)
    }

    @Test func aBadEntryIsRejectedAloneAndTheRestApply() throws {
        let plan = try makePlan([entry("boost", "artist", "Daft Punk"), entry("boost", "genre", "polka"), entry("explode", "artist", "x"),
                             entry("mute", "song", "no such song at all")])
        #expect(plan.changes.count == 1 && plan.entries.count == 4)
        var list = TasteAdjustmentList()
        let outcomes = plan.changes.map { list.apply($0, nowMs: now) }
        let report = TasteToolPlanner.report(plan: plan, outcomes: outcomes, nowMs: now)
        #expect(report["applied"]?.int64Value == 1)
        let results = try #require(report["results"]?.arrayValue)
        #expect(results.map { $0["status"]?.stringValue } == ["applied", "not_applied", "not_applied", "not_applied"])
        #expect(results[1]["detail"]?.stringValue?.contains("polka") == true)
        #expect(results[0]["id"]?.stringValue == list.items[0].id && results[0]["undo"] != nil)
    }

    @Test func theLimitsAreEnforced() throws {
        if case .failure(.noAdjustments) = TasteToolPlanner.plan(input: input([]), songs: songs()) {} else { Issue.record("empty must fail") }
        let many = (0..<21).map { entry("boost", "artist", "Artist \($0)") }
        if case .failure(.tooMany(21)) = TasteToolPlanner.plan(input: input(many), songs: songs()) {} else { Issue.record("21 must fail") }
        #expect(TasteToolPlanner.Failure.tooMany(21).message.contains("20"))
        let exactly = (0..<20).map { entry("boost", "artist", "Artist \($0)") }
        #expect(try TasteToolPlanner.plan(input: input(exactly), songs: songs()).get().changes.count == 20)
    }

    @Test func theReportSaysWhatHappenedToEachChange() throws {
        var list = TasteAdjustmentList()
        let first = try makePlan([entry("boost", "artist", "Daft Punk"), entry("mute", "genre", "Chill")])
        _ = first.changes.map { list.apply($0, nowMs: now) }
        // Replace the boost, undo a mute, undo something that was never blocked, and an outside artist.
        let second = try makePlan([entry("reduce", "artist", "Daft Punk", days: .integer(10)), entry("unmute", "genre", "Chill"),
                               entry("unblock", "artist", "Daft Punk"), entry("block", "artist", "Somebody Else")])
        let outcomes = second.changes.map { list.apply($0, nowMs: now) }
        let report = TasteToolPlanner.report(plan: second, outcomes: outcomes, nowMs: now)
        let results = try #require(report["results"]?.arrayValue)
        #expect(results.map { $0["status"]?.stringValue } == ["replaced_earlier_change", "removed", "not_applied", "applied"])
        #expect(results[0]["expires_in_days"]?.int64Value == 10 && results[0]["strength"]?.int64Value == 2)
        #expect(results[2]["detail"]?.stringValue == "It was not blocked.")
        #expect(results[3]["note"]?.stringValue?.contains("Not in the library") == true)
        #expect(report["applied"]?.int64Value == 3)
        // A full list is reported as such.
        let full = TasteToolPlanner.report(plan: second, outcomes: [.listFull, .listFull, .listFull, .listFull], nowMs: now)
        #expect(full["applied"]?.int64Value == 0)
        #expect(full["results"]?.arrayValue?.first?["detail"]?.stringValue?.contains("full") == true)
    }

    @Test func theListShowsWhoSetWhatAndHowOld() {
        var list = TasteAdjustmentList()
        list.apply(TasteChange(action: .boost, targetType: .artist, key: "daftpunk", label: "Daft Punk", strength: 3, reason: "loves them",
                               source: .taizo), nowMs: now - 3 * day)
        list.apply(TasteChange(action: .block, targetType: .genre, key: "polka", label: "Polka", reason: "", expiresDays: 7, source: .user),
                   nowMs: now - day)
        list.apply(TasteChange(action: .mute, targetType: .artist, key: "old", label: "Old", expiresDays: 1), nowMs: now - 5 * day)
        let json = TasteToolPlanner.listJSON(list.items, nowMs: now)
        #expect(json["count"]?.int64Value == 2, "the expired one is not listed")
        let items = json["adjustments"]?.arrayValue ?? []
        #expect(items.map { $0["target"]?.stringValue } == ["Polka", "Daft Punk"], "newest first")
        #expect(items[0]["set_by"]?.stringValue == "user" && items[0]["expires_in_days"]?.int64Value == 6 && items[0]["strength"] == nil)
        #expect(items[1]["strength"]?.int64Value == 3 && items[1]["age_days"]?.int64Value == 3 && items[1]["reason"]?.stringValue == "loves them")
        #expect(TasteToolPlanner.listJSON([], nowMs: now)["count"]?.int64Value == 0)
    }
}
