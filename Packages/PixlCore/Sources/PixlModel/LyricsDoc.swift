// PixelPlay lyrics JSON v1 (`data/model/LyricsDoc.kt`, `docs/lyrics-json-format.md` in the Android repo).
// All times are absolute milliseconds; line and syllable ends are exclusive. Syllable text keeps its spaces, and
// a line's syllables must join to exactly the line text. `LyricsDocCodec` reads and writes the exact JSON the
// Android app produces.

import Foundation
import PixlFoundation

/// A lyrics document: voices plus timed lines with optional syllable timing.
public struct LyricsDoc: Sendable, Hashable, Codable {
    public static let formatName = "pixelplay-lyrics"

    public var format: String
    public var version: Int
    public var metadata: LyricsMetadata
    public var voices: [Voice]
    public var lines: [TimedLine]

    public init(format: String = LyricsDoc.formatName, version: Int = 1, metadata: LyricsMetadata = LyricsMetadata(),
                voices: [Voice] = [Voice()], lines: [TimedLine]) {
        self.format = format
        self.version = version
        self.metadata = metadata
        self.voices = voices
        self.lines = lines
    }

    enum CodingKeys: String, CodingKey { case format, version, metadata, voices, lines }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? LyricsDoc.formatName
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        metadata = try c.decodeIfPresent(LyricsMetadata.self, forKey: .metadata) ?? LyricsMetadata()
        voices = try c.decodeIfPresent([Voice].self, forKey: .voices) ?? [Voice()]
        lines = try c.decode([TimedLine].self, forKey: .lines)
    }

    /// The legacy `Lyrics` view of this document (`LyricsDoc.toLyrics()`): plain text per line, and synced lines
    /// whose words are the non-blank syllables, trimmed, with `startsNewWord` derived from the spaces around them.
    public func toLyrics() -> Lyrics {
        let synced = lines.map { line -> SyncedLine in
            var words: [SyncedWord]?
            if !line.syllables.isEmpty {
                var boundary = true
                var out: [SyncedWord] = []
                for s in line.syllables {
                    let startsNew = boundary || s.text.startsWithKotlinWhitespace
                    boundary = s.text.endsWithKotlinWhitespace
                    if s.text.isKotlinBlank { continue }
                    out.append(SyncedWord(time: Self.kotlinInt(s.startMs), word: s.text.kotlinTrimmed(),
                                          startsNewWord: startsNew, endTime: Self.kotlinInt(s.startMs &+ s.durationMs)))
                }
                words = out
            }
            let role = voices.first { $0.id.isIdentical(to: line.voiceId) }?.role ?? VoiceRole.lead
            return SyncedLine(time: Self.kotlinInt(line.startMs), line: line.text, words: words,
                              endTime: Self.kotlinInt(line.endMs), voiceRole: role)
        }
        return Lyrics(plain: lines.map(\.text), synced: synced, document: self)
    }

    /// Lines active at `playbackMs` (`start ≤ t < end`); concurrent voices are all kept.
    public func activeLines(at playbackMs: Int64) -> [TimedLine] {
        lines.filter { playbackMs >= $0.startMs && playbackMs < $0.endMs }
    }

    /// The line to scroll to: the last active lead line, else the last active line (`findActiveLine`).
    public func findActiveLine(at playbackMs: Int64) -> TimedLine? {
        let active = activeLines(at: playbackMs)
        return active.last { line in
            voices.first { $0.id.isIdentical(to: line.voiceId) }?.role == VoiceRole.lead
        } ?? active.last
    }

    /// Kotlin `Long.toInt()` (wraps), as `toLyrics` uses.
    static func kotlinInt(_ value: Int64) -> Int { Int(Int32(truncatingIfNeeded: value)) }
}

/// Document metadata.
public struct LyricsMetadata: Sendable, Hashable, Codable {
    public var title: String
    public var artist: String
    public var album: String
    public var durationMs: Int64?
    /// Where the lyrics came from; `"user"` marks user-synced lyrics that fetchers must not overwrite.
    public var source: String?

    public init(title: String = "", artist: String = "", album: String = "", durationMs: Int64? = nil,
                source: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.source = source
    }

    enum CodingKeys: String, CodingKey { case title, artist, album, durationMs, source }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        durationMs = try c.decodeIfPresent(Int64.self, forKey: .durationMs)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

/// The roles a voice can have. Stored as strings in `Voice.role` for format fidelity.
public enum VoiceRole {
    public static let lead = "lead"
    public static let background = "background"
    public static let duet = "duet"
    /// Every valid role.
    public static let all: [String] = [lead, background, duet]
}

/// A singer/voice referenced by lines.
public struct Voice: Sendable, Hashable, Codable {
    public var id: String
    /// "lead", "background" or "duet" (`VoiceRole`).
    public var role: String
    public var name: String?

    public init(id: String = "lead", role: String = VoiceRole.lead, name: String? = nil) {
        self.id = id
        self.role = role
        self.name = name
    }

    enum CodingKeys: String, CodingKey { case id, role, name }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "lead"
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? VoiceRole.lead
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }
}

/// A timed line. `endMs` is exclusive.
public struct TimedLine: Sendable, Hashable, Codable {
    public var startMs: Int64
    public var endMs: Int64
    public var text: String
    public var voiceId: String
    /// Syllable timing; empty for line-synced lyrics (no timing is ever synthesised).
    public var syllables: [TimedSyllable]

    public init(startMs: Int64, endMs: Int64, text: String, voiceId: String = "lead", syllables: [TimedSyllable] = []) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.voiceId = voiceId
        self.syllables = syllables
    }

    enum CodingKeys: String, CodingKey { case startMs, endMs, text, voiceId, syllables }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startMs = try c.decode(Int64.self, forKey: .startMs)
        endMs = try c.decode(Int64.self, forKey: .endMs)
        text = try c.decode(String.self, forKey: .text)
        voiceId = try c.decodeIfPresent(String.self, forKey: .voiceId) ?? "lead"
        syllables = try c.decodeIfPresent([TimedSyllable].self, forKey: .syllables) ?? []
    }

    /// The syllable being sung at `playbackMs`, or nil in a gap between syllables (`currentSyllable`).
    public func currentSyllable(at playbackMs: Int64) -> TimedSyllable? {
        syllables.last { playbackMs >= $0.startMs && playbackMs < $0.startMs &+ $0.durationMs }
    }
}

/// A timed syllable; its text keeps any spaces exactly.
public struct TimedSyllable: Sendable, Hashable, Codable {
    public var startMs: Int64
    public var durationMs: Int64
    public var text: String

    public init(startMs: Int64, durationMs: Int64, text: String) {
        self.startMs = startMs
        self.durationMs = durationMs
        self.text = text
    }
}
