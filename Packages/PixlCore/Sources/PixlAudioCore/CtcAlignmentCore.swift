// Frame-exact audio windows and global CTC (Viterbi) alignment for on-device lyric sync, ported from
// data/tais/lyrics/CtcAlignmentCore.kt. Independent of the model runtime (Core ML on iOS, ONNX on Android).

import Foundation

/// Errors of `CtcAlignmentCore.align` (Android: `IllegalArgumentException` / an out-of-bounds index).
public enum CtcAlignmentError: Error, Sendable, Hashable {
    /// frames × states exceeds `maxPathCells` (checked before allocating the back-pointers).
    case tooLong
    /// An extended-sequence entry is not a valid column of the log-probability rows.
    case invalidToken(index: Int, token: Int)

    /// Android's message for `tooLong`.
    public static let tooLongMessage = "This song is too long for safe on-device alignment. Existing lyrics were kept."
}

/// `CtcAlignmentCore`.
public enum CtcAlignmentCore {
    /// wav2vec2 frame stride in samples at 16 kHz (50 frames/s).
    public static let strideSamples = 320
    /// Receptive field of one frame in samples.
    public static let receptiveSamples = 400
    /// Frames kept per window (16 s).
    public static let coreFrames = 800
    /// Context frames on each side of a window (2 s).
    public static let contextFrames = 100
    /// Largest frames × states product aligned (64 Mi back-pointer bytes).
    public static let maxPathCells: Int64 = 64 * 1024 * 1024

    /// One model window: the frames it keeps (`firstFrame..<endFrame`) and the samples it reads.
    public struct Window: Sendable, Hashable {
        public var firstFrame: Int
        public var endFrame: Int
        public var inputStartSample: Int
        public var inputEndSample: Int

        public init(firstFrame: Int, endFrame: Int, inputStartSample: Int, inputEndSample: Int) {
            self.firstFrame = firstFrame
            self.endFrame = endFrame
            self.inputStartSample = inputStartSample
            self.inputEndSample = inputEndSample
        }

        /// Index of `firstFrame` within the window's own output frames.
        public var localFirstFrame: Int { firstFrame - inputStartSample / CtcAlignmentCore.strideSamples }
        /// Frames this window contributes.
        public var keptFrames: Int { endFrame - firstFrame }
    }

    /// Splits `sampleCount` samples into 16 s windows with 2 s of context on each side; together the kept frames
    /// cover every frame exactly once. Empty below one receptive field.
    public static func windows(sampleCount: Int) -> [Window] {
        if sampleCount < receptiveSamples { return [] }
        let totalFrames = (sampleCount - receptiveSamples) / strideSamples + 1
        var result: [Window] = []
        result.reserveCapacity((totalFrames + coreFrames - 1) / coreFrames)
        var first = 0
        while first < totalFrames {
            let end = min(first + coreFrames, totalFrames)
            let inputFirst = max(0, first - contextFrames)
            let inputEnd = min(totalFrames, end + contextFrames)
            result.append(Window(firstFrame: first, endFrame: end, inputStartSample: inputFirst * strideSamples,
                                 inputEndSample: (inputEnd - 1) * strideSamples + receptiveSamples))
            first += coreFrames
        }
        return result
    }

    /// Conservative admission check for a line's word scores (not a calibrated probability): all finite and in
    /// 0…1, mean ≥ 0.45, and at least 75 % of them ≥ 0.3.
    public static func acceptsWordEvidence(_ scores: [Float]) -> Bool {
        guard !scores.isEmpty else { return false }
        guard scores.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return false }
        var sum = 0.0
        for s in scores { sum += Double(s) }
        guard sum / Double(scores.count) >= 0.45 else { return false }
        let strong = scores.reduce(0) { $1 >= 0.3 ? $0 + 1 : $0 }
        return Double(strong) / Double(scores.count) >= 0.75
    }

    /// Viterbi alignment of the CTC `extended` state sequence (blank-interleaved tokens) against per-frame log
    /// probabilities. Blank states stay available for the whole intro, interludes and outro. Returns the state index
    /// for every frame, or nil when no path exists (too few frames, repeated tokens without a separating blank…).
    /// - Parameter checkCancelled: called every 64 frames; throw to abandon (e.g. `Task.checkCancellation`).
    public static func align(logProbs: [[Float]], extended: [Int], blankId: Int = 0,
                             checkCancelled: () throws -> Void = {}) throws -> [Int]? {
        let frames = logProbs.count
        let length = extended.count
        if frames == 0 || length == 0 || frames < (length - 1) / 2 { return nil }
        guard Int64(frames) * Int64(length) <= maxPathCells else { throw CtcAlignmentError.tooLong }
        for row in logProbs {
            for (index, token) in extended.enumerated() where token < 0 || token >= row.count {
                throw CtcAlignmentError.invalidToken(index: index, token: token)
            }
        }
        return try logProbs.withUnsafeBufferPointer { rows in
            try viterbi(frames: frames, extended: extended, blankId: blankId, checkCancelled: checkCancelled) { t, token in
                rows[t][token]
            }
        }
    }

    /// `align` over a flat row-major buffer of `frames × vocabularySize` log probabilities (the model output).
    public static func align(logProbs: UnsafeBufferPointer<Float>, vocabularySize: Int, extended: [Int], blankId: Int = 0,
                             checkCancelled: () throws -> Void = {}) throws -> [Int]? {
        guard vocabularySize > 0 else { return nil }
        let frames = logProbs.count / vocabularySize
        let length = extended.count
        if frames == 0 || length == 0 || frames < (length - 1) / 2 { return nil }
        guard Int64(frames) * Int64(length) <= maxPathCells else { throw CtcAlignmentError.tooLong }
        for (index, token) in extended.enumerated() where token < 0 || token >= vocabularySize {
            throw CtcAlignmentError.invalidToken(index: index, token: token)
        }
        return try viterbi(frames: frames, extended: extended, blankId: blankId, checkCancelled: checkCancelled) { t, token in
            logProbs[t * vocabularySize + token]
        }
    }

    private static func viterbi(frames: Int, extended: [Int], blankId: Int, checkCancelled: () throws -> Void,
                                logProb: (Int, Int) -> Float) rethrows -> [Int]? {
        let length = extended.count
        let negInf = -Float.infinity
        var prev = [Float](repeating: negInf, count: length)
        var curr = [Float](repeating: 0, count: length)
        var backptr = [UInt8](repeating: 0, count: frames * length)
        prev[0] = logProb(0, extended[0])
        if length > 1 { prev[1] = logProb(0, extended[1]) }
        if frames > 1 {
            for t in 1..<frames {
                if t % 64 == 0 { try checkCancelled() }
                let rowOffset = t * length
                for s in 0..<length {
                    var best = prev[s]
                    var move: UInt8 = 0
                    if s >= 1 && prev[s - 1] > best { best = prev[s - 1]; move = 1 }
                    if s >= 2 && extended[s] != blankId && extended[s] != extended[s - 2] && prev[s - 2] > best {
                        best = prev[s - 2]; move = 2
                    }
                    curr[s] = best == negInf ? negInf : best + logProb(t, extended[s])
                    backptr[rowOffset + s] = move
                }
                swap(&prev, &curr)
            }
        }
        var s = (length == 1 || prev[length - 1] >= prev[length - 2]) ? length - 1 : length - 2
        if !prev[s].isFinite { return nil }
        var path = [Int](repeating: 0, count: frames)
        path[frames - 1] = s
        var t = frames - 1
        while t >= 1 {
            s -= Int(backptr[t * length + s])
            path[t - 1] = s
            t -= 1
        }
        return path
    }
}
