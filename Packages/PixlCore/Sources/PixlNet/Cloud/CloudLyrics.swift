// Cloud Studio lyrics both ways (design §2.3 `lyrics.json`, §7.1 `CloudLyrics`, §7.5 step 3):
// - the known lyrics a song already has, as the request's `lyrics.lines` (capped like the worker caps them);
// - the worker's `pixl.cloudstudio.lyrics` v1 as a PixlAudio `LyricsDoc`. Words are rebuilt from their UTF-16
//   offsets `[c0, c1)` into the ORIGINAL line text (the aligner strips punctuation), so a line's syllables always join
//   to exactly its text; any line whose offsets don't add up falls back to line timing.

import Foundation
import PixlFoundation
import PixlModel

public enum CloudLyrics {
    /// `LyricsDoc` source of aligned results, and of machine-written (transcribed) ones.
    public static let source = "cloud"
    public static let transcribedSource = "cloud-ai"

    // MARK: Request

    /// The request's lines from a song's lyrics: synced lines with their times (end = the next line's start), else
    /// plain lines without times. Blank lines are dropped; the worker's line and character caps apply.
    public static func requestLines(_ lyrics: Lyrics?) -> (lines: [CloudLyricsInputLine], hasLineTimes: Bool)? {
        guard let lyrics else { return nil }
        if let synced = lyrics.synced, synced.contains(where: { !$0.line.isKotlinBlank }) {
            let timed = synced.filter { !$0.line.isKotlinBlank }
            var lines: [CloudLyricsInputLine] = []
            for (index, line) in timed.enumerated() {
                let next = index + 1 < timed.count ? Int64(timed[index + 1].time) : nil
                let end = line.endTime.map(Int64.init) ?? next
                lines.append(CloudLyricsInputLine(startMs: Int64(max(line.time, 0)),
                                                  endMs: end.map { max($0, Int64(line.time) + 1) },
                                                  text: line.line))
            }
            return (capped(lines), true)
        }
        let plain = (lyrics.plain ?? []).filter { !$0.isKotlinBlank }
        guard !plain.isEmpty else { return nil }
        return (capped(plain.map { CloudLyricsInputLine(startMs: nil, endMs: nil, text: $0) }), false)
    }

    static func capped(_ lines: [CloudLyricsInputLine]) -> [CloudLyricsInputLine] {
        var out: [CloudLyricsInputLine] = []
        var chars = 0
        for line in lines.prefix(CloudLimits.maxLyricsLines) {
            chars += line.text.count
            if chars > CloudLimits.maxLyricsChars { break }
            out.append(line)
        }
        return out
    }

    // MARK: Result

    /// How good a set of lyrics is, for "does the result improve on what is stored?".
    public enum Level: Int, Sendable, Comparable {
        case none = 0
        case plain = 1
        case lineSynced = 2
        case wordSynced = 3

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The level of a stored `Lyrics`.
    public static func level(of lyrics: Lyrics?) -> Level {
        guard let lyrics else { return .none }
        if let synced = lyrics.synced?.filter({ !$0.line.isKotlinBlank }), !synced.isEmpty {
            let wordTimed = synced.allSatisfy { !($0.words ?? []).isEmpty }
                && !synced.allSatisfy { ($0.words ?? []).allSatisfy { $0.time == 0 } }
            return wordTimed ? .wordSynced : .lineSynced
        }
        return (lyrics.plain ?? []).contains { !$0.isKotlinBlank } ? .plain : .none
    }

    /// The level of a converted document.
    public static func level(of doc: LyricsDoc) -> Level {
        guard !doc.lines.isEmpty else { return .none }
        return doc.lines.contains { !$0.syllables.isEmpty } ? .wordSynced : .lineSynced
    }

    /// Import only what improves on the stored lyrics, and never over the person's own sync unless they asked.
    public static func shouldImport(stored: Level, incoming: Level, storedIsUserSynced: Bool, replaceUserSynced: Bool) -> Bool {
        if storedIsUserSynced && !replaceUserSynced { return false }
        if storedIsUserSynced && replaceUserSynced { return incoming >= .lineSynced }
        return incoming > stored
    }

    /// The document for `lyrics.json`, or nil when nothing usable is in it. `durationMs` is the song's length (line
    /// ends are clamped to it); title, artist and album go into the metadata.
    public static func lyricsDoc(_ cloud: CloudLyricsDocument, durationMs: Int64, title: String = "",
                                 artist: String = "", album: String = "") -> LyricsDoc? {
        guard cloud.schema == CloudSchema.lyrics, cloud.v == CloudSchema.version else { return nil }
        let duration = durationMs > 0 ? durationMs : (cloud.lines.map(\.endMs).max() ?? 0) + 1
        var lines: [TimedLine] = []
        var previousStart: Int64 = 0
        for line in cloud.lines.sorted(by: { ($0.startMs, $0.i ?? 0) < ($1.startMs, $1.i ?? 0) }) {
            guard !line.text.isKotlinBlank else { continue }
            let start = min(max(line.startMs, previousStart, 0), max(duration - 1, 0))
            var end = min(max(line.endMs, start + 1), duration)
            if end <= start { end = start + 1 }
            var syllables: [TimedSyllable] = []
            if line.isWordTimed, let rebuilt = syllablesFor(line, lineStart: start, lineEnd: end) {
                syllables = rebuilt
                end = max(end, syllables.last.map { $0.startMs + $0.durationMs } ?? end)
                end = min(end, max(duration, start + 1))
            }
            lines.append(TimedLine(startMs: start, endMs: end, text: line.text, syllables: syllables))
            previousStart = start
        }
        guard !lines.isEmpty else { return nil }
        return LyricsDoc(metadata: LyricsMetadata(title: title, artist: artist, album: album, durationMs: duration,
                                                  source: cloud.isTranscribed ? transcribedSource : source),
                         lines: lines)
    }

    /// The syllables of a word-timed line: each covers its word plus the text up to the next word (leading text
    /// joins the first word), timed by the word. Nil when the offsets or times don't hold together.
    static func syllablesFor(_ line: CloudLyricsLine, lineStart: Int64, lineEnd: Int64) -> [TimedSyllable]? {
        let utf16 = Array(line.text.utf16)
        guard let words = line.words, !words.isEmpty else { return nil }
        // Offsets: inside the line, increasing, non-overlapping, never splitting a surrogate pair.
        var previousEnd = 0
        for word in words {
            guard word.c0 >= previousEnd, word.c1 > word.c0, word.c1 <= utf16.count,
                  !splitsSurrogatePair(utf16, at: word.c0), !splitsSurrogatePair(utf16, at: word.c1) else { return nil }
            previousEnd = word.c1
        }
        var syllables: [TimedSyllable] = []
        var lastStart = lineStart
        for (k, word) in words.enumerated() {
            let from = k == 0 ? 0 : word.c0
            let to = k + 1 < words.count ? words[k + 1].c0 : utf16.count
            let text = String(decoding: utf16[from..<to], as: UTF16.self)
            let start = max(word.startMs, lastStart)
            guard start < lineEnd + 5_000 else { return nil } // a word far outside its line: distrust the line
            let end = max(word.endMs, start + 1)
            syllables.append(TimedSyllable(startMs: start, durationMs: end - start, text: text))
            lastStart = start
        }
        guard syllables.map(\.text).joined() == line.text else { return nil }
        return syllables
    }

    static func splitsSurrogatePair(_ utf16: [UInt16], at index: Int) -> Bool {
        guard index > 0, index < utf16.count else { return false }
        return UTF16.isTrailSurrogate(utf16[index]) && UTF16.isLeadSurrogate(utf16[index - 1])
    }

    /// The import precondition for word timing (Android `persistAligned`): some word timing, some after 0, none
    /// negative, starts non-decreasing. Line-only documents pass when they have lines.
    public static func isUsable(_ doc: LyricsDoc) -> Bool {
        let syllables = doc.lines.flatMap(\.syllables)
        if syllables.isEmpty { return !doc.lines.isEmpty && doc.lines.contains { $0.startMs > 0 || $0.endMs > 1 } }
        let starts = syllables.map(\.startMs)
        return starts.contains { $0 > 0 } && starts.allSatisfy { $0 >= 0 }
            && zip(starts, starts.dropFirst()).allSatisfy { $0 <= $1 }
    }
}
