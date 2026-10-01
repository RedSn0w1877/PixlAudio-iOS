// Damped-spring maths with the exact behaviour of Jetpack Compose's `FloatSpringSpec` / `SpringSimulation`
// (androidx.compose.animation.core 1.12, read from the shipped bytecode). The Android lyrics engine evaluates its
// line springs with `getValueFromNanos` / `getVelocityFromNanos`; the iOS engine calls the same functions here.
//
// Behaviour that matters for parity:
// - Unit mass. `stiffness` is k, `dampingRatio` is ζ; the natural frequency is √k (stored as a Double).
// - Play time is truncated to **whole milliseconds** (`playTimeNanos / 1_000_000`, integer division) before use.
// - Inputs and outputs are Float; the closed form is evaluated in Double, in the same operation order as Compose.
// - ζ > 1 over-damped, ζ == 1 (exactly) critically damped, otherwise under-damped (ζ = 0 is undamped).

import Foundation

/// Compose's `Spring` object constants.
public enum SpringConstants {
    public static let stiffnessHigh: Float = 10_000
    public static let stiffnessMedium: Float = 1_500
    public static let stiffnessMediumLow: Float = 400
    public static let stiffnessLow: Float = 200
    public static let stiffnessVeryLow: Float = 50
    public static let dampingRatioHighBouncy: Float = 0.2
    public static let dampingRatioMediumBouncy: Float = 0.5
    public static let dampingRatioLowBouncy: Float = 0.75
    public static let dampingRatioNoBouncy: Float = 1
    public static let defaultDisplacementThreshold: Float = 0.01
}

/// A value and velocity pair (Compose's packed `Motion`).
public struct SpringMotion: Sendable, Hashable {
    public var value: Float
    public var velocity: Float

    @inlinable
    public init(value: Float, velocity: Float) {
        self.value = value
        self.velocity = velocity
    }
}

/// Closed-form damped harmonic oscillator — Compose's `SpringSimulation`.
public struct SpringSimulation: Sendable, Hashable {
    /// The rest position the spring is pulled towards.
    public var finalPosition: Float
    /// √stiffness. Compose stores the frequency, not the stiffness.
    public private(set) var naturalFrequency: Double
    /// ζ. Must be ≥ 0.
    public var dampingRatio: Float {
        didSet { precondition(dampingRatio >= 0, "Damping ratio must be non-negative") }
    }

    /// Compose defaults: stiffness 50 (`StiffnessVeryLow`), ζ = 1.
    public init(finalPosition: Float) {
        self.finalPosition = finalPosition
        naturalFrequency = Double(50).squareRoot()
        dampingRatio = 1
    }

    /// k, read back as `(√k)²` rounded to Float, exactly like Compose's getter.
    public var stiffness: Float {
        get { Float(naturalFrequency * naturalFrequency) }
        set { naturalFrequency = Double(newValue).squareRoot() }
    }

    /// Acceleration at a displacement and velocity: `−k·x − c·v` with `c = 2·√k·ζ`.
    public func acceleration(lastDisplacement: Float, lastVelocity: Float) -> Float {
        let adjustedDisplacement = lastDisplacement - finalPosition
        let k = naturalFrequency * naturalFrequency
        let c = 2.0 * naturalFrequency * Double(dampingRatio)
        return Float(-k * Double(adjustedDisplacement) - c * Double(lastVelocity))
    }

    /// Value and velocity `timeElapsedMs` milliseconds after starting at `lastDisplacement` with `lastVelocity`.
    /// Port of `SpringSimulation.updateValues`, same operation order.
    public func updateValues(lastDisplacement: Float, lastVelocity: Float, timeElapsedMs: Int64) -> SpringMotion {
        let adjustedDisplacement = lastDisplacement - finalPosition
        let x0 = Double(adjustedDisplacement)
        let v0 = Double(lastVelocity)
        let deltaT = Double(timeElapsedMs) / 1000.0 // seconds
        let zeta = Double(dampingRatio)
        let dampingRatioSquared = zeta * zeta
        let r = Double(-dampingRatio) * naturalFrequency

        let displacement: Double
        let currentVelocity: Double

        if dampingRatio > 1 {
            // Over-damped.
            let s = naturalFrequency * (dampingRatioSquared - 1.0).squareRoot()
            let gammaPlus = r + s
            let gammaMinus = r - s
            let coeffB = (gammaMinus * x0 - v0) / (gammaMinus - gammaPlus)
            let coeffA = x0 - coeffB
            displacement = coeffA * exp(gammaMinus * deltaT) + coeffB * exp(gammaPlus * deltaT)
            currentVelocity = coeffA * gammaMinus * exp(gammaMinus * deltaT) + coeffB * gammaPlus * exp(gammaPlus * deltaT)
        } else if dampingRatio == 1 {
            // Critically damped.
            let coeffA = x0
            let coeffB = v0 + naturalFrequency * x0
            let nFdT = -naturalFrequency * deltaT
            displacement = (coeffA + coeffB * deltaT) * exp(nFdT)
            currentVelocity = (coeffA + coeffB * deltaT) * exp(nFdT) * -naturalFrequency + coeffB * exp(nFdT)
        } else {
            // Under-damped.
            let dampedFrequency = naturalFrequency * (1.0 - dampingRatioSquared).squareRoot()
            let cosCoeff = x0
            let sinCoeff = (1.0 / dampedFrequency) * (-r * x0 + v0)
            let dFdT = dampedFrequency * deltaT
            displacement = exp(r * deltaT) * (cosCoeff * cos(dFdT) + sinCoeff * sin(dFdT))
            currentVelocity = displacement * r
                + exp(r * deltaT) * (-dampedFrequency * cosCoeff * sin(dFdT) + dampedFrequency * sinCoeff * cos(dFdT))
        }

        return SpringMotion(value: Float(displacement + Double(finalPosition)), velocity: Float(currentVelocity))
    }
}

/// Compose's `FloatSpringSpec(dampingRatio, stiffness, visibilityThreshold)`: a stateless spring you evaluate at a
/// play time. Retarget by restarting from the current value and velocity.
public struct FloatSpringSpec: Sendable, Hashable {
    public let dampingRatio: Float
    public let stiffness: Float
    /// Distance from the target under which the spring counts as visually settled (used by `durationNanos`).
    public let visibilityThreshold: Float
    private let spring: SpringSimulation

    /// Defaults match Compose: ζ = 1 (`DampingRatioNoBouncy`), k = 1500 (`StiffnessMedium`), threshold 0.01.
    public init(dampingRatio: Float = SpringConstants.dampingRatioNoBouncy,
                stiffness: Float = SpringConstants.stiffnessMedium,
                visibilityThreshold: Float = SpringConstants.defaultDisplacementThreshold) {
        self.dampingRatio = dampingRatio
        self.stiffness = stiffness
        self.visibilityThreshold = visibilityThreshold
        var simulation = SpringSimulation(finalPosition: 1)
        simulation.dampingRatio = dampingRatio
        simulation.stiffness = stiffness
        spring = simulation
    }

    /// Value and velocity at `playTimeNanos` (truncated to whole milliseconds, like Compose).
    @inlinable
    public func motionFromNanos(_ playTimeNanos: Int64, initialValue: Float, targetValue: Float,
                                initialVelocity: Float) -> SpringMotion {
        motion(atMillis: playTimeNanos / 1_000_000, initialValue: initialValue, targetValue: targetValue,
               initialVelocity: initialVelocity)
    }

    /// `getValueFromNanos`.
    @inlinable
    public func valueFromNanos(_ playTimeNanos: Int64, initialValue: Float, targetValue: Float,
                               initialVelocity: Float) -> Float {
        motionFromNanos(playTimeNanos, initialValue: initialValue, targetValue: targetValue,
                        initialVelocity: initialVelocity).value
    }

    /// `getVelocityFromNanos`.
    @inlinable
    public func velocityFromNanos(_ playTimeNanos: Int64, initialValue: Float, targetValue: Float,
                                  initialVelocity: Float) -> Float {
        motionFromNanos(playTimeNanos, initialValue: initialValue, targetValue: targetValue,
                        initialVelocity: initialVelocity).velocity
    }

    /// Value and velocity after a whole number of milliseconds.
    public func motion(atMillis playTimeMillis: Int64, initialValue: Float, targetValue: Float,
                       initialVelocity: Float) -> SpringMotion {
        var simulation = spring
        simulation.finalPosition = targetValue
        return simulation.updateValues(lastDisplacement: initialValue, lastVelocity: initialVelocity,
                                       timeElapsedMs: playTimeMillis)
    }

    /// `getEndVelocity`: always 0 for a spring.
    @inlinable
    public func endVelocity(initialValue: Float, targetValue: Float, initialVelocity: Float) -> Float { 0 }

    /// `getDurationNanos`: Compose's estimate of when the spring stays within `visibilityThreshold` of the target.
    public func durationNanos(initialValue: Float, targetValue: Float, initialVelocity: Float) -> Int64 {
        let millis = SpringEstimation.estimateAnimationDurationMillis(
            stiffness: spring.stiffness,
            dampingRatio: spring.dampingRatio,
            initialVelocity: initialVelocity / visibilityThreshold,
            initialDisplacement: (initialValue - targetValue) / visibilityThreshold,
            delta: 1
        )
        return millis &* 1_000_000
    }

    /// The Android lyrics engine's rest test (`SpringChannel.update`): settled when both the distance to the target
    /// and the speed are under their thresholds. Kept here so every port uses the same comparison.
    @inlinable
    public static func isSettled(value: Float, velocity: Float, target: Float, restDelta: Float,
                                 restVelocity: Float) -> Bool {
        abs(value - target) < restDelta && abs(velocity) < restVelocity
    }

    // Equality is by configuration (the simulation is derived from it).
    public static func == (lhs: FloatSpringSpec, rhs: FloatSpringSpec) -> Bool {
        lhs.dampingRatio == rhs.dampingRatio && lhs.stiffness == rhs.stiffness
            && lhs.visibilityThreshold == rhs.visibilityThreshold
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(dampingRatio)
        hasher.combine(stiffness)
        hasher.combine(visibilityThreshold)
    }
}

/// Port of Compose's `SpringEstimation.kt` (`estimateAnimationDurationMillis`).
public enum SpringEstimation {
    /// Returned for ζ = 0 (the spring never settles): `Long.MAX_VALUE / 1_000_000`.
    public static let maxLongMillis: Int64 = Int64.max / 1_000_000

    /// Float overload: ζ == 0 → `maxLongMillis`, otherwise the Double estimate.
    public static func estimateAnimationDurationMillis(stiffness: Float, dampingRatio: Float, initialVelocity: Float,
                                                       initialDisplacement: Float, delta: Float) -> Int64 {
        if dampingRatio == 0 { return maxLongMillis }
        return estimateAnimationDurationMillis(stiffness: Double(stiffness), dampingRatio: Double(dampingRatio),
                                               initialVelocity: Double(initialVelocity),
                                               initialDisplacement: Double(initialDisplacement), delta: Double(delta))
    }

    /// Estimated settle time in milliseconds for a unit-mass spring.
    public static func estimateAnimationDurationMillis(stiffness: Double, dampingRatio: Double, initialVelocity: Double,
                                                       initialDisplacement: Double, delta: Double) -> Int64 {
        let dampingCoefficient = 2.0 * dampingRatio * stiffness.squareRoot()
        let partialRoot = dampingCoefficient * dampingCoefficient - 4.0 * stiffness
        let partialRootReal = partialRoot < 0.0 ? 0.0 : partialRoot.squareRoot()
        let partialRootImaginary = partialRoot < 0.0 ? abs(partialRoot).squareRoot() : 0.0
        let firstRootReal = (-dampingCoefficient + partialRootReal) * 0.5
        let firstRootImaginary = partialRootImaginary * 0.5
        let secondRootReal = (-dampingCoefficient - partialRootReal) * 0.5
        return estimateDurationInternal(firstRootReal: firstRootReal, firstRootImaginary: firstRootImaginary,
                                        secondRootReal: secondRootReal, dampingRatio: dampingRatio,
                                        initialVelocity: initialVelocity, initialPosition: initialDisplacement,
                                        delta: delta)
    }

    static func estimateDurationInternal(firstRootReal: Double, firstRootImaginary: Double, secondRootReal: Double,
                                         dampingRatio: Double, initialVelocity: Double, initialPosition: Double,
                                         delta: Double) -> Int64 {
        if initialPosition == 0.0 && initialVelocity == 0.0 { return 0 }
        let v0 = initialPosition < 0 ? -initialVelocity : initialVelocity
        let p0 = abs(initialPosition)
        let seconds: Double
        if dampingRatio > 1.0 {
            seconds = estimateOverDamped(r1: firstRootReal, r2: secondRootReal, p0: p0, v0: v0, delta: delta)
        } else if dampingRatio < 1.0 {
            seconds = estimateUnderDamped(r: firstRootReal, imaginary: firstRootImaginary, p0: p0, v0: v0, delta: delta)
        } else {
            seconds = estimateCriticallyDamped(r: firstRootReal, p0: p0, v0: v0, delta: delta)
        }
        return KotlinMath.toLong(seconds * 1000.0)
    }

    static func estimateUnderDamped(r: Double, imaginary: Double, p0: Double, v0: Double, delta: Double) -> Double {
        let c1 = p0
        let c2 = (v0 - r * c1) / imaginary
        let c = (c1 * c1 + c2 * c2).squareRoot()
        return log(delta / c) / r
    }

    static func estimateCriticallyDamped(r: Double, p0: Double, v0: Double, delta: Double) -> Double {
        let c1 = p0
        let c2 = v0 - r * c1
        let t1 = log(abs(delta / c1)) / r
        let guess = log(abs(delta / c2))
        var t = guess
        for _ in 0..<6 { t = guess - log(abs(t / r)) }
        let t2 = t / r

        var tCurr: Double
        if !t1.isFinite {
            tCurr = t2
        } else if !t2.isFinite {
            tCurr = t1
        } else {
            tCurr = max(t1, t2)
        }

        let tInflection = -(r * c1 + c2) / (r * c2)
        let xInflection = c1 * exp(r * tInflection) + c2 * tInflection * exp(r * tInflection)
        let signedDelta: Double
        if tInflection.isNaN || tInflection <= 0.0 {
            signedDelta = -delta
        } else if tInflection > 0.0 && -xInflection < delta {
            if c2 < 0 && c1 > 0 { tCurr = 0.0 }
            signedDelta = -delta
        } else {
            tCurr = -(2.0 / r) - (c1 / c2)
            signedDelta = delta
        }

        var tDelta = Double.greatestFiniteMagnitude
        var iterations = 0
        while tDelta > 0.001 && iterations < 100 {
            iterations += 1
            let tLast = tCurr
            let f = (c1 + c2 * tCurr) * exp(r * tCurr) + signedDelta
            let fPrime = (c2 * (r * tCurr + 1) + c1 * r) * exp(r * tCurr)
            tCurr = tCurr - f / fPrime
            tDelta = abs(tLast - tCurr)
        }
        return tCurr
    }

    static func estimateOverDamped(r1: Double, r2: Double, p0: Double, v0: Double, delta: Double) -> Double {
        let c2 = (r1 * p0 - v0) / (r1 - r2)
        let c1 = p0 - c2
        let t1 = log(abs(delta / c1)) / r1
        let t2 = log(abs(delta / c2)) / r2

        var tCurr: Double
        if !t1.isFinite {
            tCurr = t2
        } else if !t2.isFinite {
            tCurr = t1
        } else {
            tCurr = max(t1, t2)
        }

        let tInflection = log((c1 * r1) / (-c2 * r2)) / (r2 - r1)
        func xInflection() -> Double { c1 * exp(r1 * tInflection) + c2 * exp(r2 * tInflection) }
        let signedDelta: Double
        if tInflection.isNaN || tInflection <= 0.0 {
            signedDelta = -delta
        } else if tInflection > 0.0 && -xInflection() < delta {
            if c2 > 0 && c1 < 0 { tCurr = 0.0 }
            signedDelta = -delta
        } else {
            tCurr = log(-(c2 * r2 * r2) / (c1 * r1 * r1)) / (r1 - r2)
            signedDelta = delta
        }

        func fnPrime(_ t: Double) -> Double { c1 * r1 * exp(r1 * t) + c2 * r2 * exp(r2 * t) }
        if abs(fnPrime(tCurr)) < 0.0001 { return tCurr }

        var tDelta = Double.greatestFiniteMagnitude
        var iterations = 0
        while tDelta > 0.001 && iterations < 100 {
            iterations += 1
            let tLast = tCurr
            let f = c1 * exp(r1 * tCurr) + c2 * exp(r2 * tCurr) + signedDelta
            tCurr = tCurr - f / fnPrime(tCurr)
            tDelta = abs(tLast - tCurr)
        }
        return tCurr
    }
}
