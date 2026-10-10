import CoreML
import Foundation

/// Which compute units the on-device Core ML models use (the wav2vec2 aligner and the MDX-Net separator).
///
/// Foreground, cool phone, no Low Power Mode: `.cpuAndNeuralEngine` (the Neural Engine runs the layers it supports, the
/// CPU the rest; the CI parity gate measured both models on CPU_ONLY and ALL and shipped the first precision that passed
/// both). Anything else, and after any failure of that path: `.cpuOnly`, which also works inside a background window.
/// The GPU is never used for these: a backgrounded app may not submit GPU work, and the 2026-10-08 crash report shows
/// what happens to one that does (docs/handoff/2026-10-10-crash-diagnostics.md).
nonisolated enum ModelCompute {
    /// Round 2 (a device log showed a crash loop and the Neural Engine path had never run on a phone): back to `.cpuOnly`,
    /// the configuration the parity gate measured, until a phone shows the Neural Engine is safe and faster. The pacer
    /// still keeps the CPU under half a core's worth.
    static let allowsNeuralEngine = false

    static func units(forceCPU: Bool) -> MLComputeUnits {
        allowsNeuralEngine && !forceCPU && HeavyWorkGate.shared.prefersNeuralEngine ? .cpuAndNeuralEngine : .cpuOnly
    }

    /// Loads the model for `units`; a Neural Engine load that throws falls back to the CPU (`onFallback` tells the
    /// caller to stay there).
    static func load(_ url: URL, units: MLComputeUnits, onFallback: () -> Void) throws -> (model: MLModel, units: MLComputeUnits) {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        do {
            let model = try MLModel(contentsOf: url, configuration: configuration)
            DiagnosticsLog.shared.log("model", "loaded for \(units == .cpuOnly ? "CPU" : "Neural Engine + CPU")")
            return (model, units)
        } catch where units != .cpuOnly {
            DiagnosticsLog.shared.log("model", "Neural Engine load failed; using the CPU")
            onFallback()
            let fallback = MLModelConfiguration()
            fallback.computeUnits = .cpuOnly
            return (try MLModel(contentsOf: url, configuration: fallback), .cpuOnly)
        }
    }
}
