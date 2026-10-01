import Foundation
import Testing
@testable import PixlFoundation

/// Compares the Swift ports against vectors produced by the real Jetpack Compose classes
/// (`androidx.compose.animation.core` 1.12.1 `FloatSpringSpec`, `CubicBezierEasing`, `FloatExponentialDecaySpec`)
/// running on the JVM. Regenerate with `tools/android-reference/RefGen.java`.
///
/// Values are Float bit patterns. Compose and Swift do the same Float/Double operations, so most results are
/// bit-identical; `exp`/`cos`/`acos` come from different libm implementations (Java vs the platform C library),
/// which can move a Double by an ulp and, rarely, the rounded Float by one ulp. Tolerance: 4 Float ulps (or 1e-6
/// absolute for values near zero); durations within 1 ms.
@Suite("Compose reference vectors")
struct ComposeReferenceTests {
    struct Fixture {
        var springs: [(spec: FloatSpringSpec, initial: Float, target: Float, v0: Float, nanos: Int64, value: Float, velocity: Float)] = []
        var durations: [(spec: FloatSpringSpec, initial: Float, target: Float, v0: Float, nanos: Int64)] = []
        var beziers: [(easing: CubicBezierEasing, x: Float, y: Float)] = []
        var decays: [(spec: FloatExponentialDecaySpec, initial: Float, v0: Float, nanos: Int64, value: Float, velocity: Float)] = []
        var decayEnds: [(spec: FloatExponentialDecaySpec, initial: Float, v0: Float, nanos: Int64, target: Float)] = []
    }

    static func float(_ token: Substring) -> Float {
        Float(bitPattern: UInt32(token.dropFirst(2), radix: 16)!)
    }

    static func load() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "compose-reference", withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        var fixture = Fixture()
        for line in text.split(separator: "\n") where !line.hasPrefix("//") {
            let f = line.split(separator: " ")
            switch f[0] {
            case "S":
                let spec = FloatSpringSpec(dampingRatio: float(f[1]), stiffness: float(f[2]), visibilityThreshold: float(f[3]))
                fixture.springs.append((spec, float(f[4]), float(f[5]), float(f[6]), Int64(f[7])!, float(f[8]), float(f[9])))
            case "D":
                let spec = FloatSpringSpec(dampingRatio: float(f[1]), stiffness: float(f[2]), visibilityThreshold: float(f[3]))
                fixture.durations.append((spec, float(f[4]), float(f[5]), float(f[6]), Int64(f[7])!))
            case "B":
                let easing = CubicBezierEasing(float(f[1]), float(f[2]), float(f[3]), float(f[4]))
                fixture.beziers.append((easing, float(f[5]), float(f[6])))
            case "X":
                let spec = FloatExponentialDecaySpec(frictionMultiplier: float(f[1]), absVelocityThreshold: float(f[2]))
                fixture.decays.append((spec, float(f[3]), float(f[4]), Int64(f[5])!, float(f[6]), float(f[7])))
            case "Y":
                let spec = FloatExponentialDecaySpec(frictionMultiplier: float(f[1]), absVelocityThreshold: float(f[2]))
                fixture.decayEnds.append((spec, float(f[3]), float(f[4]), Int64(f[5])!, float(f[6])))
            default:
                Issue.record("Unknown fixture line \(line)")
            }
        }
        return fixture
    }

    static func close(_ actual: Float, _ expected: Float) -> Bool {
        if actual.bitPattern == expected.bitPattern { return true }
        if actual.isNaN || expected.isNaN { return false }
        return abs(actual - expected) <= max(4 * expected.ulp, 1e-6)
    }

    @Test func springValuesAndVelocitiesMatchCompose() throws {
        let fixture = try Self.load()
        #expect(fixture.springs.count == 720)
        var exact = 0
        for s in fixture.springs {
            let m = s.spec.motionFromNanos(s.nanos, initialValue: s.initial, targetValue: s.target, initialVelocity: s.v0)
            let value = s.spec.valueFromNanos(s.nanos, initialValue: s.initial, targetValue: s.target, initialVelocity: s.v0)
            let velocity = s.spec.velocityFromNanos(s.nanos, initialValue: s.initial, targetValue: s.target, initialVelocity: s.v0)
            #expect(m.value.bitPattern == value.bitPattern && m.velocity.bitPattern == velocity.bitPattern)
            #expect(Self.close(value, s.value),
                    "ζ \(s.spec.dampingRatio) k \(s.spec.stiffness) from \(s.initial)→\(s.target) v0 \(s.v0) t \(s.nanos): value \(value) vs \(s.value)")
            #expect(Self.close(velocity, s.velocity),
                    "ζ \(s.spec.dampingRatio) k \(s.spec.stiffness) from \(s.initial)→\(s.target) v0 \(s.v0) t \(s.nanos): velocity \(velocity) vs \(s.velocity)")
            if value.bitPattern == s.value.bitPattern && velocity.bitPattern == s.velocity.bitPattern { exact += 1 }
        }
        // libm differences are rare; most samples must be bit-identical.
        print("FloatSpringSpec: \(exact) of \(fixture.springs.count) samples bit-identical to Compose")
        #expect(Double(exact) / Double(fixture.springs.count) > 0.9, "only \(exact) of \(fixture.springs.count) bit-exact")
    }

    @Test func springDurationEstimatesMatchCompose() throws {
        let fixture = try Self.load()
        #expect(fixture.durations.count == 60)
        for d in fixture.durations {
            let nanos = d.spec.durationNanos(initialValue: d.initial, targetValue: d.target, initialVelocity: d.v0)
            #expect(abs(nanos - d.nanos) <= 1_000_000,
                    "ζ \(d.spec.dampingRatio) k \(d.spec.stiffness) from \(d.initial)→\(d.target) v0 \(d.v0): \(nanos) vs \(d.nanos)")
        }
    }

    @Test func cubicBezierMatchesCompose() throws {
        let fixture = try Self.load()
        #expect(fixture.beziers.count == 12 * 209)
        var exact = 0
        for b in fixture.beziers {
            let y = b.easing.transform(b.x)
            #expect(Self.close(y, b.y), "\(b.easing) at \(b.x): \(y) vs \(b.y)")
            if y.bitPattern == b.y.bitPattern { exact += 1 }
        }
        print("CubicBezierEasing: \(exact) of \(fixture.beziers.count) samples bit-identical to Compose")
        #expect(Double(exact) / Double(fixture.beziers.count) > 0.9, "only \(exact) of \(fixture.beziers.count) bit-exact")
    }

    @Test func exponentialDecayMatchesCompose() throws {
        let fixture = try Self.load()
        #expect(fixture.decays.count == 3 * 5 * 12)
        for d in fixture.decays {
            let value = d.spec.valueFromNanos(d.nanos, initialValue: d.initial, initialVelocity: d.v0)
            let velocity = d.spec.velocityFromNanos(d.nanos, initialValue: d.initial, initialVelocity: d.v0)
            #expect(Self.close(value, d.value), "decay value \(value) vs \(d.value)")
            #expect(Self.close(velocity, d.velocity), "decay velocity \(velocity) vs \(d.velocity)")
        }
        #expect(fixture.decayEnds.count == 15)
        for d in fixture.decayEnds {
            let nanos = d.spec.durationNanos(initialValue: d.initial, initialVelocity: d.v0)
            #expect(abs(nanos - d.nanos) <= 1_000_000, "decay duration \(nanos) vs \(d.nanos)")
            let target = d.spec.targetValue(initialValue: d.initial, initialVelocity: d.v0)
            #expect(Self.close(target, d.target), "decay target \(target) vs \(d.target)")
        }
    }
}
