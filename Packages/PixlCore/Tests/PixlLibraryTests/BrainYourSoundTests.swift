import Foundation
import Testing
@testable import PixlLibrary

/// "Your sound" figures, the model's voice and the genre page facts (docs/brain-spec.md, 8.6, 8.7): a port of the Android
/// `YourSoundTest` and `GenrePageTest`.
@Suite("Brain Your sound and genre pages (stage 3)")
struct BrainYourSoundTests {
    private let day: Int64 = 86_400_000
    private let now: Int64 = 1_760_000_000_000

    private func play(_ rid: Int64, _ aid: Int64, ago: Int64, first: Bool = false, tz: Int32 = 0) -> YourSound.Play {
        YourSound.Play(rid: rid, aid: aid, startedAtMs: now - ago, tzOffsetMin: tz, first: first)
    }

    @Test func islandsCountOnlyTheLast28DaysAndSortByShare() {
        let plays = [play(1, 10, ago: day), play(2, 10, ago: 2 * day), play(3, 11, ago: 3 * day), play(4, 12, ago: 40 * day),
                     play(5, 13, ago: day)]
        let islandOf: (Int64) -> Int = { rid in rid <= 2 ? 7 : (rid == 3 ? 8 : (rid == 4 ? 9 : -1)) }
        let result = YourSound.islands(plays, islandOf: islandOf, nowMs: now)
        #expect(result.map(\.islandId) == [7, 8])
        #expect(result[0].permille == 667)
        #expect(result[1].permille == 333)
        #expect(result[0].topAids[0] == 10)
        #expect(YourSound.islands([], islandOf: islandOf, nowMs: now).isEmpty)
    }

    @Test func theFirstPlayOfARecordingIsNewAKnownOneIsNot() {
        let plays = YourSound.withFirsts(rids: [1, 2, 1, 3], aids: [0, 0, 0, 0], startedAtMs: [now - 4, now - 3, now - 2, now - 1],
                                         tzOffsetMin: [0, 0, 0, 0], knownBefore: [3])
        #expect(plays.map(\.first) == [true, true, false, false])
        let n = YourSound.novelty(plays, nowMs: now)
        #expect(n.plays == 4)
        #expect(n.novel == 2)
        #expect(n.permille == 500)
    }

    @Test func daypartsAndMonths() {
        let morning = now - (now % day) + 8 * 3_600_000
        let night = now - (now % day) + 23 * 3_600_000
        let plays = [YourSound.Play(rid: 1, aid: 0, startedAtMs: morning, tzOffsetMin: 0, first: false),
                     YourSound.Play(rid: 1, aid: 0, startedAtMs: morning + 1, tzOffsetMin: 0, first: false),
                     YourSound.Play(rid: 2, aid: 0, startedAtMs: night, tzOffsetMin: 0, first: false)]
        let islandOf: (Int64) -> Int = { $0 == 1 ? 5 : 6 }
        let dp = YourSound.dayparts(plays, islandOf: islandOf)
        #expect(dp[Int(HomePlanner.daypartMorning)].plays == 2)
        #expect(dp[Int(HomePlanner.daypartMorning)].leadingIslandId == 5)
        #expect(dp[Int(HomePlanner.daypartNight)].leadingIslandId == 6)
        #expect(dp[Int(HomePlanner.daypartAfternoon)].leadingIslandId == -1)
        #expect(YourSound.monthOfDay(0) == 1970 * 12)
        #expect(YourSound.monthOfDay(19_782) == 2024 * 12 + 1)
        #expect(YourSound.monthOfDay(20_370) == 2025 * 12 + 9)
        let months = YourSound.months(plays, islandOf: islandOf)
        #expect(months.count == 1)
        #expect(months[0].plays == 3)
        #expect(months[0].islandPermille == [.init(islandId: 5, permille: 667), .init(islandId: 6, permille: 333)])
    }

    @Test func monthsAreCappedAt24() {
        let plays = (0..<40).map { YourSound.Play(rid: 1, aid: 0, startedAtMs: Int64($0) * 31 * day, tzOffsetMin: 0, first: false) }
        #expect(YourSound.months(plays, islandOf: { _ in -1 }).count == YourSound.maxMonths)
    }

    @Test func erasAreHiddenUntilAYearIsKnownForMostPlays() {
        let plays = (1...10).map { play(Int64($0), 0, ago: day) }
        #expect(YourSound.decades(plays, yearOf: { $0 <= 5 ? 1994 : 0 }).isEmpty)
        let shown = YourSound.decades(plays, yearOf: { $0 <= 7 ? 1994 : ($0 <= 8 ? 2003 : 0) })
        #expect(shown.map(\.decade) == [1990, 2000])
        #expect(shown[0].permille == 875)
    }

    @Test func unknownGenresAreAbsentNotGuessed() {
        let plays = (1...4).map { play(Int64($0), 0, ago: day) }
        let g = YourSound.genres(plays, topTagOf: { $0 <= 2 ? 12 : GenreAtlas.none })
        #expect(g == [.init(atlasId: 12, permille: 1000)])
        #expect(YourSound.genres(plays, topTagOf: { _ in GenreAtlas.none }).isEmpty)
    }

    private func summary(_ total: Int, _ accLearned: Double, _ accPrior: Double, _ before: Double?) -> Gate.Summary {
        Gate.Summary(plays: min(total, Gate.window), playsTotal: total, logLossLearned: 0.5, logLossPrior: 0.55,
                     accLearned: accLearned, accPrior: accPrior, accLearnedBefore: before, accPriorBefore: nil)
    }

    @Test func theModelVoiceFollowsTheModelsRealState() {
        #expect(ModelVoice.of(nil, useLearned: false, modelUpdates: 0).kind == ModelVoice.gettingToKnow)
        let few = ModelVoice.of(summary(120, 0.7, 0.6, nil), useLearned: true, modelUpdates: 120)
        #expect(few.kind == ModelVoice.gettingToKnow)
        #expect(few.gradedPlays == 120)
        #expect(few.accNowPercent == nil)
        let prior = ModelVoice.of(summary(900, 0.7, 0.61, 0.6), useLearned: false, modelUpdates: 0)
        #expect(prior.kind == ModelVoice.standardRecipe)
        #expect(prior.accNowPercent == nil)
        #expect(prior.accPriorPercent == 61)
        let learning = ModelVoice.of(summary(2500, 0.684, 0.61, 0.612), useLearned: true, modelUpdates: 2400)
        #expect(learning.kind == ModelVoice.learning)
        #expect(learning.learnedFrom == 2400)
        #expect(learning.accNowPercent == 68)
        #expect(learning.accBeforePercent == 61)
        #expect(learning.accPriorPercent == 61)
    }

    // MARK: Genre pages

    @Test func aPageHoldsOnlyWhatTheAtlasHolds() throws {
        let atlas = try BrainStage2bGoldenTests.atlas()
        var described = 0
        for id in atlas.allIds {
            let page = try #require(GenrePage.of(atlas, id), "page of \(id)")
            #expect(page.name == atlas.genre(id)?.name)
            for link in page.parents + page.children + page.related + page.influences { #expect(atlas.genre(link) != nil) }
            for child in page.children { #expect(atlas.genre(child)?.parents.contains(id) == true) }
            if let text = page.description {
                described += 1
                #expect(!BrainText.isBlank(text))
            }
            #expect(!page.parents.contains(id))
            #expect(!page.children.contains(id))
        }
        #expect((100...400).contains(described), "about 200 genres are described: \(described)")
    }

    @Test func anUnknownGenreHasNoPage() throws {
        let atlas = try BrainStage2bGoldenTests.atlas()
        #expect(GenrePage.of(atlas, GenreAtlas.none) == nil)
        #expect(GenrePage.of(atlas, 10_000_000) == nil)
    }

    @Test func aGenreWithNoDescriptionShowsNoneAndOneWithAStartYearShowsItsDecade() throws {
        let atlas = try BrainStage2bGoldenTests.atlas()
        let plain = try #require(atlas.allIds.first { BrainText.isBlank(atlas.genre($0)?.description ?? "") })
        #expect(GenrePage.of(atlas, plain)?.description == nil)
        if let dated = atlas.allIds.first(where: { (1000...2999).contains(atlas.genre($0)?.eraStart ?? 0) }) {
            let origin = try #require(GenrePage.of(atlas, dated)?.origin)
            #expect(origin.hasSuffix("s"), "\(origin)")
        }
    }
}
