// "Share lyrics file": turns a `LyricsDoc` into files other apps understand. Port of the Android
// `data/lyrics/sync/LyricsExport.kt`, byte for byte.
//
// - `toEnhancedLrc`: enhanced LRC — a line tag, a `<mm:ss.xx>` tag before every syllable and a closing bare tag
//   with the last word's end. Reads back through the app's LRC parser.
// - `toTtml`: word-timed TTML with begin and end on every syllable, duet agents and nested background vocals.

import Foundation
import PixlFoundation
import PixlModel

public enum LyricsExport {

    public static let credit = "PixlAudio"

    static let ttmlNamespace = "http://www.w3.org/ns/ttml"
    static let ttmlMetadataNamespace = "http://www.w3.org/ns/ttml#metadata"
    static let itunesNamespace = "http://music.apple.com/lyric-ttml-internal"

    // MARK: - Enhanced LRC

    public static func toEnhancedLrc(_ doc: LyricsDoc) -> String {
        var out = ""
        let meta = doc.metadata
        appendHeader(&out, "ti", meta.title)
        appendHeader(&out, "ar", meta.artist)
        appendHeader(&out, "al", meta.album)
        if let duration = meta.durationMs, duration > 0 { out += "[length:" + formatLength(duration) + "]\n" }
        out += "[by:" + credit + "]\n"
        for line in doc.lines {
            out += "[" + lrcTime(line.startMs) + "]"
            if line.syllables.isEmpty {
                out += singleLine(line.text)
            } else {
                for syllable in line.syllables {
                    out += "<" + lrcTime(syllable.startMs) + ">" + singleLine(syllable.text)
                }
                let last = line.syllables[line.syllables.count - 1]
                out += "<" + lrcTime(last.startMs &+ last.durationMs) + ">"
            }
            out += "\n"
        }
        return out
    }

    private static func appendHeader(_ out: inout String, _ tag: String, _ value: String) {
        let clean = singleLine(value).kotlinTrimmed()
        if !clean.isEmpty { out += "[" + tag + ":" + clean + "]\n" }
    }

    /// `mm:ss.xx`, rounded to the nearest 10 ms; minutes grow to 3 digits when needed.
    public static func lrcTime(_ ms: Int64) -> String {
        let centis = (ms.coerced(atLeast: 0) &+ 5) / 10
        let minutes = centis / 6_000
        let seconds = (centis / 100) % 60
        let hundredths = centis % 100
        return pad(minutes, 2) + ":" + pad(seconds, 2) + "." + pad(hundredths, 2)
    }

    private static func formatLength(_ ms: Int64) -> String {
        let totalSeconds = (ms &+ 500) / 1_000
        return pad(totalSeconds / 60, 2) + ":" + pad(totalSeconds % 60, 2)
    }

    /// Replaces `\r\n`, `\r` and `\n` with a space each (`\r\n` counts once).
    private static func singleLine(_ text: String) -> String {
        if !text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) { return text }
        var out = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = scalar == "\r"
            out.append(scalar == "\n" || scalar == "\r" ? " " : scalar)
        }
        return String(out)
    }

    // MARK: - TTML

    private struct Paragraph {
        let line: TimedLine
        let agent: String
        var background: [TimedLine] = []
        /// A background line with no lead line before it: the paragraph holds only that background span.
        var backgroundOnly = false

        var beginMs: Int64 { min(line.startMs, background.map(\.startMs).min() ?? line.startMs) }
        var endMs: Int64 { max(line.endMs, background.map(\.endMs).max() ?? line.endMs) }
    }

    public static func toTtml(_ doc: LyricsDoc) -> String {
        func roleOf(_ id: String) -> String? { doc.voices.last { $0.id.isIdentical(to: id) }?.role }
        var paragraphs: [Paragraph] = []
        paragraphs.reserveCapacity(doc.lines.count)
        var lastMain: Int?
        for line in doc.lines {
            let role = roleOf(line.voiceId) ?? VoiceRole.lead
            if role.isIdentical(to: VoiceRole.background) {
                if let host = lastMain {
                    paragraphs[host].background.append(line)
                } else {
                    paragraphs.append(Paragraph(line: line, agent: "v1", background: [line], backgroundOnly: true))
                }
            } else {
                let agent = role.isIdentical(to: VoiceRole.duet) ? "v2" : "v1"
                paragraphs.append(Paragraph(line: line, agent: agent))
                lastMain = paragraphs.count - 1
            }
        }
        var agents: [String] = []
        for paragraph in paragraphs where !agents.contains(paragraph.agent) { agents.append(paragraph.agent) }
        agents.sort()
        let wordTimed = doc.lines.contains { !$0.syllables.isEmpty }

        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<tt xmlns=\"" + ttmlNamespace + "\" xmlns:ttm=\"" + ttmlMetadataNamespace
            + "\" xmlns:itunes=\"" + itunesNamespace + "\" itunes:timing=\"" + (wordTimed ? "Word" : "Line") + "\">\n"
        out += "  <head>\n    <metadata>\n"
        for agent in agents { out += "      <ttm:agent type=\"person\" xml:id=\"" + agent + "\"/>\n" }
        out += "    </metadata>\n  </head>\n"
        out += "  <body"
        if let duration = doc.metadata.durationMs, duration > 0 { out += " dur=\"" + ttmlTime(duration) + "\"" }
        out += ">\n"
        if !paragraphs.isEmpty {
            out += "    <div begin=\"" + ttmlTime(paragraphs.map(\.beginMs).min()!) + "\" end=\""
                + ttmlTime(paragraphs.map(\.endMs).max()!) + "\">\n"
            for paragraph in paragraphs {
                out += "      "
                appendParagraph(&out, paragraph)
                out += "\n"
            }
            out += "    </div>\n"
        }
        out += "  </body>\n</tt>\n"
        return out
    }

    /// One `<p>` on a single line: whitespace inside it is significant.
    private static func appendParagraph(_ out: inout String, _ paragraph: Paragraph) {
        out += "<p begin=\"" + ttmlTime(paragraph.beginMs) + "\" end=\"" + ttmlTime(paragraph.endMs)
            + "\" ttm:agent=\"" + paragraph.agent + "\">"
        let backgroundOnly = paragraph.backgroundOnly && paragraph.background.count == 1
        if !backgroundOnly { appendLineContent(&out, paragraph.line) }
        for (index, background) in paragraph.background.enumerated() {
            if !backgroundOnly || index > 0 { out += " " }
            out += "<span ttm:role=\"x-bg\" begin=\"" + ttmlTime(background.startMs) + "\" end=\""
                + ttmlTime(background.endMs) + "\">"
            appendLineContent(&out, background)
            out += "</span>"
        }
        out += "</p>"
    }

    private static func appendLineContent(_ out: inout String, _ line: TimedLine) {
        if line.syllables.isEmpty {
            appendEscaped(&out, line.text.kotlinTrimmed())
            return
        }
        for (index, syllable) in line.syllables.enumerated() {
            appendSyllable(&out, syllable, last: index == line.syllables.count - 1)
        }
    }

    private static func appendSyllable(_ out: inout String, _ syllable: TimedSyllable, last: Bool) {
        let core = syllable.text.kotlinTrimmed()
        if !core.isEmpty {
            out += "<span begin=\"" + ttmlTime(syllable.startMs) + "\" end=\""
                + ttmlTime(syllable.startMs &+ syllable.durationMs) + "\">"
            appendEscaped(&out, core)
            out += "</span>"
        }
        // A trailing space ends a word; syllables of the same word sit flush against each other.
        if !last && syllable.text.endsWithKotlinWhitespace { out += " " }
    }

    /// `h:mm:ss.fff`.
    public static func ttmlTime(_ ms: Int64) -> String {
        let value = ms.coerced(atLeast: 0)
        let hours = value / 3_600_000
        let minutes = (value / 60_000) % 60
        let seconds = (value / 1_000) % 60
        let millis = value % 1_000
        return String(hours) + ":" + pad(minutes, 2) + ":" + pad(seconds, 2) + "." + pad(millis, 3)
    }

    /// XML-escapes text and drops code points XML 1.0 cannot carry (control characters).
    private static func appendEscaped(_ out: inout String, _ text: String) {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let cp = scalar.value
            switch cp {
            case 0x26: scalars.append(contentsOf: "&amp;".unicodeScalars)
            case 0x3C: scalars.append(contentsOf: "&lt;".unicodeScalars)
            case 0x3E: scalars.append(contentsOf: "&gt;".unicodeScalars)
            case 0x22: scalars.append(contentsOf: "&quot;".unicodeScalars)
            case 0x27: scalars.append(contentsOf: "&apos;".unicodeScalars)
            case 0x9, 0xA, 0xD: scalars.append(" ")
            case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: scalars.append(scalar)
            default: break
            }
        }
        out += String(scalars)
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}
