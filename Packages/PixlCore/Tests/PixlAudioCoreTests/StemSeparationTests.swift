import Foundation
import Testing
@testable import PixlAudioCore

/// Port of `StemAudioQualityTest` (all 5 cases) and `TaisInstrumentalRetentionTest`'s completeness rule, plus the
/// MDX-Net STFT pipeline with stand-in models.
@Suite("StemSeparation")
struct StemSeparationTests {
    // MARK: StemAudioQualityTest

    @Test func instrumentalEnergySurvivesWhereModelPredictsNoVoice() throws {
        #expect(try StemAudioQuality.linkedInstrumentalMask(mixPower: 4, vocalPower: 0, frequencyHz: 1000) == 1)
    }

    @Test func strongModeledVoiceIsRemovedAboveCrossover() throws {
        #expect(try StemAudioQuality.linkedInstrumentalMask(mixPower: 4, vocalPower: 4, frequencyHz: 1000) == 0)
    }

    @Test func bassCrossoverIsContinuous() throws {
        #expect(try StemAudioQuality.linkedInstrumentalMask(mixPower: 1, vocalPower: 1, frequencyHz: 40) == 1)
        let lower = try StemAudioQuality.linkedInstrumentalMask(mixPower: 1, vocalPower: 1, frequencyHz: 99.9)
        let upper = try StemAudioQuality.linkedInstrumentalMask(mixPower: 1, vocalPower: 1, frequencyHz: 100.1)
        #expect(lower > upper)
        #expect(lower - upper < 0.01)
    }

    @Test func linearGainPreservesStereoBalanceAndHeadroom() throws {
        let gain = try StemAudioQuality.peakSafeGain(left: [0.9, -0.2], right: [0.45, 0.4], desiredGain: 2)
        #expect(0.9 * gain <= 0.980001)
        #expect(abs((0.9 * gain) / (0.45 * gain) - 2) < 0.00001)
    }

    @Test func nonFiniteModelOutputFails() {
        #expect(throws: StemAudioQuality.Failure.nonFiniteModelOutput) {
            try StemAudioQuality.linkedInstrumentalMask(mixPower: 1, vocalPower: .nan, frequencyHz: 1000)
        }
    }

    // MARK: Files

    @Test func completenessFollowsTheDeclaredWavSize() {
        func header(_ declared: UInt32, _ tag: String = "RIFF") -> [UInt8] {
            Array(tag.utf8) + (0..<4).map { UInt8(truncatingIfNeeded: declared >> (8 * UInt32($0))) } + Array("WAVE".utf8)
        }
        #expect(StemFiles.isCompleteStem(firstBytes: header(164), fileLength: 172))
        #expect(!StemFiles.isCompleteStem(firstBytes: header(4096), fileLength: 172))
        #expect(!StemFiles.isCompleteStem(firstBytes: header(10), fileLength: 44))
        #expect(StemFiles.isCompleteStem(firstBytes: header(0, "fLaC"), fileLength: 2000))
    }

    @Test func fileNamesPreferTheCloudRenderAndRoundTrip() {
        let names = StemFiles.candidates(songId: "f:Music/a b.mp3")
        #expect(names[0].hasSuffix("_hq_roformer_inst.wav"))
        #expect(names[1].hasSuffix("_cloud_inst.m4a"))
        #expect(names[2].hasSuffix("_cloud_inst.flac"))
        #expect(names[3].hasSuffix("_instrumental.wav"))
        #expect(!names[0].contains("/") && !names[0].contains(":"))
        #expect(StemFiles.songId(fileName: names[1]) == StemFiles.safeName("f:Music/a b.mp3"))
        #expect(StemFiles.songId(fileName: names[2]) == StemFiles.safeName("f:Music/a b.mp3"))
        #expect(StemFiles.songId(fileName: names[3]) == StemFiles.safeName("f:Music/a b.mp3"))
        #expect(StemFiles.safeName("a:b") != StemFiles.safeName("a/b"))
    }

    @Test func wavHeaderIsCanonical() {
        let h = StereoWav.header(frames: 10, sampleRate: 44_100)
        #expect(h.count == 44)
        #expect(Array(h[0..<4]) == Array("RIFF".utf8))
        #expect(h[40] == 40 && h[4] == 76)
        let pcm = StereoWav.pcm16(left: [1, -2, 0.5], right: [0, 0, -0.5], range: 0..<3)
        #expect(pcm == [0xFF, 0x7F, 0, 0, 0x01, 0x80, 0, 0, 0xFF, 0x3F, 0x01, 0xC0])
    }

    // MARK: Pipeline

    @Test func chunkingOverlapsByAQuarter() {
        #expect(MdxSeparation.chunks(totalFrames: 100).map(\.start) == [0])
        let c = MdxSeparation.chunks(totalFrames: 600)
        #expect(c.map(\.start) == [0, 192, 384])
        #expect(c.last!.length == 216)
        #expect(MdxSeparation.triangularWeight(0, chunkLength: 1) == 1)
        #expect(MdxSeparation.triangularWeight(0, chunkLength: 256) == Float(0.05))
        #expect(abs(MdxSeparation.triangularWeight(128, chunkLength: 256) - (1 - 0.5 / 128.5)) < 1e-6)
    }

    @Test func reflectPadMatchesNumpy() {
        #expect(MdxSeparation.reflectPad([1, 2, 3, 4], pad: 2) == [3, 2, 1, 2, 3, 4, 3, 2])
    }

    static func tone(_ hz: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let n = Int(seconds * Double(MdxSeparation.sampleRate))
        return (0..<n).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / Double(MdxSeparation.sampleRate))) }
    }

    @Test func silentVocalModelReconstructsTheMix() throws {
        // 8 s: two overlapping chunks.
        let left = Self.tone(440, seconds: 8)
        let right = Self.tone(660, seconds: 8, amplitude: 0.3)
        var fft = try Fft.Workspace(size: MdxSeparation.fftSize)
        var reports: [Int] = []
        let out = try MdxSeparation.instrumental(left: left, right: right, transform: &fft,
                                                 model: { _, output in
                                                     for i in output.indices { output[i] = 0 }
                                                 }, progress: { done, _ in reports.append(done) })
        #expect(reports.count == 2)
        var maxError: Float = 0
        for i in stride(from: 0, to: left.count, by: 7) {
            maxError = max(maxError, abs(out.left[i] - left[i]), abs(out.right[i] - right[i]))
        }
        #expect(maxError < 1e-3)
    }

    @Test func fullVocalModelKeepsOnlyTheSubBass() throws {
        let bass = Self.tone(40, seconds: 3)
        let lead = Self.tone(1000, seconds: 3)
        let mix = zip(bass, lead).map { $0 + $1 }
        var fft = try Fft.Workspace(size: MdxSeparation.fftSize)
        let out = try MdxSeparation.instrumental(left: mix, right: mix, transform: &fft, model: { input, output in
            for i in output.indices { output[i] = input[i] }
        })
        // Away from the edges the 1 kHz lead is gone and the 40 Hz bass stays.
        let core = 20_000..<(mix.count - 20_000)
        var residual: Float = 0
        var bassEnergy: Float = 0
        for i in core {
            residual += (out.left[i] - bass[i]) * (out.left[i] - bass[i])
            bassEnergy += bass[i] * bass[i]
        }
        #expect(residual / bassEnergy < 0.01)
        let gain = try MdxSeparation.instrumentalGain(mixLeft: mix, mixRight: mix, left: out.left, right: out.right)
        #expect(gain >= 0.5 && gain <= 2)
    }

    @Test func cancellationStopsBetweenChunks() throws {
        struct Stop: Error {}
        let audio = Self.tone(440, seconds: 8)
        var fft = try Fft.Workspace(size: MdxSeparation.fftSize)
        #expect(throws: Stop.self) {
            _ = try MdxSeparation.instrumental(left: audio, right: audio, transform: &fft, model: { _, _ in },
                                               progress: { _, _ in throw Stop() })
        }
    }
}
