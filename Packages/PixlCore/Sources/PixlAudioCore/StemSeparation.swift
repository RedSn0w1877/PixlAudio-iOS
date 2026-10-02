// Stem separation ("Magic Instrumentalize"), the runtime-independent half: ported from
// data/tais/stems/StemAudioQuality.kt, the STFT → model → mask → inverse-STFT loop of
// data/tais/stems/TaisStemSeparator.kt, and the file rules of data/tais/TaisInstrumentalIndex.kt. The model itself
// (MDX-Net, Core ML on iOS) is injected as a closure, so the whole pipeline is testable without it.

import Foundation
import PixlFoundation

/// `StemAudioQuality`: deterministic reconstruction rules; both channels share a mask and a peak-safe linear gain.
public enum StemAudioQuality {
    public enum Failure: Error, Sendable, Hashable {
        case nonFiniteModelOutput
        case nonFiniteAudio
    }

    /// The stereo-linked instrumental mask for one bin: `1 − √(vocal / mix) × smoothstep((f − 55) / 95)`, so the
    /// sub-bass is protected and separation fades in smoothly over 55–150 Hz.
    public static func linkedInstrumentalMask(mixPower: Float, vocalPower: Float, frequencyHz: Float) throws(Failure) -> Float {
        guard mixPower.isFinite, vocalPower.isFinite else { throw .nonFiniteModelOutput }
        if mixPower <= 1e-12 { return 1 }
        let vocalFraction = (max(vocalPower, 0) / mixPower).squareRoot().coerced(in: 0, 1)
        let blend = ((frequencyHz - 55) / 95).coerced(in: 0, 1)
        let smoothBlend = blend * blend * (3 - 2 * blend)
        return (1 - vocalFraction * smoothBlend).coerced(in: 0, 1)
    }

    /// `peakSafeGain`: `desiredGain` clamped to 0.5…2, lowered so the louder channel peaks at 0.98.
    public static func peakSafeGain(left: [Float], right: [Float], desiredGain: Float) throws(Failure) -> Float {
        var peak: Float = 0
        for i in left.indices {
            guard left[i].isFinite, right[i].isFinite else { throw .nonFiniteAudio }
            peak = max(peak, abs(left[i]), abs(right[i]))
        }
        return peak <= 1e-8 ? 1 : min(desiredGain.coerced(in: 0.5, 2), 0.98 / peak)
    }
}

/// An in-place complex DFT of one fixed length (inverse scaled by 1/n). `Fft.Workspace` is the portable one; the
/// app passes a vDSP-backed one.
public protocol SpectralTransform {
    var size: Int { get }
    mutating func transform(re: UnsafeMutableBufferPointer<Float>, im: UnsafeMutableBufferPointer<Float>,
                            inverse: Bool) throws
}

extension Fft.Workspace: SpectralTransform {}

/// The MDX-Net separation loop (`TaisStemSeparator.separateChannelPair`): 6144-point periodic-Hann STFT, hop 1024,
/// reflect padding, 256-frame chunks overlapping by 25 % with triangular weights, the model's vocal prediction turned
/// into the stereo-linked complementary mask applied to the mix spectrum (mix phase kept), weighted overlap-add.
public enum MdxSeparation {
    public static let sampleRate = 44_100
    public static let fftSize = 6144
    /// `dim_f`: the one-sided spectrum with the Nyquist bin dropped.
    public static let frequencyBins = 3072
    public static let hop = 1024
    /// `dim_t`: frames per model chunk (~5.9 s).
    public static let segmentFrames = 256
    public static let chunkOverlap: Float = 0.25
    /// Flat make-up gain on the instrumental before the peak-safe limit.
    public static let instrumentalGainDb: Float = 1.5
    /// Floats in one model input or output: [1, 4, 3072, 256], planes L-re, L-im, R-re, R-im.
    public static var planeCount: Int { 4 * frequencyBins * segmentFrames }

    public enum Failure: Error, Sendable, Hashable {
        case emptyAudio
        case nonFiniteModelOutput
        case transform
    }

    /// Runs the model on one chunk: `input` holds the mix spectrum planes, `output` must receive the predicted vocal
    /// planes (same layout, `planeCount` floats each).
    public typealias Model = (_ input: UnsafeBufferPointer<Float>, _ output: UnsafeMutableBufferPointer<Float>) throws -> Void

    /// Periodic Hann window.
    public static func hannWindowPeriodic(_ size: Int) -> [Float] {
        (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
    }

    /// `reflectPad` (numpy "reflect" with Android's clamping for very short input).
    public static func reflectPad(_ x: [Float], pad: Int) -> [Float] {
        let n = x.count
        guard n > 0 else { return [Float](repeating: 0, count: 2 * pad) }
        var out = [Float](repeating: 0, count: n + 2 * pad)
        for i in 0..<pad { out[i] = x[(pad - i).coerced(in: 0, n - 1)] }
        for i in 0..<n { out[pad + i] = x[i] }
        for i in 0..<pad { out[pad + n + i] = x[(n - 2 - i).coerced(in: 0, n - 1)] }
        return out
    }

    /// `triangularWeight`.
    public static func triangularWeight(_ t: Int, chunkLength: Int) -> Float {
        if chunkLength <= 1 { return 1 }
        let mid = Float(chunkLength - 1) / 2
        return max(1 - abs(Float(t) - mid) / (mid + 1), 0.05)
    }

    /// Frames of a padded signal.
    public static func frameCount(paddedLength: Int) -> Int { 1 + (paddedLength - fftSize) / hop }

    /// Chunk starts and lengths for `totalFrames` (stride 192 frames).
    public static func chunks(totalFrames: Int) -> [(start: Int, length: Int)] {
        let stride = max(Int(Float(segmentFrames) * (1 - chunkOverlap)), 1)
        var out: [(Int, Int)] = []
        var start = 0
        while start < totalFrames {
            let length = min(segmentFrames, totalFrames - start)
            out.append((start, length))
            if start + length >= totalFrames { break }
            start += stride
        }
        return out
    }

    /// Separates 44.1 kHz stereo into the instrumental (before gain). `progress(framesDone, totalFrames)` is called
    /// after every chunk and may throw to cancel.
    public static func instrumental<T: SpectralTransform>(left: [Float], right: [Float], transform: inout T,
                                                          model: Model,
                                                          progress: (Int, Int) throws -> Void = { _, _ in }) throws -> (left: [Float], right: [Float]) {
        guard !left.isEmpty, left.count == right.count, transform.size == fftSize else { throw Failure.emptyAudio }
        let window = hannWindowPeriodic(fftSize)
        let leftPadded = reflectPad(left, pad: fftSize / 2)
        let rightPadded = reflectPad(right, pad: fftSize / 2)
        let paddedLength = leftPadded.count
        let totalFrames = frameCount(paddedLength: paddedLength)
        var accumLeft = [Float](repeating: 0, count: paddedLength)
        var accumRight = [Float](repeating: 0, count: paddedLength)
        var weightSum = [Float](repeating: 0, count: paddedLength)
        var input = [Float](repeating: 0, count: planeCount)
        var output = [Float](repeating: 0, count: planeCount)
        var stereoMask = [Float](repeating: 0, count: frequencyBins)
        var re = [Float](repeating: 0, count: fftSize)
        var im = [Float](repeating: 0, count: fftSize)
        let planeSize = frequencyBins * segmentFrames

        func fft(inverse: Bool) throws {
            try re.withUnsafeMutableBufferPointer { r in
                try im.withUnsafeMutableBufferPointer { i in try transform.transform(re: r, im: i, inverse: inverse) }
            }
        }

        for chunk in chunks(totalFrames: totalFrames) {
            // Forward STFT of both channels into the NCHW planes.
            for (channel, padded) in [leftPadded, rightPadded].enumerated() {
                let reBase = 2 * channel * planeSize
                let imBase = (2 * channel + 1) * planeSize
                for t in 0..<segmentFrames {
                    if t < chunk.length {
                        let start = (chunk.start + t) * hop
                        for i in 0..<fftSize {
                            re[i] = padded[start + i] * window[i]
                            im[i] = 0
                        }
                        try fft(inverse: false)
                    }
                    for f in 0..<frequencyBins {
                        let offset = f * segmentFrames + t
                        input[reBase + offset] = t < chunk.length ? re[f] : 0
                        input[imBase + offset] = t < chunk.length ? im[f] : 0
                    }
                }
            }
            try input.withUnsafeBufferPointer { i in try output.withUnsafeMutableBufferPointer { o in try model(i, o) } }

            for t in 0..<chunk.length {
                let w = triangularWeight(t, chunkLength: chunk.length)
                let sampleStart = (chunk.start + t) * hop
                for channel in 0..<2 {
                    let reBase = 2 * channel * planeSize
                    let imBase = (2 * channel + 1) * planeSize
                    for f in 0..<frequencyBins {
                        let offset = f * segmentFrames + t
                        if channel == 0 {
                            var mixPower: Float = 0
                            var vocalPower: Float = 0
                            for plane in 0..<4 {
                                let mixed = input[plane * planeSize + offset]
                                let predicted = output[plane * planeSize + offset]
                                mixPower += mixed * mixed
                                vocalPower += predicted * predicted
                            }
                            do {
                                stereoMask[f] = try StemAudioQuality.linkedInstrumentalMask(
                                    mixPower: mixPower, vocalPower: vocalPower,
                                    frequencyHz: Float(f) * Float(sampleRate) / Float(fftSize))
                            } catch {
                                throw Failure.nonFiniteModelOutput
                            }
                        }
                        let mask = stereoMask[f]
                        let r = input[reBase + offset] * mask
                        let i = input[imBase + offset] * mask
                        re[f] = r
                        im[f] = i
                        if f > 0 {
                            re[fftSize - f] = r
                            im[fftSize - f] = -i
                        }
                    }
                    re[frequencyBins] = 0   // dropped Nyquist bin
                    im[frequencyBins] = 0
                    try fft(inverse: true)
                    if channel == 0 {
                        for i in 0..<fftSize { accumLeft[sampleStart + i] += re[i] * window[i] * w }
                    } else {
                        for i in 0..<fftSize { accumRight[sampleStart + i] += re[i] * window[i] * w }
                    }
                }
                for i in 0..<fftSize { weightSum[sampleStart + i] += window[i] * window[i] * w }
            }
            try progress(min(chunk.start + chunk.length, totalFrames), totalFrames)
        }

        let trimStart = fftSize / 2
        var outLeft = [Float](repeating: 0, count: left.count)
        var outRight = [Float](repeating: 0, count: right.count)
        for i in 0..<min(left.count, max(paddedLength - trimStart, 0)) {
            let w = weightSum[trimStart + i]
            let divisor = w > 1e-8 ? w : 1
            outLeft[i] = accumLeft[trimStart + i] / divisor
            outRight[i] = accumRight[trimStart + i] / divisor
        }
        return (outLeft, outRight)
    }

    /// The instrumental's linear gain: RMS-matched to the mix, plus the flat make-up, limited by `peakSafeGain`.
    public static func instrumentalGain(mixLeft: [Float], mixRight: [Float], left: [Float], right: [Float]) throws -> Float {
        let mixRms = rms(mixLeft, mixRight)
        let instrumentalRms = rms(left, right)
        let rmsMatch = instrumentalRms > 1e-6 ? mixRms / instrumentalRms : 1
        let flat = Float(pow(10, Double(instrumentalGainDb) / 20))
        return try StemAudioQuality.peakSafeGain(left: left, right: right, desiredGain: rmsMatch * flat)
    }

    static func rms(_ left: [Float], _ right: [Float]) -> Float {
        var sum = 0.0
        for i in left.indices { sum += Double(left[i]) * Double(left[i]) + Double(right[i]) * Double(right[i]) }
        return Float((sum / max(2.0 * Double(left.count), 1)).squareRoot())
    }
}

/// 16-bit PCM stereo WAV (the stems' format, `writeStereoWavHeaderAndData`).
public enum StereoWav {
    /// The 44-byte header for `frames` stereo 16-bit frames.
    public static func header(frames: Int, sampleRate: Int) -> [UInt8] {
        let dataSize = UInt32(truncatingIfNeeded: frames * 4)
        var out: [UInt8] = []
        out.reserveCapacity(44)
        func u32(_ v: UInt32) { for k in 0..<4 { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(k)))) } }
        func u16(_ v: UInt16) { out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8)) }
        out += Array("RIFF".utf8); u32(36 &+ dataSize); out += Array("WAVE".utf8)
        out += Array("fmt ".utf8); u32(16); u16(1); u16(2); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(16)
        out += Array("data".utf8); u32(dataSize)
        return out
    }

    /// Interleaved little-endian 16-bit samples for `range`, each `(sample × gain)` clamped to −1…1, scaled by
    /// 32767 and truncated toward zero (Kotlin `toInt().toShort()`).
    public static func pcm16(left: [Float], right: [Float], range: Range<Int>, gain: Float = 1) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: range.count * 4)
        var o = 0
        for i in range {
            for v in [left[i], right[i]] {
                let s = Int16(truncatingIfNeeded: Int((v * gain).coerced(in: -1, 1) * Float(Int16.max)))
                out[o] = UInt8(truncatingIfNeeded: UInt16(bitPattern: s))
                out[o + 1] = UInt8(truncatingIfNeeded: UInt16(bitPattern: s) >> 8)
                o += 2
            }
        }
        return out
    }
}

/// `TaisInstrumentalIndex`'s file rules: `<songId>_instrumental.wav` (on-device MDX-Net) and
/// `<songId>_hq_roformer_inst.wav` (cloud BS-RoFormer, preferred when complete).
public enum StemFiles {
    public static let instrumentalSuffix = "_instrumental.wav"
    public static let roformerSuffix = "_hq_roformer_inst.wav"

    /// File names to try for a song, best first.
    public static func candidates(songId: String) -> [String] {
        let safe = safeName(songId)
        return [safe + roformerSuffix, safe + instrumentalSuffix]
    }

    /// The song id a stem file belongs to.
    public static func songId(fileName: String) -> String? {
        for suffix in [instrumentalSuffix, roformerSuffix] where fileName.hasSuffix(suffix) {
            return String(fileName.dropLast(suffix.count))
        }
        return nil
    }

    /// Song ids as file names (iOS ids contain ':' and '/', e.g. `f:<root>/<path>`): anything outside
    /// `[A-Za-z0-9._-]` becomes `_` followed by its scalar value in hex, so the mapping stays one-to-one.
    public static func safeName(_ songId: String) -> String {
        var out = ""
        for scalar in songId.unicodeScalars {
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "-": out.unicodeScalars.append(scalar)
            default: out += "_" + String(scalar.value, radix: 16) + "_"
            }
        }
        return out
    }

    /// `isCompleteStem`: longer than a WAV header; a RIFF/WAVE file must hold all the bytes its header declares
    /// (an interrupted write never hides an earlier complete render); other containers (cloud backends may return
    /// encoded audio) count as complete.
    public static func isCompleteStem(firstBytes: [UInt8], fileLength: Int64) -> Bool {
        guard fileLength > 44, firstBytes.count >= 12 else { return false }
        guard firstBytes[0..<4].elementsEqual(Array("RIFF".utf8)) else { return true }
        var declared: Int64 = 0
        for k in 0..<4 { declared |= Int64(firstBytes[4 + k]) << (8 * Int64(k)) }
        return firstBytes[8..<12].elementsEqual(Array("WAVE".utf8)) && declared + 8 <= fileLength
    }
}
