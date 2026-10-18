import Foundation
import Testing
@testable import PixlAudioCore

/// The Music Haptics detector on synthetic signals: a click train (snare-like, broadband), 60 Hz bass bursts
/// (kick-like), silence and steady tones.
@Suite struct MusicHapticAnalyzerTests {
    /// Runs `signal` (mono) through a fresh analyzer in chunks of `chunk` frames.
    private func analyze(_ signal: [Float], sampleRate: Double = 44_100, chunk: Int = 512)
        -> (onsets: [HapticOnset], maxBass: Float, bassAt: [Float]) {
        var analyzer = MusicHapticAnalyzer(sampleRate: sampleRate)
        var onsets: [HapticOnset] = []
        var maxBass: Float = 0
        var bassAt: [Float] = []
        signal.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = min(chunk, buffer.count - offset)
                analyzer.process(left: buffer.baseAddress! + offset, right: nil, stride: 1, frames: n) { onsets.append($0) }
                maxBass = max(maxBass, analyzer.bassLevel)
                bassAt.append(analyzer.bassLevel)
                offset += n
            }
        }
        return (onsets, maxBass, bassAt)
    }

    private func clickTrain(seconds: Double, intervalSeconds: Double, sampleRate: Double = 44_100) -> [Float] {
        var signal = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var t = 0.25
        while t < seconds {
            signal[Int(t * sampleRate)] = 0.9
            t += intervalSeconds
        }
        return signal
    }

    private func bassBursts(seconds: Double, intervalSeconds: Double, burstSeconds: Double = 0.12,
                            sampleRate: Double = 44_100) -> [Float] {
        var signal = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var t = 0.25
        while t + burstSeconds < seconds {
            let start = Int(t * sampleRate), length = Int(burstSeconds * sampleRate)
            for i in 0..<length {
                let fade = min(Float(i) / Float(0.005 * sampleRate), 1) * min(Float(length - i) / Float(0.02 * sampleRate), 1)
                signal[start + i] = 0.8 * fade * Float(sin(2 * Double.pi * 60 * Double(i) / sampleRate))
            }
            t += intervalSeconds
        }
        return signal
    }

    @Test func aClickTrainGivesOneSnareLikeOnsetPerClick() {
        let result = analyze(clickTrain(seconds: 10, intervalSeconds: 0.5))
        // Clicks at 0.25, 0.75, ... 9.75 s: twenty of them.
        #expect(result.onsets.count >= 19 && result.onsets.count <= 21)
        #expect(result.onsets.allSatisfy { $0.kind == .snare })
        let times = result.onsets.map { Double($0.frame) / 44_100 }
        for (a, b) in zip(times, times.dropFirst()) { #expect(abs((b - a) - 0.5) < 0.03) }
        #expect(result.onsets.allSatisfy { $0.strength > 0 && $0.strength <= 1 })
    }

    @Test func bassBurstsGiveKicksAndARumble() {
        let result = analyze(bassBursts(seconds: 8, intervalSeconds: 0.5))
        #expect(result.onsets.count >= 14 && result.onsets.count <= 16)
        #expect(result.onsets.allSatisfy { $0.kind == .kick })
        #expect(result.maxBass > 0.6)
    }

    @Test func aClickTrainHasNoRumble() {
        let result = analyze(clickTrain(seconds: 6, intervalSeconds: 0.5))
        #expect(result.maxBass < 0.25)
    }

    @Test func silenceGivesNothing() {
        let result = analyze([Float](repeating: 0, count: 44_100 * 3))
        #expect(result.onsets.isEmpty)
        #expect(result.maxBass == 0)
    }

    @Test func aSteadyToneDoesNotKeepFiring() {
        let tone = (0..<(44_100 * 5)).map { Float(0.5 * sin(2 * Double.pi * 80 * Double($0) / 44_100)) }
        let result = analyze(tone)
        #expect(result.onsets.count <= 2)
        #expect(result.maxBass > 0.5)
    }

    @Test func chunkSizeDoesNotChangeTheResult() {
        let signal = bassBursts(seconds: 4, intervalSeconds: 0.5)
        let whole = analyze(signal, chunk: 4_096).onsets
        let odd = analyze(signal, chunk: 137).onsets
        #expect(whole == odd)
        #expect(!whole.isEmpty)
    }

    @Test func worksAt48kHz() {
        let kicks = analyze(bassBursts(seconds: 6, intervalSeconds: 0.5, sampleRate: 48_000), sampleRate: 48_000)
        #expect(kicks.onsets.count >= 10 && kicks.onsets.count <= 12)
        #expect(kicks.onsets.allSatisfy { $0.kind == .kick })
        let clicks = analyze(clickTrain(seconds: 6, intervalSeconds: 0.5, sampleRate: 48_000), sampleRate: 48_000)
        #expect(clicks.onsets.count >= 11 && clicks.onsets.count <= 13)
        #expect(clicks.onsets.allSatisfy { $0.kind == .snare })
    }

    @Test func theLevelDoesNotDependOnTheVolume() {
        let loud = analyze(bassBursts(seconds: 6, intervalSeconds: 0.5))
        let quiet = analyze(bassBursts(seconds: 6, intervalSeconds: 0.5).map { $0 * 0.1 })
        #expect(abs(loud.onsets.count - quiet.onsets.count) <= 1)
    }

    @Test func stereoAndInterleavedInputsAgree() {
        let mono = bassBursts(seconds: 3, intervalSeconds: 0.5)
        var interleaved = [Float](repeating: 0, count: mono.count * 2)
        for (i, v) in mono.enumerated() { interleaved[2 * i] = v; interleaved[2 * i + 1] = v }
        var analyzer = MusicHapticAnalyzer(sampleRate: 44_100)
        var onsets: [HapticOnset] = []
        interleaved.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            analyzer.process(left: base, right: base + 1, stride: 2, frames: mono.count) { onsets.append($0) }
        }
        #expect(onsets == analyze(mono).onsets)
    }

    @Test func resetForgetsEverything() {
        var analyzer = MusicHapticAnalyzer(sampleRate: 44_100)
        let burst = bassBursts(seconds: 1, intervalSeconds: 0.5)
        burst.withUnsafeBufferPointer { analyzer.process(left: $0.baseAddress!, right: nil, stride: 1, frames: $0.count) { _ in } }
        #expect(analyzer.bassLevel > 0)
        analyzer.reset()
        #expect(analyzer.bassLevel == 0)
        #expect(analyzer.energyLevel == 0)
    }
}
