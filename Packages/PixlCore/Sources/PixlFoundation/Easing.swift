// Easing curves with the exact behaviour of Jetpack Compose's `androidx.compose.animation.core` easings
// (animation-core 1.12). `CubicBezierEasing` solves x(t) = fraction with Compose's Cardano solver
// (`androidx.compose.ui.graphics.findFirstCubicRoot`) in the same float/double precision mix, then evaluates y(t)
// and clamps it to the curve's precomputed vertical bounds, so results match the Android app bit for bit on
// the same inputs (up to libm differences in `acos`/`cos` for the rare three-real-roots case).

import Foundation

/// A timing curve mapping a fraction in 0…1 to an eased fraction (Compose `Easing`).
public protocol Easing: Sendable {
    /// Transforms a linear fraction into the eased fraction.
    func transform(_ fraction: Float) -> Float
}

/// Compose `LinearEasing`: returns the fraction unchanged.
public struct LinearEasing: Easing, Hashable {
    public init() {}
    @inlinable public func transform(_ fraction: Float) -> Float { fraction }
}

/// A cubic Bézier timing curve through (0, 0), (a, b), (c, d), (1, 1) — Compose `CubicBezierEasing`.
///
/// For `fraction ≤ 0` or `≥ 1` the fraction is returned unchanged (no extrapolation), exactly like Compose.
public struct CubicBezierEasing: Easing, Hashable, CustomStringConvertible {
    public let a: Float
    public let b: Float
    public let c: Float
    public let d: Float
    /// Lowest and highest y the curve reaches on t ∈ [0, 1]; the solved y is clamped to them.
    public let minimumY: Float
    public let maximumY: Float

    /// - Precondition: no control point is NaN (Compose throws `IllegalArgumentException`).
    public init(_ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        precondition(!a.isNaN && !b.isNaN && !c.isNaN && !d.isNaN,
                     "Parameters to CubicBezierEasing cannot be NaN. Actual parameters are: \(a), \(b), \(c), \(d).")
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        let bounds = ComposeBezier.cubicVerticalBounds(0, b, d, 1)
        minimumY = bounds.min
        maximumY = bounds.max
    }

    public func transform(_ fraction: Float) -> Float {
        guard fraction > 0, fraction < 1 else { return fraction }
        // Compose: "We translate the coordinates by the fraction when calling findFirstCubicRoot, but we also need
        // to make sure the fraction is never exactly 0": max(fraction, 1.1920929e-7).
        let start = max(fraction, 1.1920929e-7 as Float)
        let t = ComposeBezier.findFirstCubicRoot(0 - start, a - start, c - start, 1 - start)
        // Compose throws "The cubic curve ... has no solution at <fraction>" here. That only happens for control
        // points outside what a timing curve allows; fall back to linear instead of crashing.
        guard !t.isNaN else { return fraction }
        let y = ComposeBezier.evaluateCubic(b, d, t)
        return y.coerced(in: minimumY, maximumY)
    }

    public var description: String { "CubicBezierEasing(a=\(a), b=\(b), c=\(c), d=\(d))" }

    // Equality/hash use the control points only, like Compose.
    public static func == (lhs: CubicBezierEasing, rhs: CubicBezierEasing) -> Bool {
        lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c && lhs.d == rhs.d
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(a)
        hasher.combine(b)
        hasher.combine(c)
        hasher.combine(d)
    }
}

/// The standard Compose easing curves (`EasingKt`).
public enum Easings {
    /// `FastOutSlowInEasing` = cubic(0.4, 0, 0.2, 1).
    public static let fastOutSlowIn = CubicBezierEasing(0.4, 0, 0.2, 1)
    /// `LinearOutSlowInEasing` = cubic(0, 0, 0.2, 1).
    public static let linearOutSlowIn = CubicBezierEasing(0, 0, 0.2, 1)
    /// `FastOutLinearInEasing` = cubic(0.4, 0, 1, 1).
    public static let fastOutLinearIn = CubicBezierEasing(0.4, 0, 1, 1)
    /// `LinearEasing`.
    public static let linear = LinearEasing()
}

// MARK: - Compose's Bézier maths (androidx.compose.ui.graphics.BezierKt, ui-util MathHelpersKt)

/// Port of the parts of `androidx.compose.ui.graphics.Bezier.kt` that `CubicBezierEasing` uses. Kept internal-ish
/// (`public` only so PixlCore modules and tests can reach it).
public enum ComposeBezier {
    static let tau = 6.283185307179586
    static let epsilon = 1.0e-7
    static let floatEpsilon: Float = 1.05e-6

    /// `evaluateCubic(p1, p2, t)`: y of the unit cubic with p0 = 0 and p3 = 1.
    @inlinable
    public static func evaluateCubic(_ p1: Float, _ p2: Float, _ t: Float) -> Float {
        let a = 1.0 / 3.0 as Float + (p1 - p2)
        let b = p2 - 2.0 * p1
        let c = p1
        return 3.0 * ((a * t + b) * t + c) * t
    }

    /// `evaluateCubic(p0, p1, p2, p3, t)`: a full cubic Bézier coordinate.
    @inlinable
    public static func evaluateCubic(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let a = p3 + 3.0 * (p1 - p2) - p0
        let b = 3.0 * (p2 - 2.0 * p1 + p0)
        let c = 3.0 * (p1 - p0)
        return ((a * t + b) * t + c) * t + p0
    }

    /// `closeTo(0.0)`.
    static func closeToZero(_ x: Double) -> Bool { abs(x - 0.0) < epsilon }

    /// `clampValidRootInUnitRange`: roots within `FloatEpsilon` of [0, 1] snap into it; others become NaN.
    static func clampValidRootInUnitRange(_ r: Float) -> Float {
        let v = r.coerced(in: 0, 1)
        return abs(v - r) > floatEpsilon ? .nan : v
    }

    /// Compose's `fastCbrt` (ui-util): bit-hack estimate plus two Newton steps. Not `cbrt`; the result differs in
    /// the last bits, which is why it is ported rather than replaced.
    public static func fastCbrt(_ x: Float) -> Float {
        let v = Int64(Int32(bitPattern: x.bitPattern)) & 0x1_FFFF_FFFF
        let bits = Int32(709_952_852) &+ Int32(truncatingIfNeeded: v / 3)
        var estimate = Float(bitPattern: UInt32(bitPattern: bits))
        estimate -= (estimate - x / (estimate * estimate)) * (1.0 / 3.0 as Float)
        estimate -= (estimate - x / (estimate * estimate)) * (1.0 / 3.0 as Float)
        return estimate
    }

    /// `findFirstCubicRoot(p0, p1, p2, p3)`: the first root in [0, 1] of the cubic Bézier with those control values,
    /// or NaN. Cardano's method, with the same Float/Double conversions as Compose.
    public static func findFirstCubicRoot(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> Float {
        var a = 3.0 * (Double(p0) - 2.0 * Double(p1) + Double(p2))
        var b = 3.0 * Double(p1 - p0)
        var c = Double(p0)
        let d = Double(-p0) + 3.0 * Double(p1 - p2) + Double(p3)

        if closeToZero(d) {
            // Not a cubic.
            if closeToZero(a) {
                // Not a quadratic.
                if closeToZero(b) { return .nan }
                return clampValidRootInUnitRange(Float(-c / b))
            }
            let q = (b * b - 4.0 * a * c).squareRoot()
            let a2 = 2.0 * a
            let root = clampValidRootInUnitRange(Float((q - b) / a2))
            if !root.isNaN { return root }
            return clampValidRootInUnitRange(Float((-b - q) / a2))
        }

        a /= d
        b /= d
        c /= d

        let o3 = (3.0 * b - a * a) / 9.0
        let q2 = (2.0 * a * a * a - 9.0 * a * b + 27.0 * c) / 54.0
        let discriminant = q2 * q2 + o3 * o3 * o3
        let a3 = a / 3.0

        if discriminant < 0.0 {
            let mp33 = -(o3 * o3 * o3)
            let r = mp33.squareRoot()
            let t = -q2 / r
            let cosPhi = t.coerced(in: -1.0, 1.0)
            let phi = acos(cosPhi)
            let t1 = 2.0 * fastCbrt(Float(r))

            var root = clampValidRootInUnitRange(Float(Double(t1) * cos(phi / 3.0) - a3))
            if !root.isNaN { return root }
            root = clampValidRootInUnitRange(Float(Double(t1) * cos((phi + tau) / 3.0) - a3))
            if !root.isNaN { return root }
            return clampValidRootInUnitRange(Float(Double(t1) * cos((phi + 2.0 * tau) / 3.0) - a3))
        } else if discriminant == 0.0 {
            let u1 = -fastCbrt(Float(q2))
            let root = clampValidRootInUnitRange(2.0 * u1 - Float(a3))
            if !root.isNaN { return root }
            return clampValidRootInUnitRange(-u1 - Float(a3))
        } else {
            let sd = discriminant.squareRoot()
            let u1 = fastCbrt(Float(-q2 + sd))
            let v1 = fastCbrt(Float(q2 + sd))
            return clampValidRootInUnitRange(Float(Double(u1 - v1) - a3))
        }
    }

    /// `writeValidRootInUnitRange`: stores the clamped root (NaN included) and returns 1 if it is valid.
    static func writeValidRoot(_ r: Float, _ roots: inout [Float], _ index: Int) -> Int {
        let v = clampValidRootInUnitRange(r)
        roots[index] = v
        return v.isNaN ? 0 : 1
    }

    /// `findQuadraticRoots(p0, p1, p2, roots, index)`.
    static func findQuadraticRoots(_ p0: Float, _ p1: Float, _ p2: Float, _ roots: inout [Float], _ index: Int) -> Int {
        let a = Double(p0)
        let b = Double(p1)
        let c = Double(p2)
        let d = a - 2.0 * b + c
        var rootCount = 0
        if d != 0.0 {
            let v1 = -(b * b - a * c).squareRoot()
            let v2 = -a + b
            rootCount += writeValidRoot(Float(-(v1 + v2) / d), &roots, index)
            rootCount += writeValidRoot(Float((v1 - v2) / d), &roots, index + rootCount)
            if rootCount > 1 {
                let s = roots[index]
                let t = roots[index + 1]
                if s > t {
                    roots[index] = t
                    roots[index + 1] = s
                } else if s == t {
                    rootCount -= 1
                }
            }
        } else if b != c {
            rootCount += writeValidRoot(Float((2.0 * b - c) / (2.0 * b - 2.0 * c)), &roots, index)
        }
        return rootCount
    }

    /// `computeCubicVerticalBounds(p0, p1, p2, p3)`: min and max of the cubic over t ∈ [0, 1].
    public static func cubicVerticalBounds(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> (min: Float, max: Float) {
        var roots = [Float](repeating: 0, count: 5)
        // Coefficients of the derivative.
        let a = 3.0 * (p1 - p0)
        let b = 3.0 * (p2 - p1)
        let c = 3.0 * (p3 - p2)
        var count = findQuadraticRoots(a, b, c, &roots, 0)
        // Coefficients of the second derivative (a line); findLineRoot = -p0 / (p1 - p0).
        let a2 = 2.0 * (b - a)
        let b2 = 2.0 * (c - b)
        count += writeValidRoot(-a2 / (b2 - a2), &roots, count)
        var minY = javaMin(p0, p3)
        var maxY = javaMax(p0, p3)
        for i in 0..<count {
            let y = evaluateCubic(p0, p1, p2, p3, roots[i])
            minY = javaMin(minY, y)
            maxY = javaMax(maxY, y)
        }
        return (minY, maxY)
    }

    /// `java.lang.Math.min(float, float)`: NaN-propagating and −0 < +0 (Swift's `min` is neither).
    @inlinable
    public static func javaMin(_ a: Float, _ b: Float) -> Float {
        if a.isNaN { return a }
        if a == 0, b == 0, b.sign == .minus { return b }
        return a <= b ? a : b
    }

    /// `java.lang.Math.max(float, float)`: NaN-propagating and +0 > −0.
    @inlinable
    public static func javaMax(_ a: Float, _ b: Float) -> Float {
        if a.isNaN { return a }
        if a == 0, b == 0, a.sign == .minus { return b }
        return a >= b ? a : b
    }
}
