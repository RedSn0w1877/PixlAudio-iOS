import Testing
@testable import PixlAudioCore

/// Swift tests for the MidSideVocalProcessor maths (bit-exactness against Android is in `AudioGoldenTests`).
@Suite("MidSideVocal")
struct MidSideVocalTests {
    @Test func zeroAttenuationLeavesAudioUntouched() {
        var samples: [Float] = [0.4, -0.2, 1.5, 0.1]
        samples.withUnsafeMutableBufferPointer { MidSideVocal.process($0.baseAddress!, frames: 2, attenuation: 0) }
        #expect(samples == [0.4, -0.2, 1.5, 0.1]) // no clamping either: the input is copied as is
        samples.withUnsafeMutableBufferPointer { MidSideVocal.process($0.baseAddress!, frames: 2, attenuation: -1) }
        #expect(samples == [0.4, -0.2, 1.5, 0.1])
    }

    @Test func fullAttenuationRemovesTheCentreAndKeepsTheSides() {
        var samples: [Float] = [0.5, 0.5, 0.5, -0.5, 0.75, 0.25]
        samples.withUnsafeMutableBufferPointer { MidSideVocal.process($0.baseAddress!, frames: 3, attenuation: 1) }
        #expect(samples == [0, 0, 0.5, -0.5, 0.25, -0.25])
    }

    @Test func halfAttenuationScalesTheMid() {
        var samples: [Float] = [0.8, 0.4]
        samples.withUnsafeMutableBufferPointer { MidSideVocal.process($0.baseAddress!, frames: 1, attenuation: 0.5) }
        // mid 0.6 → 0.3, side 0.2.
        #expect(abs(samples[0] - 0.5) < 1e-7 && abs(samples[1] - 0.1) < 1e-7)
    }

    @Test func outputIsClampedAndInt16Saturates() {
        var samples: [Float] = [2, -2]
        samples.withUnsafeMutableBufferPointer { MidSideVocal.process($0.baseAddress!, frames: 1, attenuation: 0.25) }
        #expect(samples == [1, -1])
        var pcm: [Int16] = [32767, -32768, 1000, 1000, 3, 0]
        pcm.withUnsafeMutableBufferPointer { MidSideVocal.process($0.baseAddress!, frames: 3, attenuation: 1) }
        #expect(pcm == [32767, -32767, 0, 0, 1, -1])
    }
}
