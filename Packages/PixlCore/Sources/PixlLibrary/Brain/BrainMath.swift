// The only real-number functions the music brain uses (docs/brain-spec.md, 5.1, 10.2, 10.3). A transliteration of
// the Android `:brain` module's `BrainMath.kt`, operation by operation.
//
// `exp`, `ln` and `pow` of a platform maths library are not bit-identical between the JVM, ART and Swift;
// `+ - * /`, the square root and rounding down are. So everything transcendental is written out here, and THE
// EXPRESSION ORDER IN THE KOTLIN FILE IS THE DEFINITION: nothing here may be regrouped, and nothing may use a fused
// multiply-add. `math.jsonl` pins the output bits.
//
// Nothing here can produce NaN from a finite input.

/// The brain's real-number functions.
public enum BrainMath {
    // Constants as IEEE bit patterns, so no decimal parser has a say in them.
    /// ln 2, nearest double.
    public static let ln2 = Double(bitPattern: 0x3FE6_2E42_FEFA_39EF)
    /// The high part of ln 2 (its low 21 mantissa bits are zero, so `k * ln2Hi` is exact for |k| < 2^21).
    public static let ln2Hi = Double(bitPattern: 0x3FE6_2E42_FEE0_0000)
    /// ln 2 - ln2Hi.
    public static let ln2Lo = Double(bitPattern: 0x3DEA_39EF_3579_3C76)
    /// 1 / ln 2.
    public static let invLn2 = Double(bitPattern: 0x3FF7_1547_652B_82FE)
    /// sqrt 2.
    public static let sqrt2 = Double(bitPattern: 0x3FF6_A09E_667F_3BCD)

    /// 2^20: the scale of Q20 counters and of every ordering key.
    public static let q20: Double = 1_048_576.0
    /// 2^52: doubles are clipped to this before they become integers (10.3, rule 11).
    public static let twoPow52: Double = 4_503_599_627_370_496.0
    /// 2^40: the ceiling of a Q20 counter's real value.
    public static let twoPow40: Double = 1_099_511_627_776.0
    /// 2^54, to lift a subnormal into the normal range.
    static let twoPow54: Double = 18_014_398_509_481_984.0

    static let mantissaMask: UInt64 = 0x000F_FFFF_FFFF_FFFF
    static let exponentOne: UInt64 = 0x3FF0_0000_0000_0000

    // Series coefficients. A quotient of two small integers is one correctly rounded IEEE division, the same on
    // every platform.
    static let c3: Double = 1.0 / 3.0
    static let c5: Double = 1.0 / 5.0
    static let c7: Double = 1.0 / 7.0
    static let c9: Double = 1.0 / 9.0
    static let c11: Double = 1.0 / 11.0
    static let c13: Double = 1.0 / 13.0
    static let c15: Double = 1.0 / 15.0
    static let c17: Double = 1.0 / 17.0
    static let c19: Double = 1.0 / 19.0

    static let f2: Double = 1.0 / 2.0
    static let f3: Double = 1.0 / 6.0
    static let f4: Double = 1.0 / 24.0
    static let f5: Double = 1.0 / 120.0
    static let f6: Double = 1.0 / 720.0
    static let f7: Double = 1.0 / 5040.0
    static let f8: Double = 1.0 / 40320.0
    static let f9: Double = 1.0 / 362880.0
    static let f10: Double = 1.0 / 3628800.0
    static let f11: Double = 1.0 / 39916800.0
    static let f12: Double = 1.0 / 479001600.0
    static let f13: Double = 1.0 / 6227020800.0

    public static func isFinite(_ x: Double) -> Bool { x == x && x != Double.infinity && x != -Double.infinity }

    /// `max(lo, min(hi, x))`; NaN becomes `lo`.
    public static func clip(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        if x != x { return lo }
        if x < lo { return lo }
        if x > hi { return hi }
        return x
    }

    public static func min(_ a: Double, _ b: Double) -> Double { a < b ? a : b }

    public static func max(_ a: Double, _ b: Double) -> Double { a > b ? a : b }

    public static func abs(_ x: Double) -> Double { x < 0.0 ? -x : x }

    /// Natural logarithm. A value that is not finite or not above zero gives -700.
    public static func ln(_ x: Double) -> Double {
        if !isFinite(x) || x <= 0.0 { return -700.0 }
        var v = x
        var e = 0
        var bits = v.bitPattern
        if (bits >> 52) == 0 {
            // Subnormal: scale into the normal range first.
            v *= twoPow54
            e = -54
            bits = v.bitPattern
        }
        e += Int((bits >> 52) & 0x7FF) - 1023
        var m = Double(bitPattern: (bits & mantissaMask) | exponentOne) // in [1, 2)
        if m >= sqrt2 {
            m *= 0.5 // exact
            e += 1
        }
        // m in [sqrt(2)/2, sqrt(2)).
        let s = (m - 1.0) / (m + 1.0)
        let t = s * s
        // 1 + t*(C3 + t*(C5 + t*(C7 + t*(C9 + t*(C11 + t*(C13 + t*(C15 + t*(C17 + t*C19)))))))), innermost first.
        var poly = t * c19
        poly = c17 + poly
        poly = t * poly
        poly = c15 + poly
        poly = t * poly
        poly = c13 + poly
        poly = t * poly
        poly = c11 + poly
        poly = t * poly
        poly = c9 + poly
        poly = t * poly
        poly = c7 + poly
        poly = t * poly
        poly = c5 + poly
        poly = t * poly
        poly = c3 + poly
        poly = t * poly
        poly = 1.0 + poly
        let high = Double(e) * ln2
        let low = 2.0 * s
        return high + low * poly
    }

    /// e^x, with x clipped to [-700, 700]. A non-finite x gives 0.
    public static func exp(_ x: Double) -> Double {
        if !isFinite(x) { return 0.0 }
        let c = clip(x, -700.0, 700.0)
        let kd = (c * invLn2 + 0.5).rounded(.down)
        let k = Int(kd) // |k| <= 1010
        let r = (c - kd * ln2Hi) - kd * ln2Lo
        var p = f13
        p = p * r + f12
        p = p * r + f11
        p = p * r + f10
        p = p * r + f9
        p = p * r + f8
        p = p * r + f7
        p = p * r + f6
        p = p * r + f5
        p = p * r + f4
        p = p * r + f3
        p = p * r + f2
        p = p * r + 1.0
        p = p * r + 1.0
        // 2^k from its exponent bits; k is within the normal range for the clipped x.
        let scale = Double(bitPattern: UInt64(k + 1023) << 52)
        return p * scale
    }

    /// The logistic function. A non-finite x gives 0.
    public static func sigmoid(_ x: Double) -> Double {
        if !isFinite(x) { return 0.0 }
        if x >= 0.0 { return 1.0 / (1.0 + BrainMath.exp(-x)) }
        let e = BrainMath.exp(x)
        return e / (1.0 + e)
    }

    public static func log2(_ x: Double) -> Double { ln(x) * invLn2 }

    /// x^(-d) for x > 0.
    public static func powNeg(_ x: Double, _ d: Double) -> Double { BrainMath.exp(-d * ln(x)) }

    /// `ln(p / (1 - p))`.
    public static func logit(_ p: Double) -> Double { ln(p / (1.0 - p)) }

    public static func sqrt(_ x: Double) -> Double { x.squareRoot() }

    // MARK: Double to integer (10.3, rule 11)

    /// `floor(x)` as an Int64: not finite gives 0; clipped to [-2^52, 2^52] first.
    public static func floorToLong(_ x: Double) -> Int64 {
        if !isFinite(x) { return 0 }
        return Int64(clip(x, -twoPow52, twoPow52).rounded(.down))
    }

    /// A real value as a Q20 counter: `floor(x * 2^20 + 0.5)`, x clipped to [0, 2^40] first.
    public static func toQ(_ x: Double) -> Int64 {
        if !isFinite(x) { return 0 }
        return Int64((clip(x, 0.0, twoPow40) * q20 + 0.5).rounded(.down))
    }

    public static func fromQ(_ q: Int64) -> Double { Double(q) / q20 }

    /// The ordering key of a score (10.3, rule 4): `floor(score * 2^20 + 0.5)`.
    public static func orderKey(_ score: Double) -> Int64 { floorToLong(score * q20 + 0.5) }

    // MARK: Integer division (10.3, rule 12)

    public static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        var q = a / b
        if (a % b != 0) && ((a < 0) != (b < 0)) { q -= 1 }
        return q
    }

    public static func floorMod(_ a: Int64, _ b: Int64) -> Int64 { a &- floorDiv(a, b) &* b }

    public static let dayMs: Int64 = 86_400_000

    /// The local calendar day of `ms` (days since 1970-01-01 local).
    public static func localDay(_ ms: Int64, tzOffsetMin: Int32) -> Int64 {
        floorDiv(ms &+ Int64(tzOffsetMin) &* 60_000, dayMs)
    }

    /// 0 = Monday ... 6 = Sunday. 1970-01-01 was a Thursday.
    public static func weekday(_ localDay: Int64) -> Int32 { Int32(floorMod(localDay &+ 3, 7)) }

    public static func isWeekend(_ ms: Int64, tzOffsetMin: Int32) -> Bool { weekday(localDay(ms, tzOffsetMin: tzOffsetMin)) >= 5 }

    /// Unsigned comparison of two 64-bit hashes held in signed integers (10.3, rule 10): -1, 0 or 1.
    public static func compareUnsigned(_ a: Int64, _ b: Int64) -> Int {
        let x = UInt64(bitPattern: a)
        let y = UInt64(bitPattern: b)
        return x < y ? -1 : (x > y ? 1 : 0)
    }
}
