// The value types of the tap-to-sync lyrics editor ("Sync it yourself"), ported from the Android
// `data/lyrics/sync/LyricsTapSync.kt` (`SyncLine`, `SyncToken`, `SyncDraft`, `SyncStep`, `SyncDraftOrigin`,
// `SyncDraftSeed`, `SyncResult`, `SyncTiming`). Field names match the Kotlin properties, which are also the keys of
// the stored draft JSON (`LyricsSyncDraftStore`).
//
// Time domains (see `LyricsTapSync`):
//  - "raw" times are what the player reported at the moment of a tap (media ms, already corrected for the tap's
//    event latency and scaled by the playback speed; see `LyricsTapSync.rawTapPositionMs`).
//  - "built" times are what ends up in the saved lyrics: `built = raw − reactionOffset × speedAtTap + nudge`.
//    Tokens flagged `exact` (loaded from saved lyrics, or timed roughly by skip/fill) skip the reaction offset
//    because they never came from a finger. The reaction offset is never baked into the draft, so it can change
//    later without re-tapping.

import Foundation
import PixlModel

/// One lyric line of the draft. Its words are `tokens[firstToken ..< firstToken + tokenCount]`.
public struct SyncLine: Sendable, Hashable {
    public var text: String
    public var voiceId: String
    /// Line start from a line-synced source. Only used for seeking, hints and rough timing.
    public var anchorMs: Int64?
    public var translation: String?
    public var firstToken: Int
    public var tokenCount: Int
    /// Background line that already had word timing: carried through unchanged, never tapped.
    public var locked: Bool
    /// Some of the words were timed roughly (skip line, time the rest, gaps) rather than tapped.
    public var skipped: Bool

    public init(text: String, voiceId: String = LyricsTapSync.leadVoiceId, anchorMs: Int64? = nil,
                translation: String? = nil, firstToken: Int, tokenCount: Int, locked: Bool = false,
                skipped: Bool = false) {
        self.text = text
        self.voiceId = voiceId
        self.anchorMs = anchorMs
        self.translation = translation
        self.firstToken = firstToken
        self.tokenCount = tokenCount
        self.locked = locked
        self.skipped = skipped
    }

    /// One past the line's last token.
    public var endToken: Int { firstToken + tokenCount }
}

/// One tappable unit (a word, or a single CJK character). `text` keeps its trailing space except for the last token
/// of a line, so the tokens of a line always join back to exactly the line text.
public struct SyncToken: Sendable, Hashable {
    public var line: Int
    public var text: String
    public var rawStartMs: Int64?
    public var startSpeed: Float
    /// Only set when the word was held down (or loaded with an explicit end).
    public var rawEndMs: Int64?
    public var endSpeed: Float
    /// The times are final (loaded or roughly spread), not taps: no reaction offset applies.
    public var exact: Bool

    public init(line: Int, text: String, rawStartMs: Int64? = nil, startSpeed: Float = 1, rawEndMs: Int64? = nil,
                endSpeed: Float = 1, exact: Bool = false) {
        self.line = line
        self.text = text
        self.rawStartMs = rawStartMs
        self.startSpeed = startSpeed
        self.rawEndMs = rawEndMs
        self.endSpeed = endSpeed
        self.exact = exact
    }

    public var isStamped: Bool { rawStartMs != nil }

    /// The token with every timing forgotten (`SyncToken.cleared()`).
    func cleared() -> SyncToken { SyncToken(line: line, text: text) }
}

/// An unsaved tap-sync session.
public struct SyncDraft: Sendable, Hashable {
    public var songId: String
    public var durationMs: Int64
    public var lines: [SyncLine]
    public var tokens: [SyncToken]
    /// Index of the next token to tap. `tokens.count` means every word has been tapped.
    public var cursor: Int
    public var voices: [Voice]
    /// Preview "earlier / later" nudge in media ms, applied to every word.
    public var nudgeMs: Int
    public var version: Int
    public var title: String
    public var artist: String
    public var album: String

    public init(songId: String, durationMs: Int64, lines: [SyncLine], tokens: [SyncToken], cursor: Int,
                voices: [Voice] = [Voice()], nudgeMs: Int = 0, version: Int = 1, title: String = "",
                artist: String = "", album: String = "") {
        self.songId = songId
        self.durationMs = durationMs
        self.lines = lines
        self.tokens = tokens
        self.cursor = cursor
        self.voices = voices
        self.nudgeMs = nudgeMs
        self.version = version
        self.title = title
        self.artist = artist
        self.album = album
    }

    /// True when there is no word left to tap.
    public var isFinished: Bool { LyricsTapSync.nextTappable(self, from: cursor) >= tokens.count }

    /// Line holding the next word to tap (the last line once finished).
    public var currentLineIndex: Int { LyricsTapSync.currentLineIndex(self) }

    public var tappableCount: Int { tokens.reduce(0) { $0 + (lines[$1.line].locked ? 0 : 1) } }

    public var tappedCount: Int {
        tokens.reduce(0) { $0 + ($1.rawStartMs != nil && !lines[$1.line].locked ? 1 : 0) }
    }

    /// Tappable words not stamped yet.
    public var remainingCount: Int { tappableCount - tappedCount }
}

/// Result of a reducer: the new draft, where to seek (if anywhere) and what happened.
public struct SyncStep: Sendable, Hashable {
    public var draft: SyncDraft
    public var seekToMs: Int64?
    /// Number of stamped words whose timing was removed (drives "Removed timing for N words").
    public var clearedCount: Int
    /// The tap landed at or past the next line's start and was clamped just before it.
    public var pastNextLine: Bool
    /// The first tap of a line came more than 3 s before that line's anchor.
    public var tapBeforeAnchor: Bool

    public init(draft: SyncDraft, seekToMs: Int64? = nil, clearedCount: Int = 0, pastNextLine: Bool = false,
                tapBeforeAnchor: Bool = false) {
        self.draft = draft
        self.seekToMs = seekToMs
        self.clearedCount = clearedCount
        self.pastNextLine = pastNextLine
        self.tapBeforeAnchor = tapBeforeAnchor
    }
}

/// Where a draft came from, which decides the editor's first screen.
public enum SyncDraftOrigin: Sendable, Hashable, CaseIterable {
    /// Saved by the user before: opens straight into Preview.
    case userSynced
    /// Already had word timing from somewhere else: opens in Intro with the "already timed" note.
    case wordSynced
    /// Line-synced source: every word is tapped, line times become anchors.
    case lineSynced
    /// Plain or pasted text: every word is tapped, no anchors.
    case plain
    /// Nothing usable: go to NeedWords. `SyncDraftSeed.draft` is nil.
    case none
}

/// A freshly built draft and where it came from.
public struct SyncDraftSeed: Sendable, Hashable {
    public var draft: SyncDraft?
    public var origin: SyncDraftOrigin

    public init(draft: SyncDraft?, origin: SyncDraftOrigin) {
        self.draft = draft
        self.origin = origin
    }
}

/// The saved document plus which of its lines were (partly) timed roughly, for the "≈" mark.
public struct SyncResult: Sendable, Hashable {
    public var doc: LyricsDoc
    /// Indices into `doc.lines`.
    public var roughLineIndices: Set<Int>

    public init(doc: LyricsDoc, roughLineIndices: Set<Int>) {
        self.doc = doc
        self.roughLineIndices = roughLineIndices
    }
}

/// Built start/end for every token of a draft.
public struct SyncTiming: Sendable, Hashable {
    public let startsMs: [Int64]
    public let endsMs: [Int64]
    /// Indices into `SyncDraft.lines` of lines with at least one roughly timed word.
    public let roughLines: Set<Int>

    init(startsMs: [Int64], endsMs: [Int64], roughLines: Set<Int>) {
        self.startsMs = startsMs
        self.endsMs = endsMs
        self.roughLines = roughLines
    }
}

/// Why a draft could not become a lyrics document (`Result.failure` on Android).
public enum LyricsTapSyncError: Error, Sendable, Hashable, CustomStringConvertible {
    /// "No words have been tapped yet".
    case noTaps
    /// "The draft has no words".
    case noWords
    /// The built document failed `LyricsDocCodec.isValid` (a bug; the message names the first invalid line).
    case invalidDocument(String)

    public var description: String {
        switch self {
        case .noTaps: "No words have been tapped yet"
        case .noWords: "The draft has no words"
        case .invalidDocument(let message): message
        }
    }
}
