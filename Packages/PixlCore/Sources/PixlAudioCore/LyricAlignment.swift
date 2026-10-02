// On-device lyric sync ("TAIS" forced alignment), the runtime-independent half: ported from
// data/tais/lyrics/TaisWav2Vec2Aligner.kt (vocabulary, CTC target, word timings, acoustic evidence) and
// data/tais/lyrics/TaisLyricsAligner.kt (alignment state, target words, line assembly, the checks before a write).
// iOS-only: fixed-length windows for the Core ML model (10 s input, see `CtcAlignmentCore.fixedWindows`) and the
// `LyricsDoc` the result is saved as.

import Foundation
import PixlFoundation
import PixlModel

/// wav2vec2-base-960h's character vocabulary (Android `assets/tais/wav2vec2_vocab.json`).
public enum Wav2Vec2Vocabulary {
    /// Tokens by id.
    public static let tokens: [String] = ["<pad>", "<s>", "</s>", "<unk>", "|", "E", "T", "A", "O", "N", "I", "H",
                                          "S", "R", "D", "L", "U", "M", "W", "C", "F", "G", "Y", "P", "B", "V", "K",
                                          "'", "X", "J", "Q", "Z"]
    public static var size: Int { tokens.count }
    /// `<pad>` doubles as the CTC blank (`pad_token_id = 0`).
    public static let blankId = 0
    /// `|` separates words.
    public static let wordBoundaryId = 4
    /// 16 kHz / 320 samples per frame = 20 ms per frame.
    public static let msPerFrame = 20.0
    public static let sampleRate = 16_000

    private static let ids: [Unicode.Scalar: Int] = {
        var map: [Unicode.Scalar: Int] = [:]
        for (id, token) in tokens.enumerated() where token.unicodeScalars.count == 1 {
            map[token.unicodeScalars.first!] = id
        }
        return map
    }()

    /// The id of a single-scalar token (`A`…`Z`, `'`, `|`).
    public static func id(for scalar: Unicode.Scalar) -> Int? { ids[scalar] }
}

/// The CTC-extended target for a list of words (`buildExtendedTarget`): blank, s1, blank, s2, …, blank
/// (`2 × symbols + 1` states), with a `|` symbol between words. `wordStateRanges[i]` is word i's slice of extended
/// indices (first and last symbol state; the states between step by 2) — nil for a word with nothing alignable
/// (digits, punctuation, other scripts).
public struct CtcTarget: Sendable, Hashable {
    public let tokenIds: [Int]
    public let wordStateRanges: [ClosedRange<Int>?]

    private static let apostrophe: Unicode.Scalar = "'"
    private static let latinCapitals: ClosedRange<Unicode.Scalar> = "A"..."Z"

    public init(words: [String]) {
        var symbols: [Int] = []
        var ranges = [ClosedRange<Int>?](repeating: nil, count: words.count)
        var previousWordEmitted = false
        for (i, word) in words.enumerated() {
            // Kotlin `uppercase().filter { it == '\'' || it in 'A'..'Z' }`, per scalar (combining marks drop out).
            let scalars = word.uppercased().unicodeScalars.filter { $0 == Self.apostrophe || Self.latinCapitals.contains($0) }
            if scalars.isEmpty { continue }
            if previousWordEmitted { symbols.append(Wav2Vec2Vocabulary.wordBoundaryId) }
            let start = symbols.count
            for scalar in scalars {
                if let id = Wav2Vec2Vocabulary.id(for: scalar) { symbols.append(id) }
            }
            if symbols.count == start { continue }
            ranges[i] = (2 * start + 1)...(2 * (symbols.count - 1) + 1)
            previousWordEmitted = true
        }
        var extended = [Int](repeating: Wav2Vec2Vocabulary.blankId, count: symbols.count * 2 + 1)
        for (i, symbol) in symbols.enumerated() { extended[2 * i + 1] = symbol }
        tokenIds = extended
        wordStateRanges = ranges
    }
}

/// One aligned word (`TaisWav2Vec2Aligner.WordTiming`).
public struct AlignedWordTiming: Sendable, Hashable {
    public var word: String
    public var startMs: Int
    public var endMs: Int

    public init(word: String, startMs: Int, endMs: Int) {
        self.word = word
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// Reading word timings and confidence out of a CTC path (`wordTimingsFromPath` and the evidence pass of `align`).
public enum CtcWordTimings {
    /// `frameToMs`: `(frame × 20.0).toInt()`.
    public static func frameToMs(_ frame: Int) -> Int { Int(Double(frame) * Wav2Vec2Vocabulary.msPerFrame) }

    /// First and last frame of every word's symbols. A word with nothing alignable sits at the previous word's end.
    public static func timings(path: [Int], target: CtcTarget, words: [String]) -> [AlignedWordTiming] {
        var firstFrame: [Int: Int] = [:]
        var lastFrame: [Int: Int] = [:]
        for (t, state) in path.enumerated() where target.tokenIds[state] != Wav2Vec2Vocabulary.blankId {
            if firstFrame[state] == nil { firstFrame[state] = t }
            lastFrame[state] = t
        }
        var out: [AlignedWordTiming] = []
        out.reserveCapacity(words.count)
        var lastKnownEndFrame = 0
        for (i, word) in words.enumerated() {
            guard let range = target.wordStateRanges[i] else {
                out.append(AlignedWordTiming(word: word, startMs: frameToMs(lastKnownEndFrame),
                                             endMs: frameToMs(lastKnownEndFrame)))
                continue
            }
            let startFrame = range.compactMap { firstFrame[$0] }.min() ?? lastKnownEndFrame
            let endFrame = range.compactMap { lastFrame[$0] }.max() ?? startFrame
            lastKnownEndFrame = endFrame
            out.append(AlignedWordTiming(word: word, startMs: frameToMs(startFrame), endMs: frameToMs(endFrame)))
        }
        return out
    }

    /// Per alignable word, the mean over its symbols of the peak probability the path gave that symbol (Android's
    /// "acoustic evidence"; feed it to `CtcAlignmentCore.acceptsWordEvidence`).
    /// - Parameter logProb: log probability of `token` at `frame`.
    public static func evidence(path: [Int], target: CtcTarget, logProb: (_ frame: Int, _ token: Int) -> Float) -> [Float] {
        var peaks = [Float](repeating: 0, count: target.tokenIds.count)
        for (frame, state) in path.enumerated() {
            let token = target.tokenIds[state]
            if token != Wav2Vec2Vocabulary.blankId { peaks[state] = max(peaks[state], exp(logProb(frame, token))) }
        }
        return target.wordStateRanges.compactMap { range -> Float? in
            guard let range else { return nil }
            var sum = 0.0
            var count = 0
            var state = range.lowerBound
            while state <= range.upperBound {
                sum += Double(peaks[state])
                count += 1
                state += 2
            }
            return Float(sum / Double(count))
        }
    }
}

extension CtcAlignmentCore {
    /// Output frames of a wav2vec2 pass over `samples` samples (0 below one receptive field).
    public static func frameCount(samples: Int) -> Int {
        samples < receptiveSamples ? 0 : (samples - receptiveSamples) / strideSamples + 1
    }

    /// Context frames on each side of a fixed-length window (1 s).
    public static let fixedContextFrames = 50

    /// Windows for a model with a FIXED input of `inputSamples` samples (iOS: Core ML, 10 s). Every window reads
    /// exactly `inputSamples` samples from `inputStartSample` (a multiple of the stride) — the caller zero-pads only
    /// when the whole song is shorter than one window. Kept frames get ≥ 1 s of context on both sides except at the
    /// song's edges (the last window slides back to end at the song's last frame instead of padding), and together
    /// cover every frame exactly once. `inputEndSample` is the end of the real audio read (≤ `sampleCount`).
    public static func fixedWindows(sampleCount: Int, inputSamples: Int,
                                    contextFrames: Int = fixedContextFrames) -> [Window] {
        let totalFrames = frameCount(samples: sampleCount)
        let inputFrames = frameCount(samples: inputSamples)
        guard totalFrames > 0, inputFrames > 2 * contextFrames else { return [] }
        let core = inputFrames - 2 * contextFrames
        var result: [Window] = []
        result.reserveCapacity(totalFrames / core + 1)
        var first = 0
        while first < totalFrames {
            let end = min(first + core, totalFrames)
            var startFrame = first - contextFrames
            if startFrame + inputFrames > totalFrames { startFrame = totalFrames - inputFrames }
            startFrame = max(0, startFrame)
            let startSample = startFrame * strideSamples
            result.append(Window(firstFrame: first, endFrame: end, inputStartSample: startSample,
                                 inputEndSample: min(sampleCount, startSample + inputSamples)))
            first += core
        }
        return result
    }
}

/// `TaisLyricsAligner`'s pure parts: which lyrics need alignment, the words aligned, and turning timings into lines.
public enum TaisLyricsAlignment {
    /// The `LyricsDoc` source (and lyrics-table source) of acoustic sync results.
    public static let source = "tais"
    /// The user's own tap sync ("Sync it yourself"), which TAIS never overwrites unless asked.
    public static let userSource = "user"

    /// `AlignmentState`.
    public enum AlignmentState: Sendable, Hashable {
        /// Every non-blank synced line has (non-degenerate) word timings.
        case wordSynced
        /// Line timings only (or degenerate word timings from a failed earlier run).
        case lineSyncedOnly([SyncedLine])
        /// Text without timing.
        case plainTextOnly([String])
        case noLyrics
    }

    /// Android's failure messages (shown in the studio card).
    public enum Failure: Error, Sendable, Hashable {
        case incompleteFrames
        case notConfident
        case incomplete
        case inconsistent
        case noUsableTiming
        case tooLong

        public var message: String {
            switch self {
            case .incompleteFrames: "The acoustic model returned incomplete audio frames. Existing lyrics were kept."
            case .notConfident:
                "The model could not confidently match the vocals. Existing lyrics were kept; try finding synced lyrics."
            case .incomplete: "The acoustic model could not align the full lyrics. Existing lyrics were kept."
            case .inconsistent: "The acoustic model returned inconsistent timings. Existing lyrics were kept."
            case .noUsableTiming: "No usable word timing was produced. Existing lyrics were kept."
            case .tooLong: CtcAlignmentError.tooLongMessage
            }
        }
    }

    /// `alignmentStateFor`. `forceResync` distrusts existing timings but keeps the selected text.
    public static func alignmentState(for lyrics: Lyrics?, forceResync: Bool = false) -> AlignmentState {
        if forceResync {
            let synced = lyrics?.synced ?? []
            let lines = synced.isEmpty ? (lyrics?.plain ?? []) : synced.map(\.line)
            return lines.contains { !$0.isKotlinBlank } ? .plainTextOnly(lines) : .noLyrics
        }
        if let synced = lyrics?.synced, !synced.isEmpty {
            let nonBlank = synced.filter { !$0.line.isKotlinBlank }
            let hasWordTimings = !nonBlank.isEmpty && nonBlank.allSatisfy { !($0.words ?? []).isEmpty }
            let looksDegenerate = hasWordTimings && nonBlank.allSatisfy { ($0.words ?? []).allSatisfy { $0.time == 0 } }
            return hasWordTimings && !looksDegenerate ? .wordSynced : .lineSyncedOnly(synced)
        }
        if let plain = lyrics?.plain, !plain.isEmpty { return .plainTextOnly(plain) }
        return .noLyrics
    }

    /// The text lines to align for a state (nil when there is nothing to align).
    public static func lines(for state: AlignmentState) -> [String]? {
        switch state {
        case .plainTextOnly(let lines): lines
        case .lineSyncedOnly(let lines): lines.map(\.line)
        case .wordSynced, .noLyrics: nil
        }
    }

    /// A word to align and the line it belongs to.
    public struct TargetWord: Sendable, Hashable {
        public var lineIndex: Int
        public var word: String
    }

    /// `line.split(Regex("\\s+")).filter { it.isNotBlank() }` for every line (Java `\s` is ASCII whitespace).
    public static func targetWords(lines: [String]) -> [TargetWord] {
        var out: [TargetWord] = []
        for (index, line) in lines.enumerated() {
            for piece in splitOnAsciiWhitespace(line) where !piece.isKotlinBlank {
                out.append(TargetWord(lineIndex: index, word: piece))
            }
        }
        return out
    }

    static func splitOnAsciiWhitespace(_ line: String) -> [String] {
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in line.unicodeScalars {
            switch scalar {
            case " ", "\t", "\n", "\u{0B}", "\u{0C}", "\r":
                if !current.isEmpty { pieces.append(String(current)); current = String.UnicodeScalarView() }
            default:
                current.append(scalar)
            }
        }
        if !current.isEmpty { pieces.append(String(current)) }
        return pieces
    }

    /// `forceAlign`'s checks and line assembly: every word timed, some start after 0, starts within the song and
    /// non-decreasing. Lines keep their text; a line without words starts where the previous one's words ended.
    public static func assemble(lines: [String], targetWords: [TargetWord], timings: [AlignedWordTiming],
                                totalDurationMs: Int) throws(Failure) -> [SyncedLine] {
        guard timings.count == targetWords.count, timings.contains(where: { $0.startMs > 0 }) else {
            throw .incomplete
        }
        let starts = timings.map(\.startMs)
        guard starts.allSatisfy({ $0 >= 0 && $0 <= totalDurationMs }),
              zip(starts, starts.dropFirst()).allSatisfy({ $0 <= $1 }) else { throw .inconsistent }
        var wordsByLine: [Int: [SyncedWord]] = [:]
        for (i, target) in targetWords.enumerated() {
            wordsByLine[target.lineIndex, default: []].append(
                SyncedWord(time: starts[i], word: target.word, startsNewWord: true, endTime: timings[i].endMs))
        }
        var result: [SyncedLine] = []
        var lastKnownTime = 0
        for (index, text) in lines.enumerated() {
            let words = wordsByLine[index]
            let lineTime = words?.first?.time ?? lastKnownTime
            lastKnownTime = words?.last?.time ?? lastKnownTime
            result.append(SyncedLine(time: lineTime, line: text, words: words))
        }
        return result
    }

    /// `persistAligned`'s precondition: some word timing, some after 0, none negative, non-decreasing.
    public static func validateForSave(_ lines: [SyncedLine]) throws(Failure) {
        let words = lines.flatMap { $0.words ?? [] }
        guard !words.isEmpty, words.contains(where: { $0.time > 0 }), words.allSatisfy({ $0.time >= 0 }),
              zip(words, words.dropFirst()).allSatisfy({ $0.time <= $1.time }) else { throw .noUsableTiming }
    }

    /// Minimum length of a line's last word (it has no following word to end at).
    public static let lastWordMinimumMs = 120
    /// What the last word of a line keeps after its last aligned frame (one frame).
    public static let lastWordTailMs = 20

    /// The aligned lines as a `LyricsDoc` (iOS stores the document rather than Android's enhanced LRC, so word ends
    /// are explicit): one syllable per word, text joined with single spaces; a word ends where the next one in its
    /// line starts, a line's last word one frame after its last aligned frame (≥ 120 ms) but never past the next
    /// line's start or the song's end. Lines without words (spacers) are left out — the karaoke view shows the gap
    /// as an interlude.
    public static func lyricsDoc(lines: [SyncedLine], totalDurationMs: Int, title: String = "", artist: String = "",
                                 album: String = "") -> LyricsDoc {
        let timed = lines.filter { !($0.words ?? []).isEmpty }
        let duration = Int64(max(totalDurationMs, 1))
        var docLines: [TimedLine] = []
        for (index, line) in timed.enumerated() {
            let words = line.words ?? []
            let nextLineStart = index + 1 < timed.count ? Int64(timed[index + 1].time) : duration
            var syllables: [TimedSyllable] = []
            var lineEnd = Int64(line.time) + 1
            for (w, word) in words.enumerated() {
                let start = min(Int64(word.time), duration - 1)
                var end: Int64
                if w + 1 < words.count {
                    end = min(Int64(words[w + 1].time), duration)
                } else {
                    let aligned = Int64((word.endTime ?? word.time) + lastWordTailMs)
                    end = max(aligned, start + Int64(lastWordMinimumMs))
                    if nextLineStart > start { end = min(end, nextLineStart) }
                    end = min(end, duration)
                }
                let length = max(end - start, 1)
                let text = w + 1 < words.count ? word.word + " " : word.word
                syllables.append(TimedSyllable(startMs: start, durationMs: length, text: text))
                lineEnd = max(lineEnd, start + length)
            }
            let text = syllables.map(\.text).joined()
            docLines.append(TimedLine(startMs: Int64(line.time), endMs: min(max(lineEnd, Int64(line.time) + 1), duration),
                                      text: text, syllables: syllables))
        }
        return LyricsDoc(metadata: LyricsMetadata(title: title, artist: artist, album: album, durationMs: duration,
                                                  source: source),
                         lines: docLines)
    }
}
