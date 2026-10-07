import PixlLyrics
import PixlModel
import UIKit
import XCTest
@testable import PixlAudio

/// Stage 10: the sync editor's helpers (Android `LyricsSyncEditorStateHolder` companion), the tap screen's derived
/// model and a session run on the demo engine; plus (2026-10-07) close reasons, the Spotify Connect guard and the
/// shared keep-screen-on claim.
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

    // MARK: - Close reasons and errors (2026-10-07: "tap sync → loading → the editor disappears")

    /// The editor's teardown (its view disappeared) restores the player but never navigates: a dismissal from there
    /// used to take down whatever was on screen by then, the lyrics screen included.
    func testViewGoneCloseNeverNavigates() async throws {
        let playback = PlaybackStore(engine: DemoPlaybackEngine())
        playback.play(DemoLibrary.songs, startIndex: 0, playWhenReady: true)
        let (session, directory) = makeSession(playback: playback)
        defer { try? FileManager.default.removeItem(at: directory) }
        var closedCount = 0
        session.onClosed = { closedCount += 1 }

        session.open(songId: DemoLibrary.songs[0].id, entry: .auto)
        try await waitForPhase(.intro, session)
        session.close(.viewGone)
        XCTAssertEqual(session.phase, .closed)
        XCTAssertEqual(closedCount, 0, "a disappearing editor must not navigate")
        session.close()
        XCTAssertEqual(closedCount, 0, "nothing is left to close after the teardown")
    }

    /// Every other reason navigates exactly once, and the teardown that follows the dismissal is a no-op.
    func testUserCloseNavigatesOnce() async throws {
        let playback = PlaybackStore(engine: DemoPlaybackEngine())
        playback.play(DemoLibrary.songs, startIndex: 0, playWhenReady: false)
        let (session, directory) = makeSession(playback: playback)
        defer { try? FileManager.default.removeItem(at: directory) }
        var closedCount = 0
        session.onClosed = { closedCount += 1 }

        session.open(songId: DemoLibrary.songs[0].id, entry: .auto)
        try await waitForPhase(.intro, session)
        session.requestClose()
        XCTAssertEqual(closedCount, 1)
        session.close(.viewGone)
        session.close()
        XCTAssertEqual(closedCount, 1)
    }

    /// Android refuses while casting: with a Spotify Connect device attached the editor shows the message and Close,
    /// and sends nothing to the device (no queue, pause or seek).
    func testSpotifyConnectBlocksOpenWithoutTouchingTheDevice() async throws {
        let playback = PlaybackStore(engine: DemoPlaybackEngine())
        playback.play(DemoLibrary.songs, startIndex: 0, playWhenReady: false)
        let remote = SpotifyConnectStoreTests.FakeRemote()
        playback.attachRemote(remote, name: "Kitchen Echo", isPlaying: true)
        let (session, directory) = makeSession(playback: playback)
        defer { try? FileManager.default.removeItem(at: directory) }
        var closedCount = 0
        session.onClosed = { closedCount += 1 }

        session.open(songId: DemoLibrary.songs[0].id, entry: .auto)
        XCTAssertEqual(session.phase, .error(SyncStrings.remoteOutput))
        XCTAssertEqual(session.title, DemoLibrary.songs[0].title)
        XCTAssertEqual(remote.calls, [], "nothing goes to the Connect device")

        session.close()
        XCTAssertEqual(closedCount, 1, "Close on the error screen dismisses the editor")
        XCTAssertEqual(remote.calls, [])
    }

    /// A Connect device taking over mid-session stops the editor with the message, keeps the session's restore for
    /// Close, and never pauses the speaker the person just picked (Android: flushDraft + Error, no pause).
    func testSpotifyConnectMidSessionStopsWithoutPausingTheDevice() async throws {
        let playback = PlaybackStore(engine: DemoPlaybackEngine())
        playback.play(DemoLibrary.songs, startIndex: 0, playWhenReady: true)
        let (session, directory) = makeSession(playback: playback)
        defer { try? FileManager.default.removeItem(at: directory) }
        var closedCount = 0
        session.onClosed = { closedCount += 1 }

        session.open(songId: DemoLibrary.songs[0].id, entry: .auto)
        try await waitForPhase(.intro, session)
        let remote = SpotifyConnectStoreTests.FakeRemote()
        playback.attachRemote(remote, name: "Kitchen Echo", isPlaying: true)
        session.remoteOutputAttached()
        XCTAssertEqual(session.phase, .error(SyncStrings.remoteOutput))
        XCTAssertEqual(closedCount, 0, "the error waits for Close")

        session.currentSongChanged(to: nil)
        session.currentSongChanged(to: DemoLibrary.songs[1].id)
        XCTAssertEqual(session.dialog, .none, "the error screen stays; no song-changed dialog over it")

        session.close()
        XCTAssertEqual(session.phase, .closed)
        XCTAssertEqual(closedCount, 1)
        XCTAssertEqual(remote.calls, [], "no pause, play or seek reached the device")
    }

    /// The lyrics screen and the sync editor over it each hold their own keep-awake claim: the editor closing must not
    /// let the screen lock under lyrics that still want it on.
    func testScreenStaysAwakeWhileAnyOwnerHoldsIt() {
        defer {
            ScreenAwake.set(false, for: .lyrics)
            ScreenAwake.set(false, for: .lyricsSync)
        }
        ScreenAwake.set(true, for: .lyrics)
        ScreenAwake.set(true, for: .lyricsSync)
        ScreenAwake.set(false, for: .lyricsSync)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "the lyrics screen still holds it")
        ScreenAwake.set(false, for: .lyrics)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    // MARK: - Helpers

    private func makeSession(playback: PlaybackStore) -> (LyricsSyncSession, URL) {
        let settings = SettingsStore.ephemeral()
        let lyricsStore = LyricsStore()
        let controller = LyricsController(store: lyricsStore, settings: settings, persistence: nil, isUITest: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sync-tests-\(UUID().uuidString)")
        let session = LyricsSyncSession(
            player: LyricsSyncPlayer(playback: playback, engine: nil), settings: settings, lyricsStore: lyricsStore,
            lyricsController: controller, draftStore: LyricsSyncDraftStore(directory: directory),
            preferences: LyricsSyncPreferences(isUITest: true), isUITest: true, songLookup: { _ in nil })
        return (session, directory)
    }

    private func waitForPhase(_ phase: SyncPhase, _ session: LyricsSyncSession) async throws {
        for _ in 0..<200 where session.phase != phase { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.phase, phase)
    }
}
