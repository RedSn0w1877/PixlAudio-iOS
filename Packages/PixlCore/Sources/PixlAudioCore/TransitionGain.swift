// Crossfade gain curves, ported from utils/Envelope.kt (`envelope`) and the fade loop of
// DualPlayerEngine.performOverlapTransition. Android steps both players' volumes every 32 ms; on iOS the same gain
// g(t) is applied inside each deck's processing tap, ramped linearly across each buffer (`CrossfadeRamp`).

import Foundation
import PixlFoundation
import PixlModel

/// `envelope(progress, curve)`: maps linear progress 0…1 to a volume multiplier 0…1.
public enum TransitionEnvelope {
    /// The curve value at `progress` (clamped to 0…1 first; NaN stays NaN, as in Kotlin).
    /// LINEAR p · EXP p² · LOG √p · S_CURVE (1 − cos πp) / 2 (computed in Double like Kotlin's `PI * Float`).
    @inlinable
    public static func envelope(_ progress: Float, _ curve: TransitionCurve) -> Float {
        let p = progress.coerced(in: 0, 1)
        switch curve {
        case .linear: return p
        case .sCurve: return Float((1 - cos(Double.pi * Double(p))) / 2)
        case .log: return p.squareRoot()
        case .exp: return p * p
        }
    }
}

/// The volumes of both decks at one point of a crossfade.
public struct CrossfadeGains: Sendable, Hashable {
    /// The incoming (next) track's volume.
    public var incoming: Float
    /// The outgoing (current) track's volume.
    public var outgoing: Float

    public init(incoming: Float, outgoing: Float) {
        self.incoming = incoming
        self.outgoing = outgoing
    }
}

/// One running crossfade (`performOverlapTransition`): the fade lasts `durationMs` (at least 500 ms), the outgoing deck
/// falls from the volume it had when the fade started, and the incoming deck rises to its ReplayGain volume.
public struct CrossfadeRun: Sendable, Hashable {
    /// Android's floor on the fade length (`coerceAtLeast(500L)`).
    public static let minimumDurationMs: Int64 = 500
    /// Android's volume update period (`stepMs`). iOS ramps per buffer instead; kept for reference and the demo engine.
    public static let stepMs: Int64 = 32

    public let settings: TransitionSettings
    /// Fade length in ms, `max(settings.durationMs, 500)`.
    public let durationMs: Int64
    /// The outgoing deck's volume when the fade began, clamped to 0…1.
    public let outgoingStartVolume: Float

    public init(settings: TransitionSettings, outgoingStartVolume: Float = 1) {
        self.settings = settings
        durationMs = max(Int64(settings.durationMs), Self.minimumDurationMs)
        self.outgoingStartVolume = outgoingStartVolume.coerced(in: 0, 1)
    }

    /// Fade progress 0…1 after `elapsedMs` (`elapsed.toFloat() / duration`, elapsed capped at the duration).
    @inlinable
    public func progress(elapsedMs: Int64) -> Float {
        let elapsed = min(elapsedMs, durationMs)
        return (Float(elapsed) / Float(durationMs)).coerced(in: 0, 1)
    }

    /// True once the fade is complete (`elapsed >= duration`).
    @inlinable
    public func isFinished(elapsedMs: Int64) -> Bool { min(elapsedMs, durationMs) >= durationMs }

    /// Both volumes after `elapsedMs`. `incomingTarget` is the incoming track's ReplayGain volume
    /// (`incomingTrackReplayGainVolume ?: 1f`).
    @inlinable
    public func gains(elapsedMs: Int64, incomingTarget: Float? = nil) -> CrossfadeGains {
        Self.gains(progress: progress(elapsedMs: elapsedMs), settings: settings,
                   outgoingStartVolume: outgoingStartVolume, incomingTarget: incomingTarget)
    }

    /// Volumes once the fade is done: outgoing silent, incoming at its ReplayGain volume (player volumes are 0…1).
    @inlinable
    public func finalGains(incomingTarget: Float? = nil) -> CrossfadeGains {
        CrossfadeGains(incoming: (incomingTarget ?? 1).coerced(in: 0, 1), outgoing: 0)
    }

    /// The loop body of `performOverlapTransition` for a given progress.
    @inlinable
    public static func gains(progress: Float, settings: TransitionSettings, outgoingStartVolume: Float,
                             incomingTarget: Float?) -> CrossfadeGains {
        let volIn = TransitionEnvelope.envelope(progress, settings.curveIn)
        let volOut = 1 - TransitionEnvelope.envelope(progress, settings.curveOut)
        let target = incomingTarget ?? 1
        return CrossfadeGains(incoming: (volIn * target).coerced(in: 0, 1),
                              outgoing: (volOut * outgoingStartVolume).coerced(in: 0, 1))
    }
}

/// The gain one deck applies during a crossfade, as a function of that deck's own media time — what a processing tap
/// evaluates per buffer. Value type, no allocation; safe to copy into a real-time context.
public struct CrossfadeRamp: Sendable, Hashable {
    /// Which side of the crossfade this deck is on.
    public enum Role: Sendable, Hashable {
        /// Fades in with `curveIn`, scaled by the incoming ReplayGain volume.
        case incoming
        /// Fades out with `curveOut`, scaled by the volume it had when the fade began.
        case outgoing
    }

    public var role: Role
    public var curve: TransitionCurve
    /// The deck's media time (seconds) at which the fade starts.
    public var startTime: Double
    /// Fade length in seconds (already floored at 0.5 s by `CrossfadeRun`).
    public var duration: Double
    /// Multiplier applied to the curve (incoming: ReplayGain target; outgoing: start volume).
    public var scale: Float

    public init(role: Role, curve: TransitionCurve, startTime: Double, duration: Double, scale: Float) {
        self.role = role
        self.curve = curve
        self.startTime = startTime
        self.duration = duration
        self.scale = scale
    }

    /// The two ramps of a crossfade that starts at `outgoingStartTime` on the outgoing deck and at
    /// `incomingStartTime` on the incoming deck (usually 0).
    public static func pair(run: CrossfadeRun, outgoingStartTime: Double, incomingStartTime: Double = 0,
                            incomingTarget: Float? = nil) -> (incoming: CrossfadeRamp, outgoing: CrossfadeRamp) {
        let seconds = Double(run.durationMs) / 1000
        return (CrossfadeRamp(role: .incoming, curve: run.settings.curveIn, startTime: incomingStartTime,
                              duration: seconds, scale: incomingTarget ?? 1),
                CrossfadeRamp(role: .outgoing, curve: run.settings.curveOut, startTime: outgoingStartTime,
                              duration: seconds, scale: run.outgoingStartVolume))
    }

    /// The gain at media time `time` (seconds). Before the fade the incoming deck is silent and the outgoing deck at
    /// its start volume; after it, incoming sits at its target and outgoing is silent. Always clamped to 0…1.
    @inlinable
    public func gain(at time: Double) -> Float {
        let progress: Float = duration > 0 ? Float(((time - startTime) / duration)).coerced(in: 0, 1)
                                           : (time >= startTime ? 1 : 0)
        let e = TransitionEnvelope.envelope(progress, curve)
        switch role {
        case .incoming: return (e * scale).coerced(in: 0, 1)
        case .outgoing: return ((1 - e) * scale).coerced(in: 0, 1)
        }
    }

    /// Multiplies an interleaved buffer in place. The gain is evaluated at the buffer's first and last frame and
    /// interpolated linearly per frame (the curves are smooth over one buffer). No allocation.
    /// - Parameters:
    ///   - samples: `frames × channels` interleaved samples.
    ///   - firstFrameTime: media time of frame 0 in seconds.
    @inlinable
    public func apply(to samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int,
                      firstFrameTime: Double, sampleRate: Double) {
        guard frames > 0, channels > 0, sampleRate > 0 else { return }
        let g0 = gain(at: firstFrameTime)
        let g1 = gain(at: firstFrameTime + Double(frames - 1) / sampleRate)
        GainRamp.apply(to: samples, frames: frames, channels: channels, from: g0, to: g1)
    }

    /// Multiplies one channel of non-interleaved (planar) audio in place; call once per channel buffer.
    @inlinable
    public func apply(toChannel samples: UnsafeMutablePointer<Float>, frames: Int,
                      firstFrameTime: Double, sampleRate: Double) {
        apply(to: samples, frames: frames, channels: 1, firstFrameTime: firstFrameTime, sampleRate: sampleRate)
    }
}

/// Allocation-free gain helpers for render callbacks.
public enum GainRamp {
    /// Multiplies `frames × channels` interleaved samples by a gain moving linearly from `from` (frame 0) to `to`
    /// (last frame). A constant gain of 1 is a no-op.
    @inlinable
    public static func apply(to samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int, from: Float, to: Float) {
        guard frames > 0, channels > 0 else { return }
        if from == to {
            if from == 1 { return }
            for i in 0..<(frames * channels) { samples[i] *= from }
            return
        }
        let step = frames > 1 ? (to - from) / Float(frames - 1) : 0
        var g = from
        var index = 0
        for _ in 0..<frames {
            for _ in 0..<channels {
                samples[index] *= g
                index += 1
            }
            g += step
        }
    }
}
