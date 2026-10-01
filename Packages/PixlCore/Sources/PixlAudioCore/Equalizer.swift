// The 10-band equalizer, bass boost, virtualizer and loudness enhancer, ported from
// data/equalizer/EqualizerManager.kt. Android drives the platform `audiofx` effects; iOS builds the same controls
// from RBJ biquads (this file designs them) and runs them in the processing tap.
//
// Mapping of Android's effects:
// - Equalizer: 10 bands at 31 Hz…16 kHz, levels −15…+15 mapped onto the effect's millibel range
//   (−1500…+1500 mB on AOSP: one level = 1 dB) → peaking biquads, one octave wide (Q = √2).
// - BassBoost (strength 0…1000): AOSP's LVM bundle sets a bass effect level of (15·strength)/1000 dB centred on 90 Hz
//   → a low shelf at 90 Hz with that gain.
// - Virtualizer (strength 0…1000): AOSP's "concert sound" widening → mid/side stereo width (`StereoWidth`).
// - LoudnessEnhancer (target gain 0…1000 mB) → a make-up gain followed by `SoftLimiter`.

import Foundation
import PixlFoundation
import PixlModel

/// Equalizer constants (`EqualizerManager` companion and `EqualizerPreset`).
public enum EqualizerBands {
    /// `NUM_BANDS`.
    public static let count = 10
    /// `MIN_LEVEL` / `MAX_LEVEL`.
    public static let minLevel = -15
    public static let maxLevel = 15
    /// Centre frequencies (Hz) used when no device equalizer reports its own (`getBandFrequencies` fallback).
    public static let frequenciesHz: [Int] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    /// Band labels (`EqualizerPreset.BAND_FREQUENCIES`).
    public static let labels: [String] = EqualizerPreset.bandFrequencies
    /// One octave per band.
    public static let defaultQ = 2.0.squareRoot()
    /// AOSP's equalizer band-level range in millibels.
    public static let defaultMinMillibels: Int16 = -1500
    public static let defaultMaxMillibels: Int16 = 1500
    /// Bass boost and virtualizer strength range.
    public static let maxStrength = 1000
    /// `MAX_LOUDNESS_GAIN_MB` (10 dB).
    public static let maxLoudnessGainMb = 1000
    /// AOSP bass-boost centre frequency.
    public static let bassBoostFrequencyHz = 90.0
    /// AOSP bass-boost maximum level (dB).
    public static let bassBoostMaxDb = 15
}

/// The equalizer's user state (`EqualizerManager`'s StateFlows) and its mutations.
public struct EqualizerSettings: Sendable, Hashable, Codable {
    public var isEnabled: Bool = false
    /// `currentPresetName` ("flat", …, or "custom" after a manual band change).
    public var presetName: String = "flat"
    /// Levels −15…15, one per band.
    public var bandLevels: [Int] = Array(repeating: 0, count: EqualizerBands.count)
    public var bassBoostEnabled: Bool = false
    public var bassBoostStrength: Int = 0
    public var virtualizerEnabled: Bool = false
    public var virtualizerStrength: Int = 0
    public var loudnessEnhancerEnabled: Bool = false
    public var loudnessEnhancerStrength: Int = 0
    /// Effect support (Android probes the device; on iOS everything is built in). Unsupported effects stay off.
    public var isBassBoostSupported: Bool = true
    public var isVirtualizerSupported: Bool = true

    public init() {}

    /// `hasAnyEnabledEffects`.
    public var hasAnyEnabledEffects: Bool {
        isEnabled || bassBoostEnabled || virtualizerEnabled || loudnessEnhancerEnabled
    }

    public mutating func setEnabled(_ enabled: Bool) { isEnabled = enabled }

    /// `setBandLevel`: ignored outside 0..<10; the level is clamped; the preset becomes "custom".
    public mutating func setBandLevel(_ bandIndex: Int, _ level: Int) {
        guard bandIndex >= 0 && bandIndex < EqualizerBands.count else { return }
        if bandLevels.count < EqualizerBands.count {
            bandLevels += Array(repeating: 0, count: EqualizerBands.count - bandLevels.count)
        }
        bandLevels[bandIndex] = level.coerced(in: EqualizerBands.minLevel, EqualizerBands.maxLevel)
        presetName = "custom"
    }

    /// `applyPreset` (the levels are taken as they are, like Android).
    public mutating func applyPreset(_ preset: EqualizerPreset) {
        presetName = preset.name
        bandLevels = preset.bandLevels
    }

    /// `setBassBoostEnabled`: forced off when unsupported.
    public mutating func setBassBoostEnabled(_ enabled: Bool) {
        bassBoostEnabled = isBassBoostSupported ? enabled : false
    }

    /// `setBassBoostStrength`: 0…1000; ignored when unsupported.
    public mutating func setBassBoostStrength(_ strength: Int) {
        guard isBassBoostSupported else { return }
        bassBoostStrength = strength.coerced(in: 0, EqualizerBands.maxStrength)
    }

    public mutating func setVirtualizerEnabled(_ enabled: Bool) {
        virtualizerEnabled = isVirtualizerSupported ? enabled : false
    }

    public mutating func setVirtualizerStrength(_ strength: Int) {
        guard isVirtualizerSupported else { return }
        virtualizerStrength = strength.coerced(in: 0, EqualizerBands.maxStrength)
    }

    public mutating func setLoudnessEnhancerEnabled(_ enabled: Bool) { loudnessEnhancerEnabled = enabled }

    /// `setLoudnessEnhancerStrength`: target gain 0…1000 mB.
    public mutating func setLoudnessEnhancerStrength(_ strength: Int) {
        loudnessEnhancerStrength = strength.coerced(in: 0, EqualizerBands.maxLoudnessGainMb)
    }

    /// `restoreState`: a "custom" preset name takes `customBands`, any other name the built-in preset (unknown → flat).
    /// Only the loudness strength is clamped here, as on Android.
    public mutating func restore(enabled: Bool, presetName: String, customBands: [Int], bassBoostEnabled: Bool,
                                 bassBoostStrength: Int, virtualizerEnabled: Bool, virtualizerStrength: Int,
                                 loudnessEnabled: Bool, loudnessStrength: Int) {
        isEnabled = enabled
        self.bassBoostEnabled = bassBoostEnabled
        self.bassBoostStrength = bassBoostStrength
        self.virtualizerEnabled = virtualizerEnabled
        self.virtualizerStrength = virtualizerStrength
        loudnessEnhancerEnabled = loudnessEnabled
        loudnessEnhancerStrength = loudnessStrength.coerced(in: 0, EqualizerBands.maxLoudnessGainMb)
        let preset = presetName == "custom" ? EqualizerPreset.custom(bandLevels: customBands)
                                            : EqualizerPreset.fromName(presetName)
        self.presetName = preset.name
        bandLevels = preset.bandLevels
    }
}

/// How Android maps the UI's 10 levels onto a device equalizer (`applyBandLevels`, `applyBandLevelDirect`).
public enum EqualizerDeviceMapping {
    /// The level for each device band: direct when the device has at least as many bands as the UI, otherwise the
    /// integer average of the UI bands each device band covers.
    public static func deviceBandLevels(_ levels: [Int], deviceBandCount: Int) -> [Int] {
        guard deviceBandCount > 0 else { return [] }
        let uiCount = levels.count
        if deviceBandCount >= uiCount { return levels }
        let ratio = Float(uiCount) / Float(deviceBandCount)
        var result: [Int] = []
        result.reserveCapacity(deviceBandCount)
        for band in 0..<deviceBandCount {
            let start = Int(KotlinMath.toInt(Float(band) * ratio))
            let end = min(Int(KotlinMath.toInt(Float(band + 1) * ratio)), uiCount)
            var sum = 0
            var count = 0
            if start < end {
                for ui in start..<end where ui < levels.count {
                    sum += levels[ui]
                    count += 1
                }
            }
            result.append(count > 0 ? sum / count : 0)
        }
        return result
    }

    /// A level −15…15 in the device's millibel range (`minEqLevel + (level + 15) * range / 30`, Kotlin integer
    /// maths, truncated to Short).
    public static func millibels(level: Int, minMillibels: Int16 = EqualizerBands.defaultMinMillibels,
                                 maxMillibels: Int16 = EqualizerBands.defaultMaxMillibels) -> Int16 {
        let range = Int32(maxMillibels) - Int32(minMillibels)
        let value = Int32(minMillibels) &+ (Int32(truncatingIfNeeded: level) &+ 15) &* range / 30
        return Int16(truncatingIfNeeded: value)
    }

    /// The gain in dB a band level produces with AOSP's default range (one level = 1 dB).
    public static func gainDb(level: Int) -> Double { Double(millibels(level: level)) / 100 }
}

/// Mid/side stereo width for the virtualizer. `width` 1 is unchanged, 0 is mono, 2 doubles the side signal; the
/// output is scaled so a centred (mono) signal keeps its level.
public struct StereoWidth: Sendable, Hashable {
    /// Width at full virtualizer strength.
    public static let maxWidth: Float = 1.8

    public var width: Float

    public init(width: Float) { self.width = width.isFinite ? max(width, 0) : 1 }

    /// The width for a virtualizer strength 0…1000 (0 → 1, 1000 → `maxWidth`).
    public init(virtualizerStrength strength: Int) {
        let s = Float(strength.coerced(in: 0, EqualizerBands.maxStrength)) / Float(EqualizerBands.maxStrength)
        self.init(width: 1 + (Self.maxWidth - 1) * s)
    }

    /// Processes interleaved stereo in place (mid = (L+R)/2, side = (L−R)/2·width). No allocation.
    @inlinable
    public func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        if width == 1 || frames <= 0 { return }
        var i = 0
        for _ in 0..<frames {
            let l = samples[i], r = samples[i + 1]
            let mid = (l + r) * 0.5
            let side = (l - r) * 0.5 * width
            samples[i] = mid + side
            samples[i + 1] = mid - side
            i += 2
        }
    }
}

/// Everything the tap needs to run the equalizer chain, designed off the audio thread.
public struct EqualizerChainParameters: Sendable, Hashable {
    /// Band filters first (10 peaking), then the bass-boost shelf. Identity sections are skipped by the cascade.
    public var sections: [BiquadCoefficients]
    /// Linear pre-gain (loudness enhancer make-up gain; 1 when off).
    public var preGain: Float
    /// Stereo width (1 when the virtualizer is off).
    public var stereoWidth: StereoWidth
    /// Whether `SoftLimiter` must run after the chain (any boost is active).
    public var needsLimiter: Bool

    /// Number of biquad sections (`EqualizerBands.count` + bass boost).
    public static let sectionCount = EqualizerBands.count + 1

    /// A chain that leaves audio untouched.
    public static let bypass = EqualizerChainParameters(
        sections: Array(repeating: .identity, count: sectionCount), preGain: 1,
        stereoWidth: StereoWidth(width: 1), needsLimiter: false)

    public init(sections: [BiquadCoefficients], preGain: Float, stereoWidth: StereoWidth, needsLimiter: Bool) {
        self.sections = sections
        self.preGain = preGain
        self.stereoWidth = stereoWidth
        self.needsLimiter = needsLimiter
    }

    /// True when processing would not change the signal.
    public var isBypass: Bool {
        preGain == 1 && stereoWidth.width == 1 && sections.allSatisfy(\.isIdentity)
    }
}

/// Designs the iOS equalizer chain from `EqualizerSettings`.
public enum EqualizerDesigner {
    /// Band gains in dB (0 for every band when the equalizer is off).
    public static func bandGainsDb(_ settings: EqualizerSettings) -> [Double] {
        (0..<EqualizerBands.count).map { i in
            guard settings.isEnabled, i < settings.bandLevels.count else { return 0 }
            return EqualizerDeviceMapping.gainDb(level: settings.bandLevels[i].coerced(in: EqualizerBands.minLevel,
                                                                                         EqualizerBands.maxLevel))
        }
    }

    /// Bass-boost shelf gain in dB: AOSP `(15 * strength) / 1000` (integer dB), 0 when off.
    public static func bassBoostGainDb(_ settings: EqualizerSettings) -> Double {
        guard settings.bassBoostEnabled && settings.isBassBoostSupported else { return 0 }
        let strength = settings.bassBoostStrength.coerced(in: 0, EqualizerBands.maxStrength)
        return Double(EqualizerBands.bassBoostMaxDb * strength / EqualizerBands.maxStrength)
    }

    /// Loudness make-up gain in dB (target gain in mB / 100), 0 when off.
    public static func loudnessGainDb(_ settings: EqualizerSettings) -> Double {
        guard settings.loudnessEnhancerEnabled else { return 0 }
        return Double(settings.loudnessEnhancerStrength.coerced(in: 0, EqualizerBands.maxLoudnessGainMb)) / 100
    }

    /// The full chain for `sampleRate`.
    public static func design(_ settings: EqualizerSettings, sampleRate: Double,
                              q: Double = EqualizerBands.defaultQ) -> EqualizerChainParameters {
        var sections: [BiquadCoefficients] = []
        sections.reserveCapacity(EqualizerChainParameters.sectionCount)
        let gains = bandGainsDb(settings)
        for (i, gain) in gains.enumerated() {
            sections.append(BiquadDesigner.design(.peaking, frequency: Double(EqualizerBands.frequenciesHz[i]),
                                                  sampleRate: sampleRate, q: q, gainDb: gain))
        }
        let bass = bassBoostGainDb(settings)
        sections.append(BiquadDesigner.design(.lowShelf, frequency: EqualizerBands.bassBoostFrequencyHz,
                                              sampleRate: sampleRate, q: BiquadDesigner.butterworthQ, gainDb: bass))
        let loudness = loudnessGainDb(settings)
        let width = settings.virtualizerEnabled && settings.isVirtualizerSupported
            ? StereoWidth(virtualizerStrength: settings.virtualizerStrength) : StereoWidth(width: 1)
        let boosts = loudness > 0 || bass > 0 || gains.contains { $0 > 0 } || width.width > 1
        return EqualizerChainParameters(sections: sections, preGain: Float(Foundation.pow(10, loudness / 20)),
                                        stereoWidth: width, needsLimiter: boosts)
    }
}

/// The equalizer's frequency response, for the curve drawn in the UI.
public enum EqualizerResponse {
    /// Total response (dB) of `sections` at `frequency` Hz, plus `preGain`.
    public static func magnitudeDb(atFrequency frequency: Double, sections: [BiquadCoefficients],
                                   preGain: Float = 1, sampleRate: Double) -> Double {
        var db = 20 * log10(Double(preGain))
        for s in sections where !s.isIdentity {
            db += s.magnitudeDb(atFrequency: frequency, sampleRate: sampleRate)
        }
        return db
    }

    /// `count` log-spaced frequencies from `minHz` to `maxHz` (inclusive), written into `frequencies`.
    public static func logFrequencies(into frequencies: UnsafeMutableBufferPointer<Double>,
                                      minHz: Double = 20, maxHz: Double = 20_000) {
        let n = frequencies.count
        guard n > 0 else { return }
        if n == 1 { frequencies[0] = minHz; return }
        let lo = log(minHz), hi = log(maxHz)
        for i in 0..<n { frequencies[i] = exp(lo + (hi - lo) * Double(i) / Double(n - 1)) }
    }

    /// Fills `curve` with the response (dB) at `curve.count` log-spaced frequencies between `minHz` and `maxHz` —
    /// the UI curve. Pass the parameters from `EqualizerDesigner.design`.
    public static func curve(into curve: UnsafeMutableBufferPointer<Float>, parameters: EqualizerChainParameters,
                             sampleRate: Double, minHz: Double = 20, maxHz: Double = 20_000,
                             includePreGain: Bool = false) {
        let n = curve.count
        guard n > 0 else { return }
        let lo = log(minHz), hi = log(maxHz)
        for i in 0..<n {
            let f = n == 1 ? minHz : exp(lo + (hi - lo) * Double(i) / Double(n - 1))
            curve[i] = Float(magnitudeDb(atFrequency: f, sections: parameters.sections,
                                         preGain: includePreGain ? parameters.preGain : 1, sampleRate: sampleRate))
        }
    }

    /// Convenience: the response curve as an array.
    public static func curve(_ settings: EqualizerSettings, points: Int, sampleRate: Double = 48_000,
                             minHz: Double = 20, maxHz: Double = 20_000) -> [Float] {
        let parameters = EqualizerDesigner.design(settings, sampleRate: sampleRate)
        var result = [Float](repeating: 0, count: max(points, 0))
        result.withUnsafeMutableBufferPointer {
            curve(into: $0, parameters: parameters, sampleRate: sampleRate, minHz: minHz, maxHz: maxHz)
        }
        return result
    }
}

/// A reference implementation of the tap's equalizer chain for interleaved stereo (pre-gain → band biquads → bass
/// shelf → width → limiter). The app may run the same parameters through vDSP instead; this one is allocation-free
/// after `init` and is what the tests and the fallback path use.
public struct EqualizerProcessor: Sendable {
    public private(set) var parameters: EqualizerChainParameters
    private var cascade: BiquadCascade
    private var currentPreGain: Float

    public init(parameters: EqualizerChainParameters = .bypass) {
        self.parameters = parameters
        cascade = BiquadCascade(sectionCount: EqualizerChainParameters.sectionCount, channelCount: 2)
        currentPreGain = parameters.preGain
        load(parameters)
    }

    private mutating func load(_ p: EqualizerChainParameters) {
        for i in 0..<EqualizerChainParameters.sectionCount {
            cascade.setCoefficients(i < p.sections.count ? p.sections[i] : .identity, at: i)
        }
    }

    /// Swaps in new parameters (keeps filter state; the pre-gain ramps over the next buffer).
    public mutating func update(_ p: EqualizerChainParameters) {
        parameters = p
        load(p)
    }

    /// Clears filter memory.
    public mutating func reset() { cascade.reset() }

    /// Processes interleaved stereo in place.
    public mutating func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        GainRamp.apply(to: samples, frames: frames, channels: 2, from: currentPreGain, to: parameters.preGain)
        currentPreGain = parameters.preGain
        cascade.process(samples, frames: frames)
        parameters.stereoWidth.process(samples, frames: frames)
        if parameters.needsLimiter { SoftLimiter.process(samples, count: frames * 2) }
    }
}
