import Accelerate
import CoreML
import Foundation
import PixlAudioCore

/// On-device instrumentals (Android `TaisStemSeparator.separateOnDevice`): the song decoded to 44.1 kHz stereo, the
/// MDX-Net vocal model (Core ML, converted on CI with a parity gate against ONNX Runtime) run over 256-frame STFT
/// chunks by PixlAudioCore's `MdxSeparation`, the stereo-linked complementary mask applied to the mix, and the
/// level-matched instrumental written as a 16-bit WAV. The 6144-point DFTs run on vDSP.
actor MdxStemSeparator {
    private var model: MLModel?
    private var modelURL: URL?

    func unload() {
        model = nil
        modelURL = nil
    }

    private func loadModel(at url: URL) throws -> MLModel {
        if let model, modelURL == url { return model }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        model = loaded
        modelURL = url
        return loaded
    }

    /// Renders `source`'s instrumental into `destination` (a complete WAV, written through a temporary file).
    /// `progress(framesDone, totalFrames)` follows the model chunks.
    func renderInstrumental(source: URL, destination: URL, modelURL: URL,
                            progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        let channels = try await AudioPCMReader.read(url: source, sampleRate: Double(MdxSeparation.sampleRate), channels: 2)
        try Task.checkCancellation()
        let left = channels[0], right = channels.count > 1 ? channels[1] : channels[0]
        guard !left.isEmpty else { throw AudioPCMReader.Failure(message: "This song has no audio to separate") }
        let model = try loadModel(at: modelURL)
        let input = try MLMultiArray(shape: [1, 4, NSNumber(value: MdxSeparation.frequencyBins),
                                             NSNumber(value: MdxSeparation.segmentFrames)], dataType: .float32)
        var transform = try VDSPTransform(size: MdxSeparation.fftSize)
        let separated = try MdxSeparation.instrumental(left: left, right: right, transform: &transform, model: { planes, out in
            try Task.checkCancellation()
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                _ = buffer.update(fromContentsOf: planes)
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [ModelCatalog.Mdx.input: MLFeatureValue(multiArray: input)])
            let result = try model.prediction(from: provider)
            guard let vocals = result.featureValue(for: ModelCatalog.Mdx.output)?.multiArrayValue,
                  vocals.count == out.count else { throw MdxSeparation.Failure.nonFiniteModelOutput }
            Self.copyContiguous(vocals, into: out)
        }, progress: { done, total in
            try Task.checkCancellation()
            progress(done, total)
        })
        try Task.checkCancellation()
        let gain = try MdxSeparation.instrumentalGain(mixLeft: left, mixRight: right, left: separated.left,
                                                      right: separated.right)
        try Self.writeWav(left: separated.left, right: separated.right, gain: gain, to: destination)
    }

    /// The model output in NCHW order regardless of its strides / element type.
    static func copyContiguous(_ array: MLMultiArray, into out: UnsafeMutableBufferPointer<Float>) {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        var expected = [Int](repeating: 1, count: shape.count)
        for i in stride(from: shape.count - 2, through: 0, by: -1) { expected[i] = expected[i + 1] * shape[i + 1] }
        if array.dataType == .float32 && strides == expected {
            array.withUnsafeBufferPointer(ofType: Float.self) { source in _ = out.update(fromContentsOf: source) }
            return
        }
        // General path: walk the 4-D index space.
        guard shape.count == 4 else { return }
        var o = 0
        for a in 0..<shape[0] {
            for b in 0..<shape[1] {
                for c in 0..<shape[2] {
                    for d in 0..<shape[3] {
                        let index = a * strides[0] + b * strides[1] + c * strides[2] + d * strides[3]
                        out[o] = array[index].floatValue
                        o += 1
                    }
                }
            }
        }
    }

    /// `writeStereoWav` with the peak-safe gain, streamed in 64k-frame blocks into `<destination>.part`, then moved.
    static func writeWav(left: [Float], right: [Float], gain: Float, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = destination.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        guard fm.createFile(atPath: part.path, contents: nil) else {
            throw AudioPCMReader.Failure(message: "Couldn't write the instrumental")
        }
        let handle = try FileHandle(forWritingTo: part)
        do {
            try handle.write(contentsOf: Data(StereoWav.header(frames: left.count, sampleRate: MdxSeparation.sampleRate)))
            var start = 0
            while start < left.count {
                let end = min(start + 65_536, left.count)
                try handle.write(contentsOf: Data(StereoWav.pcm16(left: left, right: right, range: start..<end, gain: gain)))
                start = end
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: part)
            throw error
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: part, to: destination)
    }
}

/// `SpectralTransform` on vDSP's complex DFT (6144 = 3 × 2¹¹ is a supported length). Inverse scaled by 1/n like
/// PixlAudioCore's portable `Fft.Workspace`. A class so the setups are destroyed with it.
nonisolated final class VDSPTransform: SpectralTransform {
    let size: Int
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private var outRe: [Float]
    private var outIm: [Float]

    init(size: Int) throws {
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(forward, vDSP_Length(size), .INVERSE) else {
            throw MdxSeparation.Failure.transform
        }
        self.size = size
        self.forward = forward
        self.inverse = inverse
        outRe = [Float](repeating: 0, count: size)
        outIm = [Float](repeating: 0, count: size)
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    func transform(re: UnsafeMutableBufferPointer<Float>, im: UnsafeMutableBufferPointer<Float>,
                            inverse isInverse: Bool) throws {
        guard re.count == size, im.count == size, let reIn = re.baseAddress, let imIn = im.baseAddress else {
            throw MdxSeparation.Failure.transform
        }
        let setup = isInverse ? inverse : forward
        let n = size
        outRe.withUnsafeMutableBufferPointer { oRe in
            outIm.withUnsafeMutableBufferPointer { oIm in
                vDSP_DFT_Execute(setup, reIn, imIn, oRe.baseAddress!, oIm.baseAddress!)
                if isInverse {
                    var scale = 1 / Float(n)
                    vDSP_vsmul(oRe.baseAddress!, 1, &scale, reIn, 1, vDSP_Length(n))
                    vDSP_vsmul(oIm.baseAddress!, 1, &scale, imIn, 1, vDSP_Length(n))
                } else {
                    reIn.update(from: oRe.baseAddress!, count: n)
                    imIn.update(from: oIm.baseAddress!, count: n)
                }
            }
        }
    }
}
