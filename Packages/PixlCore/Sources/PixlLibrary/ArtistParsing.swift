// Port of the multi-artist parsing in `utils/Extensions.kt` (`splitArtistsByDelimiters`,
// `extractArtistsFromTitle`, `normalizeMetadataText`) and `data/worker/ArtistParsingUtils.kt`.
//
// The Android code builds java.util.regex patterns (case-insensitive with Kotlin's implicit UNICODE_CASE) and
// splits with Kotlin's `Regex.split`. Swift's Regex has different whitespace, case and grapheme semantics, so the
// two patterns are matched here by hand with java.util.regex's exact backtracking order over UTF-16 code units.
// `ArtistParsingGoldenTests` checks thousands of inputs against the compiled Android code.

import Foundation
import PixlFoundation

/// Splitting artist strings into individual artists.
public enum ArtistParsing {
    /// Default word delimiters (`DEFAULT_WORD_DELIMITERS` / `DEFAULT_ARTIST_WORD_DELIMITERS`), matched
    /// case-insensitively between whitespace.
    public static let defaultWordDelimiters = [
        "featuring", "feat.", "feat", "ft.", "ft", "vs.", "vs", "versus", "with", "prod.", "prod",
    ]

    /// Default character delimiters (`UserPreferencesRepository.DEFAULT_ARTIST_DELIMITERS`).
    public static let defaultArtistDelimiters = [";"]

    /// The delimiters older versions stored as the default; reading them back yields `defaultArtistDelimiters`.
    public static let legacyDefaultArtistDelimiters = ["/", ";", ",", "+", "&"]

    /// `normalizeLegacyDefaultArtistDelimiters`.
    public static func normalizeLegacyDefaultArtistDelimiters(_ delimiters: [String]) -> [String] {
        let isLegacy = delimiters.count == legacyDefaultArtistDelimiters.count
            && zip(delimiters, legacyDefaultArtistDelimiters).allSatisfy { KotlinText.equals($0, $1) }
        return isLegacy ? defaultArtistDelimiters : delimiters
    }

    /// Escape sequence before a delimiter that prevents splitting there: two backslashes (`AC\\/DC`).
    static let escapeSequence = "\\\\"
    static let escapePlaceholder = "\u{0}ESCAPED\u{0}"

    /// `String.splitArtistsByDelimiters`: splits by character delimiters and word delimiters (case-insensitive,
    /// between whitespace; one-character word delimiters such as "x" need spaces on both sides), honouring escaped
    /// delimiters. Returns trimmed, distinct, non-empty names; a single-element list when nothing splits.
    public static func split(_ text: String, delimiters: [String],
                             wordDelimiters: [String] = defaultWordDelimiters) -> [String] {
        ArtistSplitter(delimiters: delimiters, wordDelimiters: wordDelimiters).split(text)
    }

    /// `String.extractArtistsFromTitle`: finds `(feat. …)`, `[ft. …]`, `(with …)`, `(prod. …)` groups, splits
    /// their contents and removes them from the title.
    public static func extractArtistsFromTitle(_ title: String, delimiters: [String] = [],
                                               wordDelimiters: [String] = defaultWordDelimiters)
        -> (title: String, artists: [String])
    {
        ArtistSplitter(delimiters: delimiters, wordDelimiters: wordDelimiters).extractArtistsFromTitle(title)
    }

    /// `collectArtistNames`: the artists of the artist tag, plus (when enabled) featured artists from the title
    /// that are not already present (case-insensitively).
    public static func collectArtistNames(rawArtistName: String, title: String, artistDelimiters: [String],
                                          wordDelimiters: [String] = [], extractFromTitle: Bool = true) -> [String] {
        ArtistSplitter(delimiters: artistDelimiters, wordDelimiters: wordDelimiters)
            .collectArtistNames(rawArtistName: rawArtistName, title: title, extractFromTitle: extractFromTitle)
    }

    /// `choosePreferredArtistName`: between the file's own tag and the media index's value, prefer the one that
    /// names more artists, then the longer one, then the media index's.
    public static func choosePreferredArtistName(localArtistName: String, mediaStoreArtistName: String,
                                                 artistDelimiters: [String], wordDelimiters: [String] = []) -> String {
        let localTrimmed = localArtistName.kotlinTrimmed()
        let mediaTrimmed = mediaStoreArtistName.kotlinTrimmed()
        if localTrimmed.isKotlinBlank { return mediaStoreArtistName }
        if mediaTrimmed.isKotlinBlank { return localArtistName }
        let splitter = ArtistSplitter(delimiters: artistDelimiters, wordDelimiters: wordDelimiters)
        let localArtists = splitter.split(localTrimmed)
        let mediaArtists = splitter.split(mediaTrimmed)
        if mediaArtists.count > localArtists.count { return mediaStoreArtistName }
        if localArtists.count > mediaArtists.count { return localArtistName }
        if mediaTrimmed.utf16.count > localTrimmed.utf16.count { return mediaStoreArtistName }
        if localTrimmed.utf16.count > mediaTrimmed.utf16.count { return localArtistName }
        return mediaStoreArtistName
    }

    /// `joinArtistsForDisplay`.
    public static func joinForDisplay(_ artists: [String], separator: String = ", ") -> String {
        artists.joined(separator: separator)
    }
}

/// A prepared `splitArtistsByDelimiters` pattern for one delimiter configuration; reuse it across a library scan.
public struct ArtistSplitter: Sendable {
    let delimiters: [String]
    let sortedDelimiters: [String]
    let escapes: [(escaped: String, placeholder: String, delimiter: String)]
    let alternatives: [SplitAlternative]
    let isEmpty: Bool

    public init(delimiters: [String], wordDelimiters: [String] = ArtistParsing.defaultWordDelimiters) {
        self.delimiters = delimiters
        isEmpty = delimiters.isEmpty && wordDelimiters.isEmpty
        sortedDelimiters = delimiters.kotlinSorted { cmp($1.utf16.count, $0.utf16.count) }
        escapes = sortedDelimiters.enumerated().map { index, delimiter in
            let placeholder = "\(ArtistParsing.escapePlaceholder)\(index)\(ArtistParsing.escapePlaceholder)"
            return (ArtistParsing.escapeSequence + delimiter, placeholder, delimiter)
        }
        var alternatives: [SplitAlternative] = []
        for word in wordDelimiters.kotlinSorted(by: { cmp($1.utf16.count, $0.utf16.count) }) {
            let literal = JavaLiteral(word)
            if word.utf16.count == 1 {
                alternatives.append(.spaced(literal))
            } else {
                alternatives.append(.spaced(literal))
                alternatives.append(.spacedAtEnd(literal))
                alternatives.append(.atStartSpaced(literal))
            }
        }
        for delimiter in sortedDelimiters { alternatives.append(.literal(JavaLiteral(delimiter))) }
        self.alternatives = alternatives
    }

    /// `splitArtistsByDelimiters`.
    public func split(_ text: String) -> [String] {
        func whole() -> [String] {
            let trimmed = text.kotlinTrimmed()
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if isEmpty || text.isKotlinBlank || alternatives.isEmpty { return whole() }
        var working = text
        for escape in escapes { working = KotlinText.replace(working, escape.escaped, escape.placeholder) }
        let parts = kotlinRegexSplit(Array(working.utf16), alternatives)
        let restored = parts.map { part -> String in
            var value = String(decoding: part, as: UTF16.self)
            for escape in escapes { value = KotlinText.replace(value, escape.placeholder, escape.delimiter) }
            return value.kotlinTrimmed()
        }.filter { !$0.isEmpty }.kotlinDistinct()
        return restored.isEmpty ? whole() : restored
    }

    /// `extractArtistsFromTitle`.
    public func extractArtistsFromTitle(_ title: String) -> (title: String, artists: [String]) {
        if title.isKotlinBlank { return (title, []) }
        let units = Array(title.utf16)
        var extracted: [String] = []
        var cleaned = title
        var from = 0
        while from <= units.count, let match = TitleFeatureMatcher.find(units, from: from) {
            let group = String(decoding: units[match.groupStart..<match.groupEnd], as: UTF16.self)
            extracted.append(contentsOf: split(group))
            let value = String(decoding: units[match.start..<match.end], as: UTF16.self)
            cleaned = KotlinText.replace(cleaned, value, "")
            from = match.end == match.start ? match.end + 1 : match.end
        }
        return (cleaned.kotlinTrimmed(), extracted.kotlinDistinct())
    }

    /// `collectArtistNames`.
    public func collectArtistNames(rawArtistName: String, title: String, extractFromTitle: Bool = true) -> [String] {
        let fromArtist = split(rawArtistName)
        if !extractFromTitle { return fromArtist }
        let titleArtists = extractArtistsFromTitle(title).artists
        if titleArtists.isEmpty { return fromArtist }
        var combined = fromArtist
        for titleArtist in titleArtists where !combined.contains(where: { KotlinText.equalsIgnoreCase($0, titleArtist) }) {
            combined.append(titleArtist)
        }
        return combined
    }
}

// MARK: - java.util.regex emulation

/// A quoted literal (`Regex.escape(...)`) matched with CASE_INSENSITIVE | UNICODE_CASE: code points compare after
/// `toLowerCase(toUpperCase(c))`.
struct JavaLiteral {
    let units: [UInt16]
    let folded: [UInt32]

    init(_ s: String) {
        units = Array(s.utf16)
        folded = s.unicodeScalars.map { KotlinText.regexFold($0).value }
    }

    /// The end index when the literal matches at `i`, else nil.
    func match(_ text: [UInt16], at i: Int) -> Int? {
        var position = i
        for f in folded {
            guard position < text.count else { return nil }
            let (scalar, width) = decodeScalar(text, position)
            if KotlinText.regexFold(scalar).value != f { return nil }
            position += width
        }
        return position
    }
}

/// The code point at `i` (a lone surrogate stands for itself) and its UTF-16 width.
@inline(__always)
func decodeScalar(_ text: [UInt16], _ i: Int) -> (Unicode.Scalar, Int) {
    let u = text[i]
    if UTF16.isLeadSurrogate(u), i + 1 < text.count, UTF16.isTrailSurrogate(text[i + 1]) {
        let value = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(text[i + 1]) - 0xDC00)
        return (Unicode.Scalar(value)!, 2)
    }
    return (Unicode.Scalar(UInt32(u)) ?? "\u{FFFD}", 1)
}

@inline(__always)
func isJavaSpace(_ u: UInt16) -> Bool { u == 0x20 || (u >= 0x09 && u <= 0x0D) }

/// Length of the run of `\s` starting at `i`.
@inline(__always)
func spaceRun(_ text: [UInt16], _ i: Int) -> Int {
    var j = i
    while j < text.count, isJavaSpace(text[j]) { j += 1 }
    return j - i
}

/// java.util.regex `$` without MULTILINE: end of input, or before a final line terminator.
func javaDollar(_ text: [UInt16], _ i: Int) -> Bool {
    let end = text.count
    if i < end - 2 { return false }
    if i == end - 2 {
        guard text[i] == 0x0D, text[i + 1] == 0x0A else { return false }
    }
    if i < end {
        let ch = text[i]
        if ch == 0x0A {
            if i > 0 && text[i - 1] == 0x0D { return false }
        } else if !(ch == 0x0D || ch == 0x85 || (ch | 1) == 0x2029) {
            return false
        }
    }
    return true
}

/// The alternatives of the artist-splitting pattern, in pattern order.
enum SplitAlternative {
    /// `\s+L\s+`
    case spaced(JavaLiteral)
    /// `\s+L$`
    case spacedAtEnd(JavaLiteral)
    /// `^L\s+`
    case atStartSpaced(JavaLiteral)
    /// `L`
    case literal(JavaLiteral)

    /// java.util.regex backtracking order: greedy `\s+` tries its longest run first.
    func match(_ text: [UInt16], at i: Int) -> Int? {
        switch self {
        case .spaced(let literal):
            let run = spaceRun(text, i)
            guard run > 0 else { return nil }
            for k in stride(from: run, through: 1, by: -1) {
                if let after = literal.match(text, at: i + k) {
                    let trailing = spaceRun(text, after)
                    if trailing > 0 { return after + trailing }
                }
            }
            return nil
        case .spacedAtEnd(let literal):
            let run = spaceRun(text, i)
            guard run > 0 else { return nil }
            for k in stride(from: run, through: 1, by: -1) {
                if let after = literal.match(text, at: i + k), javaDollar(text, after) { return after }
            }
            return nil
        case .atStartSpaced(let literal):
            guard i == 0, let after = literal.match(text, at: 0) else { return nil }
            let trailing = spaceRun(text, after)
            return trailing > 0 ? after + trailing : nil
        case .literal(let literal):
            return literal.match(text, at: i)
        }
    }
}

/// Kotlin `CharSequence.split(regex)` over `Matcher.find()` (empty matches advance the search by one).
func kotlinRegexSplit(_ text: [UInt16], _ alternatives: [SplitAlternative]) -> [ArraySlice<UInt16>] {
    func find(from: Int) -> (start: Int, end: Int)? {
        var i = from
        while i <= text.count {
            for alternative in alternatives {
                if let end = alternative.match(text, at: i) { return (i, end) }
            }
            i += 1
        }
        return nil
    }
    guard var match = find(from: 0) else { return [text[...]] }
    var result: [ArraySlice<UInt16>] = []
    var lastStart = 0
    while true {
        result.append(text[lastStart..<max(lastStart, match.start)])
        lastStart = match.end
        let next = match.end == match.start ? match.end + 1 : match.end
        guard next <= text.count, let found = find(from: next) else { break }
        match = found
    }
    result.append(text[min(lastStart, text.count)...])
    return result
}

/// `[\(\[]\\?\s*(?:featuring|feat\.|feat|ft\.|ft|with|prod\.|prod)\s+(.+?)\s*[\)\]]`, case-insensitive.
enum TitleFeatureMatcher {
    static let keywords = ["featuring", "feat.", "feat", "ft.", "ft", "with", "prod.", "prod"].map(JavaLiteral.init)

    struct Match {
        let start: Int, end: Int, groupStart: Int, groupEnd: Int
    }

    /// java.util.regex `.` without DOTALL: anything but a line terminator.
    @inline(__always)
    static func isDot(_ u: UInt16) -> Bool { !(u == 0x0A || u == 0x0D || (u | 1) == 0x2029 || u == 0x85) }

    static func find(_ text: [UInt16], from: Int) -> Match? {
        var i = from
        while i < text.count {
            if let m = match(text, at: i) { return m }
            i += 1
        }
        return nil
    }

    static func match(_ text: [UInt16], at start: Int) -> Match? {
        guard start < text.count, text[start] == 0x28 || text[start] == 0x5B else { return nil }
        let afterOpen = start + 1
        // `\\?` is greedy: with the backslash first, then without.
        var backslashOptions = [afterOpen]
        if afterOpen < text.count, text[afterOpen] == 0x5C { backslashOptions.insert(afterOpen + 1, at: 0) }
        for p0 in backslashOptions {
            let run0 = spaceRun(text, p0)
            for k0 in stride(from: run0, through: 0, by: -1) {
                let p1 = p0 + k0
                for keyword in keywords {
                    guard let p2 = keyword.match(text, at: p1) else { continue }
                    let run1 = spaceRun(text, p2)
                    guard run1 > 0 else { continue }
                    for k1 in stride(from: run1, through: 1, by: -1) {
                        let groupStart = p2 + k1
                        // `(.+?)` is lazy: shortest group first, each followed by greedy `\s*` and a closer.
                        var groupEnd = groupStart
                        while groupEnd < text.count, isDot(text[groupEnd]) {
                            groupEnd += 1
                            let run2 = spaceRun(text, groupEnd)
                            for k2 in stride(from: run2, through: 0, by: -1) {
                                let q = groupEnd + k2
                                if q < text.count, text[q] == 0x29 || text[q] == 0x5D {
                                    return Match(start: start, end: q + 1, groupStart: groupStart, groupEnd: groupEnd)
                                }
                            }
                        }
                    }
                }
            }
        }
        return nil
    }
}

// MARK: - Metadata text

/// `normalizeMetadataText`: repairs UTF-8 text that was decoded as Windows-1252 ("CafÃ©" → "Café"), drops NULs
/// and applies NFC.
public enum MetadataText {
    static let suspiciousPatterns = ["Ã", "â", "\u{FFFD}", "ð", "Ÿ"]

    public static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.kotlinTrimmed()
        if trimmed.isEmpty { return trimmed }
        let units = Array(trimmed.utf16)
        let needsFix = suspiciousPatterns.contains { KotlinText.utf16IndexOf(units, Array($0.utf16), from: 0) != nil }
        var candidate = trimmed
        if needsFix {
            let bytes = Windows1252.encode(trimmed)
            let reencoded = String(decoding: bytes, as: UTF8.self).kotlinTrimmed()
            if !reencoded.isEmpty { candidate = reencoded }
        }
        let cleaned = KotlinText.replace(candidate, "\u{0}", "")
        return KotlinText.nfc(cleaned)
    }

    /// `normalizeMetadataTextOrEmpty`.
    public static func normalizeOrEmpty(_ value: String?) -> String { normalize(value) ?? "" }
}

/// Java's `windows-1252` encoder: unmappable code points become `?`.
enum Windows1252 {
    static let high: [UInt32: UInt8] = [
        0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87,
        0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91,
        0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98,
        0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
    ]

    static func encode(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf16.count)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v < 0x80 || (v >= 0xA0 && v <= 0xFF) {
                out.append(UInt8(v))
            } else if let mapped = high[v] {
                out.append(mapped)
            } else if v == 0x81 || v == 0x8D || v == 0x8F || v == 0x90 || v == 0x9D {
                out.append(UInt8(v))
            } else {
                out.append(0x3F)
            }
        }
        return out
    }
}
