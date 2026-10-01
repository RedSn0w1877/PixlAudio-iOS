// Port of the Android `utils/TtmlLyricsParser.kt`: TTML (Apple Music style, prefixed `tt:` documents, SMIL
// wrappers) → enhanced LRC text that `LyricsUtils.parseLyrics` then reads. Every `<p>` with a begin time (its own,
// or its first timed `<span>`) becomes `[mm:ss.xx]` + its text; a timed `<span>` becomes a `<mm:ss.xx>` word tag;
// `<br>` breaks the line. Agents, roles (background vocals, translations) and end times are not interpreted — the
// Android parser keeps only the text, in document order. DOCTYPEs and external entities are rejected.

import Foundation
import PixlFoundation

public enum TtmlLyricsParser {
    /// Documents with more paragraphs are rejected.
    public static let maxParagraphs = 5_000

    /// Enhanced LRC for a TTML document, or nil when it is not well-formed XML, has no (or too many) paragraphs, or
    /// yields no timed text.
    public static func parseToEnhancedLrc(_ ttmlText: String) -> String? {
        let normalized = normalizeTtmlDocument(ttmlText)
        if ParseKit.isBlank(normalized) { return nil }
        guard let root = try? LyricsXMLParser.parse(normalized) else { return nil }
        let paragraphs = (root.localName.isIdentical(to: "p") ? [root] : []) + root.descendants(localName: "p")
        if paragraphs.isEmpty || paragraphs.count > maxParagraphs { return nil }

        var entries: [(order: Int, beginMs: Int32, line: String)] = []
        do {
            for (index, paragraph) in paragraphs.enumerated() {
                guard let beginMs = try resolveParagraphStartMs(paragraph) else { continue }
                let body = normalizeParagraphBody(try serializeChildren(paragraph))
                if ParseKit.isBlank(body) { continue }
                entries.append((index, beginMs, "[" + ParseKit.lrcTimestamp(beginMs) + "]" + body))
            }
        } catch {
            return nil // Android: `runCatching` around the whole conversion (e.g. a NaN time).
        }
        let text = entries.sorted { $0.beginMs != $1.beginMs ? $0.beginMs < $1.beginMs : $0.order < $1.order }
            .map(\.line).joined(separator: "\n")
        return ParseKit.isBlank(text) ? nil : text
    }

    /// Strips leading whitespace/BOM/format characters and an `<?xml …?>` declaration.
    static func normalizeTtmlDocument(_ raw: String) -> String {
        let withoutLeadingNoise = ParseKit.trim(raw, end: false) {
            ParseKit.isWhitespace($0) || $0.value == 0xFEFF || ParseKit.isFormatChar($0)
        }
        if ParseKit.hasPrefixIgnoringASCIICase(withoutLeadingNoise, "<?xml") {
            return ParseKit.substringAfter(withoutLeadingNoise, "?>", missing: withoutLeadingNoise).kotlinTrimmedStart()
        }
        return withoutLeadingNoise
    }

    private struct RoundingNaN: Error {}

    /// The paragraph's `begin`, else the first descendant `<span>` with a parseable `begin`.
    private static func resolveParagraphStartMs(_ paragraph: LyricsXMLNode) throws -> Int32? {
        if let ms = try parseTimeExpression(paragraph.attribute("begin")) { return ms }
        for span in paragraph.descendants(localName: "span") {
            if let ms = try parseTimeExpression(span.attribute("begin")) { return ms }
        }
        return nil
    }

    private static func serializeChildren(_ node: LyricsXMLNode) throws -> String {
        var out = ""
        for child in node.children { out += try serializeNode(child) }
        return out
    }

    private static func serializeNode(_ node: LyricsXMLNode) throws -> String {
        switch node.kind {
        case .text, .cdata: return sanitizeTextFragment(node.text)
        case .element: return try serializeElement(node)
        case .other: return ""
        }
    }

    private static func serializeElement(_ element: LyricsXMLNode) throws -> String {
        switch element.localName.lowercased() {
        case "br":
            return "\n"
        case "span":
            let content = normalizeInlineText(try serializeChildren(element))
            if ParseKit.isBlank(content) { return "" }
            if let beginMs = try parseTimeExpression(element.attribute("begin")) {
                return "<" + ParseKit.lrcTimestamp(beginMs) + ">" + content
            }
            return content
        default:
            return try serializeChildren(element)
        }
    }

    /// Normalises one text node: line breaks unified, format/control characters dropped (newline and tab kept),
    /// whitespace-only text → " " (or "" when it contains a newline or tab), runs of `\s` → one space.
    static func sanitizeTextFragment(_ raw: String) -> String {
        if raw.isEmpty { return raw }
        var cleaned = ParseKit.replacing(raw, "\r\n", with: "\n")
        cleaned = ParseKit.replacing(cleaned, "\r", with: "\n")
        cleaned = ParseKit.filterNot(cleaned) {
            ParseKit.isFormatChar($0) || (ParseKit.isISOControl($0) && $0 != "\n" && $0 != "\t")
        }
        if cleaned.isEmpty { return "" }
        if cleaned.unicodeScalars.allSatisfy(ParseKit.isWhitespace) {
            return cleaned.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\t" }) ? "" : " "
        }
        return replaceRegexSpaceRuns(cleaned)
    }

    /// `replace(Regex("\\s+"), " ")`.
    static func replaceRegexSpaceRuns(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var inSpace = false
        for scalar in s.unicodeScalars {
            if ParseKit.isRegexSpace(scalar) {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(scalar)
                inSpace = false
            }
        }
        return String(out)
    }

    /// `replace(Regex("[ ]{2,}"), " ")`.
    static func collapseSpaces(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var previousSpace = false
        for scalar in s.unicodeScalars {
            if scalar == " " {
                if !previousSpace { out.append(" ") }
                previousSpace = true
            } else {
                out.append(scalar)
                previousSpace = false
            }
        }
        return String(out)
    }

    /// Collapses double spaces, removes spaces around line breaks, trims leading/trailing line breaks.
    static func normalizeInlineText(_ value: String) -> String {
        let collapsed = Array(collapseSpaces(value).unicodeScalars)
        // ` *\n *` → "\n"
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < collapsed.count {
            if collapsed[i] == " " || collapsed[i] == "\n" {
                var j = i
                while j < collapsed.count, collapsed[j] == " " { j += 1 }
                if j < collapsed.count, collapsed[j] == "\n" {
                    var k = j + 1
                    while k < collapsed.count, collapsed[k] == " " { k += 1 }
                    out.append("\n")
                    i = k
                    continue
                }
                out.append(contentsOf: collapsed[i..<j])
                i = j
                continue
            }
            out.append(collapsed[i])
            i += 1
        }
        return ParseKit.trim(ParseKit.string(out)) { $0 == "\n" }
    }

    /// Per line: collapse double spaces and trim; drop empty lines; trim the result.
    static func normalizeParagraphBody(_ value: String) -> String {
        let lines = ParseKit.lines(value).map { ParseKit.trim(collapseSpaces($0)) }.filter { !$0.isEmpty }
        return ParseKit.trim(lines.joined(separator: "\n"))
    }

    /// TTML time expressions: `12.5s`, `12.5`, `mm:ss(.fff)`, `hh:mm:ss(.fff)`. Throws where Android throws
    /// (rounding NaN), which aborts the whole document.
    static func parseTimeExpression(_ value: String) throws -> Int32? {
        let normalized = ParseKit.trim(value)
        if normalized.isEmpty { return nil }

        if let last = normalized.unicodeScalars.last, last == "s" || last == "S" {
            // `removeSuffix("s")` is case-sensitive: "1.5S" keeps its "S" and fails to parse.
            let number = last == "s" ? String(normalized.unicodeScalars.dropLast()) : normalized
            guard let seconds = ParseKit.parseDouble(number) else { return nil }
            guard let ms = ParseKit.roundToInt(seconds * 1000) else { throw RoundingNaN() }
            return ms
        }
        if let seconds = ParseKit.parseDouble(normalized) {
            guard let ms = ParseKit.roundToInt(seconds * 1000) else { throw RoundingNaN() }
            return ms
        }

        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 2:
            guard let minutes = ParseKit.toLong(parts[0]), let (seconds, millis) = parseSecondsWithFraction(parts[1]) else {
                return nil
            }
            return Int32(truncatingIfNeeded: minutes &* 60_000 &+ seconds &* 1_000 &+ millis)
        case 3:
            guard let hours = ParseKit.toLong(parts[0]), let minutes = ParseKit.toLong(parts[1]),
                  let (seconds, millis) = parseSecondsWithFraction(parts[2]) else { return nil }
            return Int32(truncatingIfNeeded: hours &* 3_600_000 &+ minutes &* 60_000 &+ seconds &* 1_000 &+ millis)
        default:
            return nil
        }
    }

    /// `ss` or `ss.fff…` (first three fraction digits, right-padded with zeros).
    private static func parseSecondsWithFraction(_ value: String) -> (Int64, Int64)? {
        let units = Array(value.utf16)
        let dot = units.firstIndex(of: 0x2E)
        let secondsText = String(decoding: dot.map { units[..<$0] } ?? units[...], as: UTF16.self)
        guard let seconds = ParseKit.toLong(secondsText) else { return nil }
        guard let dot else { return (seconds, 0) }
        let fraction = units[(dot + 1)...]
        if fraction.isEmpty { return (seconds, 0) }
        var digits = Array(fraction.prefix(3))
        while digits.count < 3 { digits.append(0x30) }
        guard let millis = ParseKit.toLong(String(decoding: digits, as: UTF16.self)) else { return nil }
        return (seconds, millis)
    }
}
