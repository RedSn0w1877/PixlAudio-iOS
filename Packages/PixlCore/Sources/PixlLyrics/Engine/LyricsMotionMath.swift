// Port of the motion maths at the top of `presentation/lyrics/LyricsEngine.kt`: the spring conversion table
// (`LyricsSprings`, spec §3.1), the depth-blur maths (`LyricsBlurMath`, §1/§1.3) and the cascade delays
// (`LyricsCascade`, §3.3). Springs are `PixlFoundation.FloatSpringSpec`, Compose-exact.

import Foundation
import PixlFoundation
import Synchronization

/// Web spring constants (`m·x″ + c·x′ + k·x = 0`) converted to Compose's unit-mass `spring(dampingRatio, stiffness)`:
/// `stiffness = k / m`, `ζ = c / (2·√(k·m))`.
public enum LyricsSprings {
    /// Mass of AMLL's line springs.
    public static let lineMass: Float = 0.9

    public static func dampingRatio(mass: Float, stiffness: Float, damping: Float) -> Float {
        damping / (2 * LyricsKotlinFloat.sqrt(stiffness * mass))
    }

    public static func stiffness(mass: Float, stiffness: Float) -> Float { stiffness / mass }

    /// Normal playback: `c = 2.2·√k` at m = 0.9, so `ζ = 1.1/√0.9` whatever k is.
    public static let normalDampingRatio: Float = 1.1 / LyricsKotlinFloat.sqrt(lineMass)

    /// Web stiffness for normal playback: `gap = clamp(Δstart, 100, 800)`, `ratio = (1 − (gap − 100)/700)^0.2`,
    /// `k = 170 + 50·ratio`. Lines that come quickly get a stiffer, faster spring.
    public static func normalPlaybackWebStiffness(gapMs: Int64) -> Float {
        let gap = Float(gapMs.coerced(in: 100, 800))
        let ratio = LyricsKotlinFloat.pow((1 - (gap - 100) / 700).coerced(in: 0, 1), 0.2)
        return 170 + 50 * ratio
    }

    /// Compose stiffness for normal playback (188.9 … 244.4).
    public static func normalPlaybackStiffness(gapMs: Int64) -> Float {
        stiffness(mass: lineMass, stiffness: normalPlaybackWebStiffness(gapMs: gapMs))
    }

    /// Seek, interlude, first/last line, snap-back: web (0.9, 90, 15) → ζ 0.8333, stiffness 100.
    public static let slowDampingRatio: Float = dampingRatio(mass: lineMass, stiffness: 90, damping: 15)
    public static let slowStiffness: Float = stiffness(mass: lineMass, stiffness: 90)

    /// Song ended: web (0.9, 140, 22) → ζ 0.980, stiffness 155.6.
    public static let endedDampingRatio: Float = dampingRatio(mass: lineMass, stiffness: 140, damping: 22)
    public static let endedStiffness: Float = stiffness(mass: lineMass, stiffness: 140)

    /// Line scale: web (2, 100, 25) → ζ 0.884, stiffness 50.
    public static let scaleDampingRatio: Float = dampingRatio(mass: 2, stiffness: 100, damping: 25)
    public static let scaleStiffness: Float = stiffness(mass: 2, stiffness: 100)

    /// Background-vocal expand and slide (not from a web source).
    public static let backgroundDampingRatio: Float = 0.9
    public static let backgroundStiffness: Float = 150

    public static let slow = FloatSpringSpec(dampingRatio: slowDampingRatio, stiffness: slowStiffness, visibilityThreshold: 0.5)
    public static let ended = FloatSpringSpec(dampingRatio: endedDampingRatio, stiffness: endedStiffness, visibilityThreshold: 0.5)
    public static let scale = FloatSpringSpec(dampingRatio: scaleDampingRatio, stiffness: scaleStiffness, visibilityThreshold: 0.0005)
    public static let background = FloatSpringSpec(dampingRatio: backgroundDampingRatio, stiffness: backgroundStiffness,
                                                   visibilityThreshold: 0.001)

    /// Process-wide cache, exactly like Android's `normalCache`: keyed by `round(stiffness × 10)`, so the first gap
    /// that maps to a key decides the stiffness every later gap with that key uses (≤ 0.05 apart).
    private static let normalCache = Mutex<[Int32: FloatSpringSpec]>([:])

    /// Normal-playback spec for a start gap, cached by stiffness.
    public static func normal(gapMs: Int64) -> FloatSpringSpec {
        let stiffness = normalPlaybackStiffness(gapMs: gapMs)
        let key = KotlinMath.toInt(KotlinMath.round(stiffness * 10))
        return normalCache.withLock { cache in
            if let spec = cache[key] { return spec }
            let spec = FloatSpringSpec(dampingRatio: normalDampingRatio, stiffness: stiffness, visibilityThreshold: 0.5)
            cache[key] = spec
            return spec
        }
    }
}

/// Depth blur (spec §1, §1.3).
public enum LyricsBlurMath {
    public static let maxSigmaDp: Float = 5
    public static let sigmaPerStepDp: Float = 0.8
    /// Android's radius quantum: 1.5 px (not the spec's 0.25: every row's σ retargets on each line change, and at
    /// 0.25 px a 400 ms tween re-filtered every blurred row every few frames).
    public static let radiusQuantumPx: Float = 1.5
    public static let fallbackAlphaStep: Float = 0.06
    public static let fallbackMaxDistance = 4

    /// σ in dp (a CSS `filter: blur` value) → Android/Compose blur radius in px. Skia: `σ = 0.57735·r + 0.5`.
    public static func sigmaDpToRadiusPx(_ sigmaDp: Float, density: Float) -> Float {
        ((sigmaDp * density - 0.5) / 0.57735).coerced(atLeast: 0)
    }

    /// A CSS text-shadow blur B (dp) has σ = B/2.
    public static func cssShadowBlurToRadiusPx(_ blurDp: Float, density: Float) -> Float {
        sigmaDpToRadiusPx(blurDp / 2, density: density)
    }

    /// Depth blur for a line `distance` rows from the hot lines: `min(5, (1 + d) × 0.8) × strength` dp.
    public static func depthSigmaDp(distance: Int, strength: Float) -> Float {
        distance <= 0 ? 0 : Swift.min(maxSigmaDp, Float(1 + distance) * sigmaPerStepDp) * strength
    }

    /// No-blur substitute (Android API 30): multiply the inactive alpha by `1 − 0.06·min(d, 4)`.
    public static func fallbackAlphaFactor(distance: Int) -> Float {
        distance <= 0 ? 1 : 1 - fallbackAlphaStep * Float(Swift.min(distance, fallbackMaxDistance))
    }

    /// Rounds a blur radius to `radiusQuantumPx` steps (half to even, like Kotlin `round`).
    public static func quantizeRadiusPx(_ radiusPx: Float) -> Float {
        KotlinMath.round(radiusPx / radiusQuantumPx) * radiusQuantumPx
    }

    /// Rounds a Gaussian σ (points) to `quantum` steps — the iOS output (`.blur(radius:)` takes a σ-like radius in
    /// points). Same half-to-even rounding as Android's radius quantisation.
    public static func quantizeSigma(_ sigma: Float, quantum: Float) -> Float {
        guard quantum > 0 else { return sigma }
        return KotlinMath.round(sigma / quantum) * quantum
    }
}

/// Cascade (stagger) delays (spec §3.3).
public enum LyricsCascade {
    public static let baseStepMs: Float = 50
    public static let stepDecay: Float = 1.05

    /// Stagger delays for a scroll-target change. Walks rows in index order; each row whose current bottom
    /// (`top + height`) is ≥ 0 — visible or below the viewport — gets the running delay, which then grows by `step`
    /// (50 ms). From `targetRow` on, `step /= 1.05` after each row. Rows above the viewport get 0. Zero-height rows
    /// (collapsed background vocals, interludes at rest) take the running delay without consuming a step.
    ///
    /// - Parameter out: receives delays in ms, `out[i]` for row `i`.
    public static func computeDelays(tops: [Float], heights: [Float], count: Int, targetRow: Int, out: inout [Float]) {
        var delay: Float = 0
        var step = baseStepMs
        for i in 0..<count {
            let h = heights[i].coerced(atLeast: 0)
            if tops[i] + h < 0 {
                out[i] = 0
                continue
            }
            out[i] = delay
            if h < 0.5 { continue }
            delay += step
            if i >= targetRow { step /= stepDecay }
        }
    }
}
