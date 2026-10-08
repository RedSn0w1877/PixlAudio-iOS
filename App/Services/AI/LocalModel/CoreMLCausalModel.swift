import CoreML
import Foundation
import PixlNet

/// The downloaded AI model's Core ML program (`ci/ml/convert_llm.py`, `ModelCatalog.LocalLLM`) as PixlNet's
/// `CausalLanguageModel`: one stateful prediction per step, the key/value cache kept in an `MLState` (iOS 18) across
/// steps and requests. Confined to `LocalModelRuntime`'s serial queue: Core ML requires predictions that share a
/// state to be serialized, and nothing else touches it.
nonisolated final class CoreMLCausalModel: CausalLanguageModel, @unchecked Sendable {
    nonisolated struct OutputError: LocalizedError {
        var errorDescription: String? { "the model returned no logits" }
    }

    let contextLength: Int
    let maxQueryLength: Int
    let vocabularySize: Int
    let computeUnits: MLComputeUnits

    private let model: MLModel
    private var state: MLState
    private let options = MLPredictionOptions()

    /// Loads the compiled model (the first load on a device also specialises it for the GPU, which takes a while).
    init(compiledURL: URL, computeUnits: MLComputeUnits) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        self.model = model
        self.computeUnits = computeUnits
        state = model.makeState()
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        contextLength = Int(metadata["pixl.context"] ?? "") ?? ModelCatalog.LocalLLM.context
        maxQueryLength = Int(metadata["pixl.maxQuery"] ?? "") ?? ModelCatalog.LocalLLM.maxQuery
        vocabularySize = Int(metadata["pixl.vocab"] ?? "") ?? ModelCatalog.LocalLLM.vocabulary
    }

    /// A fresh cache (every row zero). The generator's `cachedTokens` must be reset with it.
    func resetState() {
        state = model.makeState()
    }

    func step(_ tokens: ArraySlice<Int>, past: Int, logits: inout [Float]) throws {
        let count = tokens.count
        let width = past + count
        let ids = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .int32)
        ids.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, strides in
            let stride = strides.last ?? 1
            for (offset, token) in tokens.enumerated() { buffer[offset * stride] = Int32(truncatingIfNeeded: token) }
        }
        let mask = try MLMultiArray(shape: [1, 1, NSNumber(value: count), NSNumber(value: width)], dataType: .float16)
        mask.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, strides in
            let rowStride = strides[2], columnStride = strides[3]
            for row in 0..<count {
                let attended = past + row
                let base = row * rowStride
                for column in 0..<width {
                    buffer[base + column * columnStride] = column <= attended ? 0 : -Float16.infinity
                }
            }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            ModelCatalog.LocalLLM.inputIds: MLFeatureValue(multiArray: ids),
            ModelCatalog.LocalLLM.causalMask: MLFeatureValue(multiArray: mask),
        ])
        let output = try model.prediction(from: provider, using: state, options: options)
        guard let values = output.featureValue(for: ModelCatalog.LocalLLM.output)?.multiArrayValue else {
            throw OutputError()
        }
        Self.copyLastRow(values, into: &logits)
    }

    /// The `[1, 1, V]` (or `[1, V]`) logits as Float, through the array's own strides.
    static func copyLastRow(_ array: MLMultiArray, into logits: inout [Float]) {
        let count = min(array.shape.last?.intValue ?? 0, logits.count)
        let stride = array.strides.last?.intValue ?? 1
        if logits.count > count {
            for index in count..<logits.count { logits[index] = -.infinity }
        }
        switch array.dataType {
        case .float16:
            array.withUnsafeBufferPointer(ofType: Float16.self) { buffer in
                for index in 0..<count { logits[index] = Float(buffer[index * stride]) }
            }
        case .float32:
            array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                for index in 0..<count { logits[index] = buffer[index * stride] }
            }
        default:
            for index in 0..<count { logits[index] = array[index * stride].floatValue }
        }
    }
}
