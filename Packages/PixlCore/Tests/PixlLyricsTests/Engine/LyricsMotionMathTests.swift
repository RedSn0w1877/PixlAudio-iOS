import Foundation
import Testing
import PixlFoundation
@testable import PixlLyrics

/// Port of `presentation/lyrics/LyricsMotionMathTest.kt` (all 23 cases): spring conversion table, cascade delays,
/// emphasis reference values, interlude timeline, blur maths.
@Suite("Lyrics motion maths")
struct LyricsMotionMathTests {

    func near(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }
    func near(_ a: [Float], _ b: [Float], _ tol: Float) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tol }
    }

    // MARK: §3.1 spring conversion

    @Test func springConversionTable() {
        #expect(near(LyricsSprings.slowDampingRatio, 0.8333, 1e-4))
        #expect(near(LyricsSprings.slowStiffness, 100, 1e-3))
        #expect(near(LyricsSprings.endedDampingRatio, 0.980, 1e-3))
        #expect(near(LyricsSprings.endedStiffness, 155.6, 0.05))
        #expect(near(LyricsSprings.scaleDampingRatio, 0.884, 1e-3))
        #expect(near(LyricsSprings.scaleStiffness, 50, 1e-3))
        #expect(near(LyricsSprings.normalDampingRatio, 1.1595, 1e-4))
    }

    @Test func normalPlaybackDamping_isIndependentOfStiffness() {
        for k: Float in [170, 195, 220] {
            #expect(near(LyricsSprings.normalDampingRatio,
                         LyricsSprings.dampingRatio(mass: 0.9, stiffness: k, damping: 2.2 * k.squareRoot()), 1e-5))
        }
    }

    @Test func normalPlaybackStiffness_followsTheStartGap() {
        #expect(near(LyricsSprings.normalPlaybackStiffness(gapMs: 100), 244.44, 0.01))
        #expect(near(LyricsSprings.normalPlaybackStiffness(gapMs: 20), 244.44, 0.01)) // clamped to 100
        #expect(near(LyricsSprings.normalPlaybackStiffness(gapMs: 800), 188.89, 0.01))
        #expect(near(LyricsSprings.normalPlaybackStiffness(gapMs: 5_000), 188.89, 0.01)) // clamped to 800
        // gap 450: ratio = 0.5^0.2 = 0.87055, k = 213.53, stiffness = 237.25
        #expect(near(LyricsSprings.normalPlaybackStiffness(gapMs: 450), 237.25, 0.01))
        #expect(LyricsSprings.normal(gapMs: 450) == LyricsSprings.normal(gapMs: 450))
    }

    // MARK: §3.3 cascade

    @Test func cascadeDelays_stepFiftyThenDecayFromTheTarget() {
        var out = [Float](repeating: 0, count: 5)
        LyricsCascade.computeDelays(tops: [0, 100, 200, 300, 400], heights: [100, 100, 100, 100, 100], count: 5, targetRow: 2, out: &out)
        // Each row takes the running delay, then `delay += step`; from the target row on, `step /= 1.05` after it.
        #expect(near(out, [0, 50, 100, 150, 197.619], 1e-3))
    }

    @Test func cascadeDelays_rowsAboveTheViewportGetZero() {
        var out = [Float](repeating: -1, count: 4)
        LyricsCascade.computeDelays(tops: [-300, -150, 0, 100], heights: [100, 100, 100, 100], count: 4, targetRow: 3, out: &out)
        #expect(near(out, [0, 0, 0, 50], 1e-3))
    }

    @Test func cascadeDelays_zeroHeightRowsDoNotConsumeAStep() {
        var out = [Float](repeating: 0, count: 4)
        LyricsCascade.computeDelays(tops: [0, 100, 100, 200], heights: [100, 0, 100, 100], count: 4, targetRow: 0, out: &out)
        #expect(near(out, [0, 50, 50, 97.619], 1e-3))
    }

    // MARK: §1.4 emphasis

    @Test func emphasisReferenceValues() {
        #expect(near(EmphasisMath.peakScale(1_000), 1.0075, 1e-4))
        #expect(near(EmphasisMath.peakScale(2_000), 1.06, 1e-4))
        #expect(near(EmphasisMath.peakScale(3_000), 1.07, 5e-3))
        #expect(near(EmphasisMath.peakGlowAlpha(1_000), 0.02, 2e-3))
        #expect(near(EmphasisMath.peakGlowAlpha(2_000), 0.15, 3e-3))
        #expect(near(EmphasisMath.peakGlowAlpha(3_000), 0.5, 1e-4))
    }

    @Test func emphasisPeak_isReachedThroughTheEnvelope() {
        let amount = EmphasisMath.amount(2_000, isLastWord: false)
        var peak: Float = 0
        for k in 0...1000 { peak = Swift.max(peak, EmphasisMath.scale(e: EmphasisMath.envelope(Float(k) / 1000), amount: amount)) }
        #expect(near(peak, 1.06, 1e-3))
        #expect(near(EmphasisMath.envelope(0), 0, 1e-4))
        #expect(near(EmphasisMath.envelope(0.5), 1, 1e-4))
        #expect(near(EmphasisMath.envelope(1), 0, 1e-4))
    }

    @Test func emphasis_lastWordBoost_andCaps() {
        #expect(near(EmphasisMath.amount(1_000, isLastWord: true), 0.12, 1e-4))
        #expect(near(EmphasisMath.effectiveDurationMs(1_000, isLastWord: true), 1_200, 1e-3))
        #expect(EmphasisMath.amount(60_000, isLastWord: true) <= EmphasisMath.maxAmount)
        #expect(EmphasisMath.glow(60_000, isLastWord: true) <= EmphasisMath.maxGlow)
        #expect(near(EmphasisMath.glowBlurEm(5), 0.3, 1e-6))
    }

    @Test func emphasisGraphemeTiming_andPush() {
        #expect(near(EmphasisMath.graphemeStartMs(wordStartMs: 1_000, effectiveDurationMs: 1_000, n: 5, i: 2), 1_160, 1e-3))
        // Letters spread from the middle: left of centre pushes left, right pushes right.
        #expect(EmphasisMath.offsetXEm(e: 1, amount: 1, n: 4, i: 0) < 0)
        #expect(near(EmphasisMath.offsetXEm(e: 1, amount: 1, n: 4, i: 2), 0, 1e-6))
        #expect(EmphasisMath.offsetXEm(e: 1, amount: 1, n: 4, i: 3) > 0)
        #expect(EmphasisMath.offsetYEm(e: 1, amount: 1) < 0)
    }

    @Test func liftAndHop() {
        #expect(near(EmphasisMath.liftEm(tMs: 1_000, startMs: 1_000, durationMs: 500), 0, 1e-6))
        #expect(near(EmphasisMath.liftEm(tMs: 2_000, startMs: 1_000, durationMs: 500), 0.05, 1e-6))
        #expect(near(EmphasisMath.liftEm(tMs: 5_000, startMs: 1_000, durationMs: 500, background: true), 0.10, 1e-6))
        #expect(EmphasisMath.liftEm(tMs: 1_500, startMs: 1_000, durationMs: 500) > 0.025) // ease-out is ahead of linear

        let du: Float = 1_000
        #expect(near(EmphasisMath.hopEm(tMs: 600, charStartMs: 1_000, effectiveDurationMs: du), 0, 1e-6))
        #expect(near(EmphasisMath.hopEm(tMs: Int64(600 + du * 1.4 / 2), charStartMs: 1_000, effectiveDurationMs: du), 0.05, 1e-4))
    }

    @Test func sweepEdge_entersAndLeavesTheSyllableFully() {
        #expect(near(EmphasisMath.sweepEdgeCenterPx(leftPx: 10, rightPx: 110, fadePx: 20, p: 0), 0, 1e-6))
        #expect(near(EmphasisMath.sweepEdgeCenterPx(leftPx: 10, rightPx: 110, fadePx: 20, p: 1), 120, 1e-6))
        #expect(near(EmphasisMath.syllableProgress(tMs: 1_500, startMs: 1_000, endMs: 2_000), 0.5, 1e-6))
        #expect(near(EmphasisMath.syllableProgress(tMs: 3_000, startMs: 1_000, endMs: 2_000), 1, 1e-6))
        #expect(near(EmphasisMath.syllableProgress(tMs: 1_000, startMs: 1_000, endMs: 1_000), 1, 1e-6))
    }

    @Test func graphemeBoundaries_keepCombiningMarksTogether() {
        #expect(EmphasisMath.graphemeBoundaries("e\u{301}a") == [0, 2, 3])
        #expect(EmphasisMath.graphemeBoundaries("") == [0])
    }

    @Test func alphas() {
        #expect(near(KaraokeAlpha.unsung(0), 0.20, 1e-6))
        #expect(near(KaraokeAlpha.unsung(1), 0.35, 1e-6))
        #expect(near(KaraokeAlpha.sung(0), 0.20, 1e-6))
        #expect(near(KaraokeAlpha.sung(1), 1.0, 1e-6))
    }

    // MARK: §1.6 interlude

    let g0: Int64 = 10_000
    let g1: Int64 = 30_000

    @Test func interlude_expandAndCollapse() {
        #expect(InterludeTimeline.presence(tMs: g0 - 1, g0: g0, g1: g1) == 0)
        #expect(near(InterludeTimeline.presence(tMs: g0, g0: g0, g1: g1), 0, 1e-6))
        #expect(near(InterludeTimeline.scale(tMs: g0, g0: g0, g1: g1), InterludeTimeline.hiddenScale, 1e-6))
        #expect(near(InterludeTimeline.presence(tMs: g0 + 150, g0: g0, g1: g1), 0.5, 1e-3))
        #expect(near(InterludeTimeline.presence(tMs: g0 + 300, g0: g0, g1: g1), 1, 1e-6))
        #expect(near(InterludeTimeline.expand(tMs: g0 + 5_000, g0: g0, g1: g1), 1, 1e-6))
        #expect(near(InterludeTimeline.presence(tMs: g1 - 150, g0: g0, g1: g1), 0.5, 1e-3))
        #expect(InterludeTimeline.presence(tMs: g1, g0: g0, g1: g1) == 0)
        #expect(InterludeTimeline.isActive(tMs: g0, g0: g0, g1: g1))
        #expect(!InterludeTimeline.isActive(tMs: g1, g0: g0, g1: g1))
    }

    @Test func interlude_dotsFillOneAfterAnother() {
        let d = g1 - g0
        #expect(near(InterludeTimeline.dotAlpha(tMs: g0, g0: g0, g1: g1, k: 0), 0.3, 1e-6))
        #expect(near(InterludeTimeline.dotAlpha(tMs: g0 + d / 3, g0: g0, g1: g1, k: 0), 1.0, 1e-3))
        #expect(near(InterludeTimeline.dotAlpha(tMs: g0 + d / 3, g0: g0, g1: g1, k: 1), 0.3, 1e-3))
        #expect(near(InterludeTimeline.dotAlpha(tMs: g0 + d / 2, g0: g0, g1: g1, k: 1), 0.65, 1e-3))
        #expect(near(InterludeTimeline.dotAlpha(tMs: g0 + d / 2, g0: g0, g1: g1, k: 2), 0.3, 1e-3))
        #expect(near(InterludeTimeline.dotAlpha(tMs: g1 - 1, g0: g0, g1: g1, k: 2), 1.0, 1e-3))
    }

    @Test func interlude_breathingThenFinalPulse() {
        #expect(near(InterludeTimeline.baseScale(tMs: g0, g0: g0, g1: g1), 1.0, 1e-6))
        #expect(near(InterludeTimeline.baseScale(tMs: g0 + 2_500, g0: g0, g1: g1), 1.2, 1e-4))
        #expect(near(InterludeTimeline.baseScale(tMs: g0 + 5_000, g0: g0, g1: g1), 1.0, 1e-4))
        // Pulse fully blended in 500 ms after it starts: 1.1 + 0.3·sin²(π/2) = 1.4
        #expect(near(InterludeTimeline.baseScale(tMs: g1 - 1_000, g0: g0, g1: g1), 1.4, 1e-4))
        #expect(near(InterludeTimeline.baseScale(tMs: g1 - 500, g0: g0, g1: g1), 1.1, 1e-4))
    }

    @Test func interlude_shortGap_skipsBreathing_andLightsAllDots() {
        #expect(InterludeTimeline.baseScale(tMs: 1_000, g0: 0, g1: 2_000) == 1)
        for k in 0..<3 { #expect(InterludeTimeline.dotAlpha(tMs: 1_000, g0: 0, g1: 2_000, k: k) == 1) }
    }

    @Test func interlude_isContinuous_soSeeksAndPhaseChangesNeverPop() {
        var prevScale = InterludeTimeline.scale(tMs: g0 - 10, g0: g0, g1: g1)
        var prevPresence = InterludeTimeline.presence(tMs: g0 - 10, g0: g0, g1: g1)
        var t = g0 - 9
        var jumps = 0
        while t <= g1 + 10 {
            let s = InterludeTimeline.scale(tMs: t, g0: g0, g1: g1)
            let p = InterludeTimeline.presence(tMs: t, g0: g0, g1: g1)
            if abs(s - prevScale) >= 0.015 || abs(p - prevPresence) >= 0.01 { jumps += 1 }
            prevScale = s
            prevPresence = p
            t += 1
        }
        #expect(jumps == 0)
        #expect(InterludeTimeline.scale(tMs: 20_123, g0: g0, g1: g1) == InterludeTimeline.scale(tMs: 20_123, g0: g0, g1: g1))
    }

    // MARK: §1 / §1.3 blur

    @Test func depthBlurTable() {
        let expected: [Float] = [0, 1.6, 2.4, 3.2, 4.0, 4.8, 5.0, 5.0]
        for d in expected.indices { #expect(near(LyricsBlurMath.depthSigmaDp(distance: d, strength: 1), expected[d], 1e-5), "d=\(d)") }
        #expect(near(LyricsBlurMath.depthSigmaDp(distance: 1, strength: 1.2), 1.92, 1e-5))
    }

    @Test func blurConversions() {
        // σ = 0.57735·r + 0.5  ⇒  r = (σ·density − 0.5) / 0.57735
        #expect(near(LyricsBlurMath.sigmaDpToRadiusPx(1.6, density: 2.75), 6.7550, 1e-3))
        #expect(LyricsBlurMath.sigmaDpToRadiusPx(0.1, density: 1) == 0)
        #expect(near(LyricsBlurMath.sigmaDpToRadiusPx(5, density: 3), LyricsBlurMath.cssShadowBlurToRadiusPx(10, density: 3), 1e-5))
        #expect(near(LyricsBlurMath.quantizeRadiusPx(1.13), 1.5, 1e-6))
        #expect(near(LyricsBlurMath.quantizeRadiusPx(0.74), 0, 1e-6))
        #expect(near(LyricsBlurMath.quantizeRadiusPx(6.7550), 7.5, 1e-6))
    }

    @Test func api30AlphaFalloff() {
        #expect(LyricsBlurMath.fallbackAlphaFactor(distance: 0) == 1)
        #expect(near(LyricsBlurMath.fallbackAlphaFactor(distance: 1), 0.94, 1e-6))
        #expect(near(0.2 * LyricsBlurMath.fallbackAlphaFactor(distance: 4), 0.152, 1e-6))
        #expect(near(0.2 * LyricsBlurMath.fallbackAlphaFactor(distance: 9), 0.152, 1e-6))
    }

    @Test func unsungNeverDropsBelowTheInactiveTier() {
        for inactive in [KaraokeAlpha.inactive, KaraokeAlpha.inactiveBrightArt, KaraokeAlpha.inactiveHighContrast] {
            for step in 0...20 {
                let a = Float(step) / 20
                #expect(KaraokeAlpha.unsung(a, inactive: inactive) >= inactive - 1e-6, "tier \(inactive) at a=\(a)")
            }
        }
        #expect(near(KaraokeAlpha.unsung(1, inactive: KaraokeAlpha.inactiveBrightArt), 0.60, 1e-6))
    }

    // MARK: Swift-only

    @Test func sigmaQuantisation() {
        #expect(LyricsBlurMath.quantizeSigma(1.6, quantum: 0.3) == KotlinMath.round(Float(1.6) / 0.3) * 0.3)
        #expect(LyricsBlurMath.quantizeSigma(0.1, quantum: 0.3) == 0)
        #expect(LyricsBlurMath.quantizeSigma(2.2, quantum: 0) == 2.2)
    }

    @Test func rtlSweepMirrorsTheEdge() {
        #expect(near(EmphasisMath.sweepEdgeCenterRtlPx(leftPx: 10, rightPx: 110, fadePx: 20, p: 0), 120, 1e-6))
        #expect(near(EmphasisMath.sweepEdgeCenterRtlPx(leftPx: 10, rightPx: 110, fadePx: 20, p: 1), 0, 1e-6))
    }
}
