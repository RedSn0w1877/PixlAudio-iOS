import CoreML
import Foundation
import PixlAudioCore

/// English wav2vec2 acoustic alignment on Core ML (Android `TaisWav2Vec2Aligner` on ONNX Runtime). The audio is cut
/// into the model's fixed 10 s windows (`CtcAlignmentCore.fixedWindows`, ≥ 1 s of context on each side of the kept
/// frames), each window normalised and run once; the kept frames form one log-probability timeline and a single
/// global CTC pass (PixlAudioCore) matches the complete lyric text — no guessed line boundaries.
///
/// Runs on the CPU (`.cpuOnly`): that is the configuration the CI parity gate measured against PyTorch, and it keeps
/// working when the app is in the background (background GPU needs an entitlement free signing can't have).
actor Wav2Vec2Aligner {
    private var model: MLModel?
    private var modelURL: URL?

    private func loadModel(at url: URL) throws -> MLModel {
        if let model, modelURL == url { return model }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        model = loaded
        modelURL = url
        return loaded
    }

    /// Releases the model (≈ 190 MB) once a job ends.
    func unload() {
        model = nil
        modelURL = nil
    }

    /// Word timings for `words` over `samples` (16 kHz mono). Empty when there is nothing to align or no CTC path
    /// exists; throws `TaisLyricsAlignment.Failure` when the evidence is too weak. `progress(done, total)` reports
    /// the windows analysed.
    func align(samples: [Float], words: [String], modelURL: URL,
               progress: @Sendable (Int, Int) async -> Void) async throws -> [AlignedWordTiming] {
        guard !words.isEmpty else { return [] }
        let target = CtcTarget(words: words)
        guard target.tokenIds.count > 1 else { return [] }
        let emissions = try await logProbabilities(samples: samples, modelURL: modelURL, progress: progress)
        let vocabulary = Wav2Vec2Vocabulary.size
        let path: [Int]?
        do {
            path = try emissions.withUnsafeBufferPointer { buffer in
                try CtcAlignmentCore.align(logProbs: buffer, vocabularySize: vocabulary, extended: target.tokenIds,
                                           blankId: Wav2Vec2Vocabulary.blankId) { try Task.checkCancellation() }
            }
        } catch CtcAlignmentError.tooLong {
            throw TaisLyricsAlignment.Failure.tooLong
        }
        guard let path else { return [] }
        let evidence = emissions.withUnsafeBufferPointer { buffer in
            CtcWordTimings.evidence(path: path, target: target) { frame, token in buffer[frame * vocabulary + token] }
        }
        guard CtcAlignmentCore.acceptsWordEvidence(evidence) else { throw TaisLyricsAlignment.Failure.notConfident }
        return CtcWordTimings.timings(path: path, target: target, words: words)
    }

    /// The log-probability timeline (row-major `frames × 32`, Android's `emissions`) of `samples`, window by window.
    func logProbabilities(samples: [Float], modelURL: URL,
                          progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> [Float] {
        let inputSamples = ModelCatalog.Wav2Vec2.inputSamples
        let windows = CtcAlignmentCore.fixedWindows(sampleCount: samples.count, inputSamples: inputSamples)
        guard let last = windows.last else { return [] }
        let model = try loadModel(at: modelURL)
        let vocabulary = Wav2Vec2Vocabulary.size
        var emissions = [Float](repeating: 0, count: last.endFrame * vocabulary)
        let input = try MLMultiArray(shape: [1, NSNumber(value: inputSamples)], dataType: .float32)
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            Self.fillNormalised(input, from: samples, range: window.inputStartSample..<window.inputEndSample)
            let provider = try MLDictionaryFeatureProvider(dictionary: [ModelCatalog.Wav2Vec2.input: MLFeatureValue(multiArray: input)])
            let result = try model.prediction(from: provider)
            guard let logits = result.featureValue(for: ModelCatalog.Wav2Vec2.output)?.multiArrayValue,
                  logits.shape.count == 3, logits.shape[2].intValue == vocabulary,
                  logits.shape[1].intValue >= window.localFirstFrame + window.keptFrames else {
                throw TaisLyricsAlignment.Failure.incompleteFrames
            }
            Self.appendLogSoftmax(logits, frames: window.localFirstFrame..<(window.localFirstFrame + window.keptFrames),
                                  into: &emissions, at: window.firstFrame, vocabulary: vocabulary)
            await progress(index + 1, windows.count)
        }
        return emissions
    }

    /// Android `normalize` (double-precision mean and population variance, `std = sqrt(var + 1e-7)`) over the real
    /// samples; the rest of the fixed window (only when the whole song is shorter than 10 s) stays zero.
    static func fillNormalised(_ array: MLMultiArray, from samples: [Float], range: Range<Int>) {
        let count = array.count
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { out, _ in
            var mean = 0.0
            for i in range { mean += Double(samples[i]) }
            mean /= Double(max(range.count, 1))
            var variance = 0.0
            for i in range {
                let d = Double(samples[i]) - mean
                variance += d * d
            }
            variance /= Double(max(range.count, 1))
            let std = (variance + 1e-7).squareRoot()
            var o = 0
            for i in range where o < count {
                out[o] = Float((Double(samples[i]) - mean) / std)
                o += 1
            }
            while o < count {
                out[o] = 0
                o += 1
            }
        }
    }

    /// Log-softmax of the kept frames (Android `logSoftmax`), written into the flat timeline.
    static func appendLogSoftmax(_ logits: MLMultiArray, frames: Range<Int>, into emissions: inout [Float], at firstFrame: Int,
                                 vocabulary: Int) {
        let frameStride = logits.strides[1].intValue
        let tokenStride = logits.strides[2].intValue
        var row = [Float](repeating: 0, count: vocabulary)
        func write(_ value: (Int) -> Float) {
            for (k, frame) in frames.enumerated() {
                var maximum = -Float.infinity
                for v in 0..<vocabulary {
                    row[v] = value(frame * frameStride + v * tokenStride)
                    if row[v] > maximum { maximum = row[v] }
                }
                var sum = 0.0
                for v in 0..<vocabulary { sum += exp(Double(row[v] - maximum)) }
                let logSumExp = Float(log(sum)) + maximum
                let base = (firstFrame + k) * vocabulary
                for v in 0..<vocabulary { emissions[base + v] = row[v] - logSumExp }
            }
        }
        if logits.dataType == .float32 {
            logits.withUnsafeBufferPointer(ofType: Float.self) { buffer in write { buffer[$0] } }
        } else {
            write { logits[$0].floatValue }
        }
    }
}
