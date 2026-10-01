// Port of `presentation/lyrics/InterludeTimeline.kt`: interlude dots (spec §1.6) as pure functions of the lyrics time
// `t` and the gap `[g0, g1)` (`g0` = gap start, `g1` = next line start). Nothing is remembered between frames, so
// jumping into a gap after a seek recomputes everything from `t`.
//
// Phases:
// - Expand, `g0 … g0+300`: row height 0 → full, group scale 0.1 → 1, alpha 0 → 1 (EaseInOut).
// - Fill: dot k (0…2) goes 0.3 → 1.0 linearly over `[g0 + k·D/3, g0 + (k+1)·D/3]`.
// - Breathing until `g1 − 1500`: scale `1 + 0.2·sin²(π·((t − g0) mod 5000)/5000)`.
// - Final pulse `g1 − 1500 … g1 − 300`: scale `1.1 + 0.3·sin²(π·(t − (g1 − 1500))/1000)`, blended in from the
//   breathing value over its first 250 ms so the switch never pops.
// - Collapse `g1 − 300 … g1`: scale → 0.1, alpha → 0, height → 0 (EaseInOut).
// - Short gaps (`g1 − g0 < 3000`): no breathing or pulse; all dots lit; expand then collapse.

import Foundation
import PixlFoundation

/// Interlude dots timeline.
public enum InterludeTimeline {
    public static let expandMs: Int64 = 300
    public static let collapseMs: Int64 = 300
    public static let breathPeriodMs: Int64 = 5_000
    public static let breathAmplitude: Float = 0.2
    public static let finalPulseLeadMs: Int64 = 1_500
    public static let finalPulsePeriodMs: Int64 = 1_000
    public static let finalPulseBase: Float = 1.1
    public static let finalPulseAmplitude: Float = 0.3
    public static let finalPulseBlendMs: Int64 = 250
    public static let shortGapMs: Int64 = 3_000
    public static let hiddenScale: Float = 0.1
    public static let dotUnlitAlpha: Float = 0.3
    public static let dotLitAlpha: Float = 1.0
    public static let dotCount = 3

    /// Dot diameter and gap in em, and the row's vertical margins (each side).
    public static let dotSizeEm: Float = 0.3
    public static let dotGapEm: Float = 0.15
    public static let rowMarginEm: Float = 0.4

    /// Compose `EaseInOut` = cubic(0.42, 0, 0.58, 1).
    public static let easeInOut = CubicBezierEasing(0.42, 0, 0.58, 1)

    /// True while `t` is inside the gap, i.e. the dots row needs to be drawn and animated.
    public static func isActive(tMs: Int64, g0: Int64, g1: Int64) -> Bool { g1 > g0 && tMs >= g0 && tMs < g1 }

    /// Presence 0…1: the expand-in multiplied by the collapse-out. It is the row-height factor and the group alpha.
    public static func presence(tMs: Int64, g0: Int64, g1: Int64) -> Float {
        if !isActive(tMs: tMs, g0: g0, g1: g1) { return 0 }
        let expandIn = easeInOut.transform((Float(tMs &- g0) / Float(expandMs)).coerced(in: 0, 1))
        let collapse = easeInOut.transform((Float(tMs &- (g1 &- collapseMs)) / Float(collapseMs)).coerced(in: 0, 1))
        return (expandIn * (1 - collapse)).coerced(in: 0, 1)
    }

    /// Row height factor, read in placement so the rows below slide instead of re-measuring.
    public static func expand(tMs: Int64, g0: Int64, g1: Int64) -> Float { presence(tMs: tMs, g0: g0, g1: g1) }

    /// Group alpha.
    public static func alpha(tMs: Int64, g0: Int64, g1: Int64) -> Float { presence(tMs: tMs, g0: g0, g1: g1) }

    /// Group scale including the expand/collapse: `0.1 + (base − 0.1) × presence`.
    public static func scale(tMs: Int64, g0: Int64, g1: Int64) -> Float {
        let p = presence(tMs: tMs, g0: g0, g1: g1)
        if p <= 0 { return hiddenScale }
        return hiddenScale + (baseScale(tMs: tMs, g0: g0, g1: g1) - hiddenScale) * p
    }

    /// The breathing / final-pulse scale before expand and collapse are applied.
    public static func baseScale(tMs: Int64, g0: Int64, g1: Int64) -> Float {
        if g1 &- g0 < shortGapMs { return 1 }
        let pulseStart = g1 &- finalPulseLeadMs
        let breath = breathing(tMs: tMs, g0: g0)
        if tMs < pulseStart { return breath }
        let pulse = finalPulse(tMs: tMs, pulseStartMs: pulseStart)
        let w = easeInOut.transform((Float(tMs &- pulseStart) / Float(finalPulseBlendMs)).coerced(in: 0, 1))
        return breath + (pulse - breath) * w
    }

    /// `1 + 0.2·sin²(π·((t − g0) mod 5000)/5000)` (`Math.floorMod`).
    public static func breathing(tMs: Int64, g0: Int64) -> Float {
        let d = tMs &- g0
        var m = d % breathPeriodMs
        if m < 0 { m += breathPeriodMs }
        let phase = Float(m) / Float(breathPeriodMs)
        let s = LyricsKotlinFloat.sin(LyricsKotlinFloat.pi * phase)
        return 1 + breathAmplitude * s * s
    }

    /// `1.1 + 0.3·sin²(π·(t − pulseStart)/1000)`, pulsing between 1.1 and 1.4.
    public static func finalPulse(tMs: Int64, pulseStartMs: Int64) -> Float {
        let s = LyricsKotlinFloat.sin(LyricsKotlinFloat.pi * Float(tMs &- pulseStartMs) / Float(finalPulsePeriodMs))
        return finalPulseBase + finalPulseAmplitude * s * s
    }

    /// Alpha of dot `k` (0…2): 0.3 → 1.0 linearly across its third of the gap (all lit on short gaps).
    public static func dotAlpha(tMs: Int64, g0: Int64, g1: Int64, k: Int) -> Float {
        let d = g1 &- g0
        if d <= 0 { return dotUnlitAlpha }
        if d < shortGapMs { return dotLitAlpha }
        let segment = Float(d) / Float(dotCount)
        let segStart = Float(g0) + segment * Float(k)
        let f = ((Float(tMs) - segStart) / segment).coerced(in: 0, 1)
        return dotUnlitAlpha + (dotLitAlpha - dotUnlitAlpha) * f
    }
}
