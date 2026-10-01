// Grapheme and word segmentation helpers matching the Android code's use of `java.text.BreakIterator`
// (character instance = extended grapheme clusters, which is what Swift's `Character` is) and its Kotlin
// string conventions (UTF-16 offsets, `isWhitespace`, `trim`, code-unit equality).

import Foundation

/// Text segmentation helpers.
public enum TextSegmentation {

    /// User-perceived characters (extended grapheme clusters) — `BreakIterator.getCharacterInstance()`.
    @inlinable
    public static func graphemes(_ text: String) -> [String] { text.map(String.init) }

    /// Number of graphemes (`PreparedLyricsBuilder.graphemeCount`).
    @inlinable
    public static func graphemeCount(_ text: String) -> Int { text.count }

    /// `EmphasisMath.graphemeBoundaries`: grapheme boundaries as **UTF-16 offsets** `[0, b1, …, utf16Count]`, so
    /// grapheme `i` spans `[out[i], out[i+1])`. The empty string gives `[0]`.
    public static func graphemeBoundariesUTF16(_ text: String) -> [Int] {
        var out = [0]
        out.reserveCapacity(text.utf16.count + 1)
        var offset = 0
        for character in text {
            offset += character.utf16.count
            out.append(offset)
        }
        return out
    }

    /// `PreparedLyricsBuilder.estimateWordCount`: every CJK character (`TextScripts.isCjkChar`) is a word; other runs
    /// of non-whitespace are one word each.
    public static func estimateWordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if TextScripts.isCjkChar(scalar) {
                count += 1
                inWord = false
            } else if TextScripts.isKotlinWhitespace(scalar) {
                inWord = false
            } else if !inWord {
                count += 1
                inWord = true
            }
        }
        return count
    }

    /// Splits on runs of Kotlin whitespace, dropping empty pieces.
    public static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if TextScripts.isKotlinWhitespace(scalar) {
                if !current.isEmpty {
                    out.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }
}

extension String {
    /// Kotlin `trim()`: removes leading and trailing Kotlin whitespace (`Char.isWhitespace`).
    public func kotlinTrimmed() -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !TextScripts.isKotlinWhitespace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !TextScripts.isKotlinWhitespace($0) })!
        return String(scalars[first...last])
    }

    /// Kotlin `trimStart()`.
    public func kotlinTrimmedStart() -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !TextScripts.isKotlinWhitespace($0) }) else { return "" }
        return String(scalars[first...])
    }

    /// Kotlin `trimEnd()`.
    public func kotlinTrimmedEnd() -> String {
        let scalars = unicodeScalars
        guard let last = scalars.lastIndex(where: { !TextScripts.isKotlinWhitespace($0) }) else { return "" }
        return String(scalars[...last])
    }

    /// Kotlin `isBlank()`: empty or only Kotlin whitespace.
    public var isKotlinBlank: Bool { unicodeScalars.allSatisfy(TextScripts.isKotlinWhitespace) }

    /// Kotlin/Java `String.equals`: code-unit equality. Swift's `==` compares canonical equivalence, so "é"
    /// (U+00E9) equals "e\u{301}" in Swift but not in Kotlin; use this where Android's comparison is load-bearing.
    @inlinable
    public func isIdentical(to other: String) -> Bool { utf8.elementsEqual(other.utf8) }

    /// Kotlin `String.length`: the UTF-16 length.
    @inlinable
    public var kotlinLength: Int { utf16.count }

    /// First scalar is Kotlin whitespace (`firstOrNull()?.isWhitespace() == true`). All whitespace is BMP, so the
    /// first scalar decides exactly as the first UTF-16 unit does.
    public var startsWithKotlinWhitespace: Bool {
        unicodeScalars.first.map(TextScripts.isKotlinWhitespace) ?? false
    }

    /// Last scalar is Kotlin whitespace (`lastOrNull()?.isWhitespace() == true`).
    public var endsWithKotlinWhitespace: Bool {
        unicodeScalars.last.map(TextScripts.isKotlinWhitespace) ?? false
    }
}
