// Exponential decay with the exact behaviour of Compose's `FloatExponentialDecaySpec` (animation-core 1.12),
// used by the Android lyrics view for flings (`exponentialDecay(frictionMultiplier = 0.733f,
// absVelocityThreshold = 50f)`). Same Float/Double mix and whole-millisecond truncation as Compose.

import Foundation

/// A fling that slows down exponentially: `v(t) = v₀·e^(f·t)` with `f = −4.2 · frictionMultiplier` per second.
public struct FloatExponentialDecaySpec: Sendable, Hashable {
    /// Speed (units/s) under which the fling counts as stopped. At least 1e-7.
    public let absVelocityThreshold: Float
    /// `−4.2 · max(0.0001, frictionMultiplier)`.
    public let friction: Float

    /// Compose's `ExponentialDecayFriction`.
    public static let exponentialDecayFriction: Float = -4.2

    /// Defaults match Compose: friction multiplier 1, threshold 0.1.
    public init(frictionMultiplier: Float = 1, absVelocityThreshold: Float = 0.1) {
        self.absVelocityThreshold = max(1e-7, abs(absVelocityThreshold))
        friction = Self.exponentialDecayFriction * max(1e-4, frictionMultiplier)
    }

    /// `getValueFromNanos`: position `playTimeNanos` (truncated to whole ms) after the start.
    public func valueFromNanos(_ playTimeNanos: Int64, initialValue: Float, initialVelocity: Float) -> Float {
        let playTimeMillis = playTimeNanos / 1_000_000
        let e = Float(exp(Double(friction * Float(playTimeMillis) / 1000)))
        return initialValue - initialVelocity / friction + initialVelocity / friction * e
    }

    /// `getVelocityFromNanos`: velocity `playTimeNanos` (truncated to whole ms) after the start.
    public func velocityFromNanos(_ playTimeNanos: Int64, initialValue: Float, initialVelocity: Float) -> Float {
        let playTimeMillis = playTimeNanos / 1_000_000
        return initialVelocity * Float(exp(Double(Float(playTimeMillis) / 1000 * friction)))
    }

    /// `getDurationNanos`: time until the speed falls to `absVelocityThreshold`.
    public func durationNanos(initialValue: Float, initialVelocity: Float) -> Int64 {
        let millis = KotlinMath.toLong(1000 * Float(log(Double(absVelocityThreshold / abs(initialVelocity)))) / friction)
        return millis &* 1_000_000
    }

    /// `getTargetValue`: where the fling comes to rest.
    public func targetValue(initialValue: Float, initialVelocity: Float) -> Float {
        if abs(initialVelocity) <= absVelocityThreshold { return initialValue }
        let durationMillis = log(Double(abs(absVelocityThreshold / initialVelocity))) / Double(friction) * Double(1000)
        return initialValue - initialVelocity / friction
            + initialVelocity / friction * Float(exp(Double(friction) * durationMillis / Double(Float(1000))))
    }
}
