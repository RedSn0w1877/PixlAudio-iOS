import Foundation
import Testing
@testable import PixlLibrary

/// The evaluation harness of docs/brain-spec.md, 11, on three synthetic listeners and on small hand-made cases (a port
/// of Android's `EvalTest`). No number here is a claim about a real listener: the synthetic ones only show that the
/// harness measures what it says. The expected numbers are the ones Android measured with the same code: the harness is
/// a pure function, so parity applies to them too.
@Suite("Music brain evaluation harness")
struct BrainEvalTests {
    // The numbers Android's `EvalTest` prints for loyal / explorer / repeater (its handoff, "What the synthetic
    // listeners show"): test 1 held-out AUC of the prior scorer, the two built-in baselines, calibration error.
    static let brainAuc: [Double] = [0.787, 0.697, 0.657]
    static let artistRateAuc: [Double] = [0.792, 0.727, 0.549]
    static let completionsAuc: [Double] = [0.631, 0.559, 0.655]
    static let calibration: [Double] = [0.19, 0.14, 0.19]

    @Test func aucCountsWonPairsExactlyAndTiesAsHalf() {
        // 2 finished (3, 5) against 2 skipped (1, 3): pairs 3>1 win, 3=3 tie, 5>1 win, 5>3 win = 3.5 of 4.
        #expect(Eval.auc([3, 5, 1, 3], [true, true, false, false]) == 0.875)
        #expect(Eval.auc([9, 8, 1, 2], [true, true, false, false]) == 1.0)
        #expect(Eval.auc([1, 2, 8, 9], [true, true, false, false]) == 0.0)
        #expect(Eval.auc([4, 4, 4, 4], [true, false, true, false]) == 0.5)
        #expect(Eval.auc([1, 2], [true, true]) == 0.5)
    }

    @Test func theHoldOutIsTheLastEightWeeksOfALongHistoryAndTheLastFifteenPercentOfAShortOne() {
        func events(days: Int, n: Int) -> [PlayEvent] {
            (0..<n).map {
                PlayEvent(eventId: Int64($0), origin: Origin.live, rid: 1, primaryAid: 1,
                          startedAtMs: 1_000_000_000_000 + Int64($0) * (Int64(days) * 86_400_000 / Int64(n)), playedMs: 1000)
            }
        }
        let long = events(days: 200, n: 2000)
        let cutLong = Eval.cutIndex(long)
        #expect(long[cutLong].startedAtMs >= long.last!.startedAtMs - 8 * Eval.weekMs)
        #expect(cutLong == 0 || long[cutLong - 1].startedAtMs < long.last!.startedAtMs - 8 * Eval.weekMs)
        #expect(Eval.cutIndex(events(days: 40, n: 1000)) == 850)
    }

    @Test func threeSyntheticListenersAreMeasuredAndTheBrainsPriorScorerSeesWhoTheyAre() {
        for (i, listener) in SyntheticListeners.all().enumerated() {
            let report = Eval.skipPrediction(listener.events, facts: .empty, config: Eval.Config(resamples: 100))
            #expect(report.heldOutEvents > 100, "\(listener.name)")
            #expect(report.finished > 20 && report.skipped > 20, "both classes are there: \(listener.name)")
            #expect(report.brainAuc > 0.6, "\(listener.name): brain AUC \(report.brainAuc)")
            for b in report.baselineAuc.indices {
                #expect(report.deltaLow[b] <= report.delta[b] + 1e-9 && report.delta[b] <= report.deltaHigh[b] + 1e-9,
                        "the interval holds the estimate: \(listener.name)")
            }
            #expect(report.calibrationError >= 0.0 && report.calibrationError <= 1.0)
            // The same numbers as Android, to the three digits its report prints.
            #expect(abs(report.brainAuc - Self.brainAuc[i]) < 0.0005, "\(listener.name) brain AUC \(report.brainAuc)")
            #expect(abs(report.baselineAuc[0] - Self.artistRateAuc[i]) < 0.0005, "\(listener.name) artist rate \(report.baselineAuc[0])")
            #expect(abs(report.baselineAuc[1] - Self.completionsAuc[i]) < 0.0005, "\(listener.name) completions \(report.baselineAuc[1])")
            #expect(abs(report.calibrationError - Self.calibration[i]) < 0.006, "\(listener.name) ECE \(report.calibrationError)")
        }
    }

    @Test func theReportIsTheSameWhenItIsRunAgain() {
        let listener = SyntheticListeners.loyal()
        let a = Eval.skipPrediction(listener.events, facts: .empty, config: Eval.Config(resamples: 40, seed: 3))
        let b = Eval.skipPrediction(listener.events, facts: .empty, config: Eval.Config(resamples: 40, seed: 3))
        #expect(a.brainAuc.bitPattern == b.brainAuc.bitPattern)
        #expect(a.deltaLow == b.deltaLow)
        #expect(a.calibrationError.bitPattern == b.calibrationError.bitPattern)
    }

    @Test func nothingAfterTheCutInfluencesAPredictionBeforeIt() {
        let listener = SyntheticListeners.explorer()
        let events = listener.events
        let config = Eval.Config(resamples: 0)
        let full = Eval.skipPrediction(events, facts: .empty, config: config)
        // The same history with its very last events changed beyond recognition: every earlier prediction (all but the
        // changed rows) must be bit-identical.
        let changed = Array(events.dropLast(20)) + events.suffix(20).map {
            PlayEvent(eventId: $0.eventId, origin: $0.origin, rid: $0.rid, primaryAid: $0.primaryAid,
                      startedAtMs: $0.startedAtMs, playedMs: 1000, durationMs: $0.durationMs, startReason: $0.startReason,
                      endReason: EndReason.next, surface: $0.surface, sessionId: $0.sessionId, posInSession: $0.posInSession)
        }
        let other = Eval.skipPrediction(changed, facts: .empty, config: config)
        let n = min(full.labeled.count, other.labeled.count) - 20
        #expect(n > 100)
        for i in 0..<max(n, 0) {
            #expect(full.labeled[i].brain.bitPattern == other.labeled[i].brain.bitPattern, "prediction \(i)")
        }
    }

    @Test func anExtraBaselineIsScoredFromTheStateBeforeTheEvent() {
        let listener = SyntheticListeners.loyal()
        let counter = Counter()
        let spy: Eval.Baseline = { _, _, _ in
            counter.bump()
            return 0.5
        }
        let report = Eval.skipPrediction(listener.events, facts: .empty, config: Eval.Config(resamples: 0),
                                         baselines: [("spy", spy)])
        #expect(counter.value == report.heldOutEvents)
        #expect(report.baselineAuc[0] == 0.5, "a constant predictor has no skill")
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    // MARK: Test 5

    static func health(_ listener: SyntheticListeners.Listener, multiplier: Double = 1.0) -> Eval.HealthReport {
        let start = Replay.rebuild(listener.events, facts: .empty, nowMs: listener.nowMs)
        let world = Eval.HealthWorld(library: listener.library, novel: listener.novel, seeds: listener.seeds,
                                     finishRate: listener.finishRate)
        return Eval.listHealth(world, start: start, days: 30, nowMs: listener.nowMs + 3_600_000, nuMultiplier: multiplier)
    }

    // Android's measured test 5 (its handoff): distinct-track ratio over 30 days, largest artist share, novelty gap.
    static let distinct: [Double] = [0.668, 0.837, 0.713]

    /// One test per listener: each is 60 mix builds over a pool of three thousand tracks, which takes a while in a
    /// debug build, and separate tests run in parallel.
    static func checkHealth(_ listener: SyntheticListeners.Listener, distinct expected: Double) {
        let h = health(listener)
        #expect(h.days == 30)
        #expect(h.maxSameDayOverlap == 0, "no track in two mixes on one day: \(listener.name)")
        #expect(h.distinctRatio >= 0.60, "\(listener.name): distinct \(h.distinctRatio)")
        #expect(h.maxArtistShare <= 0.10 + 1e-9, "\(listener.name): one artist holds \(h.maxArtistShare)")
        #expect(h.maxNoveltyGap <= 0.05 + 1e-9, "\(listener.name): novelty gap \(h.maxNoveltyGap)")
        #expect(h.shortestList >= 25, "\(listener.name): shortest list \(h.shortestList)")
        #expect(abs(h.distinctRatio - expected) < 0.0015, "\(listener.name) distinct \(h.distinctRatio)")
    }

    @Test func over30DaysTheLoyalListenersDailyMixIsMostlyDifferentMusicAndNoTrackIsInTwoMixesOfADay() {
        Self.checkHealth(SyntheticListeners.loyal(), distinct: Self.distinct[0])
    }

    @Test func over30DaysTheExplorersDailyMixIsMostlyDifferentMusicAndNoTrackIsInTwoMixesOfADay() {
        Self.checkHealth(SyntheticListeners.explorer(), distinct: Self.distinct[1])
    }

    @Test func over30DaysTheRepeatersDailyMixIsMostlyDifferentMusicAndNoTrackIsInTwoMixesOfADay() {
        Self.checkHealth(SyntheticListeners.repeater(), distinct: Self.distinct[2])
    }

    @Test func theSwitchMovesTheShareOfNewMusic() {
        let listener = SyntheticListeners.explorer()
        let novel = Set(listener.novel.map { $0.rid })
        func share(_ multiplier: Double) -> Double {
            let affinity = Replay.rebuild(listener.events, facts: .empty, nowMs: listener.nowMs)
            let req = MixPlanner.Request(kind: MixPlanner.kindDaily, candidates: listener.library + listener.novel,
                                         seeds: listener.seeds, nowMs: listener.nowMs + 3_600_000, tzOffsetMin: 0,
                                         nuMultiplier: multiplier, salt: 1)
            let plan = MixPlanner.plan(req, affinity: affinity)
            return Double(plan.picks.filter { novel.contains($0.rid) }.count) / Double(plan.picks.count)
        }
        let familiar = share(0.4)
        let blend = share(1.0)
        let discover = share(2.0)
        #expect(familiar < blend && blend < discover, "\(familiar) \(blend) \(discover)")
    }
}
