// The arm bandit of docs/brain-spec.md, 5.10 (stage 3, completion pass): one discounted Beta posterior per arm and surface
// family, and a Thompson draw that decides which arm a novel slot is filled from. A transliteration of the Android `:brain`
// module's `ArmBandit.kt`; `bandit.jsonl` pins it bit for bit.
//
// ```
// on a recommender play from arm a:  alpha += c * r ;  beta += c * (1 - r)
// daily:                             alpha <- a0 + (alpha - a0) * 0.98 ;  same for beta
// draw:                              mu = alpha / (alpha + beta) ;  sd = sqrt(alpha * beta / ((alpha + beta)^2 * (alpha + beta + 1)))
//                                    theta = clip(mu + sd * gaussian12(rng), 0, 1)
// ```
//
// Audit (5.12 point 3): beside the main posterior each arm has one that sees only EXPLORATION plays (the slots this draw
// filled, flagged `EventFlags.exploreSlot`, which `Reward` weights 1.5). When the audit has enough evidence and its mean
// differs from the main mean by more than `auditGap`, the audit is the one drawn from.
//
// Learned state: it is used only while the gate has the learned weights on (the caller passes no `ArmPicker` otherwise, so a
// listener on the standard recipe keeps stage 2's choice of the best-valued novel candidate, byte for byte). It has only ever
// run on synthetic listeners.

/// Chooses the arm a novel slot goes to (5.10): given the arms that still have a candidate, the arm with the largest draw, or
/// -1 for none.
public protocol ArmPicker: Sendable {
    func pick(_ eligible: [Bool]) -> Int32
}

/// An `ArmPicker` made of a closure (tests, and callers with their own rule).
public struct ClosureArmPicker: ArmPicker {
    private let body: @Sendable ([Bool]) -> Int32

    public init(_ body: @escaping @Sendable ([Bool]) -> Int32) { self.body = body }

    public func pick(_ eligible: [Bool]) -> Int32 { body(eligible) }
}

/// The arm bandit.
public enum ArmBandit {
    public static let home = 0
    public static let mix = 1
    public static let station = 2
    public static let families = 3

    /// The arms that can be drawn: `Arm.fav` to `Arm.ask` (codes 0..8).
    public static let arms = 9

    public static let dailyDiscount = 0.98
    public static let maxForgetRuns = 30

    /// The audit overrides the main estimate when the two differ by more than this.
    public static let auditGap = 0.15

    /// The audit counts only with at least this many (weighted) exploration plays beyond its prior.
    public static let auditMinEvidence = 5.0

    private static let priorA: [Double] = [7.0, 5.0, 6.0, 4.0, 3.0, 5.0, 5.0, 2.0, 4.0]
    private static let priorB: [Double] = [3.0, 5.0, 4.0, 6.0, 7.0, 5.0, 5.0, 8.0, 6.0]

    public static func priorAlpha(_ arm: Int) -> Double { priorA[arm] }
    public static func priorBeta(_ arm: Int) -> Double { priorB[arm] }

    /// The family a surface belongs to, or -1 for a surface the bandit does not learn from.
    public static func familyOf(_ surface: Int32) -> Int {
        switch surface {
        case Surface.homeShelf: return home
        case Surface.dailyMix, Surface.yourMix, Surface.namedMix: return mix
        case Surface.station, Surface.autoplay: return station
        default: return -1
        }
    }

    /// The posteriors of one listener.
    public struct State: Sendable {
        public var alpha: [Double]
        public var beta: [Double]
        public var auditAlpha: [Double]
        public var auditBeta: [Double]
        public var anchorDay: Int64
        public var forgetDone: Int
        /// Recommender plays counted since the state was created or reset.
        public var updates: Int64

        public init(alpha: [Double], beta: [Double], auditAlpha: [Double], auditBeta: [Double], anchorDay: Int64,
                    forgetDone: Int = 0, updates: Int64 = 0) {
            self.alpha = alpha
            self.beta = beta
            self.auditAlpha = auditAlpha
            self.auditBeta = auditBeta
            self.anchorDay = anchorDay
            self.forgetDone = forgetDone
            self.updates = updates
        }

        public func isValid() -> Bool {
            let n = families * arms
            if alpha.count != n || beta.count != n || auditAlpha.count != n || auditBeta.count != n { return false }
            for i in 0..<n {
                if !BrainMath.isFinite(alpha[i]) || !(alpha[i] > 0.0) || !BrainMath.isFinite(beta[i]) || !(beta[i] > 0.0) { return false }
                if !BrainMath.isFinite(auditAlpha[i]) || !(auditAlpha[i] > 0.0) { return false }
                if !BrainMath.isFinite(auditBeta[i]) || !(auditBeta[i] > 0.0) { return false }
            }
            return true
        }
    }

    private static func index(_ family: Int, _ arm: Int) -> Int { family * arms + arm }

    /// Every arm at its prior; the daily discount counts from `today`.
    public static func newState(today: Int64) -> State {
        let n = families * arms
        let a = (0..<n).map { priorA[$0 % arms] }
        let b = (0..<n).map { priorB[$0 % arms] }
        return State(alpha: a, beta: b, auditAlpha: a, auditBeta: b, anchorDay: today)
    }

    /// Discounts toward the priors up to local day `today`: a pure function of the days on which plays were applied and of
    /// `today` (the runs made since the last applied play are `min(gap, 30)` in all), the same rule as `Ranker.forget`. A day
    /// before the anchor makes no run. Returns the runs made.
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
            for i in 0..<state.alpha.count {
                let a0 = priorA[i % arms]
                let b0 = priorB[i % arms]
                state.alpha[i] = a0 + (state.alpha[i] - a0) * dailyDiscount
                state.beta[i] = b0 + (state.beta[i] - b0) * dailyDiscount
                state.auditAlpha[i] = a0 + (state.auditAlpha[i] - a0) * dailyDiscount
                state.auditBeta[i] = b0 + (state.auditBeta[i] - b0) * dailyDiscount
            }
        }
        state.forgetDone = total
        return runs
    }

    /// One recommender play from `arm` in `family`: discount up to `day`, then `alpha += c * r`, `beta += c * (1 - r)`.
    /// `explore` plays also feed the audit posterior. A weight or reward that is not finite changes nothing. Returns true
    /// when the posteriors moved.
    @discardableResult
    public static func update(_ state: inout State, family: Int, arm: Int, r: Double, c: Double, explore: Bool, day: Int64) -> Bool {
        discount(&state, today: day)
        state.anchorDay = day
        state.forgetDone = 0
        if family < 0 || family >= families || arm < 0 || arm >= arms { return false }
        if !(c > 0.0) || !BrainMath.isFinite(c) || !BrainMath.isFinite(r) { return false }
        let cc = c > Ranker.cMax * 1.5 ? Ranker.cMax * 1.5 : c
        let rr = BrainMath.clip(r, 0.0, 1.0)
        let i = index(family, arm)
        state.alpha[i] = state.alpha[i] + cc * rr
        state.beta[i] = state.beta[i] + cc * (1.0 - rr)
        if explore {
            state.auditAlpha[i] = state.auditAlpha[i] + cc * rr
            state.auditBeta[i] = state.auditBeta[i] + cc * (1.0 - rr)
        }
        state.updates += 1
        return true
    }

    /// The mean of the posterior the draw uses for (`family`, `arm`): the audit's when it has evidence and disagrees with the
    /// main one by more than `auditGap`.
    public static func mean(_ state: State, family: Int, arm: Int) -> Double {
        let i = index(family, arm)
        let main = state.alpha[i] / (state.alpha[i] + state.beta[i])
        let evidence = state.auditAlpha[i] + state.auditBeta[i] - priorA[arm] - priorB[arm]
        if evidence >= auditMinEvidence {
            let audit = state.auditAlpha[i] / (state.auditAlpha[i] + state.auditBeta[i])
            if BrainMath.abs(audit - main) > auditGap { return audit }
        }
        return main
    }

    /// True when the audit posterior, not the main one, is what the draw for (`family`, `arm`) reads.
    public static func auditInUse(_ state: State, family: Int, arm: Int) -> Bool {
        let i = index(family, arm)
        let evidence = state.auditAlpha[i] + state.auditBeta[i] - priorA[arm] - priorB[arm]
        if evidence < auditMinEvidence { return false }
        let main = state.alpha[i] / (state.alpha[i] + state.beta[i])
        let audit = state.auditAlpha[i] / (state.auditAlpha[i] + state.auditBeta[i])
        return BrainMath.abs(audit - main) > auditGap
    }

    /// One draw `theta = clip(mu + sd * gaussian12, 0, 1)` for (`family`, `arm`); consumes twelve uniforms of `rng`.
    public static func draw(_ state: State, family: Int, arm: Int, _ rng: inout BrainHash.Rng) -> Double {
        let i = index(family, arm)
        let useAudit = auditInUse(state, family: family, arm: arm)
        let a = useAudit ? state.auditAlpha[i] : state.alpha[i]
        let b = useAudit ? state.auditBeta[i] : state.beta[i]
        let n = a + b
        let mu = a / n
        let sd = BrainMath.sqrt(a * b / (n * n * (n + 1.0)))
        return BrainMath.clip(mu + sd * rng.gaussian12(), 0.0, 1.0)
    }

    /// The arm with the largest draw among the arms that still have a candidate (`eligible`, indexed by arm code), ties to the
    /// lower code; -1 when none is eligible. Every eligible arm gets one draw, in ascending arm order, so the sequence of `rng`
    /// is fixed.
    public static func pickArm(_ state: State, family: Int, eligible: [Bool], _ rng: inout BrainHash.Rng) -> Int32 {
        var best = -1
        var bestTheta = 0.0
        for arm in 0..<arms {
            if arm >= eligible.count || !eligible[arm] { continue }
            let theta = draw(state, family: family, arm: arm, &rng)
            if best < 0 || theta > bestTheta {
                best = arm
                bestTheta = theta
            }
        }
        return Int32(best)
    }

    /// The picker one list uses: a private copy of the posteriors (so the list is ranked with one consistent set) and a
    /// generator seeded by `seed` (see `Ranker.listSeed`), so a mix does not redraw when it is reopened. One list builds on
    /// one thread, so the generator needs no lock.
    public final class Sampler: ArmPicker, @unchecked Sendable {
        private let snapshot: State
        private let family: Int
        private var rng: BrainHash.Rng

        public init(_ state: State, family: Int, seed: Int64) {
            snapshot = state
            self.family = family
            rng = BrainHash.Rng(seed: UInt64(bitPattern: seed))
        }

        public func pick(_ eligible: [Bool]) -> Int32 { ArmBandit.pickArm(snapshot, family: family, eligible: eligible, &rng) }
    }
}
