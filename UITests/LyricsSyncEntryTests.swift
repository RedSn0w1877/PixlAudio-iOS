import XCTest

/// The sync editor opened the way people open it: from the lyrics screen (the sync chip, and Lyrics options →
/// "Sync the words yourself") and while a Spotify Connect device plays. Until 2026-10-07 every editor test launched
/// straight into the editor (`-screen lyricsSync`), so CI never saw what the owner saw on the phone: tap sync → the
/// loading screen → the editor disappears. The editor now opens over the lyrics screen in its own cover; these tests
/// check it is still open seconds later and that closing it returns to the lyrics screen.
@MainActor
final class LyricsSyncEntryTests: XCTestCase {
    /// Line-synced lyrics show "Make the words light up · Sync it yourself". Opened twice: the second run starts a
    /// fresh session after the first one was torn down.
    func testOpensFromSyncChip() throws {
        let app = launchLyrics(demo: "lines")
        for run in 1...2 {
            let chip = element(app, "lyrics.syncChip")
            XCTAssertTrue(chip.waitForExistence(timeout: 10), "the sync chip is missing (run \(run))")
            chip.tap()
            assertEditorStaysOpen(app, shot: run == 1 ? "syncEntryChip-dark" : nil)
            closeBackToLyrics(app)
        }
    }

    /// Lyrics options → "Sync the words yourself": the editor opens once the sheet has gone.
    func testOpensFromLyricsOptions() throws {
        let app = launchLyrics(demo: "lines")
        openFromLyricsOptions(app)
        assertEditorStaysOpen(app, shot: "syncEntryMoreSheet-dark")
        closeBackToLyrics(app)
    }

    /// Word-synced lyrics (BiniLyrics, the first online source) have no chip: the More sheet is the only way in.
    func testOpensFromLyricsOptionsForWordSyncedLyrics() throws {
        let app = launchLyrics(demo: "words")
        openFromLyricsOptions(app)
        assertEditorStaysOpen(app, shot: "syncEntryWordSynced-dark")
        closeBackToLyrics(app)
    }

    /// Leaving with taps goes through the "Leave without saving?" alert: its action closes the editor, which must
    /// still land on the lyrics screen.
    func testLeaveReturnsToLyrics() throws {
        let app = launchLyrics(demo: "lines")
        let chip = element(app, "lyrics.syncChip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the sync chip is missing")
        chip.tap()
        let start = element(app, "sync.start")
        XCTAssertTrue(start.waitForExistence(timeout: 10), "the editor did not reach its intro")
        start.tap()
        let pad = element(app, "sync.pad")
        XCTAssertTrue(pad.waitForExistence(timeout: 10), "the tap screen did not appear")
        Thread.sleep(forTimeInterval: 0.8)
        pad.tap() // starts the song
        Thread.sleep(forTimeInterval: 1.0)
        for _ in 0..<3 {
            pad.tap()
            Thread.sleep(forTimeInterval: 0.45)
        }
        element(app, "sync.close").tap()
        let leave = app.alerts.buttons["Leave"].firstMatch
        XCTAssertTrue(leave.waitForExistence(timeout: 5), "taps were made: closing asks first")
        leave.tap()
        assertBackOnLyrics(app)
    }

    /// While a Spotify Connect device plays, the editor says why it can't sync, and Close dismisses it.
    func testSpotifyConnectShowsTheMessage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", "lyricsSync.spotifyConnect", "-appearance", "dark"]
        app.launch()
        XCTAssertTrue(element(app, "screen.lyricsSync").waitForExistence(timeout: 20), "the sync editor did not open")
        XCTAssertTrue(element(app, "sync.error").waitForExistence(timeout: 10), "no message while Connect plays")
        let message = "Syncing only works on this iPhone. Switch playback back to this iPhone first."
        XCTAssertTrue(app.staticTexts[message].firstMatch.exists, "the Connect message is missing")
        Thread.sleep(forTimeInterval: 2.0)
        attach(app, name: "syncConnectBlocked-dark")
        element(app, "sync.error.close").tap()
        XCTAssertTrue(element(app, "screen.lyricsSync").waitForNonExistence(timeout: 10), "Close did not dismiss the editor")
    }

    // MARK: - Helpers

    private func launchLyrics(demo: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", "lyrics", "-appearance", "dark", "-lyricsDemo", demo]
        app.launch()
        XCTAssertTrue(element(app, "screen.lyrics").waitForExistence(timeout: 20), "the lyrics screen did not open")
        return app
    }

    private func openFromLyricsOptions(_ app: XCUIApplication) {
        let more = app.buttons["Lyrics options"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Lyrics options is missing")
        more.tap()
        XCTAssertTrue(element(app, "screen.lyricsOptions").waitForExistence(timeout: 10), "the More sheet did not open")
        let row = element(app, "lyricsMore.syncYourself")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the More sheet's sync row is missing")
        row.tap()
    }

    /// The editor reaches its intro and is still there 3 s later (the bug: it showed the spinner, then vanished).
    private func assertEditorStaysOpen(_ app: XCUIApplication, shot: String?) {
        let start = element(app, "sync.start")
        XCTAssertTrue(start.waitForExistence(timeout: 10), "the editor did not reach its intro")
        Thread.sleep(forTimeInterval: 3.0)
        XCTAssertTrue(start.exists, "the editor closed itself after opening")
        XCTAssertTrue(element(app, "screen.lyricsSync").exists, "the editor closed itself after opening")
        if let shot { attach(app, name: shot) }
    }

    private func closeBackToLyrics(_ app: XCUIApplication) {
        let close = element(app, "sync.close")
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the editor's ✕ is missing")
        close.tap()
        assertBackOnLyrics(app)
    }

    private func assertBackOnLyrics(_ app: XCUIApplication) {
        XCTAssertTrue(element(app, "screen.lyricsSync").waitForNonExistence(timeout: 10), "the editor did not close")
        XCTAssertTrue(element(app, "screen.lyrics").waitForExistence(timeout: 10), "closing did not return to lyrics")
        XCTAssertTrue(app.buttons["Lyrics options"].firstMatch.waitForExistence(timeout: 5),
                      "the lyrics screen's controls are gone")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
