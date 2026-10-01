// The line helpers the Android builder took over from `presentation/components/LyricsSheet.kt` (bottom of
// `PreparedLyricsBuilder.kt`: `sanitizeLyricLineText`, `sanitizeSyncedWords`, `clusterSyncedWords`,
// `resolveLineEndTimeMs`) plus `resolveSeekPositionMs` and `LyricsUtils.stripLrcTimestamps`, which they use.
// The Java regexes are reimplemented by hand with their exact (ASCII `\d`/`\s`, ASCII case-insensitive) semantics.

import Foundation
import PixlFoundation
import PixlModel

/// Lyrics-sheet line helpers.
public enum LyricsSheetLogic {

    /// A run of synced words that may not be broken (one word made of syllables).
    public struct SyncedWordCluster: Sendable, Hashable {
        public let startIndex: Int
        public let words: [SyncedWord]

        public init(startIndex: Int, words: [SyncedWord]) {
            self.startIndex = startIndex
            self.words = words
        }
    }

    /// `sanitizeLyricLineText`: strips LRC timestamp tags and a leading `v1:` voice tag, then leading whitespace.
    public static func sanitizeLyricLineText(_ raw: String) -> String {
        removeLeadingVoiceTag(stripLrcTimestamps(raw)).kotlinTrimmedStart()
    }

    /// `sanitizeSyncedWords`: drops a leading `v1:` tag from the first word, trims every word, drops empty words and
    /// makes the first kept word start a new word.
    public static func sanitizeSyncedWords(_ words: [SyncedWord]) -> [SyncedWord] {
        var out: [SyncedWord] = []
        out.reserveCapacity(words.count)
        for (index, word) in words.enumerated() {
            let sanitized = index == 0 ? removeLeadingVoiceTag(word.word) : word.word
            let normalized = sanitized.kotlinTrimmed()
            if normalized.isEmpty { continue }
            var copy = word
            copy.word = normalized
            copy.startsNewWord = out.isEmpty ? true : word.startsNewWord
            out.append(copy)
        }
        return out
    }

    /// `clusterSyncedWords`: a new cluster starts at a word with `startsNewWord`, or whose first UTF-16 unit is CJK
    /// (CJK fragments may wrap anywhere).
    public static func clusterSyncedWords(_ words: [SyncedWord]) -> [SyncedWordCluster] {
        if words.isEmpty { return [] }
        var clusters: [SyncedWordCluster] = []
        var currentWords: [SyncedWord] = []
        var currentStartIndex = 0
        for (index, word) in words.enumerated() {
            let firstIsCjk = word.word.utf16.first.map(PreparedText.isCjk) ?? false
            let canBreakBefore = word.startsNewWord || firstIsCjk
            if canBreakBefore && !currentWords.isEmpty {
                clusters.append(SyncedWordCluster(startIndex: currentStartIndex, words: currentWords))
                currentWords = []
                currentStartIndex = index
            } else if currentWords.isEmpty {
                currentStartIndex = index
            }
            currentWords.append(word)
        }
        if !currentWords.isEmpty {
            clusters.append(SyncedWordCluster(startIndex: currentStartIndex, words: currentWords))
        }
        return clusters
    }

    /// `resolveLineEndTimeMs`: the explicit end when it is after the start; otherwise the next line's start, but at
    /// least one millisecond after the last word starts.
    public static func resolveLineEndTimeMs(_ line: SyncedLine, nextLineStartMs: Int) -> Int64 {
        if let end = line.endTime, end > line.time { return Int64(end) }
        let baseEnd = Int64(nextLineStartMs)
        let lastWordStart = line.words?.map { Int64($0.time) }.max() ?? Int64(line.time)
        return Swift.max(baseEnd, lastWordStart &+ 1)
    }

    /// `resolveSeekPositionMs`: where a tap on a line seeks — the line time minus the additive sync offset, never
    /// below zero.
    public static func resolveSeekPositionMs(lineTimeMs: Int64, lyricsSyncOffsetMs: Int) -> Int64 {
        Swift.max(lineTimeMs &- Int64(lyricsSyncOffsetMs), 0)
    }

    /// `LyricsUtils.stripLrcTimestamps`: removes every `[m:ss]`, `[mm:ss.x]`… tag
    /// (`\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?]`) and then leading whitespace.
    public static func stripLrcTimestamps(_ value: String) -> String {
        if value.isEmpty { return value }
        let u = Array(value.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(u.count)
        var i = 0
        var removed = false
        while i < u.count {
            if u[i] == 0x5B, let end = matchTimestampTag(u, i) {
                i = end
                removed = true
                continue
            }
            out.append(u[i])
            i += 1
        }
        let without = removed ? String(decoding: out, as: UTF16.self) : value
        return without.kotlinTrimmedStart()
    }

    // MARK: - Regex replacements

    @inline(__always)
    static func isAsciiDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    /// Matches `\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?]` at `start`; returns the index after `]`, or nil.
    static func matchTimestampTag(_ u: [UInt16], _ start: Int) -> Int? {
        var i = start + 1
        var digits = 0
        while i < u.count && digits < 2 && isAsciiDigit(u[i]) { i += 1; digits += 1 }
        guard digits >= 1, i < u.count, u[i] == 0x3A else { return nil } // ':'
        i += 1
        guard i + 1 < u.count, isAsciiDigit(u[i]), isAsciiDigit(u[i + 1]) else { return nil }
        i += 2
        // Optional fraction: a separator then 1–3 digits that must be followed by ']'.
        if i < u.count && (u[i] == 0x2E || u[i] == 0x3A) { // '.' or ':'
            var j = i + 1
            var n = 0
            while j < u.count && n < 3 && isAsciiDigit(u[j]) { j += 1; n += 1 }
            if n >= 1 && j < u.count && u[j] == 0x5D { return j + 1 }
        }
        if i < u.count && u[i] == 0x5D { return i + 1 } // ']'
        return nil
    }

    /// `replace(Regex("^v\\d+:\\s*", IGNORE_CASE), "")`: a leading `v<digits>:` tag and the ASCII whitespace after it.
    static func removeLeadingVoiceTag(_ s: String) -> String {
        let u = Array(s.utf16)
        guard let first = u.first, first == 0x76 || first == 0x56 else { return s } // 'v' / 'V'
        var i = 1
        while i < u.count && isAsciiDigit(u[i]) { i += 1 }
        guard i > 1, i < u.count, u[i] == 0x3A else { return s }
        i += 1
        // Java `\s` = [ \t\n\x0B\f\r].
        while i < u.count && (u[i] == 0x20 || (0x09...0x0D).contains(u[i])) { i += 1 }
        return String(decoding: u[i...], as: UTF16.self)
    }
}
