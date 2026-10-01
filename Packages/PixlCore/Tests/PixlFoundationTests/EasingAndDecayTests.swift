import Foundation
import Testing
@testable import PixlFoundation

@Suite("Easing")
struct EasingTests {
    /// The curves the Android lyrics code uses (EmphasisMath, LyricsEngine).
    static let easeOut = CubicBezierEasing(0, 0, 0.58, 1)
    static let emphasisRise = CubicBezierEasing(0.2, 0.4, 0.58, 1)
    static let emphasisFall = CubicBezierEasing(0.3, 0, 0.58, 1)

    /// Brute-force reference: bisect x(t) = fraction in Double, return y(t).
    static func reference(_ e: CubicBezierEasing, _ x: Double) -> Double {
        func bez(_ p1: Double, _ p2: Double, _ t: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t
        }
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            if bez(Double(e.a), Double(e.c), mid) < x { lo = mid } else { hi = mid }
        }
        return bez(Double(e.b), Double(e.d), (lo + hi) / 2)
    }

    @Test(arguments: [easeOut, emphasisRise, emphasisFall, Easings.fastOutSlowIn, Easings.linearOutSlowIn,
                      Easings.fastOutLinearIn, CubicBezierEasing(0.42, 0, 0.58, 1)])
    func monotonicCurvesMatchBisection(_ easing: CubicBezierEasing) {
        var previous: Float = 0
        for i in 1..<1000 {
            let x = Float(i) / 1000
            let y = easing.transform(x)
            #expect(abs(Double(y) - Self.reference(easing, Double(x))) < 2e-5, "\(easing) at \(x)")
            #expect(y >= previous - 1e-6, "\(easing) not monotonic at \(x)")
            previous = y
        }
    }

    @Test func endpointsPassThroughUnchanged() {
        for e in [Self.easeOut, CubicBezierEasing(0.34, 1.56, 0.64, 1)] {
            #expect(e.transform(0) == 0)
            #expect(e.transform(1) == 1)
            // Compose does not extrapolate: values outside 0…1 come back unchanged.
            #expect(e.transform(-0.25) == -0.25)
            #expect(e.transform(1.5) == 1.5)
        }
        #expect(LinearEasing().transform(0.37) == 0.37)
    }

    @Test func overshootIsClampedToTheCurveBounds() {
        let back = CubicBezierEasing(0.34, 1.56, 0.64, 1)
        #expect(back.minimumY == 0)
        #expect(back.maximumY > 1.09 && back.maximumY < 1.11)
        var peak: Float = 0
        for i in 1..<200 { peak = max(peak, back.transform(Float(i) / 200)) }
        #expect(peak <= back.maximumY)
        #expect(peak > 1.05)
    }

    @Test func symmetricEaseInOutHitsTheMiddle() {
        #expect(abs(CubicBezierEasing(0.42, 0, 0.58, 1).transform(0.5) - 0.5) < 1e-6)
    }

    @Test func fastCbrtIsCloseToCbrt() {
        for x: Float in [1e-6, 0.001, 0.5, 1, 2, 27, 1000, -8, -0.125] {
            #expect(abs(ComposeBezier.fastCbrt(x) - Float(cbrt(Double(x)))) <= 1e-4 * max(1, abs(Float(cbrt(Double(x))))))
        }
    }

    @Test func javaMinMaxSemantics() {
        #expect(ComposeBezier.javaMin(0.0, -0.0).sign == .minus)
        #expect(ComposeBezier.javaMax(-0.0, 0.0).sign == .plus)
        #expect(ComposeBezier.javaMin(.nan, 1).isNaN)
        #expect(ComposeBezier.javaMin(1, .nan).isNaN)
    }

    @Test func equalityUsesControlPointsLikeCompose() {
        #expect(CubicBezierEasing(0, 0, 0.58, 1) == Self.easeOut)
        #expect(CubicBezierEasing(0, 0, 0.58, 1).hashValue == Self.easeOut.hashValue)
        #expect(Self.easeOut.description == "CubicBezierEasing(a=0.0, b=0.0, c=0.58, d=1.0)")
    }
}

@Suite("Exponential decay")
struct ExponentialDecayTests {
    /// The Android lyrics fling: `exponentialDecay(frictionMultiplier = 0.733f, absVelocityThreshold = 50f)`.
    static let fling = FloatExponentialDecaySpec(frictionMultiplier: 0.733, absVelocityThreshold: 50)

    @Test func frictionMatchesTheSpec() {
        // λ = 4.2 × 0.733 = 3.08 /s, matching the web source's ×0.95 every 16.67 ms.
        #expect(abs(Self.fling.friction - -3.0786) < 1e-4)
        #expect(abs(exp(Double(Self.fling.friction) / 60) - 0.95) < 0.002)
    }

    @Test func velocityDecaysToTheThresholdAtTheDuration() {
        for v0: Float in [120, -900, 4000] {
            let duration = Self.fling.durationNanos(initialValue: 0, initialVelocity: v0)
            let end = Self.fling.velocityFromNanos(duration, initialValue: 0, initialVelocity: v0)
            #expect(abs(abs(end) - 50) < 0.5, "v0 \(v0): end speed \(end)")
            let target = Self.fling.targetValue(initialValue: 10, initialVelocity: v0)
            let atEnd = Self.fling.valueFromNanos(duration, initialValue: 10, initialVelocity: v0)
            #expect(abs(target - atEnd) < 0.5)
            #expect((target - 10).sign == v0.sign)
        }
    }

    @Test func slowFlingsDoNotMove() {
        #expect(Self.fling.targetValue(initialValue: 42, initialVelocity: 50) == 42)
        #expect(Self.fling.targetValue(initialValue: 42, initialVelocity: -20) == 42)
    }

    @Test func defaultsAndClamps() {
        let d = FloatExponentialDecaySpec()
        #expect(d.absVelocityThreshold == 0.1)
        #expect(d.friction == -4.2)
        let clamped = FloatExponentialDecaySpec(frictionMultiplier: 0, absVelocityThreshold: 0)
        #expect(clamped.absVelocityThreshold == 1e-7)
        #expect(clamped.friction == Float(-4.2) * Float(1e-4))
        #expect(FloatExponentialDecaySpec(frictionMultiplier: 1, absVelocityThreshold: -3).absVelocityThreshold == 3)
    }
}

@Suite("Kotlin numeric semantics")
struct KotlinMathTests {
    @Test func roundIsHalfToEven() {
        #expect(KotlinMath.round(Float(0.5)) == 0)
        #expect(KotlinMath.round(Float(1.5)) == 2)
        #expect(KotlinMath.round(Float(2.5)) == 2)
        #expect(KotlinMath.round(Float(-2.5)) == -2)
        #expect(KotlinMath.round(2.6) == 3.0)
    }

    @Test func roundToIntIsHalfUp() {
        #expect(KotlinMath.roundToInt(Float(0.5)) == 1)
        #expect(KotlinMath.roundToInt(Float(2.5)) == 3)
        #expect(KotlinMath.roundToInt(Float(-2.5)) == -2)
        #expect(KotlinMath.roundToInt(Float.nan) == 0)
        #expect(KotlinMath.roundToInt(Float.infinity) == Int32.max)
        #expect(KotlinMath.roundToLong(-0.5) == 0)
    }

    @Test func conversionsSaturateAndMapNaNToZero() {
        #expect(KotlinMath.toInt(Float(3e10)) == Int32.max)
        #expect(KotlinMath.toInt(Float(-3e10)) == Int32.min)
        #expect(KotlinMath.toInt(Float(-1.9)) == -1)
        #expect(KotlinMath.toLong(Double.nan) == 0)
        #expect(KotlinMath.toLong(1e30) == Int64.max)
        #expect(KotlinMath.toLong(-Float.infinity) == Int64.min)
        #expect(KotlinMath.toLong(Float(123.9)) == 123)
        #expect(KotlinMath.toInt(Int64(4_294_967_297)) == 1)
    }

    @Test func clampAndLerp() {
        #expect(Float(5).coerced(in: 0, 1) == 1)
        #expect(Float(-5).coerced(in: 0...1) == 0)
        #expect(Int64(20).coerced(in: 100, 800) == 100)
        #expect(Float(0.3).coerced(atLeast: 0.5) == 0.5)
        #expect(Float(0.3).coerced(atMost: 0.2) == 0.2)
        #expect(Interpolation.lerp(Float(2), 4, 0.25) == 2.5)
        #expect(Interpolation.progress(5, from: 0, to: 10) == 0.5)
        #expect(Interpolation.progress(5, from: 5, to: 5) == 1)
    }
}
