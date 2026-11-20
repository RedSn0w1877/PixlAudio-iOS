// The frozen-prior gate (docs/brain-spec.md, 5.12 point 8) and the figures "Your sound" shows (8.6, section 7). A
// transliteration of the Android `:brain` module's `Gate.kt`.
//
// The switch is decided by prediction, not by a traffic split: at every weekly rebuild the learned weights and the prior
// `M0` both predict the listener's last `window` graded plays prequentially (each play predicted before it was learned
// from), and the learned weights are used only while their log-loss is the lower one. Pure and deterministic: log-loss
// and accuracy are sums over the same arrays in the same order on both platforms, with the hand-rolled `ln`.
//
// Honesty rule of stage 3: every number here comes from the listener's own graded plays (`r = 1` finished, `r <= 0.1`
// skipped). The learner has run only on synthetic data so far; no real-data accuracy is claimed anywhere until a real
// export has been scored.

/// The gate.
public enum Gate {
    /// The graded plays the two weight vectors are compared on (5.12 point 8).
    public static let window = 2000

    /// Fewer graded plays than this: the standard recipe stays on, and Your sound says it is still getting to know the listener.
    public static let minPlays = 300

    /// Weeks in a row the learned weights must win before they are used.
    public static let winsNeeded = 2

    /// Two evaluations closer than this count as one week.
    public static let weekMs: Int64 = 6 * 86_400_000

    /// The relative gain in log-loss a week must show to count as a win (the stage 3 "done means": 1%). Below it the learned weights are
    /// not better than the prior in any way worth a decision, and a coin-flip week on a few hundred plays must not switch them on.
    public static let minImprovement = 0.01

    /// A month, for "up from ... a month ago".
    public static let monthMs: Int64 = 30 * 86_400_000

    /// A prediction is kept this far from 0 and 1 so the log-loss is finite.
    public static let pEdge = 1.0e-4

    /// What the gate decided, and when. `useLearned` is false until the learned weights have won `winsNeeded` weeks running.
    public struct State: Sendable, Equatable {
        public let useLearned: Bool
        /// Weeks in a row the learned log-loss was the lower one (counted at most once per `weekMs`).
        public let winStreak: Int
        /// When the last counted evaluation ran; 0 for never.
        public let atMs: Int64

        public init(useLearned: Bool = false, winStreak: Int = 0, atMs: Int64 = 0) {
            self.useLearned = useLearned
            self.winStreak = winStreak
            self.atMs = atMs
        }
    }

    /// The graded plays of one replay, in time order, predicted by both weight vectors before each was learned from.
    public struct Predictions: Sendable {
        public var times: [Int64]
        public var sessions: [Int64]
        /// True: finished (`r = 1`). False: skipped (`r <= 0.1`).
        public var finished: [Bool]
        public var learned: [Double]
        public var prior: [Double]
        /// The listener's base finish rate at that moment: a prediction at or above it calls the play a finish.
        public var threshold: [Double]

        public init(times: [Int64] = [], sessions: [Int64] = [], finished: [Bool] = [], learned: [Double] = [],
                    prior: [Double] = [], threshold: [Double] = []) {
            self.times = times
            self.sessions = sessions
            self.finished = finished
            self.learned = learned
            self.prior = prior
            self.threshold = threshold
        }

        public var size: Int { times.count }
    }

    /// The figures of one evaluation.
    public struct Summary: Sendable, Equatable {
        /// Graded plays in the window the log-losses and accuracies are over.
        public let plays: Int
        /// Graded plays in the whole history.
        public let playsTotal: Int
        public let logLossLearned: Double
        public let logLossPrior: Double
        /// Share of the window's graded plays whose finish or skip the learned weights called right; 0 when `plays` is 0.
        public let accLearned: Double
        public let accPrior: Double
        /// The learned accuracy on the window that ended a month earlier; nil with fewer than `minPlays` graded plays then.
        public let accLearnedBefore: Double?
        public let accPriorBefore: Double?

        public init(plays: Int, playsTotal: Int, logLossLearned: Double, logLossPrior: Double, accLearned: Double,
                    accPrior: Double, accLearnedBefore: Double?, accPriorBefore: Double?) {
            self.plays = plays
            self.playsTotal = playsTotal
            self.logLossLearned = logLossLearned
            self.logLossPrior = logLossPrior
            self.accLearned = accLearned
            self.accPrior = accPrior
            self.accLearnedBefore = accLearnedBefore
            self.accPriorBefore = accPriorBefore
        }

        /// Relative improvement of the learned log-loss over the prior's; 0 with no plays.
        public var improvement: Double {
            plays == 0 || logLossPrior <= 0.0 ? 0.0 : (logLossPrior - logLossLearned) / logLossPrior
        }

        public var learnedBetter: Bool { plays >= Gate.minPlays && logLossLearned < logLossPrior }

        /// Better by at least `Gate.minImprovement`: what a week must show to be counted towards switching the learned weights on.
        public var learnedClearlyBetter: Bool { learnedBetter && improvement >= Gate.minImprovement }
    }

    private static func clipP(_ p: Double) -> Double { BrainMath.clip(p, pEdge, 1.0 - pEdge) }

    /// Mean log-loss of `p` against `y` over `[from, to)`.
    public static func logLoss(_ p: [Double], _ y: [Bool], from: Int, to: Int) -> Double {
        if to <= from { return 0.0 }
        var sum = 0.0
        for i in from..<to {
            let q = clipP(p[i])
            sum += y[i] ? -BrainMath.ln(q) : -BrainMath.ln(1.0 - q)
        }
        return sum / Double(to - from)
    }

    /// Share of `[from, to)` where "prediction at or above `thr`" matches `y`.
    public static func accuracy(_ p: [Double], _ thr: [Double], _ y: [Bool], from: Int, to: Int) -> Double {
        if to <= from { return 0.0 }
        var right = 0
        for i in from..<to where (p[i] >= thr[i]) == y[i] { right += 1 }
        return Double(right) / Double(to - from)
    }

    /// The figures over the last `window` graded plays of `pred`, and the accuracy a month before `nowMs`.
    public static func summarize(_ pred: Predictions, nowMs: Int64) -> Summary {
        let n = pred.size
        let from = n > window ? n - window : 0
        // The window that ended a month ago: the last `window` graded plays that started at or before nowMs - monthMs.
        var endBefore = 0
        while endBefore < n && pred.times[endBefore] <= nowMs &- monthMs { endBefore += 1 }
        let fromBefore = endBefore > window ? endBefore - window : 0
        let hasBefore = endBefore - fromBefore >= minPlays
        return Summary(
            plays: n - from,
            playsTotal: n,
            logLossLearned: logLoss(pred.learned, pred.finished, from: from, to: n),
            logLossPrior: logLoss(pred.prior, pred.finished, from: from, to: n),
            accLearned: accuracy(pred.learned, pred.threshold, pred.finished, from: from, to: n),
            accPrior: accuracy(pred.prior, pred.threshold, pred.finished, from: from, to: n),
            accLearnedBefore: hasBefore
                ? accuracy(pred.learned, pred.threshold, pred.finished, from: fromBefore, to: endBefore) : nil,
            accPriorBefore: hasBefore
                ? accuracy(pred.prior, pred.threshold, pred.finished, from: fromBefore, to: endBefore) : nil)
    }

    /// The gate's decision after one evaluation (5.12 point 8). Off at once when the learned weights are not better (or there are too
    /// few graded plays); on only after `winsNeeded` counted weeks of winning in a row, each by at least `minImprovement` (and, from
    /// `LearnReplay.test6MinPlays` graded plays, with the bootstrap interval of test 6 above zero: `intervalAboveZero`); once on, it
    /// stays on while it is still better. An evaluation less than `weekMs` after the last counted one changes the streak only
    /// downward, never upward. A week that is better but not clearly better is not a win: it ends a streak that has not switched the
    /// learned weights on, and leaves one that has alone (no flapping on noise).
    public static func decide(_ prev: State, _ summary: Summary, nowMs: Int64, intervalAboveZero: Bool = true) -> State {
        if !summary.learnedBetter { return State(useLearned: false, winStreak: 0, atMs: nowMs) }
        let clear = summary.learnedClearlyBetter && (summary.playsTotal < LearnReplay.test6MinPlays || intervalAboveZero)
        if !clear { return prev.useLearned ? prev : State(useLearned: false, winStreak: 0, atMs: prev.atMs) }
        let newWeek = prev.atMs == 0 || nowMs &- prev.atMs >= weekMs || nowMs < prev.atMs
        if !newWeek { return prev }
        let streak = prev.winStreak >= winsNeeded ? prev.winStreak : prev.winStreak + 1
        return State(useLearned: prev.useLearned || streak >= winsNeeded, winStreak: streak, atMs: nowMs)
    }

    /// Graded plays flagged as a control session, or not, need at least this many to be shown side by side (5.12 point 8).
    public static let controlMinPlays = 300

    /// Completion rate of a set of plays; nil below `controlMinPlays`.
    public static func shownRate(finished: Int, total: Int) -> Double? {
        total < controlMinPlays ? nil : Double(finished) / Double(total)
    }
}
