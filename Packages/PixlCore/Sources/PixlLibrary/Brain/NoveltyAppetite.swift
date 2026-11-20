// The listener's novelty appetite (docs/brain-spec.md, 5.10): the share of slots given to music they have never played. A
// transliteration of the Android `:brain` module's `NoveltyAppetite.kt`; `novelty.jsonl` pins it bit for bit.
//
// ```
// nu0      = clip( share of qualified plays in the trailing 365 days that were the track's first play, 0.08, 0.50 ) ; 0.25 with no history
// F, N     = two discounted Beta posteriors on recommender surfaces: familiar plays and novel plays
// nuLong   = clip( nu0 * (mean(N) / mean(F))^1.5, 0.08, 0.60 ), moving at most 0.02 per day
// boost    = +0.01 per novel track liked or saved, fading to nothing over 30 days, at most +0.10
// nu       = clip(nuLong + boost, 0, 0.60)
// surface  = nu * k    (k = 1.0 mixes, 1.2 a station from a seed, 0.8 autoplay after an album or playlist, 0 On Repeat and Rediscover)
// switch   = Familiar / Blend / Discover multiplies it by 0.4 / 1.0 / 2.0
// ```
//
// Choices the spec leaves open (Android deviation 192, which holds here): F and N start at Beta(4, 4) each, the daily discount
// is 0.98 like the arm bandit's, the boost fades linearly, and a "qualified" play is one with `c > 0` that is not excluded
// from learning. Learned state: it replaces the stage 2 constant only while the gate has the learned weights on.

/// The novelty appetite.
public enum NoveltyAppetite {
    public static let nu0Default = 0.25
    public static let nu0Min = 0.08
    public static let nu0Max = 0.50
    public static let nuLongMin = 0.08
    public static let nuLongMax = 0.60

    /// The most `nuLong` moves toward its target in one day.
    public static let maxStepPerDay = 0.02

    public static let boostEach = 0.01
    public static let boostCap = 0.10
    public static let boostDays = 30

    public static let windowDays = 365

    public static let prior = 4.0
    public static let dailyDiscount = 0.98
    public static let maxForgetRuns = 30

    /// At most this many boosting likes are kept (the cap is reached at ten whole ones).
    public static let maxBoosts = 64

    public struct State: Sendable {
        public var fAlpha: Double
        public var fBeta: Double
        public var nAlpha: Double
        public var nBeta: Double
        /// The slow appetite; NaN until the first day it is advanced.
        public var nuLong: Double
        public var anchorDay: Int64
        public var forgetDone: Int
        /// The day `nuLong` was last advanced to.
        public var nuDay: Int64
        /// Local day -> (qualified plays, first plays). Days older than the window are dropped.
        public var days: [Int64: [Int]]
        /// Start times of the novel tracks liked or saved in the last `boostDays` days, oldest first.
        public var boosts: [Int64]
        /// Recommender plays counted into F and N since the state was created or reset.
        public var updates: Int64

        public init(fAlpha: Double = NoveltyAppetite.prior, fBeta: Double = NoveltyAppetite.prior,
                    nAlpha: Double = NoveltyAppetite.prior, nBeta: Double = NoveltyAppetite.prior,
                    nuLong: Double = Double.nan, anchorDay: Int64 = 0, forgetDone: Int = 0, nuDay: Int64 = Int64.min,
                    days: [Int64: [Int]] = [:], boosts: [Int64] = [], updates: Int64 = 0) {
            self.fAlpha = fAlpha
            self.fBeta = fBeta
            self.nAlpha = nAlpha
            self.nBeta = nBeta
            self.nuLong = nuLong
            self.anchorDay = anchorDay
            self.forgetDone = forgetDone
            self.nuDay = nuDay
            self.days = days
            self.boosts = boosts
            self.updates = updates
        }

        public func isValid() -> Bool {
            BrainMath.isFinite(fAlpha) && fAlpha > 0.0 && BrainMath.isFinite(fBeta) && fBeta > 0.0
                && BrainMath.isFinite(nAlpha) && nAlpha > 0.0 && BrainMath.isFinite(nBeta) && nBeta > 0.0
                && (nuLong != nuLong || (nuLong >= NoveltyAppetite.nuLongMin - 1e-9 && nuLong <= NoveltyAppetite.nuLongMax + 1e-9))
        }
    }

    public static func newState(today: Int64) -> State { State(anchorDay: today) }

    /// Discounts F and N toward their priors up to local day `today`, the same pure-of-the-days rule as `ArmBandit.discount`.
    @discardableResult
    public static func discount(_ state: inout State, today: Int64) -> Int {
        if today < state.anchorDay {
            state.anchorDay = today
            state.forgetDone = 0
            return 0
        }
        let gap = today &- state.anchorDay
        let total = gap > Int64(maxForgetRuns) ? maxForgetRuns : Int(gap)
        let runs = total - state.forgetDone
        if runs <= 0 { return 0 }
        for _ in 0..<runs {
            state.fAlpha = prior + (state.fAlpha - prior) * dailyDiscount
            state.fBeta = prior + (state.fBeta - prior) * dailyDiscount
            state.nAlpha = prior + (state.nAlpha - prior) * dailyDiscount
            state.nBeta = prior + (state.nBeta - prior) * dailyDiscount
        }
        state.forgetDone = total
        return runs
    }

    /// The share of qualified plays in the trailing `windowDays` days (up to `today`) that were a first play, clipped;
    /// `nu0Default` with none.
    public static func nu0(_ state: State, today: Int64) -> Double {
        var plays = 0
        var first = 0
        let from = today - Int64(windowDays)
        for (day, v) in state.days where day >= from && day <= today {
            plays += v[0]
            first += v[1]
        }
        if plays == 0 { return nu0Default }
        return BrainMath.clip(Double(first) / Double(plays), nu0Min, nu0Max)
    }

    /// `nu0 * (mean(N) / mean(F))^1.5`, clipped: where the slow appetite is heading. `x^1.5 = x * sqrt(x)`.
    public static func target(_ state: State, today: Int64) -> Double {
        let meanF = state.fAlpha / (state.fAlpha + state.fBeta)
        let meanN = state.nAlpha / (state.nAlpha + state.nBeta)
        let ratio = meanN / meanF
        return BrainMath.clip(nu0(state, today: today) * ratio * BrainMath.sqrt(ratio), nuLongMin, nuLongMax)
    }

    /// Moves the slow appetite toward its target by at most `maxStepPerDay` for each day since it was last advanced (and at
    /// most 60 days' worth at once). The first time it takes the target at once, so a listener with no evidence starts at
    /// `nu0`. Days only go forward.
    public static func advance(_ state: inout State, today: Int64) {
        discount(&state, today: today)
        let tgt = target(state, today: today)
        if state.nuLong != state.nuLong || state.nuDay == Int64.min {
            state.nuLong = tgt
            state.nuDay = today
            return
        }
        if today <= state.nuDay { return }
        let gap = today - state.nuDay
        let days = gap > 60 ? Int64(60) : gap
        let step = maxStepPerDay * Double(days)
        state.nuLong = BrainMath.clip(state.nuLong + BrainMath.clip(tgt - state.nuLong, -step, step), nuLongMin, nuLongMax)
        state.nuDay = today
    }

    /// The boost of the novel tracks liked or saved in the last `boostDays` days, fading linearly, at most `boostCap`.
    public static func boost(_ state: State, nowMs: Int64) -> Double {
        let span = Double(boostDays) * Double(BrainMath.dayMs)
        var sum = 0.0
        for t in state.boosts {
            let age = Double(nowMs - t)
            if age < 0.0 || age >= span { continue }
            sum += 1.0 - age / span
        }
        return BrainMath.min(boostCap, boostEach * sum)
    }

    /// The share of slots for music the listener has never played, before the surface factor and the switch.
    public static func nu(_ state: State, nowMs: Int64) -> Double {
        let base = state.nuLong != state.nuLong ? nu0(state, today: BrainMath.localDay(nowMs, tzOffsetMin: 0)) : state.nuLong
        return BrainMath.clip(base + boost(state, nowMs: nowMs), 0.0, nuLongMax)
    }

    /// One play, as both the live path and the replay take it. `novel` is true when it was the first play of the track;
    /// `recommender` when it came from a recommender surface (an engine arm on an engine surface); `day` is its local day.
    /// Returns true when the state moved.
    @discardableResult
    public static func onPlay(_ state: inout State, _ e: PlayEvent, _ g: Reward.Graded, novel: Bool, recommender: Bool,
                              day: Int64) -> Bool {
        advance(&state, today: day)
        // The discount counts from the last day a play was applied, as `ArmBandit.update` does. Without moving the anchor, a gap of
        // 30 days or more spends all 30 runs once and F and N are never discounted again.
        state.anchorDay = day
        state.forgetDone = 0
        if !(g.c > 0.0) || e.has(EventFlags.learnExcluded) || e.has(EventFlags.neverAudible) { return false }
        var counts = state.days[day] ?? [0, 0]
        counts[0] += 1
        if novel { counts[1] += 1 }
        state.days[day] = counts
        // Keep the window: older days never count again.
        let oldest = day - Int64(windowDays) - 1
        for k in state.days.keys where k < oldest { state.days.removeValue(forKey: k) }
        if recommender {
            let cc = g.c > Ranker.cMax * 1.5 ? Ranker.cMax * 1.5 : g.c
            let r = BrainMath.clip(g.r, 0.0, 1.0)
            if novel {
                state.nAlpha += cc * r
                state.nBeta += cc * (1.0 - r)
            } else {
                state.fAlpha += cc * r
                state.fBeta += cc * (1.0 - r)
            }
            state.updates += 1
        }
        let liked = (e.flags & (EventFlags.likedDuring | EventFlags.savedDuring)) != 0 && !e.has(EventFlags.notForMe)
        if liked && novel {
            state.boosts.append(e.startedAtMs)
            while state.boosts.count > maxBoosts { state.boosts.removeFirst() }
        }
        return true
    }

    /// Drops the boosts that have faded out by `nowMs`.
    public static func prune(_ state: inout State, nowMs: Int64) {
        let span = Int64(boostDays) * BrainMath.dayMs
        state.boosts.removeAll { nowMs - $0 >= span }
    }
}
