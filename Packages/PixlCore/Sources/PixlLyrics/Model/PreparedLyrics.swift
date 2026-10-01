// Port of `presentation/lyrics/model/PreparedLyrics.kt`: the immutable, render-ready shape of a song's synced lyrics.
// Built once per lyrics change by `PreparedLyricsBuilder` (off the main thread) and handed to the karaoke view and
// `LyricsEngine`. Nothing in here changes per frame: every per-frame value lives in the engine.
//
// Text offsets (`PreparedSyllable.charStart`/`charEnd`) are **UTF-16 offsets** into `PreparedLine.text`, exactly as
// on Android (Kotlin `String` indices). Use `PreparedLine.substring(utf16From:to:)` or `String.utf16` to map them.

import Foundation
import PixlFoundation

/// The prepared lyrics of one song.
///
/// - `lines` are sorted by `PreparedLine.startMs` and `PreparedLine.index` is the position in this array.
///   `startsSorted` mirrors their start times for the engine's binary search.
/// - `rows` is the visual order: every line appears exactly once, background vocals sit directly above or below the
///   line they belong to, and interlude pseudo-rows sit before the group they lead into.
public struct PreparedLyrics: Sendable, Hashable {
    public let lines: [PreparedLine]
    public let rows: [PreparedRow]
    public let hasWordTiming: Bool
    public let hasDuet: Bool
    public let startsSorted: [Int64]

    /// Longest `endMs - startMs` of any line (≥ 0); bounds the backward scan of the hot-set lookup.
    public let maxLineDurationMs: Int64

    /// Latest end of any line: once playback passes it the song's lyrics are over.
    public let lastEndMs: Int64

    public init(lines: [PreparedLine], rows: [PreparedRow], hasWordTiming: Bool, hasDuet: Bool, startsSorted: [Int64]) {
        self.lines = lines
        self.rows = rows
        self.hasWordTiming = hasWordTiming
        self.hasDuet = hasDuet
        self.startsSorted = startsSorted
        if let longest = lines.map({ $0.endMs &- $0.startMs }).max() {
            maxLineDurationMs = Swift.max(longest, 0)
        } else {
            maxLineDurationMs = 0
        }
        lastEndMs = lines.map(\.endMs).max() ?? 0
    }

    // Equality and hashing use the stored model only (the two derived values follow from it), like Android.
    public static func == (lhs: PreparedLyrics, rhs: PreparedLyrics) -> Bool {
        lhs.hasWordTiming == rhs.hasWordTiming && lhs.hasDuet == rhs.hasDuet && lhs.lines == rhs.lines
            && lhs.rows == rhs.rows && lhs.startsSorted == rhs.startsSorted
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(lines)
        hasher.combine(rows)
        hasher.combine(hasWordTiming)
        hasher.combine(hasDuet)
        hasher.combine(startsSorted)
    }
}

/// Voice of a line (Android `presentation.lyrics.model.VoiceRole`). Parsed from the `voiceRole` strings `"lead"`,
/// `"background"` and `"duet"`. Named `PreparedVoiceRole` so it never clashes with `PixlModel.VoiceRole` (the string
/// constants of the lyrics JSON).
public enum PreparedVoiceRole: String, Sendable, Hashable, CaseIterable {
    case lead
    case background
    case duet

    /// `VoiceRole.fromRole`: trims and lowercases; `"background"`, `"bg"`, `"x-bg"` → background, `"duet"` → duet,
    /// anything else (or nil) → lead.
    public static func fromRole(_ role: String?) -> PreparedVoiceRole {
        guard let role else { return .lead }
        switch role.kotlinTrimmed().lowercased() {
        case "background", "bg", "x-bg": return .background
        case "duet": return .duet
        default: return .lead
        }
    }
}

/// One lyric line.
public struct PreparedLine: Sendable, Hashable {
    public let index: Int
    public let startMs: Int64
    /// Exclusive end. Explicit when the source said so (`endIsExplicit`); otherwise inferred (next lead line's start,
    /// or an estimate for the last line / a line before an interlude).
    public let endMs: Int64
    public let endIsExplicit: Bool
    public let text: String
    public let role: PreparedVoiceRole
    /// Index of the line this one is grouped under. A background vocal points at its lead line; every other line
    /// (and a background vocal with no lead to attach to) points at itself.
    public let groupLeadIndex: Int
    /// For a grouped background vocal, whether it is drawn above its lead line.
    public let bgAbove: Bool
    /// Word timing, or nil for a line-synced-only line. Character ranges index into `text` (UTF-16) exactly.
    /// Characters not covered by any syllable (spaces, untimed trailing text) are drawn with the unsung colour.
    public let syllables: [PreparedSyllable]?
    public let translation: String?
    public let romanization: String?

    public init(index: Int, startMs: Int64, endMs: Int64, endIsExplicit: Bool, text: String, role: PreparedVoiceRole,
                groupLeadIndex: Int, bgAbove: Bool, syllables: [PreparedSyllable]?, translation: String?,
                romanization: String?) {
        self.index = index
        self.startMs = startMs
        self.endMs = endMs
        self.endIsExplicit = endIsExplicit
        self.text = text
        self.role = role
        self.groupLeadIndex = groupLeadIndex
        self.bgAbove = bgAbove
        self.syllables = syllables
        self.translation = translation
        self.romanization = romanization
    }

    /// True for the line that owns its group: every lead and duet line, and orphan background vocals.
    public var isGroupLead: Bool { groupLeadIndex == index }

    /// A background vocal grouped under another line: collapsed until its group turns hot.
    public var isGroupedBackground: Bool { role == .background && groupLeadIndex != index }

    public var hasWordTiming: Bool { !(syllables?.isEmpty ?? true) }

    /// `wordIndex` of the final word, for the "last word of the line" emphasis boost; -1 if none.
    public var lastWordIndex: Int { syllables?.last?.wordIndex ?? -1 }

    /// The text between two UTF-16 offsets (clamped). A range that splits a surrogate pair decodes the lone half as
    /// U+FFFD (Swift strings cannot hold unpaired surrogates).
    public func substring(utf16From start: Int, to end: Int) -> String {
        PreparedText.substring(text, start, end)
    }
}

/// One timed syllable (or whole word) of a line.
public struct PreparedSyllable: Sendable, Hashable {
    /// Inclusive UTF-16 index into `PreparedLine.text` of the first glyph (no whitespace).
    public let charStart: Int
    /// Exclusive UTF-16 end index; whitespace around the syllable is left out of the range.
    public let charEnd: Int
    public let startMs: Int64
    public let endMs: Int64
    /// Whether the source gave this syllable's end (a `LyricsDoc` duration or a `SyncedWord.endTime`). Inferred ends
    /// never drive emphasis.
    public let endIsExplicit: Bool
    /// Syllables sharing a `wordIndex` form one word (e.g. "su" + "gar").
    public let wordIndex: Int
    /// The word this syllable belongs to qualifies for the long-word glow (spec §1.4).
    public let emphasis: Bool

    public init(charStart: Int, charEnd: Int, startMs: Int64, endMs: Int64, endIsExplicit: Bool, wordIndex: Int,
                emphasis: Bool) {
        self.charStart = charStart
        self.charEnd = charEnd
        self.startMs = startMs
        self.endMs = endMs
        self.endIsExplicit = endIsExplicit
        self.wordIndex = wordIndex
        self.emphasis = emphasis
    }
}

/// A visual row of the lyrics list (Android `Row`).
public enum PreparedRow: Sendable, Hashable {
    /// A lyric line, by index into `PreparedLyrics.lines`.
    case line(lineIndex: Int)
    /// Interlude dots for the instrumental gap `[startMs, endMs)`; `endMs` is the start of the group that follows.
    /// `alignEnd` right-aligns the dots when that group is a duet line.
    case interlude(startMs: Int64, endMs: Int64, alignEnd: Bool)

    /// The line index for a `.line` row, else nil.
    public var lineIndex: Int? {
        if case .line(let index) = self { return index }
        return nil
    }

    public var isInterlude: Bool {
        if case .interlude = self { return true }
        return false
    }
}

// MARK: - UTF-16 helpers (Kotlin `String`/`Char` semantics)

/// Kotlin string operations on UTF-16 code units, so the builder indexes text exactly like Android.
enum PreparedText {
    @inline(__always)
    static func units(_ s: String) -> [UInt16] { Array(s.utf16) }

    @inline(__always)
    static func isSurrogate(_ u: UInt16) -> Bool { (0xD800...0xDFFF).contains(u) }

    /// Kotlin `Char.isWhitespace()` on one UTF-16 unit (surrogates are never whitespace).
    @inline(__always)
    static func isWhitespace(_ u: UInt16) -> Bool {
        if isSurrogate(u) { return false }
        return TextScripts.isKotlinWhitespace(Unicode.Scalar(u)!)
    }

    /// `PreparedLyricsBuilder.isCjk(Char)`: Han/Hiragana/Katakana/Hangul per UTF-16 unit (a surrogate is UNKNOWN).
    @inline(__always)
    static func isCjk(_ u: UInt16) -> Bool {
        if isSurrogate(u) { return false }
        return TextScripts.isCjkChar(Unicode.Scalar(u)!)
    }

    /// `String.substring(start, end)` on UTF-16 offsets, clamped to the text.
    static func substring(_ s: String, _ start: Int, _ end: Int) -> String {
        let u = s.utf16
        let a = Swift.max(0, Swift.min(start, u.count))
        let b = Swift.max(a, Swift.min(end, u.count))
        let from = u.index(u.startIndex, offsetBy: a)
        let to = u.index(from, offsetBy: b - a)
        return String(decoding: u[from..<to], as: UTF16.self)
    }

    static func string(_ units: ArraySlice<UInt16>) -> String { String(decoding: units, as: UTF16.self) }

    /// `CharSequence.indexOf(other, startIndex)` (code-unit match); -1 when absent.
    static func indexOf(_ haystack: [UInt16], _ needle: [UInt16], from start: Int) -> Int {
        let from = Swift.max(start, 0)
        if needle.isEmpty { return Swift.min(from, haystack.count) }
        if needle.count > haystack.count { return -1 }
        let last = haystack.count - needle.count
        if from > last { return -1 }
        var i = from
        while i <= last {
            if haystack[i] == needle[0] {
                var k = 1
                while k < needle.count && haystack[i + k] == needle[k] { k += 1 }
                if k == needle.count { return i }
            }
            i += 1
        }
        return -1
    }

    /// Index of the first unit that is not whitespace, or -1.
    static func firstNonWhitespace(_ u: [UInt16]) -> Int { u.firstIndex { !isWhitespace($0) } ?? -1 }

    /// Index of the last unit that is not whitespace, or -1.
    static func lastNonWhitespace(_ u: [UInt16]) -> Int { u.lastIndex { !isWhitespace($0) } ?? -1 }
}

extension PreparedText {
    /// Stable sort (Kotlin `sortedBy` is stable; Swift's `sorted` does not promise stability).
    static func stableSorted<T, K: Comparable>(_ items: [T], by key: (T) -> K) -> [T] {
        items.enumerated().sorted { lhs, rhs in
            let a = key(lhs.element)
            let b = key(rhs.element)
            return a < b || (a == b && lhs.offset < rhs.offset)
        }.map(\.element)
    }
}
