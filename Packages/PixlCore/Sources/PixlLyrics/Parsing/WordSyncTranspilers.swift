// Port of the Android `data/network/lyrics/WordSyncTranspilers.kt`: Musixmatch richsync JSON and NetEase YRC →
// `LyricsDoc` (absolute milliseconds, exclusive ends). Format conversion only — never invents timing: anything
// malformed, or a document `LyricsDocCodec.isValid` rejects, gives nil.

import Foundation
import PixlFoundation
import PixlModel

public enum WordSyncTranspilers {

    /// Richsync: `[{"ts":s,"te":s,"x":text,"l":[{"c":fragment,"o":offsetSeconds}…]}…]`. Fragment ends are the next
    /// fragment's start (the last one ends at the line end).
    public static func richSync(_ raw: String,
                                metadata: LyricsMetadata = LyricsMetadata(source: "Musixmatch")) -> LyricsDoc? {
        guard LyricsDocCodec.isBoundedJson(raw) else { return nil }
        do throws(GsonError) {
            let array = try GsonJSON.array(try GsonJSON.parse(raw))
            if array.count > 10_000 { return nil }
            var lines: [TimedLine] = []
            lines.reserveCapacity(array.count)
            for element in array {
                let line = try GsonJSON.object(element)
                let start = try seconds(try GsonJSON.double(line["ts"]))
                let end = try seconds(try GsonJSON.double(line["te"]))
                let text = try GsonJSON.string(line["x"])
                let fragments = try (GsonJSON.optionalArray(line, "l") ?? []).map { item throws(GsonError) in
                    try GsonJSON.object(item)
                }
                var starts: [Int64] = []
                for fragment in fragments { starts.append(start &+ (try seconds(try GsonJSON.double(fragment["o"])))) }
                var syllables: [TimedSyllable] = []
                for (i, fragment) in fragments.enumerated() {
                    let next = i + 1 < starts.count ? starts[i + 1] : end
                    syllables.append(TimedSyllable(startMs: starts[i], durationMs: next &- starts[i],
                                                   text: try GsonJSON.string(fragment["c"])))
                }
                lines.append(TimedLine(startMs: start, endMs: end, text: text, syllables: syllables))
            }
            let doc = LyricsDoc(metadata: metadata, lines: lines)
            return LyricsDocCodec.isValid(doc) ? doc : nil
        } catch {
            return nil
        }
    }

    /// NetEase YRC: `[lineStartMs,lineDurationMs](wordStartMs,wordDurationMs,0)text…` per line; JSON metadata lines
    /// (`{…}`) and blank lines are skipped. Zero-duration punctuation/censor markers sharing an onset with exactly
    /// one timed fragment are joined into it; a zero-duration fragment holding letters or digits rejects the file.
    public static func yrc(_ raw: String, metadata: LyricsMetadata = LyricsMetadata(source: "NetEase")) -> LyricsDoc? {
        if raw.utf16.count > 1_048_576 { return nil }
        var lines: [TimedLine] = []
        for rawLine in ParseKit.lines(raw) {
            if ParseKit.isBlank(rawLine) || ParseKit.hasPrefix(rawLine.kotlinTrimmedStart(), "{") { continue }
            let trimmed = ParseKit.trim(rawLine, start: false) { $0 == "\r" }
            guard let header = matchLine(trimmed),
                  let start = Int64(header.start), let duration = Int64(header.duration) else { return nil }
            if !(0...86_400_000).contains(start) || !(1...86_400_000).contains(duration) { return nil }
            let body = Array(header.body.unicodeScalars)
            let tags = wordTags(body)
            if let first = tags.first, first.range.lowerBound != 0 { return nil }
            var fragments: [TimedSyllable] = []
            for (i, tag) in tags.enumerated() {
                let textEnd = i + 1 < tags.count ? tags[i + 1].range.lowerBound : body.count
                guard let s = Int64(tag.start), let d = Int64(tag.duration) else { return nil }
                fragments.append(TimedSyllable(startMs: s, durationMs: d, text: ParseKit.string(body[tag.range.upperBound..<textEnd])))
            }
            var syllables: [TimedSyllable] = []
            var index = 0
            while index < fragments.count {
                let first = fragments[index]
                var end = index + 1
                while end < fragments.count, fragments[end].startMs == first.startMs { end += 1 }
                let group = fragments[index..<end]
                if group.contains(where: { $0.durationMs == 0 }) {
                    if group.contains(where: { $0.durationMs == 0 && $0.text.unicodeScalars.contains(where: ParseKit.isLetterOrDigit) }) {
                        return nil
                    }
                    let timed = group.filter { $0.durationMs > 0 }
                    guard timed.count == 1 else { return nil }
                    var joined = timed[0]
                    joined.text = group.map(\.text).joined()
                    syllables.append(joined)
                } else {
                    syllables.append(contentsOf: group)
                }
                index = end
            }
            // A malformed timing marker must not silently become display text.
            if tags.isEmpty && containsMalformedMarker(body) { return nil }
            lines.append(TimedLine(startMs: start, endMs: start + duration,
                                   text: syllables.isEmpty ? header.body : syllables.map(\.text).joined(),
                                   syllables: syllables))
        }
        let doc = LyricsDoc(metadata: metadata, lines: lines)
        return LyricsDocCodec.isValid(doc) ? doc : nil
    }

    /// `require(value.isFinite() && value >= 0 && value <= 86_400)` then `(value * 1000).roundToLong()`.
    private static func seconds(_ value: Double) throws(GsonError) -> Int64 {
        guard value.isFinite, value >= 0, value <= 86_400 else { throw GsonError(message: "IllegalArgumentException") }
        return ParseKit.javaRound(value * 1000)
    }

    /// `^\[(\d+),(\d+)](.*)$` (whole line; `.` excludes line terminators).
    private static func matchLine(_ line: String) -> (start: String, duration: String, body: String)? {
        LyricsUtils.matchKugouLine(line)
    }

    /// `\((\d+),(\d+),0\)` matches.
    private static func wordTags(_ s: [Unicode.Scalar]) -> [(start: String, duration: String, range: Range<Int>)] {
        var out: [(start: String, duration: String, range: Range<Int>)] = []
        var i = 0
        while i < s.count {
            if s[i] == "(", let tag = matchWordTag(s, i) {
                out.append(tag)
                i = tag.range.upperBound
                continue
            }
            i += 1
        }
        return out
    }

    private static func matchWordTag(_ s: [Unicode.Scalar], _ i: Int) -> (start: String, duration: String, range: Range<Int>)? {
        var j = i + 1
        let startBegin = j
        while j < s.count, ParseKit.isAsciiDigit(s[j]) { j += 1 }
        guard j > startBegin, j < s.count, s[j] == "," else { return nil }
        let startText = ParseKit.string(s[startBegin..<j])
        j += 1
        let durationBegin = j
        while j < s.count, ParseKit.isAsciiDigit(s[j]) { j += 1 }
        guard j > durationBegin, j + 2 < s.count, s[j] == ",", s[j + 1] == "0", s[j + 2] == ")" else { return nil }
        return (startText, ParseKit.string(s[durationBegin..<j]), i..<(j + 3))
    }

    /// `\(<?-?\d+,` anywhere.
    private static func containsMalformedMarker(_ s: [Unicode.Scalar]) -> Bool {
        for i in s.indices where s[i] == "(" {
            var j = i + 1
            if j < s.count, s[j] == "<" { j += 1 }
            if j < s.count, s[j] == "-" { j += 1 }
            let digitsStart = j
            while j < s.count, ParseKit.isAsciiDigit(s[j]) { j += 1 }
            if j > digitsStart, j < s.count, s[j] == "," { return true }
        }
        return false
    }
}
