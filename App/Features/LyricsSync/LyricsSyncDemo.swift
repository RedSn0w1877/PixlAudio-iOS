import Foundation
import PixlLyrics
import PixlModel

/// Launch options of the sync editor's screenshot tests (with `-uiTest -screen lyricsSync`):
///
///     -syncStep intro|words|resume|manage|tap|tapPaused|tapBreak|tapNotice|tapEnded|fixLine|preview|previewFixLine
///
/// Without `-syncStep` the editor opens normally on the demo song (lyrics from `-lyricsDemo`, default word-synced).
nonisolated struct LyricsSyncLaunchOptions: Sendable, Equatable {
    var step: LyricsSyncDemoStep?

    init(arguments: [String]) {
        if let index = arguments.firstIndex(of: "-syncStep"), arguments.indices.contains(index + 1) {
            step = LyricsSyncDemoStep(rawValue: arguments[index + 1])
        }
    }

    static let current = LyricsSyncLaunchOptions(arguments: ProcessInfo.processInfo.arguments)
}

nonisolated enum LyricsSyncDemoStep: String, Sendable, CaseIterable {
    case intro, words, resume, manage, tap, tapPaused, tapBreak, tapNotice, tapEnded, fixLine, preview, previewFixLine
}

/// One screen state of the editor, built from the line-synced demo lyrics (`LyricsDemoContent`, lines every 4 s from
/// 1 s; an instrumental gap 56–67 s).
nonisolated struct LyricsSyncDemoState: Sendable {
    var phase: SyncPhase
    var draft: SyncDraft?
    var origin: SyncDraftOrigin = .lineSynced
    var wordsSeed = ""
    var speed: Float = 1
    var isPlaying = false
    var started = false
    var sessionTaps = 40
    var lineSelectMode = false
    var notice: SyncNotice?
    var dialog: SyncDialog = .none
    var positionMs: Int64?

    /// Taps in the demo: each word of a line 100 ms after its anchor plus 380 ms per word (the demo's word length).
    static func tapped(lines lineCount: Int, extraWords: Int = 0, song: Song) -> SyncDraft? {
        let seed = LyricsTapSync.buildDraft(song: song, lyrics: LyricsDemoContent.lyrics(.lines), pasted: nil)
        guard var draft = seed.draft else { return nil }
        let offset = LyricsTapSync.defaultOffsetSpeakerMs
        for lineIndex in draft.lines.indices {
            let line = draft.lines[lineIndex]
            let words = lineIndex < lineCount ? line.tokenCount : (lineIndex == lineCount ? extraWords : 0)
            guard words > 0, let anchor = line.anchorMs else { continue }
            for word in 0..<min(words, line.tokenCount) {
                let raw = anchor + Int64(offset) + Int64(word * 380)
                draft = LyricsTapSync.tap(draft, rawStartMs: raw, speed: 1, offsetMs: offset).draft
            }
        }
        return draft
    }

    static func make(_ step: LyricsSyncDemoStep, song: Song) -> LyricsSyncDemoState {
        let lineCount = LyricsDemoContent.lyrics(.lines)?.synced?.count ?? 0
        switch step {
        case .intro:
            return LyricsSyncDemoState(phase: .intro, draft: tapped(lines: 0, song: song), sessionTaps: 0)
        case .words:
            return LyricsSyncDemoState(phase: .needWords, draft: nil, origin: .none, sessionTaps: 0)
        case .resume:
            let draft = tapped(lines: 6, extraWords: 2, song: song)
            return LyricsSyncDemoState(phase: .resumePrompt(tapped: draft?.tappedCount ?? 0, total: draft?.tappableCount ?? 0),
                                       draft: draft, sessionTaps: 0)
        case .manage:
            return LyricsSyncDemoState(phase: .manage, draft: tapped(lines: lineCount, song: song), origin: .userSynced)
        case .tap:
            // "Carry the night" tapped: "night" in the white box, "in" next.
            return LyricsSyncDemoState(phase: .tapping, draft: tapped(lines: 4, extraWords: 3, song: song), isPlaying: true,
                                       sessionTaps: 31, positionMs: 18_300)
        case .tapPaused:
            return LyricsSyncDemoState(phase: .tapping, draft: tapped(lines: 0, song: song), isPlaying: false,
                                       started: false, sessionTaps: 0, positionMs: 0)
        case .tapBreak:
            // Everything before the instrumental gap tapped; the countdown to "Light up the harbour" (67 s).
            return LyricsSyncDemoState(phase: .tapping, draft: tapped(lines: 14, song: song), isPlaying: true,
                                       positionMs: 61_000)
        case .tapNotice:
            return LyricsSyncDemoState(phase: .tapping, draft: tapped(lines: 2, song: song), isPlaying: true,
                                       notice: SyncNotice(id: 1, kind: .removedWords, count: 14, canUndo: true),
                                       positionMs: 9_200)
        case .tapEnded:
            return LyricsSyncDemoState(phase: .tapping, draft: tapped(lines: lineCount - 2, song: song), isPlaying: false,
                                       started: true, dialog: .endedEarly, positionMs: 83_000)
        case .fixLine:
            return LyricsSyncDemoState(phase: .fixLine(9), draft: tapped(lines: lineCount, song: song).map { draft in
                LyricsTapSync.fixLine(draft, lineIndex: 9, speed: 1, offsetMs: LyricsTapSync.defaultOffsetSpeakerMs).draft
            }, isPlaying: true, positionMs: 35_600)
        case .preview:
            return LyricsSyncDemoState(phase: .preview, draft: tapped(lines: lineCount, song: song), isPlaying: true,
                                       positionMs: 42_300)
        case .previewFixLine:
            return LyricsSyncDemoState(phase: .preview, draft: tapped(lines: lineCount, song: song), isPlaying: true,
                                       lineSelectMode: true, positionMs: 42_300)
        }
    }
}
