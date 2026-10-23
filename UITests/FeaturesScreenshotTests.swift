import XCTest

/// The 2026-10-18 features, on demo data: Find in playlist (open on a query, no matches, tapping a result), blocked
/// artists (the dimmed rows with their badge, "Play anyway", the settings page), the Gestures & haptics settings with
/// Music Haptics, plus the gestures themselves (swipe a row to queue it, swipe the mini player, double-tap
/// the artwork). Tag the commit message with `[shots:FeaturesScreenshotTests]` to run them.
@MainActor
final class FeaturesScreenshotTests: XCTestCase {
    // MARK: Find in playlist

    func testFindLight() throws { try capture("playlistFind", "light", ready: "find.field") }
    func testFindDark() throws { try capture("playlistFind", "dark", ready: "find.field") }
    func testFindNoMatchesLight() throws { try capture("playlistFindEmpty", "light", ready: "find.field") }
    func testFindNoMatchesDark() throws { try capture("playlistFindEmpty", "dark", ready: "find.field") }

    /// Three songs match "sora"; tapping one plays it (the mini player shows its title) and Cancel clears the field.
    func testTappingAResultPlaysAndCancelClears() throws {
        continueAfterFailure = false
        let app = launch("playlistFind", "light")
        XCTAssertTrue(element(app, "find.field").waitForExistence(timeout: 20))
        let result = row(app, "Cloud Atlas Drive")
        XCTAssertTrue(result.waitForExistence(timeout: 10), "the matching song is missing")
        result.tap()
        XCTAssertTrue(element(app, "miniPlayer").waitForExistence(timeout: 10), "tapping a result did not start playback")
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "playlistFind-played-light")
        app.buttons["find.cancel"].firstMatch.tap()
        XCTAssertTrue(row(app, "Chromatic").waitForExistence(timeout: 10),
                      "Cancel did not bring the whole list back")
        XCTAssertFalse(element(app, "find.field").exists)
        app.terminate()
    }

    // MARK: Blocked artists

    func testBlockedPlaylistLight() throws { try capture("playlistBlocked", "light", ready: "screen.playlistDetail") }
    func testBlockedPlaylistDark() throws { try capture("playlistBlocked", "dark", ready: "screen.playlistDetail") }

    /// A blocked song is tagged, and tapping it asks before playing.
    func testTappingABlockedSongOffersPlayAnyway() throws {
        continueAfterFailure = false
        let app = launch("playlistBlocked", "light")
        XCTAssertTrue(element(app, "screen.playlistDetail").waitForExistence(timeout: 20))
        let blocked = row(app, "Chromatic")
        XCTAssertTrue(blocked.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Blocked artist")).firstMatch.exists,
                      "the Blocked badge is missing")
        blocked.tap()
        let playAnyway = app.buttons["Play anyway"].firstMatch
        XCTAssertTrue(playAnyway.waitForExistence(timeout: 10), "the Play anyway dialog did not appear")
        Thread.sleep(forTimeInterval: 0.8)
        attach(app, "playlistBlocked-dialog-light")
        playAnyway.tap()
        XCTAssertTrue(element(app, "miniPlayer").waitForExistence(timeout: 10), "Play anyway did not start the song")
        app.terminate()
    }

    func testBlockedArtistsLight() throws { try capture("blockedArtists", "light", ready: "screen.blockedArtists") }
    func testBlockedArtistsDark() throws { try capture("blockedArtists", "dark", ready: "screen.blockedArtists") }
    func testBlockedArtistsEmptyLight() throws {
        try capture("blockedArtistsEmpty", "light", ready: "screen.blockedArtists")
    }

    /// Unblock removes an artist from the list (typing into the search field is not driven here: the Simulator's
    /// keyboard is not reliable in CI; the matching itself is unit-tested).
    func testBlockedArtistsUnblock() throws {
        continueAfterFailure = false
        let app = launch("blockedArtists", "light")
        XCTAssertTrue(element(app, "screen.blockedArtists").waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Hollow Pines"].firstMatch.waitForExistence(timeout: 10))
        let unblock = app.buttons["Unblock Hollow Pines"].firstMatch
        unblock.tap()
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, "blockedArtists-afterUnblockTap-light")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: unblock)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 8), .completed, "Unblock did not remove the artist")
        XCTAssertTrue(app.staticTexts["Pixel Parade"].firstMatch.exists)
        Thread.sleep(forTimeInterval: 0.6)
        attach(app, "blockedArtists-unblocked-light")
        app.terminate()
    }

    /// Gestures & haptics (the former Behavior and Gestures pages in one): the gesture switches at the top and, scrolled,
    /// Vibrate with the music with its switch on (Strength and Follows open; Status sits under Advanced).
    func testBehaviorWithMusicHapticsLight() throws { try behavior("light") }
    func testBehaviorWithMusicHapticsDark() throws { try behavior("dark") }

    private func behavior(_ appearance: String) throws {
        continueAfterFailure = false
        let app = launch("settingsCategory.behavior", appearance)
        XCTAssertTrue(element(app, "screen.settingsCategory.behavior").waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "settings.switch.Swipe the cover to change song").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.2)
        attach(app, "settingsBehavior-top-\(appearance)")
        let toggle = app.descendants(matching: .any)["settings.switch.Vibrate with the music"].firstMatch
        for _ in 0..<6 where !toggle.exists || toggle.frame.maxY > app.windows.firstMatch.frame.maxY - 160 {
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the Vibrate with the music switch is missing")
        // The switch sits at the row's trailing end (the row is one combined element).
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        // The status row is in the Advanced block, a lazy row of its own: scroll until it is built.
        let status = element(app, "settings.musicHaptics.status")
        for _ in 0..<4 where !status.exists {
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "settingsBehavior-musicHaptics-\(appearance)")
        app.terminate()
    }

    // MARK: Gestures

    /// A horizontal swipe on a song row queues it; vertical scrolling still works around it.
    func testSwipeARowToQueueIt() throws {
        continueAfterFailure = false
        let app = launch("playlistDetail", "light")
        XCTAssertTrue(element(app, "screen.playlistDetail").waitForExistence(timeout: 20))
        let target = row(app, "Midnight Transit")
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        let frame = target.frame
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 60, dy: frame.midY))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 220, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)
        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Playing next")).firstMatch
        let shown = toast.waitForExistence(timeout: 5)
        attach(app, "swipeToQueue-light")
        XCTAssertTrue(shown, "swiping right did not play next")

        // Vertical drags that start on a row still scroll the list, up and back down: the row's pan only takes
        // sideways drags. Each drag starts inside the list, on a row, and holds before lifting (no momentum), so
        // the list ends exactly where the finger left it. (`app.swipeUp()` / `swipeDown()` started wherever the
        // app's frame put them: on a short screen, 386 × 678 pt in CI since 2026-10-23, the list is scrollable and
        // a swipe that starts outside it, on the fixed header, cannot bring it back.)
        let list = app.scrollViews.matching(identifier: "screen.playlistDetail").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), "the song list is missing")
        let top = target.frame.minY
        let box = list.frame
        let lastRow = row(app, "Blue Hour")
        // Only a list taller than its frame can move; on a tall screen the five songs and their padding fit.
        let overflows = !lastRow.exists || lastRow.frame.maxY > box.maxY - 80
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let distance = box.height * 0.5
        let up = origin.withOffset(CGVector(dx: box.midX, dy: box.minY + box.height * 0.55))
        up.press(forDuration: 0.05, thenDragTo: up.withOffset(CGVector(dx: 0, dy: -distance)),
                 withVelocity: .default, thenHoldForDuration: 0.3)
        if overflows {
            XCTAssertTrue(!target.exists || target.frame.minY < top - 20,
                          "a drag up that started on a row did not scroll the list (row at \(target.frame.minY), was \(top))")
        }
        let down = origin.withOffset(CGVector(dx: box.midX, dy: box.minY + box.height * 0.2))
        down.press(forDuration: 0.05, thenDragTo: down.withOffset(CGVector(dx: 0, dy: distance)),
                   withVelocity: .default, thenHoldForDuration: 0.3)
        let deadline = Date().addingTimeInterval(5)
        var back = false
        repeat {
            back = target.exists && abs(target.frame.minY - top) < 2
            if !back { Thread.sleep(forTimeInterval: 0.25) }
        } while !back && Date() < deadline
        XCTAssertTrue(back, "a drag down that started on a row did not scroll the list back (row at "
                       + "\(target.exists ? "\(target.frame.minY)" : "none"), was \(top))")
        app.terminate()
    }

    /// Swiping the mini player left moves to the next song.
    func testSwipeTheMiniPlayerToSkip() throws {
        continueAfterFailure = false
        let app = launch("miniPlayer", "light")
        let title = app.descendants(matching: .any)["miniPlayer.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        let before = title.label
        element(app, "miniPlayer").swipeLeft()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 8), .completed, "the mini player did not skip")
        attach(app, "miniPlayer-swiped-light")
        app.terminate()
    }

    /// Double-tapping the artwork shows the heart.
    func testDoubleTapTheArtworkLikes() throws {
        continueAfterFailure = false
        let app = launch("nowPlaying", "light")
        XCTAssertTrue(element(app, "screen.nowPlaying").waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 1.5)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38)).doubleTap()
        Thread.sleep(forTimeInterval: 0.35)
        attach(app, "nowPlaying-heartBurst-light")
        app.terminate()
    }

    // MARK: Helpers

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func launch(_ screen: String, _ appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance]
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func capture(_ screen: String, _ appearance: String, ready: String) throws {
        continueAfterFailure = false
        let app = launch(screen, appearance)
        XCTAssertTrue(element(app, ready).waitForExistence(timeout: 20), "\(ready) did not appear")
        Thread.sleep(forTimeInterval: 2.0)
        attach(app, "\(screen)-\(appearance)")
        app.terminate()
    }
}

extension FeaturesScreenshotTests {
    /// A playlist row: one combined button whose label starts with the title.
    fileprivate func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }
}
