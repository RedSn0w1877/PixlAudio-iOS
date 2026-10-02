import PixlLyrics
import PixlModel
import XCTest
@testable import PixlAudio

/// Stage 10: the sync editor's helpers (Android `LyricsSyncEditorStateHolder` companion), the tap screen's derived
/// model and a session run on the demo engine.
@MainActor
final class LyricsSyncTests: XCTestCase {
    func testPlainTextOfEveryLyricsShape() {
        XCTAssertEqual(LyricsSyncSession.plainText(of: nil), "")
        let plain = Lyrics(plain: ["  First line \nromaji", "", "Second"], synced: nil)
        XCTAssertEqual(LyricsSyncSession.plainText(of: plain), "First line\nSecond")
        let synced = Lyrics(plain: nil, synced: [SyncedLine(time: 0, line: " One "), SyncedLine(time: 10, line: "  "),
                                                  SyncedLine(time: 20, line: "Two")])
        XCTAssertEqual(LyricsSyncSession.plainText(of: synced), "One\nTwo")
        let doc = LyricsDoc(lines: [TimedLine(startMs: 0, endMs: 10, text: " Doc "), TimedLine(startMs: 10, endMs: 20, text: "Line")])
        XCTAssertEqual(LyricsSyncSession.plainText(of: Lyrics(plain: ["ignored"], synced: nil, document: doc)), "Doc\nLine")
    }

    func testExportFileNameIsSanitised() {
        XCTAssertEqual(LyricsSyncSession.exportFileName(artist: "AC/DC", title: "What? Now", ttml: false), "AC_DC - What_ Now.lrc")
        XCTAssertEqual(LyricsSyncSession.exportFileName(artist: "", title: "Solo", ttml: true), "Solo.ttml")
        XCTAssertEqual(LyricsSyncSession.exportFileName(artist: " ", title: "", ttml: false), "lyrics.lrc")
    }

    func testPreviewMapsEveryPreparedLineToItsDraftLine() throws {
        let song = try XCTUnwrap(DemoLibrary.songs.first)
        let lineCount = try XCTUnwrap(LyricsDemoContent.lyrics(.lines)?.synced?.count)
        let draft = try XCTUnwrap(LyricsSyncDemoState.tapped(lines: lineCount, song: song))
        XCTAssertTrue(draft.isFinished)
        let preview = try XCTUnwrap(LyricsSyncSession.buildPreview(draft, offsetMs: LyricsTapSync.defaultOffsetSpeakerMs))
        XCTAssertTrue(preview.prepared.hasWordTiming)
        XCTAssertFalse(preview.hasRoughLines)
        XCTAssertEqual(preview.draftLineForPrepared.count, preview.prepared.lines.count)
        XCTAssertEqual(preview.draftLineForPrepared, Array(0..<lineCount))
    }

    func testRoughLinesGetTheMark() throws {
        let song = try XCTUnwrap(DemoLibrary.songs.first)
        let draft = try XCTUnwrap(LyricsSyncDemoState.tapped(lines: 3, song: song))
        let filled = LyricsTapSync.fillRest(draft, offsetMs: LyricsTapSync.defaultOffsetSpeakerMs).draft
        let preview = try XCTUnwrap(LyricsSyncSession.buildPreview(filled, offsetMs: LyricsTapSync.defaultOffsetSpeakerMs))
        XCTAssertTrue(preview.hasRoughLines)
        XCTAssertTrue(preview.prepared.lines.contains { $0.text.hasSuffix(LyricsSyncSession.roughMark) })
    }

    func testTapModelMarksTheSungAndNextWords() throws {
        let song = try XCTUnwrap(DemoLibrary.songs.first)
        // "Carry the night in a folded hand": three words tapped.
        let draft = try XCTUnwrap(LyricsSyncDemoState.tapped(lines: 4, extraWords: 3, song: song))
        let model = SyncTapModel.make(draft: draft, fixLine: nil)
        XCTAssertEqual(model.currentLine, 4)
        XCTAssertEqual(model.lineNumber, 5)
        XCTAssertEqual(model.previousLine, 3)
        XCTAssertEqual(model.nextLine, 5)
        XCTAssertEqual(model.nextWord, "in")
        XCTAssertEqual(draft.tokens[model.sungIndex].text.trimmingCharacters(in: .whitespaces), "night")
        XCTAssertTrue(model.canUndo)
        XCTAssertNil(model.musicBreak)
        XCTAssertEqual(model.progress, Double(draft.tappedCount) / Double(draft.tappableCount), accuracy: 1e-9)
    }

    func testMusicBreakBeforeTheLineAfterTheGap() throws {
        let song = try XCTUnwrap(DemoLibrary.songs.first)
        let draft = try XCTUnwrap(LyricsSyncDemoState.tapped(lines: 14, song: song))
        let model = SyncTapModel.make(draft: draft, fixLine: nil)
        let breakInfo = try XCTUnwrap(model.musicBreak)
        XCTAssertEqual(breakInfo.anchorMs, 67_000)
        XCTAssertGreaterThan(breakInfo.anchorMs - breakInfo.fromMs, SyncTapModel.musicBreakMinMs)
    }

    func testSessionOpensTapsUndoesAndCloses() async throws {
        let playback = PlaybackStore(engine: DemoPlaybackEngine())
        playback.play(DemoLibrary.songs, startIndex: 0, playWhenReady: true)
        let settings = SettingsStore.ephemeral()
        let lyricsStore = LyricsStore()
        let controller = LyricsController(store: lyricsStore, settings: settings, persistence: nil, isUITest: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sync-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = LyricsSyncSession(
            player: LyricsSyncPlayer(playback: playback, engine: nil), settings: settings, lyricsStore: lyricsStore,
            lyricsController: controller, draftStore: LyricsSyncDraftStore(directory: directory),
            preferences: LyricsSyncPreferences(isUITest: true), isUITest: true, songLookup: { _ in nil })
        var closed = false
        session.onClosed = { closed = true }

        session.open(songId: DemoLibrary.songs[0].id, entry: .auto)
        for _ in 0..<200 where session.phase != .intro { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.phase, .intro)
        XCTAssertFalse(session.isPlaying, "opening pauses the song")

        session.startFromIntro(dontShowAgain: false)
        XCTAssertEqual(session.phase, .tapping)
        XCTAssertEqual(session.draft?.tappedCount, 0)

        let now = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(session.onTapDown(eventUptime: now), -1, "the first press starts the song")
        XCTAssertTrue(session.isPlaying)
        XCTAssertEqual(session.onTapDown(eventUptime: now + 0.2), 0)
        XCTAssertEqual(session.draft?.tappedCount, 1)
        XCTAssertEqual(session.onTapDown(eventUptime: now + 0.21), -1, "a bounce within 60 ms is ignored")
        XCTAssertEqual(session.onTapDown(eventUptime: now + 0.6), 1)
        XCTAssertEqual(session.draft?.tappedCount, 2)

        session.undo()
        XCTAssertEqual(session.draft?.tappedCount, 1)

        session.setSpeed(0.75)
        XCTAssertEqual(session.speed, 0.75)
        session.setSpeed(0.6)
        XCTAssertEqual(session.speed, 0.75, "only 1, 0.75 and 0.5")

        session.requestClose()
        XCTAssertEqual(session.dialog, .leave, "taps would be left as a draft: ask first")
        session.confirmLeave()
        XCTAssertEqual(session.phase, .closed)
        XCTAssertTrue(closed)
    }
}
