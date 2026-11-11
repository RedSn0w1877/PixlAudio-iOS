import XCTest

/// Spatial audio (cloud audio spec 6.5) in demo states (`SpatialDemo`: the no-op services, a state pinned per screen):
/// the sheet over the full player for every status line and for Off; the full player's button (on, held back, and a tap
/// that opens the sheet, where a pick applies at once); Settings › Playback's rows (Sound, the "Cloud processing is
/// off" row, Developer mode's rows) and the confirm before "Remove downloaded renders".
///
/// Cloud renders need both switches (spec 6.1). `SpatialDemo` sets `spatial.cloud`; Cloud Studio's own "Process songs in
/// the cloud" is switched on here with the launch argument `-cloud_studio_enabled YES` (the argument domain is shared
/// by every `UserDefaults`, the UI-test suite included). Without it the cloud lines read "On your phone only. Turn on
/// cloud renders for the full version." and Settings shows the row that leads to the master switch.
@MainActor
final class SpatialScreenshotTests: XCTestCase {
    // MARK: The sheet, one shot per line of 6.5's table

    func testSheetOnPhoneForNowLight() throws {
        try captureSheet("spatialAudio", "light", selected: "studio",
                         line: "On your phone for now. The cloud version takes about a minute.")
    }
    func testSheetOnPhoneForNowDark() throws {
        try captureSheet("spatialAudio", "dark", selected: "studio",
                         line: "On your phone for now. The cloud version takes about a minute.")
    }
    func testSheetOffLight() throws { try captureSheet("spatialAudio.off", "light", selected: "off", line: nil) }
    func testSheetWaitingForWifiLight() throws {
        try captureSheet("spatialAudio.waitingForWifi", "light", selected: "hall",
                         line: "On your phone for now. The cloud version waits for Wi-Fi.")
    }
    func testSheetCloudLimitLight() throws {
        try captureSheet("spatialAudio.cloudLimit", "light", selected: "wide",
                         line: "On your phone only. This month's cloud limit is reached.")
    }
    func testSheetGettingCloudVersionDark() throws {
        try captureSheet("spatialAudio.gettingCloudVersion", "dark", selected: "intimate",
                         line: "Getting the cloud version.")
    }
    func testSheetCloudVersionLight() throws {
        try captureSheet("spatialAudio.cloudVersion", "light", selected: "night", line: "Playing the cloud version.")
    }
    func testSheetOnPhoneOnlyLight() throws {
        try captureSheet("spatialAudio.onPhoneOnly", "light", selected: "surround",
                         line: "On your phone only. Turn on cloud renders for the full version.")
    }
    func testSheetCloudFailedDark() throws {
        try captureSheet("spatialAudio.cloudFailed", "dark", selected: "studio",
                         line: "The cloud version didn't work this time. Still playing on your phone.")
    }
    func testSheetHeadphonesOnlyLight() throws {
        try captureSheet("spatialAudio.headphonesOnly", "light", selected: "hall",
                         line: "Headphones only. Plug in to hear it.")
    }
    func testSheetPausedForSingLight() throws {
        try captureSheet("spatialAudio.pausedForSing", "light", selected: "studio", line: "Paused while Sing is on.")
    }
    /// Cloud Studio's own switch off: the cloud lines give way to "On your phone only".
    func testSheetMasterSwitchOffLight() throws {
        try captureSheet("spatialAudio", "light", selected: "studio",
                         line: "On your phone only. Turn on cloud renders for the full version.",
                         cloudStudioOn: false, suffix: "-masterOff")
    }

    // MARK: The full player's button

    func testPlayerButtonOnLight() throws {
        continueAfterFailure = false
        let app = launch("nowPlaying.spatial", "light")
        let button = app.buttons["player.spatialAudio"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "the Spatial audio button is missing")
        XCTAssertEqual(button.label, "Spatial audio")
        XCTAssertEqual(button.value as? String, "Studio")
        snapshot(app, "nowPlaying.spatial-light")
    }

    func testPlayerButtonHeldBackDark() throws {
        continueAfterFailure = false
        let app = launch("nowPlaying.spatialHeld", "dark")
        let button = app.buttons["player.spatialAudio"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "the Spatial audio button is missing")
        XCTAssertEqual(button.value as? String, "Concert Hall. Not playing right now.")
        snapshot(app, "nowPlaying.spatialHeld-dark")
    }

    /// Off in the player; a tap opens the sheet with Off selected; picking Wide applies at once and the sheet stays
    /// open; closed, the button names the pick.
    func testTheButtonOpensTheSheetAndAPickApplies() throws {
        continueAfterFailure = false
        let app = launch("nowPlaying", "light")
        let button = app.buttons["player.spatialAudio"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "the Spatial audio button is missing")
        XCTAssertEqual(button.value as? String, "Off")
        Thread.sleep(forTimeInterval: 1.0)
        button.tap()

        let sheet = app.descendants(matching: .any)["screen.spatialAudio"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the sheet did not open")
        let off = app.buttons["spatialAudio.choice.off"].firstMatch
        let wide = app.buttons["spatialAudio.choice.wide"].firstMatch
        XCTAssertTrue(wide.waitForExistence(timeout: 5), "the Wide row is missing")
        XCTAssertTrue(off.isSelected, "Off is not the selected row")
        XCTAssertFalse(wide.isSelected)
        XCTAssertFalse(app.descendants(matching: .any)["spatialAudio.status"].firstMatch.exists,
                       "nothing plays in Spatial audio, so there is no status line")
        XCTAssertTrue(app.descendants(matching: .any)["spatialAudio.levelNote"].firstMatch.exists)

        wide.tap()
        waitFor(NSPredicate(format: "isSelected == true"), wide, "Wide did not become the selected row")
        XCTAssertFalse(off.isSelected)
        XCTAssertTrue(sheet.exists, "the sheet closed after a pick")
        Thread.sleep(forTimeInterval: 1.0)
        snapshot(app, "spatialAudio-picked-light", terminate: false)

        // Pull the sheet down from its top edge.
        let top = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12))
        top.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        waitFor(NSPredicate(format: "exists == false"), sheet, "the sheet did not close")
        waitFor(NSPredicate(format: "value == %@", "Wide"), button, "the player's button does not name the pick")
        app.terminate()
    }

    // MARK: Settings › Playback

    /// Sound: the profile, Cloud renders, Prepare ahead and "Songs ready" with the demo numbers; both switches on, so no
    /// row about the master.
    func testSettingsSoundRowsLight() throws {
        let app = launch("settingsCategory.playback.spatial", "light")
        XCTAssertTrue(app.descendants(matching: .any)["screen.settingsCategory.playback"].firstMatch
            .waitForExistence(timeout: 20), "Settings › Playback did not appear")
        let songsReady = app.descendants(matching: .any)["settings.spatial.songsReady"].firstMatch
        scroll(app, toShow: songsReady)
        let profile = app.buttons["settings.spatial.profile"].firstMatch
        XCTAssertTrue(profile.exists, "the Spatial audio row is missing")
        XCTAssertTrue(profile.label.contains("Studio · Clean and close, like good speakers in a quiet room."),
                      "the profile row says \(profile.label)")
        XCTAssertTrue(app.staticTexts["Songs ready: 12 · 1.4 GB on this phone"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["settings.spatial.masterOff"].firstMatch.exists)
        snapshot(app, "settingsCategory.playback.spatial-light")
    }

    /// "Cloud renders" on while Cloud Studio's own switch is off: the row that says so and leads there.
    func testSettingsMasterOffDark() throws {
        let app = launch("settingsCategory.playback.spatial", "dark", cloudStudioOn: false)
        XCTAssertTrue(app.descendants(matching: .any)["screen.settingsCategory.playback"].firstMatch
            .waitForExistence(timeout: 20), "Settings › Playback did not appear")
        let masterOff = app.descendants(matching: .any)["settings.spatial.masterOff"].firstMatch
        scroll(app, toShow: app.descendants(matching: .any)["settings.spatial.songsReady"].firstMatch)
        XCTAssertTrue(masterOff.exists, "the Cloud processing is off row is missing")
        XCTAssertTrue(masterOff.label.contains("Cloud processing is off"))
        snapshot(app, "settingsCategory.playback.spatial-dark-masterOff")
    }

    /// Developer mode (on in UI tests): route, monthly limit, storage, songs a day and this song's diagnostics.
    func testSettingsDeveloperRowsLight() throws {
        let app = launch("settingsCategory.playback.spatial", "light")
        XCTAssertTrue(app.descendants(matching: .any)["screen.settingsCategory.playback"].firstMatch
            .waitForExistence(timeout: 20), "Settings › Playback did not appear")
        let diagnostics = app.descendants(matching: .any)["settings.spatial.diagnostics"].firstMatch
        scroll(app, toShow: diagnostics)
        XCTAssertTrue(diagnostics.label.contains("Rendition: on device · studio"), "diagnostics say \(diagnostics.label)")
        XCTAssertTrue(app.descendants(matching: .any)["settings.choice.Spatial cloud limit per month"].firstMatch.exists)
        snapshot(app, "settingsCategory.playback.spatial-light-developer")
    }

    /// "Remove downloaded renders" asks first; Cancel keeps them, Remove clears them (the demo library holds none after).
    func testRemoveDownloadedRendersAsksFirst() throws {
        continueAfterFailure = false
        let app = launch("settingsCategory.playback.spatial", "light")
        XCTAssertTrue(app.descendants(matching: .any)["screen.settingsCategory.playback"].firstMatch
            .waitForExistence(timeout: 20), "Settings › Playback did not appear")
        scroll(app, toShow: app.descendants(matching: .any)["settings.spatial.songsReady"].firstMatch)
        let remove = app.buttons["Remove downloaded renders"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "the Remove button is missing")

        remove.tap()
        let alert = app.alerts["Remove downloaded renders?"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no confirm before removing")
        Thread.sleep(forTimeInterval: 0.8)
        snapshot(app, "settingsCategory.playback.spatial-light-removeConfirm", terminate: false)
        alert.buttons["Cancel"].tap()
        waitFor(NSPredicate(format: "exists == false"), alert, "the confirm did not close")
        XCTAssertTrue(app.staticTexts["Songs ready: 12 · 1.4 GB on this phone"].firstMatch.exists, "Cancel removed renders")

        remove.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Remove"].tap()
        let empty = app.staticTexts["Songs ready: 0 · 0 GB on this phone"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 5), "the row did not empty after Remove")
        waitFor(NSPredicate(format: "isEnabled == false"), remove, "Remove stays enabled with nothing to remove")
        app.terminate()
    }

    // MARK: Helpers

    /// The sheet over the full player: the status line is `line` word for word (none for nil), `selected` is the one
    /// selected row, the quiet line is there; then a screenshot.
    private func captureSheet(_ screen: String, _ appearance: String, selected: String, line: String?,
                              cloudStudioOn: Bool = true, suffix: String = "") throws {
        continueAfterFailure = false
        let app = launch(screen, appearance, cloudStudioOn: cloudStudioOn)
        XCTAssertTrue(app.descendants(matching: .any)["screen.spatialAudio"].firstMatch.waitForExistence(timeout: 20),
                      "the Spatial audio sheet did not appear")
        let status = app.descendants(matching: .any)["spatialAudio.status"].firstMatch
        if let line {
            XCTAssertTrue(status.waitForExistence(timeout: 5), "the status line is missing")
            XCTAssertEqual(status.label, line)
        } else {
            XCTAssertFalse(status.exists, "a status line shows where the spec has none")
        }
        let row = app.buttons["spatialAudio.choice.\(selected)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the \(selected) row is missing")
        XCTAssertTrue(row.isSelected, "\(selected) is not the selected row")
        XCTAssertTrue(app.descendants(matching: .any)["spatialAudio.levelNote"].firstMatch.exists,
                      "the quiet line is missing")
        // Let the glass and the sheet's detent settle.
        Thread.sleep(forTimeInterval: 2.0)
        snapshot(app, "\(screen)-\(appearance)\(suffix)")
    }

    private func launch(_ screen: String, _ appearance: String, cloudStudioOn: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-uiTest", "-screen", screen, "-appearance", appearance]
        // Cloud Studio's own switch, the master of cloud renders (spec 6.1 "Two switches").
        if cloudStudioOn { arguments += ["-cloud_studio_enabled", "YES"] }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Short drags along the leading margin (never starting on a switch or a slider) until `element` sits above the mini
    /// player, or the page can't go further (its last row: the page keeps room for the mini player under it).
    private func scroll(_ app: XCUIApplication, toShow element: XCUIElement) {
        Thread.sleep(forTimeInterval: 1.0)
        // The mini player, alone at the bottom of a pushed page, covers about the bottom 110 pt.
        let limit = app.windows.firstMatch.frame.maxY - 110
        var lastMaxY: CGFloat = -1
        for _ in 0..<16 {
            if element.exists && element.frame.maxY <= limit && element.frame.minY > 0 { break }
            if element.exists {
                if element.frame.maxY == lastMaxY { break }
                lastMaxY = element.frame.maxY
            }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.7))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(element.exists, "\(element) is not on the page")
        XCTAssertLessThanOrEqual(element.frame.maxY, limit, "\(element) is under the mini player")
        Thread.sleep(forTimeInterval: 1.0)
    }

    private func waitFor(_ predicate: NSPredicate, _ element: XCUIElement, _ message: String,
                         timeout: TimeInterval = 8) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message)
    }

    private func snapshot(_ app: XCUIApplication, _ name: String, terminate: Bool = true) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if terminate { app.terminate() }
    }
}
