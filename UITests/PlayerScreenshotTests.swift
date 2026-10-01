import XCTest

/// Stage 8 screenshots: the player sheet collapsed (mini player) and expanded, the drag-up / collapse gestures, and
/// the player's sheets — queue, sleep timer, song info, edit song, artist picker, AirPlay & devices — each in demo
/// data (`-uiTest -screen <id>`). Compare with docs/design-refs/ pp_player (mini player), pp_full (full player) and
/// pp_sheet (song info).
@MainActor
final class PlayerScreenshotTests: XCTestCase {
    // MARK: Collapsed and expanded (ref: pp_player, pp_full)

    func testCollapsedLight() throws { try capture("miniPlayer", "light", ready: "miniPlayer", name: "playerCollapsed") }
    func testCollapsedDark() throws { try capture("miniPlayer", "dark", ready: "miniPlayer", name: "playerCollapsed") }
    func testExpandedPausedLight() throws {
        try capture("nowPlaying", "light", ready: "screen.nowPlaying", extra: ["-paused"], name: "playerExpandedPaused")
    }
    func testExpandedDark() throws { try capture("nowPlaying", "dark", ready: "screen.nowPlaying", name: "playerExpanded") }

    // MARK: Gestures

    /// Drag the mini player up: the sheet follows and settles expanded.
    func testDragUpExpandsLight() throws {
        let app = launch("miniPlayer", "light")
        let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 20), "the mini player did not appear")
        let start = mini.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -420))
        start.press(forDuration: 0.05, thenDragTo: end)
        let player = app.descendants(matching: .any)["player.collapse"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10), "the drag did not expand the player")
        snapshot(app, "playerDragExpanded-light")
    }

    /// The collapse circle brings the mini player back.
    func testCollapseButtonDark() throws {
        let app = launch("nowPlaying", "dark")
        let collapse = app.descendants(matching: .any)["player.collapse"].firstMatch
        XCTAssertTrue(collapse.waitForExistence(timeout: 20), "the full player did not appear")
        collapse.tap()
        let mini = app.descendants(matching: .any)["miniPlayer.title"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "the player did not collapse")
        snapshot(app, "playerCollapsedAfterTap-dark")
    }

    // MARK: Sheets over the player

    func testQueueLight() throws { try capture("queue", "light", ready: "screen.queue") }
    func testQueueDark() throws { try capture("queue", "dark", ready: "screen.queue") }
    func testQueueMenuLight() throws {
        try capture("queue", "light", ready: "screen.queue", tap: "More actions", name: "queueMenu")
    }
    func testSleepTimerLight() throws { try capture("sleepTimer", "light", ready: "screen.sleepTimer") }
    func testSleepTimerDark() throws { try capture("sleepTimer", "dark", ready: "screen.sleepTimer") }
    func testSongInfoLight() throws { try capture("songInfo", "light", ready: "screen.songInfo", name: "playerSongInfo") }
    func testSongInfoDark() throws { try capture("songInfo", "dark", ready: "screen.songInfo", name: "playerSongInfo") }
    func testEditSongLight() throws { try capture("editSong", "light", ready: "screen.editSong") }
    func testEditSongDark() throws { try capture("editSong", "dark", ready: "screen.editSong") }
    func testArtistPickerLight() throws { try capture("artistPicker", "light", ready: "screen.artistPicker") }
    func testArtistPickerDark() throws { try capture("artistPicker", "dark", ready: "screen.artistPicker") }
    func testDevicesLight() throws { try capture("devices", "light", ready: "screen.devices") }
    func testDevicesDark() throws { try capture("devices", "dark", ready: "screen.devices") }
    func testDevicesTabLight() throws {
        try capture("devices", "light", ready: "screen.devices", tap: "DEVICES", name: "devicesList")
    }

    // MARK: - Helpers

    private func launch(_ screen: String, _ appearance: String, extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance] + extra
        app.launch()
        return app
    }

    private func capture(_ screen: String, _ appearance: String, ready: String, extra: [String] = [],
                         tap: String? = nil, name: String? = nil) throws {
        let app = launch(screen, appearance, extra: extra)
        let element = app.descendants(matching: .any)[ready].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(ready) did not appear on \(screen)")
        if let tap {
            // By identifier or label (controls inside a GlassEffectContainer keep only their labels).
            let predicate = NSPredicate(format: "identifier == %@ OR label == %@", tap, tap)
            let button = app.buttons.matching(predicate).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), "\(tap) is missing on \(screen)")
            button.tap()
        }
        snapshot(app, "\(name ?? screen)-\(appearance)")
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        // Let artwork decoding, album colour extraction, glass and sheet presentations settle.
        Thread.sleep(forTimeInterval: 2.0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
