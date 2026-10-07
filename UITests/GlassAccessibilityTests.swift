import XCTest

/// Grouping glass shapes in one `GlassEffectContainer` (docs/performance.md: settings groups, the full player's top
/// bar, detail headers) must not change what VoiceOver gets: the controls inside stay buttons, sliders and switches
/// with their labels. Only their accessibility identifiers can be lost inside a container (UI tests look such
/// controls up by label), which VoiceOver never reads.
@MainActor
final class GlassAccessibilityTests: XCTestCase {
    /// Settings › Music Management: an item row is a button, the filtering rows keep their sliders and the switch row
    /// is still a switch.
    func testSettingsGroupsKeepControlTraits() {
        let app = launch("settingsCategory.library", ready: "screen.settingsCategory.library")
        let folders = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Excluded Directories"))
            .firstMatch
        XCTAssertTrue(folders.waitForExistence(timeout: 10), "the Excluded Directories row is not a button")
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 5), "the filtering rows have no slider")
        // A Toggle combined into its row reports as a switch (or, on newer runtimes, a toggle).
        let switchRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %lu OR elementType == %lu",
            XCUIElement.ElementType.switch.rawValue, XCUIElement.ElementType.toggle.rawValue)).firstMatch
        var swipes = 0
        while !switchRow.exists, swipes < 3 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(switchRow.waitForExistence(timeout: 5), "the switch row is not a switch")
    }

    /// The full player's top bar: the collapse circle is a button with its label.
    func testPlayerTopBarKeepsButtonTraits() {
        let app = launch("nowPlaying", ready: "screen.nowPlaying")
        let collapse = app.buttons.matching(NSPredicate(format: "label == %@", "Collapse player")).firstMatch
        XCTAssertTrue(collapse.waitForExistence(timeout: 15), "Collapse player is not a button")
    }

    /// The queue's toolbar and ⋯ menu (2026-10-07): separate glass circles and pills in one container with the menu,
    /// the ⋯ circle morphing into "Save as playlist". The circles and pills stay buttons with their labels, and the
    /// morphed pill still opens Save as playlist.
    func testQueueControlsKeepButtonTraits() {
        let app = launch("queue", ready: "screen.queue")
        for label in ["Toggle shuffle", "Toggle repeat", "Sleep timer"] {
            let circle = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(circle.waitForExistence(timeout: 15), "\(label) is not a button")
        }
        let more = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "queue.more",
                                                    "More actions")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "More actions is not a button")
        more.tap()
        let clear = app.buttons.matching(NSPredicate(format: "label == %@", "Clear queue")).firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "Clear queue is not a button")
        let save = app.buttons.matching(NSPredicate(format: "label == %@", "Save as playlist")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "Save as playlist is not a button")
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sheet.saveQueue"].firstMatch.waitForExistence(timeout: 15),
                      "Save as playlist did not open from the menu")
    }

    /// The album header's circles: Back is a button with its label.
    func testDetailHeaderKeepsButtonTraits() {
        let app = launch("albumDetail", ready: "screen.albumDetail")
        let back = app.buttons.matching(NSPredicate(format: "label == %@", "Back")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "Back is not a button")
    }

    /// The lyrics screen's control cluster (2026-10-07: one container for play/pause, the seek bar and the toolbar;
    /// Translate · Sing replace Synced · Static): every control stays a button with its fixed label, and the segments
    /// report their state as the value.
    func testLyricsToolbarKeepsButtonTraits() {
        let app = launch("lyrics", ready: "screen.lyrics")
        for label in ["Back", "Translate", "Sing", "Lyrics options"] {
            let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 15), "\(label) is not a button")
        }
        let playPause = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Play", "Pause"))
            .firstMatch
        XCTAssertTrue(playPause.exists, "play/pause is not a button")
        let sing = app.buttons.matching(NSPredicate(format: "label == %@", "Sing")).firstMatch
        XCTAssertEqual(sing.value as? String, "Vocals on", "Sing does not report its state")
        let translate = app.buttons.matching(NSPredicate(format: "label == %@", "Translate")).firstMatch
        XCTAssertFalse((translate.value as? String ?? "").isEmpty, "Translate does not report its state")
    }

    private func launch(_ screen: String, ready: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 30),
                      "\(ready) did not appear on \(screen)")
        return app
    }
}
