// The learner of docs/brain-spec.md, 5.9 and 5.12 (stage 3): the diagonal extended-Kalman step, its forgetting, the
// per-list posterior sample of 5.10 and the weights a list is ranked with. A transliteration of the Android `:brain`
// module's `Ranker.kt` (the part after `precision`). It has only ever run on synthetic listeners: the gate of 5.12
// point 8 (`Gate`) decides whether its weights are used at all.

/// What the learner holds: the mean and precision of each of the 51 weights, the prior they are boxed around, the
/// forgetting anchor, the watermark of the last play applied, and how many plays moved the weights since the model was
/// last at its prior. A cache: `LearnReplay` reproduces it from the log.
public struct RankerModel: Sendable, Equatable {
    /// Rounding of a bit pattern that went through text.
    static let boxSlack = 1e-9

    public var m: [Double]
    public var q: [Double]
    /// The prior mean (`M0`, bias 0); each `m[i]` is boxed around it.
    public var m0: [Double]
    /// The local day of the last applied play (or of creation): the forgetting counts from it.
    public var anchorDay: Int64
    /// Plays that moved the weights since the model was created or last reset to its prior.
    public var updates: Int64
    /// The id of the newest event applied; an event at or below it is never applied again.
    public var lastEventId: Int64
    /// Forgetting runs already made since `anchorDay`.
    public var forgetDone: Int
    /// How many times the model was reset to its prior because a value was not finite.
    public var resets: Int

    public init(m: [Double], q: [Double], m0: [Double], anchorDay: Int64, updates: Int64 = 0,
                lastEventId: Int64 = Int64.min, forgetDone: Int = 0, resets: Int = 0) {
        self.m = m
        self.q = q
        self.m0 = m0
        self.anchorDay = anchorDay
        self.updates = updates
        self.lastEventId = lastEventId
        self.forgetDone = forgetDone
        self.resets = resets
    }

    /// Every value finite, every precision above 0, every mean inside its box.
    public func isValid() -> Bool {
        if m.count != Ranker.d || q.count != Ranker.d || m0.count != Ranker.d { return false }
        for i in 0..<Ranker.d {
            if !BrainMath.isFinite(m[i]) || !BrainMath.isFinite(q[i]) || !(q[i] > 0.0) { return false }
            let lo = m0[i] - Ranker.boxSd * Ranker.sd0(i) - RankerModel.boxSlack
            let hi = m0[i] + Ranker.boxSd * Ranker.sd0(i) + RankerModel.boxSlack
            if m[i] < lo || m[i] > hi { return false }
        }
        return true
    }

    /// Back to `m = M0`, `q = 1 / SD0^2`; the watermark and the anchor are kept, `updates` starts again at 0, `resets` counts it.
    public mutating func resetToPrior() {
        let q0 = Ranker.priorPrecision()
        for i in 0..<Ranker.d {
            m[i] = m0[i]
            q[i] = q0[i]
        }
        updates = 0
        forgetDone = 0
        resets += 1
    }

    /// True when the weights are the prior exactly (nothing learned yet, or reset).
    public func isPrior() -> Bool {
        let q0 = Ranker.priorPrecision()
        for i in 0..<Ranker.d where m[i] != m0[i] || q[i] != q0[i] { return false }
        return true
    }
}

extension Ranker {
    /// The most one update may move a weight.
    public static let stepClip = 0.25

    /// The floor of the curvature `h = p(1 - p)`.
    public static let hFloor = 0.02

    /// Each `m[i]` stays within `m0[i] +- boxSd * sd0[i]` (5.12 point 2).
    public static let boxSd = 4.0

    /// Every feature of 5.8 is in about -3..3; an input beyond this is a bug somewhere else and is not learned from.
    public static let xMax = 4.0

    /// The trust weight `Reward` can give (`maxC`); a larger value is clipped.
    public static let cMax = 4.5

    /// Daily forgetting of the precision toward the prior, and of the weight toward `M0`.
    public static let qKeep = 0.995
    public static let mPull = 0.001

    /// The daily line runs at most this many times for one stretch without a play.
    public static let maxForgetRuns = 30

    public static let updateApplied = 0

    /// No weight, an input that is not finite or too large, or an event that was already applied: nothing changed.
    public static let updateSkipped = 1

    /// A value was not finite (or the model was not valid): the model went back to its prior; the caller schedules a replay.
    public static let updateReset = 2

    /// The prior precision vector, as a copy.
    public static func priorPrecision() -> [Double] { q0Table }

    /// A fresh model: `m = M0`, `q = 1 / SD0^2`, the forgetting counting from `today`.
    ///
    /// The bias is learned as an OFFSET from the live `logit(p0)`: `m[0]` starts at 0 and is boxed around 0, and the
    /// weight vector that ranks (`weightsFor`) and the predictions (`predict`, `update`) add `logit(p0)` to it. So the
    /// learned model and the prior share one intercept that follows the listener's own finish rate, the gate compares
    /// ranking and not calibration, and "Reset what I've learned" returns exactly to `M0` with the live `logit(p0)`
    /// (deviation 175 from the spec's "bias fixed at the first rebuild").
    public static func newModel(today: Int64) -> RankerModel {
        var prior = m0Table
        prior[0] = 0.0
        return RankerModel(m: prior, q: q0Table, m0: prior, anchorDay: today)
    }

    /// `s = sum_i x_i^2 / q_i`, by index.
    public static func s(_ q: [Double], _ x: [Double]) -> Double {
        var s = 0.0
        for i in 0..<d { s += x[i] * x[i] / q[i] }
        return s
    }

    /// `p = sigmoid(z / sqrt(1 + 0.3927 * s))` for any precision vector `q`.
    public static func p(_ z: Double, _ x: [Double], _ q: [Double]) -> Double {
        BrainMath.sigmoid(z / BrainMath.sqrt(1.0 + probit * s(q, x)))
    }

    /// `z` of a model's mean with the intercept `bias` added to index 0, summed in exactly the order `z` sums
    /// `weights`: a model that is still at its prior then predicts bit for bit what the prior does, so the gate cannot
    /// see a difference that is only rounding.
    public static func zBiased(_ m: [Double], bias: Double, _ x: [Double]) -> Double {
        var z = (m[0] + bias) * x[0]
        for i in 1..<d { z += m[i] * x[i] }
        return z
    }

    /// The learned model's predicted finish probability for `x`; `bias` is `logit(p0)` of the moment.
    public static func predict(_ model: RankerModel, _ x: [Double], bias: Double) -> Double {
        p(zBiased(model.m, bias: bias, x), x, model.q)
    }

    /// The frozen prior's prediction for `x`, with the same intercept: the weights `M0` and the bias `logit(p0)`.
    public static func predictPrior(_ x: [Double], p0: Double) -> Double { p(z(weights(p0: p0), x), x, q0Table) }

    /// `logit` of a finish rate kept inside 0.05..0.95, the way `weights` callers do.
    public static func biasOf(_ p0: Double) -> Double { BrainMath.logit(BrainMath.clip(p0, 0.05, 0.95)) }

    /// One online step with the soft target `r` and weight `c` (5.9); `bias` is `logit(p0)` of the moment (see `newModel`).
    /// Returns `updateApplied`, `updateSkipped` or `updateReset`.
    ///
    /// A model that is not valid on entry (a value not finite, a precision not above 0) is reset BEFORE anything is
    /// computed: a NaN weight under an active feature would otherwise be turned into the edge of its box by the clip. On
    /// exit every value is checked again; the step is computed into temporaries and only committed when all of it is finite.
    @discardableResult
    public static func update(_ model: inout RankerModel, _ x: [Double], r: Double, c: Double, bias: Double = 0.0) -> Int {
        if !model.isValid() {
            model.resetToPrior()
            return updateReset
        }
        if !(c > 0.0) || !BrainMath.isFinite(c) || !BrainMath.isFinite(r) || !BrainMath.isFinite(bias) { return updateSkipped }
        for i in 0..<d {
            let xi = x[i]
            if !BrainMath.isFinite(xi) || xi > xMax || xi < -xMax { return updateSkipped }
        }
        let cc = c > cMax ? cMax : c
        let target = BrainMath.clip(r, 0.0, 1.0)
        let zz = zBiased(model.m, bias: bias, x)
        let sum = s(model.q, x)
        let pHat = BrainMath.sigmoid(zz)
        var h = pHat * (1.0 - pHat)
        if h < hFloor { h = hFloor }
        let denom = 1.0 + cc * h * sum
        let err = target - pHat
        var nm = [Double](repeating: 0.0, count: d)
        var nq = [Double](repeating: 0.0, count: d)
        for i in 0..<d {
            nm[i] = model.m[i]
            nq[i] = model.q[i]
            let xi = x[i]
            if xi == 0.0 { continue }
            let qi = model.q[i]
            let step = BrainMath.clip((xi / qi) * cc * err / denom, -stepClip, stepClip)
            let lo = model.m0[i] - boxSd * sd0Table[i]
            let hi = model.m0[i] + boxSd * sd0Table[i]
            nm[i] = BrainMath.clip(model.m[i] + step, lo, hi)
            nq[i] = qi / (1.0 - (xi * xi / qi) * cc * h / denom)
        }
        for i in 0..<d where !BrainMath.isFinite(nm[i]) || !BrainMath.isFinite(nq[i]) || !(nq[i] > 0.0) {
            model.resetToPrior()
            return updateReset
        }
        for i in 0..<d {
            model.m[i] = nm[i]
            model.q[i] = nq[i]
        }
        model.updates += 1
        return updateApplied
    }

    /// Forgets up to local day `today` (5.9, "daily"), a pure function of the days on which plays were applied and of
    /// `today`, not of how often it is called: the runs made since the last applied play are `min(gap, 30)` in all, and a
    /// second call only makes the runs that are still owed. A `today` before the anchor (a clock set back, or a day once
    /// written by a clock that was ahead) makes no run and pulls the anchor back to `today`. Returns the runs made.
    @discardableResult
    public static func forget(_ model: inout RankerModel, today: Int64) -> Int {
        if today < model.anchorDay {
            model.anchorDay = today
            model.forgetDone = 0
            return 0
        }
        let gap = today &- model.anchorDay
        let total = gap > Int64(maxForgetRuns) ? maxForgetRuns : Int(gap)
        let runs = total - model.forgetDone
        if runs <= 0 { return 0 }
        for _ in 0..<runs {
            for i in 0..<d {
                model.q[i] = q0Table[i] + (model.q[i] - q0Table[i]) * qKeep
                model.m[i] = model.m[i] + (model.m0[i] - model.m[i]) * mPull
            }
        }
        model.forgetDone = total
        return runs
    }

    /// One graded play, the way both the live path and `LearnReplay` apply it: forget up to `day`, take one `update` step,
    /// move the anchor to `day` and the watermark to `eventId`. An event at or below the watermark was applied already
    /// and changes nothing, so a catch-up after a rebuild can never apply a play twice.
    @discardableResult
    public static func applyEvent(_ model: inout RankerModel, _ x: [Double], r: Double, c: Double, bias: Double, day: Int64,
                                  eventId: Int64) -> Int {
        if eventId <= model.lastEventId { return updateSkipped }
        forget(&model, today: day)
        let result = update(&model, x, r: r, c: c, bias: bias)
        model.anchorDay = day
        model.forgetDone = 0
        model.lastEventId = eventId
        return result
    }

    /// One posterior sample of the weights: `w_i = m_i + gaussian12(rng) / sqrt(q_i)`, i ascending (5.10). Without the intercept.
    public static func sampleWeights(_ model: RankerModel, _ rng: inout BrainHash.Rng) -> [Double] {
        var w = [Double](repeating: 0.0, count: d)
        for i in 0..<d { w[i] = model.m[i] + rng.gaussian12() / BrainMath.sqrt(model.q[i]) }
        return w
    }

    /// The seed of a list's posterior sample and of its arm draws (5.10): `fnv1a64` over the 8 little-endian bytes of
    /// `salt`, the 4 little-endian bytes of the UTF-8 length of `listId`, the UTF-8 bytes of `listId` and the 8
    /// little-endian bytes of `localDay` (a length, not a separator: no id can collide with another). `listseed.jsonl` holds vectors.
    public static func listSeed(salt: Int64, listId: String, localDay: Int64) -> Int64 {
        let id = Array(listId.utf8)
        var bytes = [UInt8](repeating: 0, count: 8 + 4 + id.count + 8)
        let s = UInt64(bitPattern: salt)
        let day = UInt64(bitPattern: localDay)
        for k in 0..<8 { bytes[k] = UInt8(truncatingIfNeeded: s >> UInt64(8 * k)) }
        for k in 0..<4 { bytes[8 + k] = UInt8(truncatingIfNeeded: UInt64(id.count) >> UInt64(8 * k)) }
        for k in 0..<id.count { bytes[12 + k] = id[k] }
        for k in 0..<8 { bytes[12 + id.count + k] = UInt8(truncatingIfNeeded: day >> UInt64(8 * k)) }
        return BrainHash.id(BrainHash.fnv1a64(bytes: bytes))
    }

    /// The weight vector that ranks one list. `learned` is false when the gate has the prior on, the listener reset what
    /// was learned, there is no (valid) model, or this is a control session (5.12 point 8): then it is `M0` with the bias
    /// `logit(p0)`. Otherwise it is the model's mean (or, with `seed` given, one posterior sample) with the intercept
    /// `logit(p0)` added to index 0. Never a vector with a value that is not finite: that falls back to the prior.
    public static func weightsFor(_ model: RankerModel?, learned: Bool, p0: Double, seed: Int64?) -> [Double] {
        guard learned, let model, model.isValid() else { return weights(p0: p0) }
        var w: [Double]
        if let seed {
            var rng = BrainHash.Rng(seed: UInt64(bitPattern: seed))
            w = sampleWeights(model, &rng)
        } else {
            w = model.m
        }
        w[0] += biasOf(p0)
        for i in 0..<d where !BrainMath.isFinite(w[i]) { return weights(p0: p0) }
        return w
    }

    /// The precision vector that goes with `weightsFor`'s answer, for `p`.
    public static func precisionFor(_ model: RankerModel?, learned: Bool) -> [Double] {
        guard learned, let model, model.isValid() else { return q0Table }
        return model.q
    }

    /// One session in ten is ranked with `M0` and flagged (5.12 point 8): `splitmix64(sessionId) mod 10 == 0`, unsigned.
    public static func isControlSession(_ sessionId: Int64) -> Bool {
        BrainHash.splitmix64(UInt64(bitPattern: sessionId)) % 10 == 0
    }

    /// Which weights rank one list: the learned model's (mean or one posterior sample, `seed`) when `learned` says the
    /// gate has them on and this is not a control session, else the prior `M0`. Immutable once built, so a list is
    /// ranked with one consistent vector.
    public struct WeightSource: Sendable {
        private let snapshot: RankerModel?
        public let seed: Int64?

        public init(model: RankerModel?, learned: Bool, seed: Int64? = nil) {
            if learned, let model, model.isValid() { snapshot = model } else { snapshot = nil }
            self.seed = seed
        }

        /// True when the learned weights are in use.
        public var usesLearned: Bool { snapshot != nil }

        public func weights(p0: Double) -> [Double] { Ranker.weightsFor(snapshot, learned: snapshot != nil, p0: p0, seed: seed) }

        /// The precision vector for `p`, or nil for the prior's (the planner then uses the shared prior one).
        public func precision() -> [Double]? { snapshot?.q }
    }
}
