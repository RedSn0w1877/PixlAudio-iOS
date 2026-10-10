// Pure rules for being a good citizen while heavy work runs (docs/handoff/2026-10-10-crash-diagnostics.md): nothing
// CPU-heavy keeps running while the app is not in the foreground (unless the system granted a background window), a
// hot phone or Low Power Mode slows the work down, a memory warning slows it further, and the work is spread over time
// (a duty cycle) so the average CPU stays well under half a core's worth. The callers read the system (thermal state,
// Low Power Mode, scene phase) and pass it in; nothing here touches a clock or a thread.

import Foundation

public enum ThermalLevel: Int, Sendable, Comparable, Equatable {
    case nominal = 0, fair, serious, critical

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct HeavyWorkConditions: Sendable, Equatable {
    public var isForeground: Bool
    /// iOS granted time to finish (a background task assertion, a continued-processing task).
    public var hasBackgroundWindow: Bool
    public var thermal: ThermalLevel
    public var lowPowerMode: Bool
    /// A memory warning or pressure event arrived in the last half minute.
    public var recentMemoryPressure: Bool

    public init(isForeground: Bool, hasBackgroundWindow: Bool = false, thermal: ThermalLevel = .nominal,
                lowPowerMode: Bool = false, recentMemoryPressure: Bool = false) {
        self.isForeground = isForeground
        self.hasBackgroundWindow = hasBackgroundWindow
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
        self.recentMemoryPressure = recentMemoryPressure
    }
}

public enum PauseReason: String, Sendable, Equatable {
    case background
    case thermal
}

public enum HeavyWorkVerdict: Sendable, Equatable {
    /// Keep going, but only this share of the time (0.5 = as long asleep as computing).
    case run(dutyCycle: Double)
    case pause(PauseReason)
}

public enum HeavyWorkPolicy {
    /// Average share of the time heavy work may compute in a normal state: ~half a core's worth of CPU.
    public static let baseDutyCycle = 0.5
    public static let fairDutyCycle = 0.35
    public static let lowPowerDutyCycle = 0.3
    public static let memoryPressureDutyCycle = 0.2
    /// The longest sleep one checkpoint inserts.
    public static let maxIdleMs: Int64 = 4_000

    public static func verdict(_ conditions: HeavyWorkConditions) -> HeavyWorkVerdict {
        if !conditions.isForeground && !conditions.hasBackgroundWindow { return .pause(.background) }
        if conditions.thermal >= .serious { return .pause(.thermal) }
        var duty = baseDutyCycle
        if conditions.thermal == .fair { duty = min(duty, fairDutyCycle) }
        if conditions.lowPowerMode { duty = min(duty, lowPowerDutyCycle) }
        if conditions.recentMemoryPressure { duty = min(duty, memoryPressureDutyCycle) }
        return .run(dutyCycle: duty)
    }

    /// How long to sleep after `busyMs` of computing so the share of computing is `dutyCycle`.
    public static func idleMs(afterBusyMs busyMs: Int64, dutyCycle: Double) -> Int64 {
        guard busyMs > 0, dutyCycle > 0, dutyCycle < 1 else { return 0 }
        let idle = Double(busyMs) * (1 - dutyCycle) / dutyCycle
        return min(Int64(idle.rounded()), maxIdleMs)
    }

    /// Whether a model may use the Neural Engine now: the foreground, a cool phone and no Low Power Mode. Everywhere else
    /// the CPU (which also keeps working while the app is in the background; the Neural Engine and GPU do not).
    public static func prefersNeuralEngine(_ conditions: HeavyWorkConditions) -> Bool {
        conditions.isForeground && conditions.thermal <= .fair && !conditions.lowPowerMode
    }

    /// Whether automatic heavy work (the automatic studio, a launch rescan) may start: the foreground, not hot, not in
    /// Low Power Mode, no memory pressure.
    public static func allowsAutomaticStart(_ conditions: HeavyWorkConditions) -> Bool {
        conditions.isForeground && conditions.thermal <= .fair && !conditions.lowPowerMode
            && !conditions.recentMemoryPressure
    }
}
