import Foundation
import Testing
@testable import PixlFoundation

/// The spring solver against textbook closed forms of `x″ + 2ζω·x′ + ω²·x = 0` (ω = √k), computed independently in
/// Double, plus the Compose behaviours the lyrics engine depends on.
@Suite("Spring solver")
struct SpringTests {
    /// Reference displacement and velocity relative to the target.
    static func reference(zeta: Double, k: Double, x0: Double, v0: Double, t: Double) -> (x: Double, v: Double) {
        let w = k.squareRoot()
        if zeta < 1 {
            let wd = w * (1 - zeta * zeta).squareRoot()
            let a = x0
            let b = (v0 + zeta * w * x0) / wd
            let e = exp(-zeta * w * t)
            let x = e * (a * cos(wd * t) + b * sin(wd * t))
            let v = -zeta * w * x + e * (-a * wd * sin(wd * t) + b * wd * cos(wd * t))
            return (x, v)
        } else if zeta == 1 {
            let a = x0
            let b = v0 + w * x0
            let e = exp(-w * t)
            return ((a + b * t) * e, b * e - w * (a + b * t) * e)
        } else {
            let s = w * (zeta * zeta - 1).squareRoot()
            let r1 = -zeta * w + s
            let r2 = -zeta * w - s
            // x = c1·e^(r1 t) + c2·e^(r2 t); c1 + c2 = x0; r1·c1 + r2·c2 = v0.
            let c1 = (v0 - r2 * x0) / (r1 - r2)
            let c2 = x0 - c1
            return (c1 * exp(r1 * t) + c2 * exp(r2 * t), c1 * r1 * exp(r1 * t) + c2 * r2 * exp(r2 * t))
        }
    }

    static let cases: [(zeta: Float, k: Float)] = [
        (1.1 / Float(0.9).squareRoot(), 220 / 0.9), // lyrics normal (over-damped)
        (15 / (2 * Float(81).squareRoot()), 100),   // lyrics slow (under-damped)
        (0.884, 50),                                 // lyrics scale
        (0.9, 150),                                  // background vocals
        (1, 200),                                    // critical
        (0.2, 400),                                  // bouncy
        (0, 100),                                    // undamped
        (3, 60),                                     // over-damped
    ]

    @Test(arguments: cases.indices)
    func matchesTextbookClosedForm(_ index: Int) {
        let (zeta, k) = Self.cases[index]
        let spec = FloatSpringSpec(dampingRatio: zeta, stiffness: k, visibilityThreshold: 0.5)
        for (from, to, v0) in [(Float(0), Float(100), Float(0)), (250, -40, 800), (-12.5, 30, -300)] {
            for ms in stride(from: Int64(0), through: 3000, by: 37) {
                let m = spec.motionFromNanos(ms * 1_000_000, initialValue: from, targetValue: to, initialVelocity: v0)
                let r = Self.reference(zeta: Double(zeta), k: Double(k), x0: Double(from - to), v0: Double(v0), t: Double(ms) / 1000)
                let scale = max(abs(Double(from - to)), abs(Double(v0)) / 10, 1)
                #expect(abs(Double(m.value) - (r.x + Double(to))) <= 1e-4 * scale, "ζ \(zeta) k \(k) t \(ms) ms")
                #expect(abs(Double(m.velocity) - r.v) <= 1e-3 * scale * max(1, Double(k).squareRoot()), "ζ \(zeta) k \(k) t \(ms) ms")
            }
        }
    }

    @Test func startsAtInitialValueAndVelocity() {
        for (zeta, k) in Self.cases {
            let spec = FloatSpringSpec(dampingRatio: zeta, stiffness: k)
            let m = spec.motionFromNanos(0, initialValue: 12, targetValue: 80, initialVelocity: -35)
            #expect(abs(m.value - 12) < 1e-4)
            #expect(abs(m.velocity - -35) < 1e-3)
        }
    }

    @Test func playTimeIsTruncatedToWholeMilliseconds() {
        let spec = FloatSpringSpec(dampingRatio: 0.8333, stiffness: 100)
        let atZero = spec.valueFromNanos(0, initialValue: 0, targetValue: 100, initialVelocity: 0)
        let justUnder = spec.valueFromNanos(999_999, initialValue: 0, targetValue: 100, initialVelocity: 0)
        #expect(atZero.bitPattern == justUnder.bitPattern)
        let frame = spec.valueFromNanos(16_666_667, initialValue: 0, targetValue: 100, initialVelocity: 0)
        let sixteen = spec.valueFromNanos(16_000_000, initialValue: 0, targetValue: 100, initialVelocity: 0)
        #expect(frame.bitPattern == sixteen.bitPattern)
        #expect(spec.motion(atMillis: 16, initialValue: 0, targetValue: 100, initialVelocity: 0).value.bitPattern == sixteen.bitPattern)
    }

    @Test func dampedSpringsConvergeAndSettle() {
        // Mirrors SpringChannel.update: y channel rest 0.1 px / 5 px/s within the 10 s cap.
        for (zeta, k) in Self.cases where zeta > 0 {
            let spec = FloatSpringSpec(dampingRatio: zeta, stiffness: k, visibilityThreshold: 0.5)
            var settledAt: Int64?
            for ms in stride(from: Int64(0), through: 10_000, by: 16) {
                let m = spec.motionFromNanos(ms * 1_000_000, initialValue: 0, targetValue: 400, initialVelocity: 0)
                if FloatSpringSpec.isSettled(value: m.value, velocity: m.velocity, target: 400, restDelta: 0.1, restVelocity: 5) {
                    settledAt = ms
                    break
                }
            }
            #expect(settledAt != nil, "ζ \(zeta) k \(k) never settled")
            if let settledAt { #expect(settledAt < 10_000) }
        }
        // ζ = 0 never settles; the duration estimate is "forever", like Compose.
        let undamped = FloatSpringSpec(dampingRatio: 0, stiffness: 100)
        #expect(undamped.durationNanos(initialValue: 0, targetValue: 1, initialVelocity: 0) == SpringEstimation.maxLongMillis &* 1_000_000)
    }

    @Test func retargetingFromCurrentStateIsContinuous() {
        // The lyrics engine restarts a spring from its current value and velocity when the target changes.
        let spec = FloatSpringSpec(dampingRatio: 1.1595, stiffness: 244.44, visibilityThreshold: 0.5)
        let mid = spec.motionFromNanos(120_000_000, initialValue: 0, targetValue: 300, initialVelocity: 0)
        let restarted = spec.motionFromNanos(0, initialValue: mid.value, targetValue: 500, initialVelocity: mid.velocity)
        #expect(abs(restarted.value - mid.value) < 1e-3)
        #expect(abs(restarted.velocity - mid.velocity) < 1e-2)
    }

    @Test func criticalDampingUsesExactOneOnly() {
        // ζ == 1 exactly takes the critically damped branch; 1.0000001 the over-damped one. Both stay close.
        let critical = FloatSpringSpec(dampingRatio: 1, stiffness: 200)
        let over = FloatSpringSpec(dampingRatio: 1.0000001, stiffness: 200)
        for ms in stride(from: Int64(0), through: 1000, by: 50) {
            let a = critical.valueFromNanos(ms * 1_000_000, initialValue: 0, targetValue: 1, initialVelocity: 0)
            let b = over.valueFromNanos(ms * 1_000_000, initialValue: 0, targetValue: 1, initialVelocity: 0)
            #expect(abs(a - b) < 1e-2)
        }
    }

    @Test func stiffnessIsStoredAsNaturalFrequency() {
        var simulation = SpringSimulation(finalPosition: 0)
        #expect(simulation.stiffness == 50)
        simulation.stiffness = 244.44
        #expect(simulation.naturalFrequency == Double(Float(244.44)).squareRoot())
        #expect(simulation.stiffness == Float(simulation.naturalFrequency * simulation.naturalFrequency))
        // Acceleration: −k·x − 2·√k·ζ·v.
        simulation.dampingRatio = 0.5
        let a = simulation.acceleration(lastDisplacement: 2, lastVelocity: 3)
        let k = simulation.naturalFrequency * simulation.naturalFrequency
        #expect(abs(Double(a) - (-k * 2 - 2 * simulation.naturalFrequency * 0.5 * 3)) < 1e-3)
    }

    @Test func specDefaultsMatchCompose() {
        let spec = FloatSpringSpec()
        #expect(spec.dampingRatio == 1)
        #expect(spec.stiffness == 1500)
        #expect(spec.visibilityThreshold == 0.01)
        #expect(spec.endVelocity(initialValue: 0, targetValue: 1, initialVelocity: 5) == 0)
        #expect(FloatSpringSpec(dampingRatio: 0.5, stiffness: 10) == FloatSpringSpec(dampingRatio: 0.5, stiffness: 10))
    }
}
