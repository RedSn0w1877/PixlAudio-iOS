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

    /// The album header's circles: Back is a button with its label.
    func testDetailHeaderKeepsButtonTraits() {
        let app = launch("albumDetail", ready: "screen.albumDetail")
        let back = app.buttons.matching(NSPredicate(format: "label == %@", "Back")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "Back is not a button")
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
