// The evaluation harness (docs/brain-spec.md, 11), pure: it takes events and facts and returns a report. Stage 2a runs
// test 1 (skip prediction, `skipPrediction`) and test 5 (list health over 30 simulated daily builds, `listHealth`).
// Test 7 is the golden files. Tests 2, 3 and 4 need the stage 2b arms and are not here; test 6 is stage 3. A
// transliteration of the Android `:brain` module's `Eval.kt`.
//
// Protocol: prequential. Every event is first predicted (from the state built by the events before it) and only then
// applied, so nothing after a play can influence its prediction. The hold-out is the last 8 weeks of the history, or
// its last 15% of events when the history is shorter than 16 weeks. Intervals are bootstrap percentiles over
// resampled sessions, drawn with SplitMix64 so the report is the same on both platforms.
//
// Arithmetic is integer where it can be: AUC is an exact count of won pairs, so it does not depend on how a platform
// rounds a sum of doubles.

/// The harness.
public enum Eval {
    public static let weekMs: Int64 = 7 * 86_400_000

    public struct Config: Sendable {
        public var holdOutMs: Int64
        public var holdOutFraction: Double
        /// Calibration bins.
        public var bins: Int
        /// Session resamples for the intervals.
        public var resamples: Int
        public var seed: Int64

        public init(holdOutMs: Int64 = 8 * Eval.weekMs, holdOutFraction: Double = 0.15, bins: Int = 10,
                    resamples: Int = 200, seed: Int64 = 1) {
            self.holdOutMs = holdOutMs
            self.holdOutFraction = holdOutFraction
            self.bins = bins
            self.resamples = resamples
            self.seed = seed
        }
    }

    /// Another predictor to compare with, given the state before the event (read only). A higher score means "will be
    /// finished". The legacy engine's score is one of these, supplied by the app.
    public typealias Baseline = @Sendable (PlayEvent, Affinity.State, Int64) -> Double

    /// Built in: the artist's plain finish rate so far (pos / (pos + neg), shrunk by one pseudo-play).
    public static let artistRate: Baseline = { e, affinity, now in
        guard let k = affinity.counter(Family.artist, e.primaryAid) else { return 0.5 }
        let p = Affinity.pos(k, nowMs: now)
        let n = Affinity.neg(k, nowMs: now)
        return (p + 0.5) / (p + n + 1.0)
    }

    /// Built in: how often the track was finished before (the popularity-of-this-listener baseline).
    public static let trackCompletions: Baseline = { e, affinity, _ in Double(affinity.completions[e.rid] ?? 0) }

    public struct Labeled: Sendable {
        /// True: the play was finished (`r = 1`). False: it was skipped (`r <= 0.1`).
        public var finished: Bool
        public var sessionId: Int64
        /// The brain's prior scorer: `p` of 5.7 with the weights `M0`.
        public var brain: Double
        /// One per baseline, in the order they were given.
        public var baselines: [Double]
    }

    public struct SkipReport: Sendable {
        /// Events before the cut (training) and after it (held out, graded).
        public var trainEvents: Int
        public var heldOutEvents: Int
        public var labeled: [Labeled]
        public var finished: Int
        public var skipped: Int
        public var brainAuc: Double
        public var baselineNames: [String]
        public var baselineAuc: [Double]
        /// `brainAuc - baselineAuc[i]`, and the 2.5 and 97.5 percentiles of that difference over session resamples.
        public var delta: [Double]
        public var deltaLow: [Double]
        public var deltaHigh: [Double]
        /// Expected calibration error of the brain's `p` over `Config.bins` bins.
        public var calibrationError: Double
    }

    /// Where the hold-out starts: the index of its first event. `events` are in ascending `eventId`.
    public static func cutIndex(_ events: [PlayEvent], config: Config = Config()) -> Int {
        if events.isEmpty { return 0 }
        let first = events[0].startedAtMs
        let last = events[events.count - 1].startedAtMs
        if last &- first >= 2 &* config.holdOutMs {
            let from = last &- config.holdOutMs
            var i = 0
            while i < events.count && events[i].startedAtMs < from { i += 1 }
            return i
        }
        let held = Int(BrainMath.floorToLong(Double(events.count) * config.holdOutFraction))
        return events.count - (held < 1 ? 1 : held)
    }

    public static let defaultBaselines: [(String, Baseline)] = [("artistRate", artistRate), ("trackCompletions", trackCompletions)]

    /// Test 1: skip prediction on the held-out plays.
    public static func skipPrediction(_ events: [PlayEvent], facts: LibraryFacts, config: Config = Config(),
                                      baselines: [(String, Baseline)] = defaultBaselines) -> SkipReport {
        let cut = cutIndex(events, config: config)
        var affinity = Affinity.State()
        Replay.applyFacts(&affinity, facts)
        var likedRids: Set<Int64> = []
        for f in facts.liked { likedRids.insert(f.rid) }
        var tracker = GradeTracker()
        var session = SessionState()
        let graph = Graph.empty
        var x = [Double](repeating: 0.0, count: Features.d)
        var labeled: [Labeled] = []
        for i in events.indices {
            let e = events[i]
            if Session.isExpired(session, startedAtMs: e.startedAtMs) { session = SessionState() }
            _ = Session.begin(&session, startedAtMs: e.startedAtMs, startReason: e.startReason)
            var brainP = 0.0
            var others: [Double] = []
            if i >= cut {
                let now = e.startedAtMs
                let p0 = Affinity.p0(affinity, nowMs: now)
                let c = Candidate(rid: e.rid, aid: e.primaryAid, inLibrary: true, liked: likedRids.contains(e.rid))
                Features.compute(c, arm: Arm.none, retrieval: 0.0, bestRank: 0, affinity: affinity, session: session,
                                 graph: graph, nowMs: now, p0: p0, allNovel: false, out: &x)
                brainP = Ranker.p(Ranker.z(Ranker.weights(p0: p0), x), x)
                others = baselines.map { $0.1(e, affinity, now) }
            }
            let novel = !Affinity.isHeard(affinity, family: Family.track, key: e.rid)
            let g = tracker.grade(e, completions: affinity.completions)
            Affinity.applyEvent(&affinity, e, g, tMs: e.startedAtMs)
            Session.apply(&session, e, g, novel: novel)
            if i >= cut && g.c > 0.0 && !e.has(EventFlags.neverAudible) {
                let finished = g.r >= 1.0
                let skipped = g.r <= 0.1
                if finished || skipped {
                    labeled.append(Labeled(finished: finished, sessionId: e.sessionId, brain: brainP, baselines: others))
                }
            }
        }
        var pos = 0
        for l in labeled where l.finished { pos += 1 }
        let names = baselines.map { $0.0 }
        let brainKeys = labeled.map { BrainMath.orderKey($0.brain) }
        let labels = labeled.map { $0.finished }
        let brainAuc = auc(brainKeys, labels)
        let baseKeys: [[Int64]] = baselines.indices.map { b in labeled.map { BrainMath.orderKey($0.baselines[b]) } }
        var baseAuc = [Double](repeating: 0.0, count: baselines.count)
        for b in baselines.indices { baseAuc[b] = auc(baseKeys[b], labels) }
        let delta = baselines.indices.map { brainAuc - baseAuc[$0] }
        var low = [Double](repeating: 0.0, count: baselines.count)
        var high = [Double](repeating: 0.0, count: baselines.count)
        if !labeled.isEmpty && pos > 0 && pos < labeled.count && config.resamples > 0 {
            let (lo, hi) = bootstrap(labeled, brainKeys: brainKeys, baseKeys: baseKeys, labels: labels, config: config)
            for b in baselines.indices {
                low[b] = lo[b]
                high[b] = hi[b]
            }
        }
        return SkipReport(
            trainEvents: cut,
            heldOutEvents: events.count - cut,
            labeled: labeled,
            finished: pos,
            skipped: labeled.count - pos,
            brainAuc: brainAuc,
            baselineNames: names,
            baselineAuc: baseAuc,
            delta: delta,
            deltaLow: low,
            deltaHigh: high,
            calibrationError: calibrationError(labeled, bins: config.bins)
        )
    }

    /// The area under the ROC curve of `keys` against `finished`, as an exact count of won pairs (ties count half).
    /// 0.5 when one of the classes is empty.
    public static func auc(_ keys: [Int64], _ finished: [Bool]) -> Double {
        let n = keys.count
        var pos: Int64 = 0
        for f in finished where f { pos += 1 }
        let neg = Int64(n) - pos
        if pos == 0 || neg == 0 { return 0.5 }
        let order = (0..<n).sorted { keys[$0] < keys[$1] }
        var wins2: Int64 = 0 // twice the number of won pairs, so a tie is an integer
        var negBelow: Int64 = 0
        var i = 0
        while i < n {
            var j = i
            var gp: Int64 = 0
            var gn: Int64 = 0
            while j < n && keys[order[j]] == keys[order[i]] {
                if finished[order[j]] { gp += 1 } else { gn += 1 }
                j += 1
            }
            wins2 += 2 * gp * negBelow + gp * gn
            negBelow += gn
            i = j
        }
        return Double(wins2) / (2.0 * Double(pos) * Double(neg))
    }

    /// Expected calibration error: the weighted mean of |mean prediction - finish rate| over equal-width bins.
    public static func calibrationError(_ labeled: [Labeled], bins: Int) -> Double {
        if labeled.isEmpty || bins <= 0 { return 0.0 }
        var sumP = [Double](repeating: 0.0, count: bins)
        var sumY = [Double](repeating: 0.0, count: bins)
        var count = [Int](repeating: 0, count: bins)
        for l in labeled {
            var b = Int(BrainMath.floorToLong(l.brain * Double(bins)))
            if b < 0 { b = 0 }
            if b >= bins { b = bins - 1 }
            sumP[b] += l.brain
            sumY[b] += l.finished ? 1.0 : 0.0
            count[b] += 1
        }
        var err = 0.0
        for b in 0..<bins {
            if count[b] == 0 { continue }
            err += Double(count[b]) * BrainMath.abs(sumP[b] / Double(count[b]) - sumY[b] / Double(count[b]))
        }
        return err / Double(labeled.count)
    }

    private static func bootstrap(_ labeled: [Labeled], brainKeys: [Int64], baseKeys: [[Int64]], labels: [Bool],
                                  config: Config) -> ([Double], [Double]) {
        // Sessions in order of first appearance; rows of one session stay together.
        var order: [Int64] = []
        var bySession: [Int64: [Int]] = [:]
        for i in labeled.indices {
            let sid = labeled[i].sessionId
            if bySession[sid] == nil {
                order.append(sid)
                bySession[sid] = []
            }
            bySession[sid]!.append(i)
        }
        let groups = order.map { bySession[$0]! }
        var rng = BrainHash.Rng(seed: BrainHash.splitmix64(UInt64(bitPattern: config.seed)))
        let nb = baseKeys.count
        var diffs = [[Double]](repeating: [Double](repeating: 0.0, count: config.resamples), count: nb)
        for r in 0..<config.resamples {
            var idx: [Int] = []
            idx.reserveCapacity(labeled.count)
            for _ in groups.indices {
                var g = Int(BrainMath.floorToLong(rng.uniform() * Double(groups.count)))
                if g < 0 { g = 0 }
                if g > groups.count - 1 { g = groups.count - 1 }
                idx.append(contentsOf: groups[g])
            }
            let l = idx.map { labels[$0] }
            let a = auc(idx.map { brainKeys[$0] }, l)
            for b in 0..<nb { diffs[b][r] = a - auc(idx.map { baseKeys[b][$0] }, l) }
        }
        var lo = [Double](repeating: 0.0, count: nb)
        var hi = [Double](repeating: 0.0, count: nb)
        for b in 0..<nb {
            diffs[b].sort()
            lo[b] = diffs[b][clampIndex(Int(BrainMath.floorToLong(0.025 * Double(config.resamples))), config.resamples)]
            hi[b] = diffs[b][clampIndex(Int(BrainMath.floorToLong(0.975 * Double(config.resamples))), config.resamples)]
        }
        return (lo, hi)
    }

    private static func clampIndex(_ i: Int, _ count: Int) -> Int { i < 0 ? 0 : (i > count - 1 ? count - 1 : i) }

    // MARK: Test 5: list health

    /// The world a list-health simulation runs in.
    public struct HealthWorld: Sendable {
        public var library: [Candidate]
        public var novel: [Candidate]
        public var seeds: [Retrieval.SeedList]
        /// How likely the listener finishes a track, 0..1, by rid. A track not listed is finished half the time.
        public var finishRate: [Int64: Double]

        public init(library: [Candidate], novel: [Candidate], seeds: [Retrieval.SeedList], finishRate: [Int64: Double]) {
            self.library = library
            self.novel = novel
            self.seeds = seeds
            self.finishRate = finishRate
        }
    }

    public struct HealthReport: Sendable {
        public var days: Int
        /// Distinct recordings over all recordings of the Daily Mixes of the period. Target at least 0.60.
        public var distinctRatio: Double
        /// The most any artist held of any list (a share of it). Target at most 0.10.
        public var maxArtistShare: Double
        /// The largest gap between a list's share of new music and the `nu` asked for. Target at most 0.05.
        public var maxNoveltyGap: Double
        /// The most recordings any day's two mixes share. Target 0.
        public var maxSameDayOverlap: Int
        public var shortestList: Int
        /// The mean finish rate the world gives the Daily Mix's tracks: how good the music was, by the listener's own
        /// taste.
        public var meanFinishRate: Double
    }

    /// Test 5: `days` simulated daily builds of a Daily Mix and a Your Mix from `world`, each followed by the listener
    /// playing the Daily Mix (finishing a track with the probability the world gives it), so the state moves the way
    /// it would. The served log feeds the repetition budget and the same-day rule.
    public static func listHealth(_ world: HealthWorld, start: Affinity.State, days: Int = 30,
                                  nowMs: Int64 = 1_760_000_000_000, tzOffsetMin: Int32 = 0, salt: Int64 = 7,
                                  nuMultiplier: Double = 1.0, jitter: Double = MixPlanner.jitter,
                                  servedMax: Double = Repetition.maxPenalty) -> HealthReport {
        var affinity = start
        var tracker = GradeTracker()
        var served: [Repetition.Served] = []
        var rng = BrainHash.Rng(seed: BrainHash.splitmix64(UInt64(bitPattern: salt ^ 0x5EED)))
        var aidOf: [Int64: Int64] = [:]
        var novelOf: Set<Int64> = []
        for c in world.library { aidOf[c.rid] = c.aid }
        for c in world.novel {
            aidOf[c.rid] = c.aid
            novelOf.insert(c.rid)
        }
        var builds: [[Int64]] = []
        var maxShare = 0.0
        var maxGap = 0.0
        var maxOverlap = 0
        var shortest = Int.max
        var eventSeq: Int64 = 0
        var rateSum = 0.0
        var rateCount = 0
        for day in 0..<days {
            let t = nowMs &+ Int64(day) &* Repetition.dayMs
            var pool: [Candidate] = []
            pool.reserveCapacity(world.library.count + world.novel.count)
            pool.append(contentsOf: world.library)
            pool.append(contentsOf: world.novel)
            let times = Repetition.timesServed(served, nowMs: t)
            let dailyReq = MixPlanner.Request(
                kind: MixPlanner.kindDaily, candidates: pool, seeds: world.seeds, nowMs: t, tzOffsetMin: tzOffsetMin,
                nuMultiplier: nuMultiplier, salt: salt,
                excludedRids: Repetition.takenOnDay(served, nowMs: t, tzOffsetMin: tzOffsetMin, exceptSurface: Surface.dailyMix),
                servedTimes: times, jitter: jitter, servedMax: servedMax)
            let daily = MixPlanner.plan(dailyReq, affinity: affinity)
            let dailyRids = daily.picks.map { $0.rid }
            served.append(Repetition.Served(surface: Surface.dailyMix, builtAtMs: t, rids: dailyRids))
            let yourReq = MixPlanner.Request(
                kind: MixPlanner.kindYour, candidates: pool, seeds: world.seeds, nowMs: t &+ 1, tzOffsetMin: tzOffsetMin,
                nuMultiplier: nuMultiplier, salt: salt,
                excludedRids: Repetition.takenOnDay(served, nowMs: t &+ 1, tzOffsetMin: tzOffsetMin, exceptSurface: Surface.yourMix),
                servedTimes: times, jitter: jitter, servedMax: servedMax)
            let your = MixPlanner.plan(yourReq, affinity: affinity)
            let yourRids = your.picks.map { $0.rid }
            served.append(Repetition.Served(surface: Surface.yourMix, builtAtMs: t &+ 1, rids: yourRids))
            builds.append(dailyRids)
            for r in dailyRids {
                rateSum += world.finishRate[r] ?? 0.5
                rateCount += 1
            }
            for (plan, kind) in [(daily, MixPlanner.kindDaily), (your, MixPlanner.kindYour)] {
                if plan.picks.isEmpty { continue }
                if plan.picks.count < shortest { shortest = plan.picks.count }
                let aids = plan.picks.map { aidOf[$0.rid] ?? 0 }
                let share = Repetition.maxArtistShare(aids)
                if share > maxShare { maxShare = share }
                var novelCount = 0
                for p in plan.picks where novelOf.contains(p.rid) { novelCount += 1 }
                let gap = BrainMath.abs(Double(novelCount) / Double(plan.picks.count) - MixPlanner.nuOf(kind, multiplier: nuMultiplier))
                if gap > maxGap { maxGap = gap }
            }
            let mine = Set(dailyRids)
            var overlap = 0
            for r in yourRids where mine.contains(r) { overlap += 1 }
            if overlap > maxOverlap { maxOverlap = overlap }
            // The listener plays the Daily Mix.
            var at = t &+ 6 &* 3_600_000
            for rid in dailyRids {
                let rate = world.finishRate[rid] ?? 0.5
                let done = rng.uniform() < rate
                let duration: Int32 = 200_000
                eventSeq += 1
                let e = PlayEvent(
                    eventId: (at &<< 16) | (eventSeq & 0xFFFF), origin: Origin.live, rid: rid, primaryAid: aidOf[rid] ?? 0,
                    startedAtMs: at, playedMs: done ? duration : 6_000, durationMs: duration,
                    startReason: StartReason.tap, endReason: done ? EndReason.trackDone : EndReason.next,
                    surface: Surface.dailyMix, arm: Arm.none, sessionId: at / 1_000)
                let g = tracker.grade(e, completions: affinity.completions)
                Affinity.applyEvent(&affinity, e, g, tMs: at)
                at = at &+ (done ? Int64(duration) : 6_000)
            }
        }
        return HealthReport(
            days: days,
            distinctRatio: Repetition.distinctRatio(builds),
            maxArtistShare: maxShare,
            maxNoveltyGap: maxGap,
            maxSameDayOverlap: maxOverlap,
            shortestList: shortest == Int.max ? 0 : shortest,
            meanFinishRate: rateCount == 0 ? 0.0 : rateSum / Double(rateCount)
        )
    }
}
