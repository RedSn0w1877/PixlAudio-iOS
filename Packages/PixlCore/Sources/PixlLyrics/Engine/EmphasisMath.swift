// Port of `presentation/lyrics/EmphasisMath.kt`: word-level motion maths for word-synced lines (spec §1.4) — the
// karaoke sweep, the lift and the long-word emphasis ("glow") — plus the line/word alphas (`KaraokeAlpha`, §1.2).
// Pure functions of time, so the renderer evaluates them per frame without animation state and a seek simply
// recomputes everything from `t`. Times in ms, lengths in `em` unless the name says px.

import Foundation
import PixlFoundation

/// Word-level motion maths.
public enum EmphasisMath {

    /// `ease-out` (0, 0, 0.58, 1): the lift, and the line activeness tweens.
    public static let easeOut = CubicBezierEasing(0, 0, 0.58, 1)

    /// Rising half of the emphasis curve.
    public static let emphasisRise = CubicBezierEasing(0.2, 0.4, 0.58, 1)

    /// Falling half of the emphasis curve (applied as `1 - fall(x)`).
    public static let emphasisFall = CubicBezierEasing(0.3, 0, 0.58, 1)

    // MARK: Sweep

    /// Soft-edge width of the karaoke fill: half a line height (AMLL's iPad value).
    public static let fadeWidthLineHeights: Float = 0.5

    public static func fadeWidthPx(lineHeightPx: Float) -> Float { fadeWidthLineHeights * lineHeightPx }

    /// Linear progress of `t` through `[startMs, endMs)`, clamped to 0…1.
    public static func syllableProgress(tMs: Int64, startMs: Int64, endMs: Int64) -> Float {
        if endMs <= startMs { return tMs >= startMs ? 1 : 0 }
        return (Float(tMs &- startMs) / Float(endMs &- startMs)).coerced(in: 0, 1)
    }

    /// Centre of the soft edge for a syllable box `[leftPx, rightPx]` at progress `p`: travels from `L - fade/2`
    /// (all unsung) to `R + fade/2` (all sung), so the edge fully enters and leaves.
    public static func sweepEdgeCenterPx(leftPx: Float, rightPx: Float, fadePx: Float, p: Float) -> Float {
        let from = leftPx - fadePx / 2
        let to = rightPx + fadePx / 2
        return from + (to - from) * p
    }

    /// The right-to-left edge centre (`LyricLineNode.drawSegments`): from `R + fade/2` down to `L - fade/2`.
    public static func sweepEdgeCenterRtlPx(leftPx: Float, rightPx: Float, fadePx: Float, p: Float) -> Float {
        rightPx + fadePx / 2 - (rightPx - leftPx + fadePx) * p
    }

    // MARK: Lift

    public static let liftAmountEm: Float = 0.05
    public static let backgroundLiftAmountEm: Float = 0.10
    public static let liftMinDurationMs: Int64 = 1_000

    /// Upward lift of a syllable in em (positive = up): `0.05 em × easeOut(progress)` over `max(1000, duration)`,
    /// 0.10 em for background vocals. The caller multiplies it by the line's activeness so words settle back down as
    /// the line deactivates.
    public static func liftEm(tMs: Int64, startMs: Int64, durationMs: Int64, background: Bool = false) -> Float {
        let span = Float(Swift.max(liftMinDurationMs, durationMs))
        let x = (Float(tMs &- startMs) / span).coerced(in: 0, 1)
        return (background ? backgroundLiftAmountEm : liftAmountEm) * easeOut.transform(x)
    }

    // MARK: Emphasis

    public static let emphasisMinDurationMs: Float = 1_000
    public static let lastWordAmountBoost: Float = 1.6
    public static let lastWordGlowBoost: Float = 1.5
    public static let lastWordDurationBoost: Float = 1.2
    public static let maxAmount: Float = 1.2
    public static let maxGlow: Float = 0.8
    public static let hopAmountEm: Float = 0.05
    public static let hopLeadMs: Float = 400
    public static let hopDurationFactor: Float = 1.4

    /// `f(v) = v > 1 ? √v : v³` — gentle for short words, slowly growing for long ones.
    public static func strengthCurve(_ v: Float) -> Float { v > 1 ? LyricsKotlinFloat.sqrt(v) : v * v * v }

    /// Base duration `du = max(1000, wordDur)`, before any last-word boost.
    public static func baseDurationMs(_ wordDurationMs: Int64) -> Float {
        ComposeBezier.javaMax(emphasisMinDurationMs, Float(wordDurationMs))
    }

    /// Effective animation duration: `du`, ×1.2 for the last word of the line.
    public static func effectiveDurationMs(_ wordDurationMs: Int64, isLastWord: Bool) -> Float {
        baseDurationMs(wordDurationMs) * (isLastWord ? lastWordDurationBoost : 1)
    }

    /// Scale / push strength: `f(du/2000) × 0.6` (×1.6 for the last word), capped at 1.2.
    public static func amount(_ wordDurationMs: Int64, isLastWord: Bool) -> Float {
        let du = baseDurationMs(wordDurationMs)
        let a = strengthCurve(du / 2000) * 0.6 * (isLastWord ? lastWordAmountBoost : 1)
        return ComposeBezier.javaMin(maxAmount, a)
    }

    /// Glow strength: `f(du/3000) × 0.5` (×1.5 for the last word), capped at 0.8.
    public static func glow(_ wordDurationMs: Int64, isLastWord: Bool) -> Float {
        let du = baseDurationMs(wordDurationMs)
        let g = strengthCurve(du / 3000) * 0.5 * (isLastWord ? lastWordGlowBoost : 1)
        return ComposeBezier.javaMin(maxGlow, g)
    }

    /// Start of grapheme `i` of `n`: `wordStart + (du / 2.5 / N) × i`.
    public static func graphemeStartMs(wordStartMs: Int64, effectiveDurationMs: Float, n: Int, i: Int) -> Float {
        Float(wordStartMs) + (effectiveDurationMs / 2.5 / Float(Swift.max(n, 1))) * Float(i)
    }

    /// `x = clamp((t − charStart) / du)`.
    public static func graphemeProgress(tMs: Int64, charStartMs: Float, effectiveDurationMs: Float) -> Float {
        ((Float(tMs) - charStartMs) / effectiveDurationMs).coerced(in: 0, 1)
    }

    /// The emphasis envelope `e(x)`: rises with `emphasisRise` over the first half, falls as `1 − emphasisFall` over
    /// the second. 0 at both ends, 1 at `x = 0.5`.
    public static func envelope(_ x: Float) -> Float {
        let c = x.coerced(in: 0, 1)
        return c < 0.5 ? emphasisRise.transform(c * 2) : 1 - emphasisFall.transform((c - 0.5) * 2)
    }

    /// Scale about the grapheme centre: `1 + e × 0.1 × amount`.
    public static func scale(e: Float, amount: Float) -> Float { 1 + e * 0.1 * amount }

    /// Horizontal push in em: `−e × 0.03 × amount × (N/2 − i)`, spreading letters from the middle.
    public static func offsetXEm(e: Float, amount: Float, n: Int, i: Int) -> Float {
        -e * 0.03 * amount * (Float(n) / 2 - Float(i))
    }

    /// Vertical offset in em (negative = up): `−e × 0.025 × amount`.
    public static func offsetYEm(e: Float, amount: Float) -> Float { -e * 0.025 * amount }

    /// Glow shadow alpha: `e × glow`.
    public static func glowAlpha(e: Float, glow: Float) -> Float { (e * glow).coerced(in: 0, 1) }

    /// CSS text-shadow blur of the glow in em: `min(0.3, glow × 0.3)` (a CSS blur B has σ = B/2).
    public static func glowBlurEm(_ glow: Float) -> Float { ComposeBezier.javaMin(0.3, glow * 0.3) }

    /// The extra hop in em (positive = up): `sin(π·x′) × 0.05`, with `x′ = clamp((t − (charStart − 400)) / (du × 1.4))`.
    /// Added on top of the normal lift.
    public static func hopEm(tMs: Int64, charStartMs: Float, effectiveDurationMs: Float) -> Float {
        let x = ((Float(tMs) - (charStartMs - hopLeadMs)) / (effectiveDurationMs * hopDurationFactor)).coerced(in: 0, 1)
        return LyricsKotlinFloat.sin(LyricsKotlinFloat.pi * x) * hopAmountEm
    }

    /// Peak scale reached by a word of this duration (the envelope's maximum is 1).
    public static func peakScale(_ wordDurationMs: Int64, isLastWord: Bool = false) -> Float {
        scale(e: 1, amount: amount(wordDurationMs, isLastWord: isLastWord))
    }

    /// Peak glow alpha reached by a word of this duration.
    public static func peakGlowAlpha(_ wordDurationMs: Int64, isLastWord: Bool = false) -> Float {
        glowAlpha(e: 1, glow: glow(wordDurationMs, isLastWord: isLastWord))
    }

    /// Grapheme boundaries of `text` as UTF-16 offsets `[0, b1, …, utf16Count]` (grapheme `i` is `[out[i], out[i+1])`).
    public static func graphemeBoundaries(_ text: String) -> [Int] { TextSegmentation.graphemeBoundariesUTF16(text) }
}

/// Line and word alphas (spec §1.2). All text is white; brightness comes only from alpha. `a` is the line's
/// activeness in 0…1.
public enum KaraokeAlpha {
    public static let inactive: Float = 0.20
    public static let activeLineOnly: Float = 1.0
    public static let unsungActive: Float = 0.35
    public static let fullySung: Float = 1.0
    public static let backgroundUnsung: Float = 0.175
    public static let backgroundSung: Float = 0.35
    public static let translationActive: Float = 0.45
    public static let translationInactive: Float = 0.20
    public static let pressHighlight: Float = 0.07

    /// Inactive alpha for the bright-artwork exception (§1.2).
    public static let inactiveBrightArt: Float = 0.50

    /// Inactive alpha under increased contrast (§1.2).
    public static let inactiveHighContrast: Float = 0.55

    /// How far the unsung words of the active line sit above the inactive lines, at least.
    public static let unsungMinLift: Float = 0.10

    public static func lerp(_ from: Float, _ to: Float, _ f: Float) -> Float { from + (to - from) * f }

    /// Unsung words of a word-synced line: `lerp(inactive, 0.35, a)`. The active target never drops below
    /// `inactive + 0.10`, so over bright art (inactive 0.50) the unsung words brighten to 0.60.
    public static func unsung(_ a: Float, inactive: Float = KaraokeAlpha.inactive) -> Float {
        lerp(inactive, ComposeBezier.javaMax(unsungActive, inactive + unsungMinLift), a)
    }

    /// Sung words, or a whole line-synced-only line: `lerp(inactive, 1.0, a)`.
    public static func sung(_ a: Float, inactive: Float = KaraokeAlpha.inactive) -> Float {
        lerp(inactive, fullySung, a)
    }

    public static func translation(_ a: Float, inactive: Float = KaraokeAlpha.translationInactive) -> Float {
        lerp(inactive, translationActive, a)
    }
}
