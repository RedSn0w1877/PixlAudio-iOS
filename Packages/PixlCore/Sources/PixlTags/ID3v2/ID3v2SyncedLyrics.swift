// ID3v2 `SYLT` (synchronised lyrics/text). Android never reads SYLT (TagLib keeps it out of the property map);
// the iOS app uses it as one more embedded-lyrics source, so this file also converts SYLT to and from the PixlModel
// `SyncedLine`/`SyncedWord` model and LRC text.

import Foundation
import PixlModel

/// A `SYLT` frame.
public struct ID3v2SyncedLyrics: Sendable, Hashable {
    /// Unit of the entry timestamps.
    public enum TimestampFormat: UInt8, Sendable, Hashable {
        /// Absolute time in MPEG frames.
        case mpegFrames = 1
        /// Absolute time in milliseconds.
        case milliseconds = 2
    }

    /// One timed piece of text.
    public struct Entry: Sendable, Hashable {
        public var text: String
        public var time: UInt32

        public init(text: String, time: UInt32) {
            self.text = text
            self.time = time
        }
    }

    public var encoding: ID3v2TextEncoding
    public var language: String
    /// The raw timestamp-format byte (1 = MPEG frames, 2 = milliseconds; other values are kept as read).
    public var timestampFormatByte: UInt8
    /// Content type: 0 other, 1 lyrics, 2 text transcription, 3 movement, 4 events, 5 chord, 6 trivia, 7 URLs,
    /// 8 images.
    public var contentType: UInt8
    public var description: String
    public var entries: [Entry]

    public init(encoding: ID3v2TextEncoding = .utf8, language: String = "XXX",
                timestampFormat: TimestampFormat = .milliseconds, contentType: UInt8 = 1, description: String = "",
                entries: [Entry]) {
        self.encoding = encoding
        self.language = language
        self.timestampFormatByte = timestampFormat.rawValue
        self.contentType = contentType
        self.description = description
        self.entries = entries
    }

    public var timestampFormat: TimestampFormat? { TimestampFormat(rawValue: timestampFormatByte) }

    // MARK: Codec

    /// TagLib `SynchronizedLyricsFrame::parseFields`. Stops at the first entry without a terminator or without a
    /// complete 4-byte timestamp.
    static func parse(_ data: [UInt8]) -> ID3v2SyncedLyrics? {
        guard data.count >= 7, let encoding = ID3v2TextEncoding(rawValue: data[0]) else { return nil }
        let language = String(decoding: data[1..<4], as: UTF8.self)
        var lyrics = ID3v2SyncedLyrics(encoding: encoding, language: language, entries: [])
        lyrics.timestampFormatByte = data[4]
        lyrics.contentType = data[5]
        var pos = 6
        var order: TagText.ByteOrder = .little
        if encoding == .utf16, pos + 1 < data.count {
            if data[pos] == 0xFE && data[pos + 1] == 0xFF { order = .big }
        }
        guard let description = TagText.readTerminated(data, encoding, &pos, utf16Fallback: order) else { return lyrics }
        lyrics.description = description
        while pos < data.count {
            guard let text = TagText.readTerminated(data, encoding, &pos, utf16Fallback: order), pos + 4 <= data.count else {
                break
            }
            lyrics.entries.append(Entry(text: text, time: ByteIO.uint32BE(data, pos)))
            pos += 4
        }
        return lyrics
    }

    func render(version: UInt8) -> [UInt8] {
        let enc = TagText.checkEncoding([description] + entries.map(\.text), encoding, version: version)
        var out: [UInt8] = [enc.rawValue]
        out += ID3v2Frame.languageBytes(language)
        out.append(timestampFormatByte)
        out.append(contentType)
        out += TagText.encode(description, enc) + enc.delimiter
        for e in entries {
            out += TagText.encode(e.text, enc) + enc.delimiter
            ByteIO.appendUInt32BE(e.time, to: &out)
        }
        return out
    }

    // MARK: Lyrics model

    /// Converts the entries to synced lines. Entries whose text starts with a line break (`\n` or `\r`) begin a new
    /// line, the usual way word-level SYLT is written; when no entry does, every entry is its own line. Lines made of
    /// several entries carry word timings. Times are milliseconds; MPEG-frame timestamps need `mpegFrameDurationMs`
    /// (nil otherwise).
    public func syncedLines(mpegFrameDurationMs: Double? = nil) -> [SyncedLine]? {
        let toMs: (UInt32) -> Int
        switch timestampFormat {
        case .milliseconds: toMs = { Int($0) }
        case .mpegFrames:
            guard let frameMs = mpegFrameDurationMs, frameMs > 0 else { return nil }
            toMs = { Int((Double($0) * frameMs).rounded()) }
        case nil: return nil
        }
        func isBreak(_ s: String) -> Bool { s.hasPrefix("\n") || s.hasPrefix("\r") }
        func stripBreak(_ s: String) -> String {
            var t = Substring(s)
            while let f = t.first, f == "\n" || f == "\r" || f == "\r\n" { t = t.dropFirst() }
            return String(t)
        }
        let grouped = entries.contains { isBreak($0.text) }
        if !grouped {
            return entries.map { SyncedLine(time: toMs($0.time), line: $0.text) }
        }
        var lines: [SyncedLine] = []
        var current: [(text: String, time: Int)] = []
        func flush() {
            guard let first = current.first else { return }
            let text = current.map(\.text).joined()
            if current.count == 1 {
                lines.append(SyncedLine(time: first.time, line: text))
            } else {
                var words: [SyncedWord] = []
                for (i, piece) in current.enumerated() {
                    let startsNewWord = i == 0 || piece.text.hasPrefix(" ") || current[i - 1].text.hasSuffix(" ")
                    let word = Self.trimSpaces(piece.text)
                    if word.isEmpty { continue }
                    words.append(SyncedWord(time: piece.time, word: word, startsNewWord: startsNewWord))
                }
                lines.append(SyncedLine(time: first.time, line: Self.trimSpaces(text), words: words))
            }
            current = []
        }
        for (i, e) in entries.enumerated() {
            if i > 0 && isBreak(e.text) { flush() }
            current.append((text: stripBreak(e.text), time: toMs(e.time)))
        }
        flush()
        return lines
    }

    /// Builds a millisecond SYLT frame from synced lines. Lines with word timings are written word by word (the
    /// first word of every line after the first starts with `\n`, spaces separate words); other lines are one entry.
    public init(syncedLines: [SyncedLine], language: String = "XXX", description: String = "",
                encoding: ID3v2TextEncoding = .utf8) {
        var entries: [Entry] = []
        for (lineIndex, line) in syncedLines.enumerated() {
            let prefix = lineIndex == 0 ? "" : "\n"
            if let words = line.words, !words.isEmpty {
                for (i, w) in words.enumerated() {
                    let lead = i == 0 ? prefix : (w.startsNewWord ? " " : "")
                    entries.append(Entry(text: lead + w.word, time: UInt32(clamping: w.time)))
                }
            } else {
                entries.append(Entry(text: prefix + line.line, time: UInt32(clamping: line.time)))
            }
        }
        self.init(encoding: encoding, language: language, timestampFormat: .milliseconds, contentType: 1,
                  description: description, entries: entries)
    }

    /// LRC text (`[mm:ss.xx]line`, with `<mm:ss.xx>` word stamps for word-timed lines), or nil when the timestamps
    /// cannot be converted. Uses the `%02d:%02d.%02d` stamp format of Android's LRC writers.
    public func lrcText(mpegFrameDurationMs: Double? = nil) -> String? {
        guard let lines = syncedLines(mpegFrameDurationMs: mpegFrameDurationMs) else { return nil }
        return lines.map { line -> String in
            var s = "[" + Self.stamp(line.time) + "]"
            if let words = line.words, !words.isEmpty {
                for (i, w) in words.enumerated() {
                    if i > 0 && w.startsNewWord { s += " " }
                    s += "<" + Self.stamp(w.time) + ">" + w.word
                }
            } else {
                s += line.line
            }
            return s
        }.joined(separator: "\n")
    }

    /// Trims spaces and tabs.
    static func trimSpaces(_ s: String) -> String {
        let u = Array(s.unicodeScalars)
        var a = 0, b = u.count
        while a < b, u[a] == " " || u[a] == "\u{09}" { a += 1 }
        while b > a, u[b - 1] == " " || u[b - 1] == "\u{09}" { b -= 1 }
        return String(String.UnicodeScalarView(u[a..<b]))
    }

    static func stamp(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        return pad(totalSeconds / 60) + ":" + pad(totalSeconds % 60) + "." + pad((ms % 1000) / 10)
    }
}
