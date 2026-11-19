// Training the ranker from the event log (docs/brain-spec.md, 5.9 "Training on history", 11 test 6). A transliteration of
// the Android `:brain` module's `LearnReplay.kt`.
//
// `run` walks the events in ascending id, exactly as `Replay.rebuild` does for the affinity tables (and produces the same
// tables), and beside them: rebuilds the session state with `Session.apply`, computes the feature vector of each play from
// the state as of just before it, has BOTH weight vectors (the prior `M0` and the learned model) predict it, records the
// two predictions (the evaluation is prequential: a play is predicted before it is learned from), and then takes one
// `Ranker.update` step.
//
// What the old rows can and cannot give (5.9): the features that need a graph, islands, tags or repeat activation are 0 for
// a replayed play, so their weights stay at the prior until live data arrives; features 37 and 38 come from the `retrQ`
// and `radioRank` the event carried since stage 1; the origin one-hot (48-50) is switched on for imported and migrated
// rows in training only and is 0 in every prediction, as it is when serving.
//
// The LIVE path (the app's recorder) computes the same vector with `featuresOf` from the state before the play is applied,
// so a live update and a replay of the same play agree up to the session's expiry rule.

/// Replaying the log into the learner.
public enum LearnReplay {
    /// Bumped when the features a replay computes, their definition or the update rule change: the learned model is rebuilt.
    public static let version = 1

    /// The first of the three origin one-hot features (48 import Spotify, 49 import YouTube Music, 50 migrated history).
    public static let originBase = 48

    /// A graded play is finished (`r = 1`) or skipped (`r <= 0.1`); anything between is training only.
    public static let skippedMax = 0.1

    /// The local day of an event: its own timezone, or UTC for an import.
    public static func dayOf(_ e: PlayEvent, _ tMs: Int64) -> Int64 {
        BrainMath.localDay(tMs, tzOffsetMin: e.tzOffsetMin == PlayEvent.tzUnknown ? 0 : e.tzOffsetMin)
    }

    /// The feature vector of play `e` from the state just before it (5.8), without the origin one-hot. `liked` says the
    /// track was a favourite. Fills `out` (length `Ranker.d`).
    public static func featuresOf(_ e: PlayEvent, liked: Bool, affinity: Affinity.State, session: SessionState, nowMs: Int64,
                                  p0: Double, out: inout [Double]) {
        let c = Candidate(rid: e.rid, aid: e.primaryAid, inLibrary: true, liked: liked)
        let retrieval = e.retrQ >= 0 ? Double(e.retrQ) / 1000.0 : 0.0
        let bestRank: Int32 = e.radioRank > 0 ? e.radioRank : 0
        Features.compute(c, arm: e.arm, retrieval: retrieval, bestRank: bestRank, affinity: affinity, session: session,
                         graph: Graph.empty, nowMs: nowMs, p0: p0, allNovel: false, out: &out)
    }

    /// True for a play that can be graded for the gate and the accuracy: it counted, was heard, and is a clear finish or a clear skip.
    public static func isGradedLabel(_ e: PlayEvent, _ g: Reward.Graded) -> Bool {
        g.c > 0.0 && !e.has(EventFlags.neverAudible) && (g.r >= 1.0 || g.r <= skippedMax)
    }

    /// One live play into `model` (5.9, "Timing"): the same steps `run` takes for one event, from the state as it is before
    /// the play is applied. The caller applies the tables and the session afterwards. Returns `Ranker.updateApplied`,
    /// `updateSkipped` or `updateReset` (the model went back to its prior: the caller schedules a replay). Cost: one
    /// feature vector and 51 multiply-adds, no allocation but a 51-double vector.
    @discardableResult
    public static func applyLive(_ model: inout RankerModel, _ e: PlayEvent, _ g: Reward.Graded, liked: Bool,
                                 affinity: Affinity.State, session: SessionState, nowMs: Int64) -> Int {
        let t = e.startedAtMs > nowMs ? nowMs : e.startedAtMs
        var x = [Double](repeating: 0.0, count: Ranker.d)
        let p0 = Affinity.p0(affinity, nowMs: t)
        featuresOf(e, liked: liked, affinity: affinity, session: session, nowMs: t, p0: p0, out: &x)
        let originIndex = originIndexOf(e.origin)
        if originIndex >= 0 { x[originIndex] = 1.0 }
        return Ranker.applyEvent(&model, x, r: g.r, c: g.c, bias: Ranker.biasOf(p0), day: dayOf(e, t), eventId: e.eventId)
    }

    private static func originIndexOf(_ origin: Int32) -> Int {
        if origin == Origin.importSpotify { return originBase }
        if origin == Origin.importYtm { return originBase + 1 }
        if origin == Origin.migratedHistory { return originBase + 2 }
        return -1
    }

    public struct Result: Sendable {
        /// The affinity tables, equal to `Replay.rebuild`'s.
        public let state: Affinity.State
        public let model: RankerModel
        public let predictions: Gate.Predictions
        /// Events replayed.
        public let events: Int
        /// The id of the newest event replayed: the watermark the live path catches up from.
        public let lastEventId: Int64
    }

    /// Replays `events` (ascending `eventId`, rids already mapped through `track_merge`, as `Replay.rebuild` needs them).
    /// Every event time is clamped to `nowMs`. `likedRids` are the favourites (feature 8); `tzNowMin` is the device's offset
    /// now, for the last forgetting up to today. Plays at or below `learnAfterEventId` still build the tables and the
    /// session but are not predicted or learned from ("Reset what I've learned").
    public static func run<Events: Sequence>(_ events: Events, facts: LibraryFacts, nowMs: Int64, likedRids: Set<Int64>,
                                             tzNowMin: Int32 = 0, learnAfterEventId: Int64 = Int64.min) -> Result
        where Events.Element == PlayEvent {
        var affinity = Affinity.State()
        affinity.recordsTouched = false
        Replay.applyFacts(&affinity, facts)
        var tracker = GradeTracker()
        var session = SessionState()
        var model: RankerModel?
        var x = [Double](repeating: 0.0, count: Ranker.d)
        var times: [Int64] = []
        var sessions: [Int64] = []
        var finished: [Bool] = []
        var pl: [Double] = []
        var pp: [Double] = []
        var thr: [Double] = []
        var count = 0
        var lastId = Int64.min
        for e in events {
            let t = e.startedAtMs > nowMs ? nowMs : e.startedAtMs
            let day = dayOf(e, t)
            if Session.isExpired(session, startedAtMs: t) { session = SessionState() }
            _ = Session.begin(&session, startedAtMs: t, startReason: e.startReason)
            let g = tracker.grade(e, completions: affinity.completions)
            if e.eventId <= learnAfterEventId {
                let novelOld = !Affinity.isHeard(affinity, family: Family.track, key: e.rid)
                Affinity.applyEvent(&affinity, e, g, tMs: t)
                Session.apply(&session, e, g, novel: novelOld)
                count += 1
                lastId = e.eventId
                continue
            }
            if model == nil {
                var fresh = Ranker.newModel(today: day)
                fresh.lastEventId = learnAfterEventId == Int64.min ? Int64.min : learnAfterEventId
                model = fresh
            }
            let p0 = Affinity.p0(affinity, nowMs: t)
            featuresOf(e, liked: likedRids.contains(e.rid), affinity: affinity, session: session, nowMs: t, p0: p0, out: &x)
            let bias = Ranker.biasOf(p0)
            Ranker.forget(&model!, today: day)
            if isGradedLabel(e, g) {
                times.append(t)
                sessions.append(e.sessionId)
                finished.append(g.r >= 1.0)
                pl.append(Ranker.predict(model!, x, bias: bias))
                pp.append(Ranker.predictPrior(x, p0: p0))
                thr.append(BrainMath.clip(p0, 0.05, 0.95))
            }
            // Training only: the origin one-hot absorbs the bias of imported and migrated rows.
            let originIndex = originIndexOf(e.origin)
            if originIndex >= 0 { x[originIndex] = 1.0 }
            Ranker.applyEvent(&model!, x, r: g.r, c: g.c, bias: bias, day: day, eventId: e.eventId)
            let novel = !Affinity.isHeard(affinity, family: Family.track, key: e.rid)
            Affinity.applyEvent(&affinity, e, g, tMs: t)
            Session.apply(&session, e, g, novel: novel)
            count += 1
            lastId = e.eventId
        }
        affinity.recordsTouched = true
        var finalModel = model ?? {
            var fresh = Ranker.newModel(today: BrainMath.localDay(nowMs, tzOffsetMin: tzNowMin))
            fresh.lastEventId = learnAfterEventId
            return fresh
        }()
        Ranker.forget(&finalModel, today: BrainMath.localDay(nowMs, tzOffsetMin: tzNowMin))
        let pred = Gate.Predictions(times: times, sessions: sessions, finished: finished, learned: pl, prior: pp, threshold: thr)
        return Result(state: affinity, model: finalModel, predictions: pred, events: count, lastEventId: lastId)
    }

    // MARK: Test 6 (11): learned weights against the frozen prior

    public struct Test6Report: Sendable {
        /// Graded plays the comparison is over (the last `Gate.window`).
        public let plays: Int
        public let logLossLearned: Double
        public let logLossPrior: Double
        /// `(prior - learned) / prior`.
        public let improvement: Double
        /// 2.5 and 97.5 percentiles of the mean per-play log-loss gain over session resamples (positive: learned is better).
        public let gainLow: Double
        public let gainHigh: Double
        /// At least 2,000 graded plays, a gain of at least 1% and an interval above 0. Otherwise the listener keeps the prior.
        public let passes: Bool
        /// False below 2,000 graded plays: the test does not apply and the answer is "keep the prior".
        public let enoughPlays: Bool
    }

    public static let test6MinPlays = 2000
    public static let test6MinImprovement = 0.01

    public static func test6(_ pred: Gate.Predictions, resamples: Int = 200, seed: Int64 = 1) -> Test6Report {
        let n = pred.size
        let from = n > Gate.window ? n - Gate.window : 0
        let plays = n - from
        let llL = Gate.logLoss(pred.learned, pred.finished, from: from, to: n)
        let llP = Gate.logLoss(pred.prior, pred.finished, from: from, to: n)
        let improvement = plays == 0 || llP <= 0.0 ? 0.0 : (llP - llL) / llP
        let enough = n >= test6MinPlays
        var low = 0.0
        var high = 0.0
        if plays > 0 && resamples > 0 {
            // Per-session sums of the per-play gain; resampling sessions keeps the plays of one sitting together.
            var groupOf: [Int64: Int] = [:]
            var sum: [Double] = []
            var cnt: [Int] = []
            for i in from..<n {
                let gi: Int
                if let known = groupOf[pred.sessions[i]] {
                    gi = known
                } else {
                    sum.append(0.0)
                    cnt.append(0)
                    gi = sum.count - 1
                    groupOf[pred.sessions[i]] = gi
                }
                let pl = BrainMath.clip(pred.learned[i], Gate.pEdge, 1.0 - Gate.pEdge)
                let pr = BrainMath.clip(pred.prior[i], Gate.pEdge, 1.0 - Gate.pEdge)
                let lossL = pred.finished[i] ? -BrainMath.ln(pl) : -BrainMath.ln(1.0 - pl)
                let lossP = pred.finished[i] ? -BrainMath.ln(pr) : -BrainMath.ln(1.0 - pr)
                sum[gi] = sum[gi] + (lossP - lossL)
                cnt[gi] = cnt[gi] + 1
            }
            let groups = sum.count
            var rng = BrainHash.Rng(seed: BrainHash.splitmix64(UInt64(bitPattern: seed)))
            var gains = [Double](repeating: 0.0, count: resamples)
            for r in 0..<resamples {
                var s = 0.0
                var c = 0
                for _ in 0..<groups {
                    let pick = Int(clampInt(BrainMath.floorToLong(rng.uniform() * Double(groups)), 0, Int64(groups - 1)))
                    s += sum[pick]
                    c += cnt[pick]
                }
                gains[r] = c == 0 ? 0.0 : s / Double(c)
            }
            gains.sort()
            low = gains[Int(clampInt(BrainMath.floorToLong(0.025 * Double(resamples)), 0, Int64(resamples - 1)))]
            high = gains[Int(clampInt(BrainMath.floorToLong(0.975 * Double(resamples)), 0, Int64(resamples - 1)))]
        }
        return Test6Report(plays: plays, logLossLearned: llL, logLossPrior: llP, improvement: improvement, gainLow: low,
                           gainHigh: high, passes: enough && improvement >= test6MinImprovement && low > 0.0,
                           enoughPlays: enough)
    }

    private static func clampInt(_ v: Int64, _ lo: Int64, _ hi: Int64) -> Int64 { v < lo ? lo : (v > hi ? hi : v) }
}
