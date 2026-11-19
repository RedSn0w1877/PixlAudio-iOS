// Repeat activation (docs/brain-spec.md, 5.6, stage 2). A transliteration of the Android `:brain` module's
// `RepeatActivation.kt`.

/// How "active" a track still is in the listener's memory, from the hours since each of its past plays,
///
///     B(t, now) = ln( sum_j c_j * powNeg( hours(now - t_j) + 1, d ) ),   d = 0.5
///
/// Features 10 and 11 of 5.8 are `clip((B + 4) / 6, 0, 1)` and its square, so the ranker can place the listener's own
/// point of fatigue: just played reads high (the track is "hot", and the weight on it is negative once squared), long
/// ago reads low.
///
/// A track keeps its last `maxPlays` plays and one aggregate bucket for every older one: the bucket holds their total
/// weight and the weighted mean of their times, and counts as one play at that time. Plain `+ - * /` and the
/// hand-rolled `ln` and `powNeg` of 10.2 only, so both platforms agree to the bit. `d` is fixed at 0.5 in stages 1 and 2.
public enum RepeatActivation {
    public static let maxPlays = 30
    public static let decayD: Double = 0.5
    private static let hourMs: Double = 3_600_000.0

    /// The plays of one track, oldest first; `aggC` and `aggT` are the older plays folded into one.
    public struct History: Sendable {
        var times: [Int64]
        var weights: [Double]
        public private(set) var count = 0
        /// Total weight of the folded plays; 0 when none were folded.
        public private(set) var aggC: Double = 0.0
        /// Weighted mean time (ms) of the folded plays.
        public private(set) var aggT: Double = 0.0

        public init() {
            times = [Int64](repeating: 0, count: RepeatActivation.maxPlays)
            weights = [Double](repeating: 0.0, count: RepeatActivation.maxPlays)
        }

        /// Records a play at `tMs` with weight `c` (its trust weight, 4.3). Plays must come oldest first.
        public mutating func add(_ tMs: Int64, _ c: Double) {
            if c <= 0.0 { return }
            if count == RepeatActivation.maxPlays {
                // The oldest play joins the bucket.
                let oldT = Double(times[0])
                let oldC = weights[0]
                let total = aggC + oldC
                aggT = (aggT * aggC + oldT * oldC) / total
                aggC = total
                var i = 1
                while i < RepeatActivation.maxPlays {
                    times[i - 1] = times[i]
                    weights[i - 1] = weights[i]
                    i += 1
                }
                count -= 1
            }
            times[count] = tMs
            weights[count] = c
            count += 1
        }

        public var isEmpty: Bool { count == 0 && aggC == 0.0 }
    }

    /// `B` at `nowMs`, or NaN when the track has no play with weight (never played: the feature is 0, not low). A play
    /// in the future (a clock set back) counts as just now.
    public static func b(_ history: History, nowMs: Int64) -> Double {
        var sum = 0.0
        var i = 0
        while i < history.count {
            sum += history.weights[i] * BrainMath.powNeg(hours(Double(nowMs) - Double(history.times[i])) + 1.0, decayD)
            i += 1
        }
        if history.aggC > 0.0 {
            sum += history.aggC * BrainMath.powNeg(hours(Double(nowMs) - history.aggT) + 1.0, decayD)
        }
        if sum <= 0.0 { return Double.nan }
        return BrainMath.ln(sum)
    }

    /// Feature 10: `clip((B + 4) / 6, 0, 1)`; 0 for a track with no weighted play.
    public static func feature(_ history: History?, nowMs: Int64) -> Double {
        guard let history, !history.isEmpty else { return 0.0 }
        let b = b(history, nowMs: nowMs)
        if b.isNaN { return 0.0 }
        return BrainMath.clip((b + 4.0) / 6.0, 0.0, 1.0)
    }

    private static func hours(_ deltaMs: Double) -> Double { deltaMs <= 0.0 ? 0.0 : deltaMs / hourMs }
}
