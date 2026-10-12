// One decision for "may the downloaded AI model (~900 MB) be loaded now?" (docs/handoff/2026-10-10-crash-diagnostics.md,
// round 2). The 2026-10-10 diagnostics log shows the app killed on every launch by the Home greeting loading the model
// 8 s after launch. Pure: the app passes what it reads from the system.

import Foundation

public enum LocalModelReason: String, Sendable, Equatable {
    /// A person asked an AI feature that needs the model (Taizo's chat, a playlist, a translation).
    case userRequest
    /// Anything the app starts by itself (the Home greeting, headlines, curation, prewarming at launch).
    case automatic
}

public enum LocalModelDecision: Sendable, Equatable {
    case allowed
    case denied(String)

    public var isAllowed: Bool { self == .allowed }
}

public enum LocalModelGatePolicy {
    /// Free memory needed as a multiple of the model's size before it may load.
    public static let memoryHeadroom = 1.5
    /// While loaded or generating, less free memory than this stops everything.
    public static let floorBytes: Int64 = 250_000_000

    public static func decide(reason: LocalModelReason, isForeground: Bool, safeModeActive: Bool, lowPowerMode: Bool,
                              thermal: ThermalLevel, availableBytes: Int64, modelBytes: Int64) -> LocalModelDecision {
        if !isForeground { return .denied("PixlAudio is not in front") }
        if reason == .automatic { return .denied("automatic features never load the downloaded AI model") }
        if safeModeActive {
            return .denied("Safe mode is on because PixlAudio closed unexpectedly. Turn it off in Settings › Developer › Diagnostics to use the downloaded AI model.")
        }
        if lowPowerMode { return .denied("Low Power Mode is on") }
        if thermal >= .serious { return .denied("The phone is too hot") }
        if availableBytes < Int64(Double(modelBytes) * memoryHeadroom) { return .denied("Not enough memory on this phone") }
        return .allowed
    }
}

extension SafeModePolicy {
    /// The previous run died with the downloaded model in flight: the setting that uses it is turned off, so a crash loop
    /// cannot repeat.
    public static func blamesLocalModel(_ inFlight: [InFlightEntry]) -> Bool {
        inFlight.contains { $0.kind == "localModel" }
    }
}
