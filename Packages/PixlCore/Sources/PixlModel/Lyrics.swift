// Legacy lyrics model mirroring `data/model/Lyrics.kt` (`Lyrics`, `SyncedLine`, `SyncedWord`). kotlinx-serialized on
// Android (lyrics cache), so the Codable keys and defaults match. Kotlin `Int` times are Swift `Int` here.

import Foundation

/// Lyrics for a song: plain lines, line/word-synced lines, and optionally the richer `LyricsDoc`.
public struct Lyrics: Sendable, Hashable, Codable {
    public var plain: [String]?
    public var synced: [SyncedLine]?
    public var areFromRemote: Bool
    public var document: LyricsDoc?

    public init(plain: [String]? = nil, synced: [SyncedLine]? = nil, areFromRemote: Bool = false,
                document: LyricsDoc? = nil) {
        self.plain = plain
        self.synced = synced
        self.areFromRemote = areFromRemote
        self.document = document
    }

    enum CodingKeys: String, CodingKey { case plain, synced, areFromRemote, document }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plain = try c.decodeIfPresent([String].self, forKey: .plain)
        synced = try c.decodeIfPresent([SyncedLine].self, forKey: .synced)
        areFromRemote = try c.decodeIfPresent(Bool.self, forKey: .areFromRemote) ?? false
        document = try c.decodeIfPresent(LyricsDoc.self, forKey: .document)
    }
}

/// One synced line (`SyncedLine`).
public struct SyncedLine: Sendable, Hashable, Codable {
    /// Start in ms.
    public var time: Int
    public var line: String
    /// Word timings; nil when the line is only line-synced.
    public var words: [SyncedWord]?
    /// Translation paired by identical timestamp.
    public var translation: String?
    /// Romanisation paired by identical timestamp.
    public var romanization: String?
    /// Explicit end in ms.
    public var endTime: Int?
    /// "lead", "background" or "duet".
    public var voiceRole: String

    public init(time: Int, line: String, words: [SyncedWord]? = nil, translation: String? = nil,
                romanization: String? = nil, endTime: Int? = nil, voiceRole: String = "lead") {
        self.time = time
        self.line = line
        self.words = words
        self.translation = translation
        self.romanization = romanization
        self.endTime = endTime
        self.voiceRole = voiceRole
    }

    enum CodingKeys: String, CodingKey { case time, line, words, translation, romanization, endTime, voiceRole }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Int.self, forKey: .time)
        line = try c.decode(String.self, forKey: .line)
        words = try c.decodeIfPresent([SyncedWord].self, forKey: .words)
        translation = try c.decodeIfPresent(String.self, forKey: .translation)
        romanization = try c.decodeIfPresent(String.self, forKey: .romanization)
        endTime = try c.decodeIfPresent(Int.self, forKey: .endTime)
        voiceRole = try c.decodeIfPresent(String.self, forKey: .voiceRole) ?? "lead"
    }
}

/// One timed word or syllable (`SyncedWord`).
public struct SyncedWord: Sendable, Hashable, Codable {
    /// Start in ms.
    public var time: Int
    public var word: String
    /// False when this piece continues the previous word (a syllable).
    public var startsNewWord: Bool
    /// Explicit end in ms; nil when it has to be inferred (enhanced LRC).
    public var endTime: Int?

    public init(time: Int, word: String, startsNewWord: Bool = true, endTime: Int? = nil) {
        self.time = time
        self.word = word
        self.startsNewWord = startsNewWord
        self.endTime = endTime
    }

    enum CodingKeys: String, CodingKey { case time, word, startsNewWord, endTime }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Int.self, forKey: .time)
        word = try c.decode(String.self, forKey: .word)
        startsNewWord = try c.decodeIfPresent(Bool.self, forKey: .startsNewWord) ?? true
        endTime = try c.decodeIfPresent(Int.self, forKey: .endTime)
    }
}
