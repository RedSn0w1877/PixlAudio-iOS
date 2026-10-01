// Small numeric helpers with the exact semantics of the Kotlin/JVM operations the Android code uses,
// so ported logic can be written line for line without silently changing rounding or overflow.

import Foundation

/// Kotlin/JVM numeric semantics that differ from Swift's defaults.
public enum KotlinMath {
    /// `kotlin.math.round(x)`: rounds half to **even** (`Math.rint`). Swift's `rounded()` rounds half away from zero.
    @inlinable
    public static func round(_ x: Float) -> Float { x.rounded(.toNearestOrEven) }

    /// `kotlin.math.round(x)` for doubles (half to even).
    @inlinable
    public static func round(_ x: Double) -> Double { x.rounded(.toNearestOrEven) }

    /// `Float.roundToInt()`: `Math.round`, i.e. `floor(x + 0.5)`, saturating, NaN → 0.
    @inlinable
    public static func roundToInt(_ x: Float) -> Int32 {
        if x.isNaN { return 0 }
        return toInt((x + 0.5).rounded(.down))
    }

    /// `Double.roundToLong()`: `Math.round`, i.e. `floor(x + 0.5)`, saturating, NaN → 0.
    @inlinable
    public static func roundToLong(_ x: Double) -> Int64 {
        if x.isNaN { return 0 }
        return toLong((x + 0.5).rounded(.down))
    }

    /// `Float.toInt()` (JVM `f2i`): truncates toward zero, saturates at the `Int` range, NaN → 0.
    @inlinable
    public static func toInt(_ x: Float) -> Int32 {
        if x.isNaN { return 0 }
        if x >= 2_147_483_648 { return .max }
        if x <= -2_147_483_648 { return .min }
        return Int32(x)
    }

    /// `Double.toInt()` (JVM `d2i`): truncates toward zero, saturates, NaN → 0.
    @inlinable
    public static func toInt(_ x: Double) -> Int32 {
        if x.isNaN { return 0 }
        if x >= 2_147_483_648 { return .max }
        if x <= -2_147_483_648 { return .min }
        return Int32(x)
    }

    /// `Float.toLong()` (JVM `f2l`): truncates toward zero, saturates at the `Long` range, NaN → 0.
    @inlinable
    public static func toLong(_ x: Float) -> Int64 {
        if x.isNaN { return 0 }
        if x >= Float(sign: .plus, exponent: 63, significand: 1) { return .max }
        if x <= Float(sign: .minus, exponent: 63, significand: 1) { return .min }
        return Int64(x)
    }

    /// `Double.toLong()` (JVM `d2l`): truncates toward zero, saturates at the `Long` range, NaN → 0.
    @inlinable
    public static func toLong(_ x: Double) -> Int64 {
        if x.isNaN { return 0 }
        if x >= Double(sign: .plus, exponent: 63, significand: 1) { return .max }
        if x <= Double(sign: .minus, exponent: 63, significand: 1) { return .min }
        return Int64(x)
    }

    /// `Long.toInt()`: keeps the low 32 bits (wraps), like Kotlin.
    @inlinable
    public static func toInt(_ x: Int64) -> Int32 { Int32(truncatingIfNeeded: x) }
}

// MARK: - Clamping and interpolation

extension Comparable {
    /// `coerceIn(minimumValue, maximumValue)`: Kotlin's clamp, applied like Compose's `fastCoerceIn` (minimum
    /// first, then maximum). Unlike Kotlin it does not throw when `minimum > maximum`. NaN stays NaN.
    @inlinable
    public func coerced(in minimum: Self, _ maximum: Self) -> Self {
        var v = self
        if v < minimum { v = minimum }
        if v > maximum { v = maximum }
        return v
    }

    /// `coerceIn(range)`.
    @inlinable
    public func coerced(in range: ClosedRange<Self>) -> Self { coerced(in: range.lowerBound, range.upperBound) }

    /// `coerceAtLeast(minimum)`.
    @inlinable
    public func coerced(atLeast minimum: Self) -> Self { self < minimum ? minimum : self }

    /// `coerceAtMost(maximum)`.
    @inlinable
    public func coerced(atMost maximum: Self) -> Self { self > maximum ? maximum : self }
}

/// Small interpolation helpers used by motion code.
public enum Interpolation {
    /// Linear interpolation `start + (stop − start) · fraction` (Compose `lerp(Float, Float, Float)`).
    @inlinable
    public static func lerp(_ start: Float, _ stop: Float, _ fraction: Float) -> Float {
        start + (stop - start) * fraction
    }

    /// Linear interpolation for doubles.
    @inlinable
    public static func lerp(_ start: Double, _ stop: Double, _ fraction: Double) -> Double {
        start + (stop - start) * fraction
    }

    /// Inverse of `lerp`: where `value` sits between `start` and `stop`, clamped to 0…1. Returns 0 when the range
    /// is empty.
    @inlinable
    public static func progress(_ value: Float, from start: Float, to stop: Float) -> Float {
        let span = stop - start
        if span == 0 { return value >= stop ? 1 : 0 }
        return ((value - start) / span).coerced(in: 0, 1)
    }
}
