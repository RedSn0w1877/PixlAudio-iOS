import Accelerate
import AVFoundation
import PixlAudioCore
import PixlModel
import Synchronization
import XCTest
@testable import PixlAudio

/// The processing-tap chain measured offline (generated sines and noise through `AVAssetReaderAudioMixOutput` with the
/// tap's audio mix): bypass transparency, EQ / bass-boost response against PixlAudioCore's design, ReplayGain, the
/// crossfade gain curve through the tap's own meter log, mid/side and the virtualizer.
final class ProcessingTapTests: XCTestCase {
    private let rate = Double(TestAudio.sampleRate)

    private func render(_ url: URL, effects: AudioEffectsParameters = AudioEffectsParameters(),
                        item: TapItemParameters = TapItemParameters()) async throws -> [Float] {
        let samples = try await TapOfflineRenderer.render(url, effects: effects, item: item)
        XCTAssertTrue(item.hasProcessed.load(ordering: .relaxed), "the tap's process callback never ran")
        return samples
    }

    /// Steady-state RMS ratio output / input on the left channel, skipping the first `skip` seconds.
    private func gain(_ output: [Float], input: [Float], skip: Double = 0.3) -> Double {
        let frames = min(output.count, input.count) / 2
        let range = Int(skip * rate)..<frames
        return TapOfflineRenderer.rms(output, channel: 0, frames: range)
            / TapOfflineRenderer.rms(input, channel: 0, frames: range)
    }

    func testBypassIsTransparent() async throws {
        let url = try TestAudio.sine(frequency: 1000, seconds: 1)
        let reference = try await TapOfflineRenderer.render(url, effects: AudioEffectsParameters(),
                                                            item: TapItemParameters())
        XCTAssertEqual(reference.count / 2, TestAudio.sampleRate, accuracy: 64, "whole file delivered")
        let rms = TapOfflineRenderer.rms(reference, channel: 0, frames: 0..<(reference.count / 2))
        XCTAssertEqual(rms, 0.5 / 2.0.squareRoot(), accuracy: 0.002)
    }

    /// The tap's vDSP usage on its own: one single-channel `vDSP_biquadm` setup per channel, run in place on
    /// interleaved stereo (stride 2), must match PixlAudioCore's reference cascade sample for sample.
    func testPerChannelBiquadmMatchesTheReferenceCascade() throws {
        var settings = EqualizerSettings()
        settings.setEnabled(true)
        settings.setBandLevel(2, 9)
        settings.setBandLevel(6, -7)
        settings.setBassBoostEnabled(true)
        settings.setBassBoostStrength(600)
        let design = EqualizerDesigner.design(settings, sampleRate: rate)
        let block = UnsafeMutablePointer<Double>.allocate(capacity: AudioEffectsParameters.blockSize)
        defer { block.deallocate() }
        AudioEffectsParameters.write(design, into: block)

        let frames = 2048
        var samples = [Float](repeating: 0, count: frames * 2)
        var state: UInt64 = 7
        for i in samples.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            samples[i] = Float(Double(state >> 11) / Double(1 << 53) * 0.2 - 0.1)
        }
        var reference = samples
        var cascade = BiquadCascade(sectionCount: AudioEffectsParameters.sectionCount, channelCount: 2)
        for (i, section) in design.sections.enumerated() { cascade.setCoefficients(section, at: i) }
        reference.withUnsafeMutableBufferPointer { cascade.process($0.baseAddress!, frames: frames) }

        let sections = vDSP_Length(AudioEffectsParameters.sectionCount)
        let setups = try (0..<2).map { _ in try XCTUnwrap(vDSP_biquadm_CreateSetup(block, sections, 1)) }
        defer { setups.forEach(vDSP_biquadm_DestroySetup) }
        samples.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            for c in 0..<2 {
                var input = UnsafePointer(base + c)
                var output = base + c
                withUnsafeMutablePointer(to: &input) { x in
                    withUnsafeMutablePointer(to: &output) { y in
                        vDSP_biquadm(setups[c], x, 2, y, 2, vDSP_Length(frames))
                    }
                }
            }
        }
        var worst: Float = 0
        for i in samples.indices { worst = max(worst, abs(samples[i] - reference[i])) }
        XCTAssertLessThan(worst, 1e-4, "vDSP_biquadm differs from the reference cascade")
    }

    func testEqualizerBoostMatchesDesignedResponse() async throws {
        var settings = EqualizerSettings()
        settings.setEnabled(true)
        settings.setBandLevel(5, 12)   // 1 kHz +12 dB
        settings.setBandLevel(8, -12)  // 8 kHz −12 dB
        let effects = AudioEffectsParameters()
        effects.setEqualizer(settings, sampleRate: rate)
        let designed = EqualizerDesigner.design(settings, sampleRate: rate)

        for frequency in [125.0, 1000.0, 8000.0] {
            let url = try TestAudio.sine(frequency: frequency, seconds: 1.5, amplitude: 0.05)
            let input = try await render(url)
            let output = try await render(url, effects: effects)
            let measuredDb = 20 * log10(gain(output, input: input))
            let expectedDb = EqualizerResponse.magnitudeDb(atFrequency: frequency, sections: designed.sections,
                                                           preGain: designed.preGain, sampleRate: rate)
            XCTAssertEqual(measuredDb, expectedDb, accuracy: 0.5, "\(frequency) Hz")
        }
    }

    func testEqualizerAtAnotherSampleRateIsRedesignedForTheTap() async throws {
        var settings = EqualizerSettings()
        settings.setEnabled(true)
        settings.setBandLevel(7, 9)   // 4 kHz +9 dB
        let effects = AudioEffectsParameters()
        effects.setEqualizer(settings, sampleRate: 48_000)   // published for 48 kHz, the file is 44.1 kHz
        let url = try TestAudio.sine(frequency: 4000, seconds: 1.5, amplitude: 0.05)
        let input = try await render(url)
        let output = try await render(url, effects: effects)
        let designed = EqualizerDesigner.design(settings, sampleRate: rate)
        let expectedDb = EqualizerResponse.magnitudeDb(atFrequency: 4000, sections: designed.sections, sampleRate: rate)
        XCTAssertEqual(20 * log10(gain(output, input: input)), expectedDb, accuracy: 0.5)
    }

    func testBassBoostShelf() async throws {
        var settings = EqualizerSettings()
        settings.setBassBoostEnabled(true)
        settings.setBassBoostStrength(1000)   // +15 dB shelf at 90 Hz
        let effects = AudioEffectsParameters()
        effects.setEqualizer(settings, sampleRate: rate)
        let url = try TestAudio.sine(frequency: 40, seconds: 2, amplitude: 0.03)
        let input = try await render(url)
        let output = try await render(url, effects: effects)
        let designed = EqualizerDesigner.design(settings, sampleRate: rate)
        let expectedDb = EqualizerResponse.magnitudeDb(atFrequency: 40, sections: designed.sections, sampleRate: rate)
        XCTAssertGreaterThan(expectedDb, 12)
        XCTAssertEqual(20 * log10(gain(output, input: input, skip: 0.5)), expectedDb, accuracy: 0.6)
    }

    func testReplayGainVolumeScalesTheSignal() async throws {
        let url = try TestAudio.sine(frequency: 440, seconds: 1)
        let input = try await render(url)
        let item = TapItemParameters()
        item.replayGainVolume.store(ReplayGain.gainDbToVolume(-6))
        let output = try await render(url, item: item)
        XCTAssertEqual(20 * log10(gain(output, input: input, skip: 0.05)), -6, accuracy: 0.1)
    }

    func testReplayGainBoostIsCappedAtUnityLikeAndroid() async throws {
        let url = try TestAudio.sine(frequency: 440, seconds: 1, amplitude: 0.2)
        let input = try await render(url)
        let item = TapItemParameters()
        item.replayGainVolume.store(ReplayGain.gainDbToVolume(6))
        let output = try await render(url, item: item)
        XCTAssertEqual(gain(output, input: input, skip: 0.05), 1, accuracy: 0.005)
    }

    /// The crossfade curves measured through the tap's meter log: per buffer, rmsOut / rmsIn must equal the RMS of
    /// the gain ramp the tap applies across that buffer (linear between g(t₀) and g(t₁) of `CrossfadeRamp`).
    func testCrossfadeGainCurveMeasuredThroughTapMetering() async throws {
        let url = try TestAudio.sine(frequency: 500, seconds: 4)
        for (role, curve) in [(CrossfadeRamp.Role.outgoing, TransitionCurve.sCurve),
                              (.incoming, .exp), (.incoming, .log), (.outgoing, .linear)] {
            let ramp = CrossfadeRamp(role: role, curve: curve, startTime: 1, duration: 2, scale: 1)
            let item = TapItemParameters(logCapacity: 4096)
            item.ramp.publish(ramp)
            _ = try await render(url, item: item)
            let entries = try XCTUnwrap(item.log?.snapshot())
            XCTAssertGreaterThan(entries.count, 4)
            var checked = 0
            for entry in entries where entry.rmsIn > 0.01 && entry.frames > 64 {
                let g0 = Double(ramp.gain(at: entry.mediaTime))
                let g1 = Double(ramp.gain(at: entry.mediaTime + Double(entry.frames - 1) / rate))
                let expected = ((g0 * g0 + g0 * g1 + g1 * g1) / 3).squareRoot()
                let measured = Double(entry.rmsOut / entry.rmsIn)
                XCTAssertEqual(measured, expected, accuracy: 0.02,
                               "\(role) \(curve) at \(entry.mediaTime) s")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 4)
            // Before the fade: the incoming deck is silent, the outgoing one untouched; after it, the reverse.
            let first = try XCTUnwrap(entries.first { $0.mediaTime + Double($0.frames) / rate < 0.9 })
            let last = try XCTUnwrap(entries.last { $0.mediaTime > 3.1 })
            let before = Double(first.rmsOut / first.rmsIn), after = Double(last.rmsOut / last.rmsIn)
            XCTAssertEqual(before, role == .incoming ? 0 : 1, accuracy: 0.01)
            XCTAssertEqual(after, role == .incoming ? 1 : 0, accuracy: 0.01)
        }
    }

    func testMidSideAttenuationRemovesTheCentre() async throws {
        let centred = try TestAudio.sine(frequency: 300, seconds: 1)
        let effects = AudioEffectsParameters()
        effects.midSideAttenuation.store(1)
        let output = try await render(centred, effects: effects)
        XCTAssertLessThan(TapOfflineRenderer.rms(output, channel: 0, frames: 2000..<40_000), 0.001)

        // Hard-left content is side signal: it survives (at half level in each channel).
        let left = try TestAudio.sine(frequency: 300, seconds: 1, amplitude: 0.4, rightAmplitude: 0)
        let input = try await render(left)
        let kept = try await render(left, effects: effects)
        XCTAssertEqual(gain(kept, input: input, skip: 0.05), 0.5, accuracy: 0.01)
    }

    func testVirtualizerWidensTheSideSignal() async throws {
        var settings = EqualizerSettings()
        settings.setVirtualizerEnabled(true)
        settings.setVirtualizerStrength(1000)   // width 1.8
        let effects = AudioEffectsParameters()
        effects.setEqualizer(settings, sampleRate: rate)
        let url = try TestAudio.noise(seconds: 1, amplitude: 0.1)
        let input = try await render(url)
        let output = try await render(url, effects: effects)
        func sideRMS(_ s: [Float]) -> Double {
            var sum = 0.0
            let frames = s.count / 2
            for i in 2000..<frames { let d = Double(s[2 * i] - s[2 * i + 1]) / 2; sum += d * d }
            return (sum / Double(frames - 2000)).squareRoot()
        }
        XCTAssertEqual(sideRMS(output) / sideRMS(input), Double(StereoWidth.maxWidth), accuracy: 0.03)
    }
}
