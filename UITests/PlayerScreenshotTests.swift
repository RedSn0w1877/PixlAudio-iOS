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

    // MARK: Top bar (Hoa, 2026-10-07: no "Now Playing" title; the output pill names the device)

    /// A Bluetooth output (the demo route, "AirPods Pro"): the output pill names it and may use the width the title
    /// left; the title is gone.
    func testExpandedBluetoothLight() throws {
        let app = launch("nowPlaying.bluetooth", "light")
        let pill = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Playing on AirPods Pro")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 20), "the output pill does not name the Bluetooth device")
        XCTAssertFalse(app.staticTexts["Now Playing"].exists, "the top bar still shows its title")
        snapshot(app, "playerBluetooth-light")
    }

    // MARK: Favourite hearts flip at once (they used to wait for another control to redraw the view)

    /// The full player's toggle row. Demo song 0 is liked.
    func testFavoriteTogglesImmediately() throws {
        let app = launch("nowPlaying", "light")
        assertFavoriteFlips(app, heart: "player.favorite", name: "playerFavoriteToggled-light")
    }

    /// The song sheet's favourite tile. By its own identifier: the full player is pre-built under the sheet, collapsed
    /// and off screen, and its heart carries the same label (a label query found that one first, which can't be tapped).
    func testSongInfoFavoriteTogglesImmediately() throws {
        let app = launch("songInfo", "light")
        XCTAssertTrue(app.descendants(matching: .any)["screen.songInfo"].firstMatch.waitForExistence(timeout: 20),
                      "the song sheet did not appear")
        assertFavoriteFlips(app, heart: "songInfo.favorite", name: "songInfoFavoriteToggled-light")
    }

    /// The lyrics More sheet's shuffle · repeat · favourite row (the heart's state is its selected trait).
    func testLyricsOptionsFavoriteTogglesImmediately() throws {
        let app = launch("lyricsOptions", "dark")
        let sheet = app.descendants(matching: .any)["screen.lyricsOptions"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "the lyrics options did not appear")
        let heart = app.buttons.matching(NSPredicate(format: "label == %@", "Favorite")).firstMatch
        XCTAssertTrue(heart.waitForExistence(timeout: 10), "the favourite toggle is missing")
        var swipes = 0
        while !heart.isHittable, swipes < 4 {
            sheet.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(heart.isSelected, "demo song 0 should start liked")
        heart.tap()
        let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == false"), object: heart)
        XCTAssertEqual(XCTWaiter.wait(for: [off], timeout: 3), .completed, "the heart kept its old state after the tap")
        snapshot(app, "lyricsOptionsFavoriteToggled-dark")
    }

    /// While the full player is up, the tab bar under it is out of the accessibility tree, so the player's controls
    /// can be tapped as elements; once the player collapses, the tabs are back. The bar's UIKit tabs used to stay in
    /// the tree under the shuffle · repeat · favourite row: XCUITest then tapped each toggle at its top-left corner
    /// (CI diagnostics, 2026-10-07), which misses a toggle that is on (a full capsule), and VoiceOver touch
    /// exploration could land on a hidden tab. The tab is found with `descendants(matching: .any)`, as the tab bar
    /// tests find it: the UIKit segment's element type isn't pinned, and a query that never matches would pass the
    /// "hidden" check without proving anything.
    func testTabBarLeavesAccessibilityUnderThePlayer() throws {
        let app = launch("nowPlaying", "light")
        continueAfterFailure = true // every check reports
        let heart = app.buttons["player.favorite"]
        XCTAssertTrue(heart.waitForExistence(timeout: 20), "the heart is missing")
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: heart)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 10), .completed, "the heart can't be tapped")
        let libraryTab = app.descendants(matching: .any)["navBar.library"].firstMatch
        XCTAssertFalse(libraryTab.exists && libraryTab.isHittable, "the hidden tab bar still answers under the player")
        XCTAssertEqual(heart.label, "Remove from favorites", "demo song 0 should start liked")
        heart.tap()
        let unliked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Add to favorites"),
                                                object: heart)
        XCTAssertEqual(XCTWaiter.wait(for: [unliked], timeout: 3), .completed,
                       "an element tap on the liked heart did not reach it")

        // Collapsed again, the tabs are back in the accessibility tree: VoiceOver reads them and taps reach them.
        let collapse = collapseButton(app)
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), "the collapse circle is missing")
        collapse.tap()
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10),
                      "the tab bar did not come back to accessibility after the player collapsed")
        let tabHittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"),
                                                    object: libraryTab)
        XCTAssertEqual(XCTWaiter.wait(for: [tabHittable], timeout: 5), .completed,
                       "the Library tab can't be tapped after the player collapsed")
        app.terminate()
    }

    // MARK: Gestures

    /// Drag the mini player up: the sheet follows and settles expanded.
    func testDragUpExpandsLight() throws {
        let app = launch("miniPlayer", "light")
        let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 20), "the mini player did not appear")
        let start = mini.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -420))
        start.press(forDuration: 0.05, thenDragTo: end)
        let player = collapseButton(app)
        XCTAssertTrue(player.waitForExistence(timeout: 10), "the drag did not expand the player")
        snapshot(app, "playerDragExpanded-light")
    }

    /// The collapse circle brings the mini player back.
    func testCollapseButtonDark() throws {
        let app = launch("nowPlaying", "dark")
        let collapse = collapseButton(app)
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
    func testQueueMenuDark() throws {
        try capture("queue", "dark", ready: "screen.queue", tap: "More actions", name: "queueMenu")
    }
    /// Save as playlist, opened by the queue on launch (`queue.saveAsPlaylist`): the summary capsule and the Save pill
    /// as separate glass (2026-10-07). The name field focuses itself, so the keyboard may show.
    func testSaveQueueLight() throws {
        try capture("queue.saveAsPlaylist", "light", ready: "sheet.saveQueue", name: "saveQueue")
    }
    func testSaveQueueDark() throws {
        try capture("queue.saveAsPlaylist", "dark", ready: "sheet.saveQueue", name: "saveQueue")
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

    /// The collapse circle, by identifier or label (it sits in the top bar's glass container, whose children keep
    /// only their labels).
    private func collapseButton(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label == %@", "player.collapse", "Collapse player"))
            .firstMatch
    }

    /// Taps the liked heart (identifier `heart`, labelled "Remove from favorites") in its centre, where a finger
    /// lands, and expects the same button to read "Add to favorites" without touching anything else. By identifier:
    /// both hearts keep theirs (CI hierarchy dumps, 2026-10-07), and the collapsed player's hidden heart shares the
    /// label. At the centre rather than `tap()`'s hit point: XCUITest picks that point from accessibility hit tests,
    /// and anything left in the tree under the heart moves it to a corner, outside a toggle that is on (see
    /// `testTabBarLeavesAccessibilityUnderThePlayer`, which guards that case).
    private func assertFavoriteFlips(_ app: XCUIApplication, heart identifier: String, name: String) {
        let heart = app.buttons[identifier]
        XCTAssertTrue(heart.waitForExistence(timeout: 20), "the heart \(identifier) is missing")
        // The pre-built player is in the hierarchy before it has expanded: wait until the heart can take the tap.
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: heart)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 10), .completed, "the heart can't be tapped")
        XCTAssertEqual(heart.label, "Remove from favorites", "demo song 0 should start liked")
        heart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let unliked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Add to favorites"),
                                                object: heart)
        XCTAssertEqual(XCTWaiter.wait(for: [unliked], timeout: 3), .completed,
                       "the heart kept its old state after the tap")
        snapshot(app, name)
    }

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
