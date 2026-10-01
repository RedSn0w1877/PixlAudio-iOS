import Foundation
import Testing
@testable import PixlLyrics

/// Deterministic generator for the property tests (Kotlin's seeded `Random` sequence is not reproduced; the tests
/// only need many colours).
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextInt(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func nextFloat() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

/// Port of `presentation/lyrics/background/LyricsBackgroundGradeTest.kt` (all 6 cases), plus Swift-only tests of
/// the shader steps and the motion/crossfade clock.
@Suite("Lyrics background grade")
struct LyricsBackgroundTests {

    /// Independent three-step reference, in double precision, on 0…1 sRGB.
    func referenceGrade(_ r: Double, _ g: Double, _ b: Double) -> [Double] {
        let luma = 0.2125 * r + 0.7154 * g + 0.0721 * b
        let sat = [r, g, b].map { luma + ($0 - luma) * 2.75 }
        let con = sat.map { ($0 - 0.5) * 1.9 + 0.5 }
        return con.map { Swift.min(Swift.max($0 * 0.7, 0), 1) }
    }

    @Test func singleGradeMatrixEqualsTheThreeStepReferenceOnRandomColours() {
        var random = SplitMix64(state: 20260925)
        var failures = 0
        for _ in 0..<20_000 {
            let r = random.nextInt(256), g = random.nextInt(256), b = random.nextInt(256)
            let expected = referenceGrade(Double(r) / 255, Double(g) / 255, Double(b) / 255)
            let actual = LyricsBackgroundGrade.applyMatrix(Float(r), Float(g), Float(b), 255)
            let channels = [actual.r, actual.g, actual.b]
            for c in 0..<3 where abs(expected[c] * 255 - Double(channels[c])) > 0.01 { failures += 1 }
            if actual.a != 255 { failures += 1 }
        }
        #expect(failures == 0)
    }

    @Test func referenceGradeMatchesTheIndependentReference() {
        var random = SplitMix64(state: 7)
        for _ in 0..<5_000 {
            let r = random.nextFloat(), g = random.nextFloat(), b = random.nextFloat()
            let out = LyricsBackgroundGrade.gradeReference(r, g, b)
            let expected = referenceGrade(Double(r), Double(g), Double(b))
            #expect(abs(expected[0] - Double(out.r)) <= 1e-5)
            #expect(abs(expected[1] - Double(out.g)) <= 1e-5)
            #expect(abs(expected[2] - Double(out.b)) <= 1e-5)
        }
    }

    @Test func gradeMatchesTheCoefficientsPublishedInTheSpec() {
        let expected: [Float] = [
            3.16291, -1.66509, -0.16781, 0, -80.325,
            -0.49459, 1.99241, -0.16781, 0, -80.325,
            -0.49459, -1.66509, 3.48969, 0, -80.325,
            0, 0, 0, 1, 0,
        ]
        let grade = LyricsBackgroundGrade.gradeMatrix
        for i in expected.indices {
            let tolerance: Float = i % 5 == 4 ? 1e-3 : 1e-4
            #expect(abs(expected[i] - grade[i]) <= tolerance, "matrix entry \(i)")
        }
        for row in 0..<3 {
            #expect(abs(grade[row * 5] + grade[row * 5 + 1] + grade[row * 5 + 2] - 1.33) <= 1e-5)
        }
    }

    @Test func whiteArtCountsAsBrightAndBlackArtDoesNot() {
        #expect(LyricsBackgroundGrade.gradedLuma(1, 1, 1) > LyricsBackgroundGrade.brightArtLuma)
        #expect(LyricsBackgroundGrade.gradedLuma(0, 0, 0) < LyricsBackgroundGrade.brightArtLuma)
        #expect(LyricsBackgroundGrade.gradedLuma(0.5, 0.5, 0.5) < LyricsBackgroundGrade.brightArtLuma)
    }

    @Test func threeBoxPassesApproximateTheRequestedGaussianSigma() {
        for sigma: Float in [1.5, 3.5, 4.9, 7.8, 15.5] {
            let radii = SpriteBlur.boxRadiiForGaussian(sigma)
            let variance = radii.reduce(0.0) { $0 + Double((2 * $1 + 1) * (2 * $1 + 1) - 1) / 12 }
            let relativeError = abs(variance.squareRoot() - Double(sigma)) / Double(sigma)
            #expect(relativeError < 0.12, "σ=\(sigma) → radii \(radii)")
        }
    }

    @Test func paddedSpriteBlurConservesEnergyAndFadesToTransparentAtTheEdge() {
        let artSize = 8
        let art = [UInt32](repeating: 0xFFFF_FFFF, count: artSize * artSize)
        let sigma: Float = 2
        let pad = Int((3 * sigma).rounded(.up))
        let out = SpriteBlur.bakeSprite(art: art, artSize: artSize, pad: pad, sigma: sigma, opaque: false)
        let size = artSize + 2 * pad
        let alphaSum = out.reduce(0) { $0 + Int($1 >> 24) }
        #expect(abs(Double(alphaSum) - 64 * 255) <= 64 * 255 * 0.03)
        #expect(out[0] >> 24 <= 2)
        #expect(out[size * size - 1] >> 24 <= 2)
        let centre = out[(size / 2) * size + size / 2]
        #expect(centre >> 24 > 200)
        #expect((centre >> 16) & 0xFF == 0xFF)
    }

    // MARK: Swift-only

    @Test func meanLumaAndBrightness() {
        #expect(LyricsBackgroundGrade.meanGradedLuma(argb: []) == 0)
        let white = LyricsBackgroundGrade.meanGradedLuma(argb: [0xFFFF_FFFF, 0xFFFF_FFFF])
        #expect(LyricsBackgroundGrade.isBright(meanLuma: white))
        #expect(!LyricsBackgroundGrade.isBright(meanLuma: LyricsBackgroundGrade.meanGradedLuma(argb: [0xFF00_0000])))
    }

    @Test func shaderStepsMatchTheGradeAndOverlays() {
        // An opaque mid-grey composite: grade → clamp → black 50 % → white 5 % (no scrim), ± half a dither step.
        let grey = SIMD4<Float>(0.4, 0.4, 0.4, 1)
        let px = LyricsBackgroundGrade.shadePixel(composite: grey, pixelX: 10, pixelY: 20, scrim: 0, alpha: 1)
        let graded = LyricsBackgroundGrade.gradeReference(0.4, 0.4, 0.4)
        let expected = LyricsBackgroundGrade.overlays(graded.r, graded.g, graded.b, scrim: 0)
        #expect(abs(px.x - expected.r) <= 0.5 / 255 + 1e-6)
        #expect(px.w == 1)
        // Premultiplied input decodes to the same colour.
        let half = LyricsBackgroundGrade.shadePixel(composite: grey * 0.5, pixelX: 10, pixelY: 20, scrim: 0, alpha: 1)
        #expect(abs(half.x - px.x) <= 1e-6)
        // The noise stays in 0..<1.
        for k in 0..<1000 {
            let n = LyricsBackgroundGrade.interleavedGradientNoise(x: Float(k % 97), y: Float(k / 97))
            #expect(n >= 0 && n < 1)
        }
    }

    @Test func twistRotatesInsideTheRadiusOnly() {
        let centre = LyricsBackgroundGrade.twist(x: 50, y: 50, width: 100, height: 100, radius: 100)
        #expect(centre.x == 50 && centre.y == 50)
        let outside = LyricsBackgroundGrade.twist(x: 0, y: 0, width: 100, height: 100, radius: 50)
        #expect(outside.x == 0 && outside.y == 0)
        let inside = LyricsBackgroundGrade.twist(x: 60, y: 50, width: 100, height: 100, radius: 100)
        let dist = ((inside.x - 50) * (inside.x - 50) + (inside.y - 50) * (inside.y - 50)).squareRoot()
        #expect(abs(dist - 10) <= 1e-4, "a twist keeps the distance from the centre")
        #expect(abs(inside.y - 50) > 1)
    }

    @Test func spriteGeometry() {
        #expect(ArtworkSprites.aspectBucket(width: 0, height: 0) == 50)
        #expect(ArtworkSprites.aspectBucket(width: 100, height: 5) == 10)
        #expect(ArtworkSprites.padTexels(0, aspectBucket: 46) == 0)
        let sigma1 = ArtworkSprites.sigmaTexels(1, aspectBucket: 50)
        #expect(abs(sigma1 - 0.09 * (0.5 / 0.8) * 96) <= 1e-4)
        #expect(ArtworkSprites.padTexels(1, aspectBucket: 50) == Int((3 * sigma1).rounded(.up)))
    }

    @Test func crossfadeAndMotion() {
        var motion = LyricsBackgroundMotion<String>(initial: nil, reducedMotion: false)
        #expect(!motion.resolved)
        motion.show("a")
        #expect(motion.current == "a")
        #expect(motion.setAlphas.current == 0)
        motion.step(dtSeconds: 0.85, motion: true)
        #expect(abs(motion.fade - 0.5) <= 1e-5)
        motion.step(dtSeconds: 1, motion: true)
        #expect(motion.fadeDone)
        #expect(motion.previous == nil)
        #expect(abs(motion.phases[0] - 0.09 * 1.85) <= 1e-5)
        motion.show("b")
        #expect(motion.previous == "a")
        #expect(motion.setAlphas.previous == 1)
        motion.step(dtSeconds: 0.2, motion: false)
        motion.show("a") // bounced back while "a" still contributes more
        #expect(motion.previous == nil)
        #expect(motion.fadeDone)
        motion.show(nil)
        motion.step(dtSeconds: 0.425, motion: false)
        #expect(abs(motion.setAlphas.previous - 0.75) <= 1e-5)

        let reduced = LyricsBackgroundMotion<String>(initial: "x", reducedMotion: true)
        let g = reduced.geometry(initialAngles: [0, 1, 2, 3], width: 400, height: 800)
        #expect(g[0].centerX == 200 && g[0].centerY == 400)
        #expect(abs(g[1].centerX - 160) <= 1e-4)
        #expect(abs(g[0].size - (400 * 400 + 800 * 800 as Float).squareRoot()) <= 1e-3)
        let xf = reduced.shaderUniforms(initialAngles: [0, 1, 2, 3], width: 400, height: 800)
        #expect(abs(xf[0].x - 96 / g[0].size) <= 1e-6)
    }
}
