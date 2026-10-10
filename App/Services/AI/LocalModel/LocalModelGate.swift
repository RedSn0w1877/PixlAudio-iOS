import Foundation
import Observation
import PixlModel
import os

/// The single gate in front of loading the downloaded AI model (docs/handoff/2026-10-10-crash-diagnostics.md, round 2):
/// every load and every generation goes through `LocalModelRuntime.run` / `prewarm`, which ask here first. The decision
/// itself is `LocalModelGatePolicy` (pure, tested); this reads the system and writes the answer to the event log.
nonisolated enum LocalModelGate {
    /// Who is asking. A request is a person's unless something that starts by itself says otherwise (`automatic`).
    @TaskLocal static var reason: LocalModelReason = .userRequest

    static func canLoad(reason: LocalModelReason = LocalModelGate.reason, log: Bool = true) -> LocalModelDecision {
        let gate = HeavyWorkGate.shared
        let conditions = gate.conditions
        let decision = LocalModelGatePolicy.decide(
            reason: reason, isForeground: conditions.isForeground, safeModeActive: gate.automaticStartsBlocked,
            lowPowerMode: conditions.lowPowerMode, thermal: conditions.thermal,
            availableBytes: availableBytes(), modelBytes: ModelCatalog.llm.bytes)
        if log, case .denied(let why) = decision {
            DiagnosticsLog.shared.log("modelgate", "denied \(reason.rawValue): \(why)")
        }
        return decision
    }

    /// Free memory for this app; `Int64.max` where the system reports none (the simulator returns 0).
    static func availableBytes() -> Int64 {
        let value = Int64(os_proc_available_memory())
        return value > 0 ? value : Int64.max
    }

    static func memoryText() -> String {
        "footprint \(AppHealth.footprintText()), available \(availableBytes() == Int64.max ? "unknown" : "\(availableBytes() / 1_048_576) MB")"
    }
}

/// What the downloaded model is doing, for Active jobs (a row with Waiting / Loading / Generating and a Cancel).
@MainActor
@Observable
final class LocalModelActivity {
    static let shared = LocalModelActivity()

    enum Phase: Equatable { case waiting, loading, generating }

    private(set) var phase: Phase?
    private(set) var failure: String?
    @ObservationIgnored private var pending = 0

    var isBusy: Bool { phase != nil }

    func requestQueued() {
        pending += 1
        if phase == nil { phase = .waiting }
    }

    func set(_ phase: Phase) { if pending > 0 { self.phase = phase } }

    func requestEnded(failure: String?) {
        pending = max(pending - 1, 0)
        if pending == 0 { phase = nil }
        if let failure { self.failure = failure }
    }

    func dismissFailure() { failure = nil }

    /// Cancel on the row, Cancel all and Emergency stop.
    func cancel() { LocalModelRuntime.shared.cancelAll() }
}
