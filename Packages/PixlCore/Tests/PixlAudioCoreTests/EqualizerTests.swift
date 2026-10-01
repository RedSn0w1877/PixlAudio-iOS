import Foundation
import Testing
import PixlModel
@testable import PixlAudioCore

/// Swift tests for the EqualizerManager port and the iOS chain design (no Android unit test exists).
@Suite("Equalizer")
struct EqualizerTests {
    @Test func bandLevelEditsSwitchToCustom() {
        var s = EqualizerSettings()
        s.applyPreset(.rock)
        #expect(s.presetName == "rock" && s.bandLevels == EqualizerPreset.rock.bandLevels)
        s.setBandLevel(3, 40)
        #expect(s.bandLevels[3] == 15 && s.presetName == "custom")
        s.setBandLevel(0, -99)
        #expect(s.bandLevels[0] == -15)
        let before = s
        s.setBandLevel(10, 3)
        s.setBandLevel(-1, 3)
        #expect(s == before)
    }

    @Test func effectTogglesAndStrengths() {
        var s = EqualizerSettings()
        #expect(!s.hasAnyEnabledEffects)
        s.setBassBoostStrength(1500)
        #expect(s.bassBoostStrength == 1000)
        s.setVirtualizerStrength(-5)
        #expect(s.virtualizerStrength == 0)
        s.setLoudnessEnhancerStrength(2000)
        #expect(s.loudnessEnhancerStrength == 1000)
        s.setLoudnessEnhancerEnabled(true)
        #expect(s.hasAnyEnabledEffects)
        s.isBassBoostSupported = false
        s.setBassBoostEnabled(true)
        #expect(!s.bassBoostEnabled)
        s.setBassBoostStrength(10)
        #expect(s.bassBoostStrength == 1000)
        s.isVirtualizerSupported = false
        s.setVirtualizerEnabled(true)
        #expect(!s.virtualizerEnabled)
    }

    @Test func restoreStatePicksThePreset() {
        var s = EqualizerSettings()
        s.restore(enabled: true, presetName: "custom", customBands: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], bassBoostEnabled: true,
                  bassBoostStrength: 300, virtualizerEnabled: false, virtualizerStrength: 0, loudnessEnabled: true,
                  loudnessStrength: 5000)
        #expect(s.presetName == "custom" && s.bandLevels == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(s.loudnessEnhancerStrength == 1000 && s.isEnabled && s.bassBoostStrength == 300)
        s.restore(enabled: false, presetName: "jazz", customBands: [], bassBoostEnabled: false, bassBoostStrength: 0,
                  virtualizerEnabled: false, virtualizerStrength: 0, loudnessEnabled: false, loudnessStrength: 0)
        #expect(s.presetName == "jazz" && s.bandLevels == EqualizerPreset.jazz.bandLevels)
        s.restore(enabled: false, presetName: "nope", customBands: [], bassBoostEnabled: false, bassBoostStrength: 0,
                  virtualizerEnabled: false, virtualizerStrength: 0, loudnessEnabled: false, loudnessStrength: 0)
        #expect(s.presetName == "flat")
        #expect(!s.hasAnyEnabledEffects)
    }

    @Test func deviceBandMappingAveragesLikeAndroid() {
        let rock = EqualizerPreset.rock.bandLevels // [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]
        #expect(EqualizerDeviceMapping.deviceBandLevels(rock, deviceBandCount: 10) == rock)
        #expect(EqualizerDeviceMapping.deviceBandLevels(rock, deviceBandCount: 12) == rock)
        #expect(EqualizerDeviceMapping.deviceBandLevels(rock, deviceBandCount: 5) == [4, 2, -1, 2, 4])
        // ratio 3.33: bands 0..<3, 3..<6, 6..<10; Kotlin integer division truncates toward zero.
        #expect(EqualizerDeviceMapping.deviceBandLevels(rock, deviceBandCount: 3) == [4, 0, 3])
        #expect(EqualizerDeviceMapping.deviceBandLevels([-1, -2, 0, 0, 0, 0, 0, 0, 0, 0], deviceBandCount: 5)[0] == -1)
        #expect(EqualizerDeviceMapping.deviceBandLevels([-1, 0, 0, 0, 0, 0, 0, 0, 0, 0], deviceBandCount: 5)[0] == 0)
        #expect(EqualizerDeviceMapping.deviceBandLevels(rock, deviceBandCount: 0) == [])
    }

    @Test func millibelMapping() {
        #expect(EqualizerDeviceMapping.millibels(level: -15) == -1500)
        #expect(EqualizerDeviceMapping.millibels(level: 0) == 0)
        #expect(EqualizerDeviceMapping.millibels(level: 15) == 1500)
        #expect(EqualizerDeviceMapping.millibels(level: 7) == 700)
        #expect(EqualizerDeviceMapping.millibels(level: 1, minMillibels: -1200, maxMillibels: 1200) == 80)
        #expect(EqualizerDeviceMapping.millibels(level: -14, minMillibels: -1200, maxMillibels: 1200) == -1120)
        #expect(EqualizerDeviceMapping.gainDb(level: -4) == -4)
    }

    @Test func chainDesign() {
        var s = EqualizerSettings()
        #expect(EqualizerDesigner.design(s, sampleRate: 48_000).isBypass)
        s.applyPreset(.rock)
        #expect(EqualizerDesigner.design(s, sampleRate: 48_000).isBypass) // EQ itself is off
        s.setEnabled(true)
        let p = EqualizerDesigner.design(s, sampleRate: 48_000)
        #expect(p.sections.count == EqualizerChainParameters.sectionCount)
        #expect(!p.sections[0].isIdentity && p.sections[10].isIdentity && p.needsLimiter)
        #expect(abs(p.sections[0].magnitudeDb(atFrequency: 31, sampleRate: 48_000) - 5) < 1e-9)
        s.setBassBoostEnabled(true)
        s.setBassBoostStrength(1000)
        #expect(EqualizerDesigner.bassBoostGainDb(s) == 15)
        s.setBassBoostStrength(500)
        #expect(EqualizerDesigner.bassBoostGainDb(s) == 7)
        s.setBassBoostStrength(66)
        #expect(EqualizerDesigner.bassBoostGainDb(s) == 0)
        s.setLoudnessEnhancerEnabled(true)
        s.setLoudnessEnhancerStrength(600)
        let loud = EqualizerDesigner.design(s, sampleRate: 44_100)
        #expect(abs(Double(loud.preGain) - Foundation.pow(10, 6.0 / 20)) < 1e-6)
        s.setVirtualizerEnabled(true)
        s.setVirtualizerStrength(1000)
        #expect(EqualizerDesigner.design(s, sampleRate: 44_100).stereoWidth.width == StereoWidth.maxWidth)
        for section in EqualizerDesigner.design(s, sampleRate: 44_100).sections { #expect(section.isStable) }
    }

    @Test func responseCurveForTheUI() {
        var s = EqualizerSettings()
        #expect(EqualizerResponse.curve(s, points: 64).allSatisfy { $0 == 0 })
        s.setEnabled(true)
        s.applyPreset(.bassBoost) // [7, 9, 6, 3, 0, …]
        let curve = EqualizerResponse.curve(s, points: 128)
        #expect(curve.count == 128)
        #expect(curve[0] > 3)                 // 20 Hz: lifted
        #expect(curve.max()! > 9)             // the 31/62 Hz bands
        #expect(abs(curve[127]) < 0.5)        // 20 kHz: flat
        #expect(curve.max()! < 25)
        var frequencies = [Double](repeating: 0, count: 31)
        frequencies.withUnsafeMutableBufferPointer { EqualizerResponse.logFrequencies(into: $0) }
        #expect(abs(frequencies[0] - 20) < 1e-9 && abs(frequencies[30] - 20_000) < 1e-6)
        #expect(abs(frequencies[15] - (20.0 * 20_000).squareRoot()) < 1e-6)
        let p = EqualizerDesigner.design(s, sampleRate: 48_000)
        let at62 = EqualizerResponse.magnitudeDb(atFrequency: 62, sections: p.sections, sampleRate: 48_000)
        #expect(at62 > 9) // the 62 Hz band plus its neighbours' skirts
    }

    @Test func stereoWidth() {
        #expect(StereoWidth(virtualizerStrength: 0).width == 1)
        #expect(abs(StereoWidth(virtualizerStrength: 500).width - 1.4) < 1e-6)
        #expect(StereoWidth(width: .nan).width == 1)
        var mono: [Float] = [0.3, 0.3, -0.2, -0.2]
        mono.withUnsafeMutableBufferPointer { StereoWidth(width: 1.8).process($0.baseAddress!, frames: 2) }
        #expect(mono == [0.3, 0.3, -0.2, -0.2])
        var wide: [Float] = [0.5, 0.1]
        wide.withUnsafeMutableBufferPointer { StereoWidth(width: 0).process($0.baseAddress!, frames: 1) }
        #expect(abs(wide[0] - 0.3) < 1e-7 && abs(wide[1] - 0.3) < 1e-7)
    }

    @Test func processorBypassesAndBoundsItsOutput() {
        var processor = EqualizerProcessor()
        var samples: [Float] = (0..<512).map { Float(sin(Double($0) * 0.05)) * 0.9 }
        let original = samples
        samples.withUnsafeMutableBufferPointer { processor.process($0.baseAddress!, frames: 256) }
        #expect(samples == original)
        var s = EqualizerSettings()
        s.setEnabled(true)
        for band in 0..<10 { s.setBandLevel(band, 15) }
        s.setLoudnessEnhancerEnabled(true)
        s.setLoudnessEnhancerStrength(1000)
        processor.update(EqualizerDesigner.design(s, sampleRate: 48_000))
        for _ in 0..<4 {
            samples.withUnsafeMutableBufferPointer { processor.process($0.baseAddress!, frames: 256) }
            #expect(samples.allSatisfy { abs($0) <= 1 })
        }
        processor.reset()
    }
}
