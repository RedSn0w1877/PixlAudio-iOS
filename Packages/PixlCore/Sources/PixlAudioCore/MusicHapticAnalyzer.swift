// Music Haptics, the analysis half (iOS-first, owner request 2026-10-18; not Apple's Music Haptics — our own).
//
// A small real-time detector that listens to the audio the processing tap already sees and says "a kick landed",
// "a snare / hi-hat landed" and "how much bass is sounding". It is built for the audio render thread (AGENTS.md ›
// Performance rules): a value type of scalars only, so `process` never allocates, takes no lock and calls nothing
// that could. All state is preallocated in `init`.
//
// Method. The mono mix is split into three bands with two-pole low-pass filters (bass below about 160 Hz, mid up to
// about 2.5 kHz, high above). Each band's energy is smoothed per sample with a one-pole envelope (20 ms for bass, 6 ms
// for mid / high: a plain per-block RMS of a 60 Hz tone would swing with the phase it is cut at). Every 512 frames the
// three envelopes are read and divided by a slowly decaying peak of the broadband level, so a band's value is its
// share of the loudest recent sound (0…1) and a click, which is broadband, cannot pass for a kick. Onsets are the
// half-wave-rectified rise of a band's level since the previous block (spectral flux over three bands): the bass rise
// scores a kick, the mid + high rise scores a snare / hi-hat; the larger wins, one onset per refractory window
// (80 ms). The smoothed bass level feeds the continuous "rumble".

import Foundation

/// One detected onset.
public struct HapticOnset: Sendable, Equatable {
    public enum Kind: UInt8, Sendable, Equatable {
        /// Bass-band onset (kick drum, bass note).
        case kick
        /// Mid / high-band onset (snare, clap, hi-hat).
        case snare
    }

    public var kind: Kind
    /// 0…1, how hard the hit was relative to the recent peak.
    public var strength: Float
    /// Frames from the start of the analysis to the end of the block that held the onset.
    public var frame: Int64

    public init(kind: Kind, strength: Float, frame: Int64) {
        self.kind = kind
        self.strength = strength
        self.frame = frame
    }
}

public struct MusicHapticAnalyzer: Sendable {
    /// Analysis block: 512 frames (about 11.6 ms at 44.1 kHz).
    public static let blockFrames = 512

    // Tuning. Levels are shares of the broadband peak, so the thresholds are relative and volume-independent.
    static let bassCutoffHz = 160.0
    static let midCutoffHz = 2_500.0
    /// Three cascaded one-pole high-passes at this corner take the bass out of the mid band (one stage would let
    /// about a third of a 60 Hz tone through, which then scores as a snare).
    static let midHighPassHz = 200.0
    static let bassEnvelopeSeconds = 0.020
    static let highEnvelopeSeconds = 0.006
    /// The broadband peak follower's decay time constant.
    static let peakDecaySeconds = 3.0
    /// Below this broadband RMS the music counts as silence (no onsets, no rumble).
    static let silenceRms: Float = 0.002
    static let onsetThreshold: Float = 0.16
    static let refractorySeconds = 0.08
    /// Bass level smoothing per block: fast up, slower down.
    static let bassAttack: Float = 0.6
    static let bassRelease: Float = 0.18

    // Coefficients (set in init for the sample rate).
    private let lowCoefficient: Float
    private let midCoefficient: Float
    private let midHighPassCoefficient: Float
    private let lowEnvCoefficient: Float
    private let highEnvCoefficient: Float
    private let peakDecay: Float
    private let refractoryBlocks: Int

    // Filter state.
    private var low1: Float = 0
    private var low2: Float = 0
    private var mid1: Float = 0
    private var mid2: Float = 0
    private var highPass1: Float = 0
    private var highPass2: Float = 0
    private var highPass3: Float = 0

    // Smoothed band energies, updated per sample and read at the end of each block.
    private var blockFill = 0
    private var envLow: Float = 0
    private var envMid: Float = 0
    private var envHigh: Float = 0

    // Per-block state.
    private var peak: Float = 0
    private var previousLow: Float = 0
    private var previousMid: Float = 0
    private var previousHigh: Float = 0
    private var blocksSinceOnset = 1_000
    private var framesDone: Int64 = 0

    /// The bass band's share of the recent peak, smoothed (0…1). Read after `process`.
    public private(set) var bassLevel: Float = 0
    /// The broadband level's share of the recent peak (0…1): how loud this moment is.
    public private(set) var energyLevel: Float = 0

    public let sampleRate: Double

    public init(sampleRate: Double) {
        let rate = sampleRate > 8_000 ? sampleRate : 44_100
        self.sampleRate = rate
        func onePole(_ cutoff: Double) -> Float { Float(1 - exp(-2 * Double.pi * cutoff / rate)) }
        lowCoefficient = onePole(Self.bassCutoffHz)
        midCoefficient = onePole(Self.midCutoffHz)
        midHighPassCoefficient = onePole(Self.midHighPassHz)
        lowEnvCoefficient = Float(1 - exp(-1 / (Self.bassEnvelopeSeconds * rate)))
        highEnvCoefficient = Float(1 - exp(-1 / (Self.highEnvelopeSeconds * rate)))
        let blockSeconds = Double(Self.blockFrames) / rate
        peakDecay = Float(exp(-blockSeconds / Self.peakDecaySeconds))
        refractoryBlocks = max(Int((Self.refractorySeconds / blockSeconds).rounded()), 1)
    }

    /// Forgets everything heard (a seek, a pause, a new song).
    public mutating func reset() {
        low1 = 0; low2 = 0; mid1 = 0; mid2 = 0; highPass1 = 0; highPass2 = 0; highPass3 = 0
        blockFill = 0
        envLow = 0; envMid = 0; envHigh = 0
        peak = 0
        previousLow = 0; previousMid = 0; previousHigh = 0
        blocksSinceOnset = 1_000
        bassLevel = 0
        energyLevel = 0
    }

    /// Feeds `frames` frames. `left` / `right` point at the first sample of each channel and step by `stride`
    /// (interleaved stereo: both point into one buffer, stride 2; planar: stride 1). `right` nil = mono.
    /// `onset` is called once per detected onset, on the calling thread; it must be as real-time safe as the caller.
    public mutating func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, stride: Int, frames: Int,
                                 onset: (HapticOnset) -> Void) {
        var l = left
        var r = right
        for _ in 0..<frames {
            let sample: Float
            if let rp = r {
                sample = (l.pointee + rp.pointee) * 0.5
                r = rp + stride
            } else {
                sample = l.pointee
            }
            l += stride
            accumulate(sample)
            blockFill += 1
            if blockFill == Self.blockFrames {
                finishBlock(onset)
            }
        }
    }

    @inline(__always)
    private mutating func accumulate(_ x: Float) {
        // Bass: two cascaded one-pole low-pass filters. Mid: a band-pass (see below).
        low1 += lowCoefficient * (x - low1)
        low2 += lowCoefficient * (low1 - low2)
        mid1 += midCoefficient * (x - mid1)
        mid2 += midCoefficient * (mid1 - mid2)
        let bass = low2
        // Mid: the 2.5 kHz low-passed signal through three one-pole high-passes.
        highPass1 += midHighPassCoefficient * (mid2 - highPass1)
        let stage1 = mid2 - highPass1
        highPass2 += midHighPassCoefficient * (stage1 - highPass2)
        let stage2 = stage1 - highPass2
        highPass3 += midHighPassCoefficient * (stage2 - highPass3)
        let mid = stage2 - highPass3
        let high = x - mid2
        envLow += lowEnvCoefficient * (bass * bass - envLow)
        envMid += highEnvCoefficient * (mid * mid - envMid)
        envHigh += highEnvCoefficient * (high * high - envHigh)
    }

    private mutating func finishBlock(_ onset: (HapticOnset) -> Void) {
        let rmsLow = envLow.squareRoot()
        let rmsMid = envMid.squareRoot()
        let rmsHigh = envHigh.squareRoot()
        blockFill = 0
        framesDone += Int64(Self.blockFrames)
        blocksSinceOnset = min(blocksSinceOnset + 1, 1_000_000)

        let broadband = (rmsLow * rmsLow + rmsMid * rmsMid + rmsHigh * rmsHigh).squareRoot()
        peak = max(broadband, peak * peakDecay)
        guard broadband >= Self.silenceRms, peak > 0 else {
            // Silence: the rumble dies.
            previousLow = 0; previousMid = 0; previousHigh = 0
            bassLevel -= bassLevel * Self.bassRelease
            if bassLevel < 0.001 { bassLevel = 0 }
            energyLevel = 0
            return
        }
        let levelLow = min(rmsLow / peak, 1)
        let levelMid = min(rmsMid / peak, 1)
        let levelHigh = min(rmsHigh / peak, 1)
        energyLevel = min(broadband / peak, 1)

        let fluxLow = max(levelLow - previousLow, 0)
        let fluxMid = max(levelMid - previousMid, 0)
        let fluxHigh = max(levelHigh - previousHigh, 0)
        previousLow = levelLow
        previousMid = levelMid
        previousHigh = levelHigh

        let kickScore = fluxLow
        let snareScore = fluxMid * 0.8 + fluxHigh
        let best = max(kickScore, snareScore)
        if best >= Self.onsetThreshold, blocksSinceOnset >= refractoryBlocks {
            blocksSinceOnset = 0
            let kind: HapticOnset.Kind = kickScore >= snareScore ? .kick : .snare
            onset(HapticOnset(kind: kind, strength: min(best / 0.7, 1), frame: framesDone))
        }

        let rate = levelLow > bassLevel ? Self.bassAttack : Self.bassRelease
        bassLevel += (levelLow - bassLevel) * rate
    }
}
