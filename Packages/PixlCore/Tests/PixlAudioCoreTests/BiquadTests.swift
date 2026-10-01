import Foundation
import Testing
@testable import PixlAudioCore

/// RBJ biquad design, response and processing (no Android counterpart: Android used the platform effects).
@Suite("Biquad")
struct BiquadTests {
    static let fs = 48_000.0

    @Test func zeroGainShapesAreTheIdentity() {
        for shape in [BiquadShape.peaking, .lowShelf, .highShelf] {
            #expect(BiquadDesigner.design(shape, frequency: 1000, sampleRate: Self.fs, gainDb: 0).isIdentity)
        }
        #expect(!BiquadDesigner.design(.lowPass, frequency: 1000, sampleRate: Self.fs).isIdentity)
        #expect(BiquadDesigner.design(.peaking, frequency: 1000, sampleRate: 0, gainDb: 6).isIdentity)
    }

    @Test func peakingHitsItsGainAtTheCentre() {
        for gain in [-15.0, -6, 3, 12] {
            for f in [31.0, 1000, 16_000] {
                let c = BiquadDesigner.design(.peaking, frequency: f, sampleRate: Self.fs, q: 2.0.squareRoot(), gainDb: gain)
                #expect(abs(c.magnitudeDb(atFrequency: f, sampleRate: Self.fs) - gain) < 1e-9, "f \(f) gain \(gain)")
                #expect(abs(c.magnitudeDb(atFrequency: 1, sampleRate: Self.fs)) < 0.05 || f < 100)
                #expect(c.isStable)
            }
        }
    }

    @Test func shelvesReachTheirGainOnOneSideAndUnityOnTheOther() {
        let low = BiquadDesigner.design(.lowShelf, frequency: 90, sampleRate: Self.fs, gainDb: 9)
        #expect(abs(low.magnitudeDb(atFrequency: 0, sampleRate: Self.fs) - 9) < 1e-9)
        #expect(abs(low.magnitudeDb(atFrequency: Self.fs / 2, sampleRate: Self.fs)) < 1e-9)
        #expect(abs(low.magnitudeDb(atFrequency: 90, sampleRate: Self.fs) - 4.5) < 1e-6) // half the gain at the corner
        let high = BiquadDesigner.design(.highShelf, frequency: 8000, sampleRate: Self.fs, gainDb: -6)
        #expect(abs(high.magnitudeDb(atFrequency: Self.fs / 2, sampleRate: Self.fs) + 6) < 1e-9)
        #expect(abs(high.magnitudeDb(atFrequency: 0, sampleRate: Self.fs)) < 1e-9)
    }

    @Test func butterworthLowAndHighPassAreThreeDbDownAtTheCorner() {
        let lp = BiquadDesigner.design(.lowPass, frequency: 1000, sampleRate: Self.fs)
        #expect(abs(lp.magnitudeDb(atFrequency: 1000, sampleRate: Self.fs) + 3.0103) < 1e-3)
        #expect(abs(lp.magnitude(atFrequency: 0, sampleRate: Self.fs) - 1) < 1e-12)
        #expect(lp.magnitude(atFrequency: Self.fs / 2, sampleRate: Self.fs) < 1e-6)
        let hp = BiquadDesigner.design(.highPass, frequency: 1000, sampleRate: Self.fs)
        #expect(abs(hp.magnitudeDb(atFrequency: 1000, sampleRate: Self.fs) + 3.0103) < 1e-3)
        #expect(hp.magnitude(atFrequency: 0, sampleRate: Self.fs) < 1e-12)
    }

    @Test func frequencyAndQAreSanitised() {
        let nearNyquist = BiquadDesigner.design(.peaking, frequency: 30_000, sampleRate: 32_000, gainDb: 6)
        #expect(nearNyquist.isStable)
        let badQ = BiquadDesigner.design(.lowPass, frequency: 500, sampleRate: Self.fs, q: -1)
        #expect(badQ == BiquadDesigner.design(.lowPass, frequency: 500, sampleRate: Self.fs, q: BiquadDesigner.butterworthQ))
    }

    @Test func cascadeMatchesADirectDifferenceEquation() {
        let c = BiquadDesigner.design(.peaking, frequency: 2000, sampleRate: Self.fs, q: 1, gainDb: 9)
        var cascade = BiquadCascade(sectionCount: 1, channelCount: 1)
        cascade.setCoefficients(c, at: 0)
        #expect(cascade.coefficients(at: 0) == c)
        let input: [Float] = (0..<256).map { (i: Int) -> Float in
            let tone: Double = sin(Double(i) * 0.37) * 0.5
            let click: Double = i == 3 ? 0.4 : 0
            return Float(tone + click)
        }
        var output = input
        output.withUnsafeMutableBufferPointer { cascade.process($0.baseAddress!, frames: 256) }
        // Direct form I reference in Double.
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for (i, sample) in input.enumerated() {
            let x = Double(sample)
            let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            #expect(abs(Double(output[i]) - y) < 1e-6, "sample \(i)")
        }
    }

    @Test func steadyStateSineFollowsTheMagnitudeResponse() {
        let c = BiquadDesigner.design(.peaking, frequency: 1000, sampleRate: Self.fs, q: 2.0.squareRoot(), gainDb: 6)
        var cascade = BiquadCascade(sectionCount: 1, channelCount: 2)
        cascade.setCoefficients(c, at: 0)
        let frames = 9600
        var buffer = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let phase: Double = 2 * Double.pi * 1000 * Double(i) / Self.fs
            buffer[2 * i] = Float(sin(phase) * 0.25)
            buffer[2 * i + 1] = 0 // the right channel stays silent: channels are independent
        }
        buffer.withUnsafeMutableBufferPointer { cascade.process($0.baseAddress!, frames: frames) }
        let peak = (frames / 2..<frames).map { abs(buffer[2 * $0]) }.max()!
        let expected = 0.25 * c.magnitude(atFrequency: 1000, sampleRate: Self.fs)
        #expect(abs(Double(peak) - expected) < 0.002)
        #expect((0..<frames).allSatisfy { buffer[2 * $0 + 1] == 0 })
    }

    @Test func identitySectionsLeaveSamplesUntouchedAndResetClearsState() {
        var cascade = BiquadCascade(sectionCount: 3, channelCount: 2)
        var samples: [Float] = [0.1, -0.2, 0.3, -0.4, 0.5, -0.6]
        let original = samples
        samples.withUnsafeMutableBufferPointer { cascade.process($0.baseAddress!, frames: 3) }
        #expect(samples == original)
        cascade.setCoefficients(BiquadDesigner.design(.lowPass, frequency: 200, sampleRate: Self.fs), at: 1)
        var a: [Float] = [1, 1, 0, 0, 0, 0]
        a.withUnsafeMutableBufferPointer { cascade.process($0.baseAddress!, frames: 3) }
        cascade.reset()
        var b: [Float] = [1, 1, 0, 0, 0, 0]
        b.withUnsafeMutableBufferPointer { cascade.process($0.baseAddress!, frames: 3) }
        #expect(a == b)
    }

    @Test func vDSPOrderAndStability() {
        let c = BiquadCoefficients(b0: 1, b1: 2, b2: 3, a1: 0.5, a2: 0.25)
        #expect(c.vDSPOrder == [1, 2, 3, 0.5, 0.25])
        #expect(c.isStable)
        #expect(!BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: -2.1, a2: 1.2).isStable)
    }
}
