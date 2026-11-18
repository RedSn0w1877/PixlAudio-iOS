import Foundation
import Testing
@testable import PixlLibrary

/// Daily Mix and Your Mix (6.2, 6.4, 8.2), the served-log budget (6.5), the snapshot codec (10.1) and the seeds of the
/// refresh (3.6): a port of Android's `MixPlannerTest` and `SeedsTest`.
@Suite("Music brain mix planner")
struct BrainMixPlannerTests {
    let listener = SyntheticListeners.explorer()
    var now: Int64 { listener.nowMs + 3_600_000 }
    var affinity: Affinity.State { Replay.rebuild(listener.events, facts: .empty, nowMs: now) }
    var pool: [Candidate] { listener.library + listener.novel }

    func request(kind: Int32 = MixPlanner.kindDaily, multiplier: Double = 1.0, excluded: Set<Int64> = [],
                 served: [Int64: Int32] = [:], regenerate: Int32 = 0, at: Int64? = nil) -> MixPlanner.Request {
        MixPlanner.Request(kind: kind, candidates: pool, seeds: listener.seeds, nowMs: at ?? now, tzOffsetMin: 0,
                           nuMultiplier: multiplier, salt: 99, regenerate: regenerate, excludedRids: excluded,
                           servedTimes: served)
    }

    @Test func aDailyMixHas30TracksAndYourMix60EachTrackOnce() {
        let daily = MixPlanner.plan(request(), affinity: affinity)
        let your = MixPlanner.plan(request(kind: MixPlanner.kindYour), affinity: affinity)
        #expect(daily.picks.count == 30)
        #expect(your.picks.count == 60)
        #expect(Set(daily.picks.map { $0.rid }).count == daily.picks.count)
        #expect(Set(your.picks.map { $0.rid }).count == your.picks.count)
    }

    @Test func theSameDayGivesTheSameMixAndRegenerateGivesAnother() {
        let a = MixPlanner.plan(request(), affinity: affinity).picks.map { $0.rid }
        let b = MixPlanner.plan(request(), affinity: affinity).picks.map { $0.rid }
        #expect(a == b)
        let c = MixPlanner.plan(request(regenerate: 1), affinity: affinity).picks.map { $0.rid }
        #expect(a != c)
        #expect(MixPlanner.tieSeedOf(request(at: now)) == MixPlanner.tieSeedOf(request(at: now)))
        #expect(MixPlanner.tieSeedOf(request(at: now)) != MixPlanner.tieSeedOf(request(at: now + 2 * Repetition.dayMs)))
    }

    @Test func nothingExcludedIsPickedAndNothingPlayedInTheLastFourHours() {
        let first = Set(MixPlanner.plan(request(), affinity: affinity).picks.map { $0.rid })
        let second = Set(MixPlanner.plan(request(excluded: first), affinity: affinity).picks.map { $0.rid })
        #expect(first.isDisjoint(with: second))
        let last = listener.events.last!
        #expect(now - last.endedAtMs < StationPlanner.fourHoursMs)
        #expect(!MixPlanner.plan(request(), affinity: affinity).picks.contains { $0.rid == last.rid })
    }

    @Test func theSwitchSetsTheShareOfNewMusic() {
        #expect(abs(MixPlanner.nuOf(MixPlanner.kindDaily, multiplier: 0.4) - 0.10) < 1e-12)
        #expect(abs(MixPlanner.nuOf(MixPlanner.kindDaily, multiplier: 1.0) - 0.25) < 1e-12)
        #expect(abs(MixPlanner.nuOf(MixPlanner.kindDaily, multiplier: 2.0) - 0.50) < 1e-12)
        #expect(abs(MixPlanner.nuOf(MixPlanner.kindYour, multiplier: 1.0) - 0.20) < 1e-12)
        #expect(MixPlanner.nuOf(MixPlanner.kindDaily, multiplier: 9.0) == MixPlanner.nuMax)
        let novel = Set(listener.novel.map { $0.rid })
        func share(_ m: Double) -> Double {
            let p = MixPlanner.plan(request(multiplier: m), affinity: affinity).picks
            return Double(p.filter { novel.contains($0.rid) }.count) / Double(p.count)
        }
        let shares = [0.4, 1.0, 2.0].map(share)
        #expect(shares[0] < shares[1] && shares[1] < shares[2], "\(shares)")
        for (i, m) in [0.4, 1.0, 2.0].enumerated() {
            #expect(abs(MixPlanner.nuOf(MixPlanner.kindDaily, multiplier: m) - shares[i]) <= 0.05)
        }
    }

    @Test func aTrackServedOftenLatelyIsPickedLess() {
        let base = MixPlanner.plan(request(), affinity: affinity).picks.map { $0.rid }
        var served: [Int64: Int32] = [:]
        for rid in base.prefix(10) { served[rid] = 3 }
        let after = Set(MixPlanner.plan(request(served: served), affinity: affinity).picks.map { $0.rid })
        // Not a ban, a penalty: but ten full penalties must have moved some of them out.
        #expect(base.prefix(10).filter { after.contains($0) }.count < 10)
    }

    @Test func theLibraryIsNotAskedToBeCloseToASeedAndAMixCarriesNoLineUnderAPlainLibraryTrack() {
        let plan = MixPlanner.plan(request(), affinity: affinity)
        let library = Set(listener.library.map { $0.rid })
        let libraryPicks = plan.picks.filter { library.contains($0.rid) }
        #expect(!libraryPicks.isEmpty)
        for p in libraryPicks { #expect(p.whyKey == WhyLine.none || p.whyKey == WhyLine.onRepeat, "library why \(p.whyKey)") }
        for p in plan.picks where !library.contains(p.rid) { #expect(p.novel) }
    }

    @Test func persistedEdgesReachTheGraph() {
        let edge = MixPlanner.Edge(a: pool[3].rid, b: pool[700].rid, weight: 0.9)
        let plain = MixPlanner.plan(request(), affinity: affinity)
        let with = MixPlanner.plan(
            MixPlanner.Request(kind: MixPlanner.kindDaily, candidates: pool, seeds: listener.seeds, nowMs: now, tzOffsetMin: 0,
                               salt: 99, edges: [edge]), affinity: affinity)
        #expect(plain.picks.count == with.picks.count)
    }

    // MARK: Repetition

    @Test func theServedPenaltyGrowsByAThirdPerServeAndStopsAtThree() {
        #expect(Repetition.servedPenalty(0) == 0.0)
        #expect(abs(Repetition.servedPenalty(1) - Repetition.maxPenalty / 3.0) < 1e-12)
        #expect(abs(Repetition.servedPenalty(3) - Repetition.maxPenalty) < 1e-12)
        #expect(abs(Repetition.servedPenalty(9) - Repetition.maxPenalty) < 1e-12)
    }

    @Test func theDayOfAMixStartsAtFourInTheMorningLocalTime() {
        let t: Int64 = 1_760_000_000_000
        let tz: Int32 = 420
        let local = t + Int64(tz) * 60_000
        let fourAm = BrainMath.floorDiv(local, Repetition.dayMs) * Repetition.dayMs + 4 * 3_600_000 - Int64(tz) * 60_000
        #expect(Repetition.mixDay(fourAm, tzOffsetMin: tz) == Repetition.mixDay(fourAm + 3_600_000, tzOffsetMin: tz))
        #expect(Repetition.mixDay(fourAm, tzOffsetMin: tz) - 1 == Repetition.mixDay(fourAm - 1, tzOffsetMin: tz))
    }

    @Test func timesServedCountsAListOncePerRecordingAndOnlyTheLast30Days() {
        let now = 10 * Repetition.dayMs * 10
        let lists = [
            Repetition.Served(surface: Surface.dailyMix, builtAtMs: now - Repetition.dayMs, rids: [1, 2, 2, 3]),
            Repetition.Served(surface: Surface.yourMix, builtAtMs: now - 5 * Repetition.dayMs, rids: [2, 4]),
            Repetition.Served(surface: Surface.dailyMix, builtAtMs: now - 31 * Repetition.dayMs, rids: [1, 1]),
            Repetition.Served(surface: Surface.dailyMix, builtAtMs: now + Repetition.dayMs, rids: [9]),
        ]
        #expect(Repetition.timesServed(lists, nowMs: now) == [1: 1, 2: 2, 3: 1, 4: 1])
    }

    @Test func aMixOfTheSameDayHoldsItsRecordingsARebuiltListDoesNotHoldItself() {
        let now = 5_000 * Repetition.dayMs + 9 * 3_600_000
        let lists = [
            Repetition.Served(surface: Surface.dailyMix, builtAtMs: now - 2 * 3_600_000, rids: [1, 2, 3]),
            Repetition.Served(surface: Surface.yourMix, builtAtMs: now - 1 * 3_600_000, rids: [7, 8]),
            Repetition.Served(surface: Surface.autoplay, builtAtMs: now - 1 * 3_600_000, rids: [50]),
            Repetition.Served(surface: Surface.dailyMix, builtAtMs: now - 30 * 3_600_000, rids: [99]),
        ]
        #expect(Repetition.takenOnDay(lists, nowMs: now, tzOffsetMin: 0) == [1, 2, 3, 7, 8])
        #expect(Repetition.takenOnDay(lists, nowMs: now, tzOffsetMin: 0, exceptSurface: Surface.dailyMix) == [7, 8])
    }

    @Test func distinctRatioAndArtistShare() {
        #expect(Repetition.distinctRatio([[1, 2], [1, 2]]) == 0.5)
        #expect(Repetition.distinctRatio([]) == 1.0)
        #expect(Repetition.maxArtistShare([1, 1, 2, 3]) == 0.5)
    }

    // MARK: On repeat

    @Test func onRepeatNeedsARecentRateAndAboutThreeFinishedPlaysLately() {
        func why(_ aff: Double, _ mass: Double) -> Int32 {
            WhyLine.pick(arm: Arm.fav, slotKind: ListBuilder.slotFamiliar, homeRow: false, candidateAid: 5, seedAid: 6,
                         bestRank: 3, likedRid: 0, homeSeedRid: 0, trackAffRecent: aff, trackPosRecent: mass).key
        }
        #expect(why(1.5, 3.0) == WhyLine.onRepeat)
        #expect(why(1.5, 1.0) != WhyLine.onRepeat)
        #expect(why(0.5, 3.0) != WhyLine.onRepeat)
    }

    // MARK: Seeds

    func group(_ g: Int, _ from: Int, _ n: Int, artistOf: (Int) -> Int64 = { Int64($0) }) -> [Seeds.Seed] {
        (from..<(from + n)).map { Seeds.Seed(rid: Int64($0) + 1, aid: artistOf($0), group: g) }
    }

    @Test func eachGroupTakesItsQuotaAndTheDayNeverPasses24() {
        let seeds = Seeds.select([group(0, 0, 20), group(1, 100, 20), group(2, 200, 20), group(3, 300, 20)])
        #expect(seeds.count == 24)
        #expect((0...3).map { g in seeds.filter { $0.group == g }.count } == [8, 8, 4, 4])
    }

    @Test func atMostTwoSeedsPerArtistAcrossTheGroups() {
        let seeds = Seeds.select([group(0, 0, 10) { _ in 7 }, group(1, 100, 10) { _ in 7 }, group(2, 200, 5)])
        #expect(seeds.filter { $0.aid == 7 }.count == 2)
        #expect(seeds.filter { $0.aid == 7 }.map { $0.group } == [0, 0])
    }

    @Test func aRecordingIsASeedOnceAndASkippedOneNever() {
        let a = [Seeds.Seed(rid: 5, aid: 1, group: 0), Seeds.Seed(rid: 6, aid: 2, group: 0)]
        let b = [Seeds.Seed(rid: 5, aid: 1, group: 1), Seeds.Seed(rid: 7, aid: 3, group: 1)]
        #expect(Seeds.select([a, b], skip: [6]).map { $0.rid } == [5, 7])
    }

    @Test func anUnknownArtistHasNoCap() {
        #expect(Seeds.select([(1...8).map { Seeds.Seed(rid: Int64($0), aid: 0, group: 0) }]).count == 8)
    }

    @Test func thePseudoRandomOrderIsTheDaysAndChangesWithTheDay() {
        let rids = (0..<50).map { Int64($0) + 1 }
        let a = Seeds.pseudoRandomOrder(rids, salt: 99, day: 20_000)
        #expect(a == Seeds.pseudoRandomOrder(rids, salt: 99, day: 20_000))
        #expect(a != Seeds.pseudoRandomOrder(rids, salt: 99, day: 20_001))
        #expect(a.sorted() == rids)
    }
}
