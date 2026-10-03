import XCTest

/// Slow, still-separated steps for CI to film (`[record:TransitionRecordingTests]`), so a branch's transitions can be
/// compared frame by frame with main's recording (docs/performance.md › Merge gate): the full player expanding from
/// a tap and collapsing from its button, twice, and settings rows held down — two interactive rows of one group and
/// a choice row between an item row and a switch row. Opt-in (ci/ui-test-args.sh): full screenshot runs skip it.
/// Its screenshots show each page at rest before the press.
@MainActor
final class TransitionRecordingTests: XCTestCase {
    func testPlayerExpandCollapse() {
        let app = launch("miniPlayer", ready: "miniPlayer")
        let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
        // After the full player's pre-warm (a second after the mini player appears).
        Thread.sleep(forTimeInterval: 2.0)
        for _ in 0..<2 {
            mini.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 2.5)
            let collapse = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@ OR label ==[c] %@", "player.collapse", "Collapse player"))
                .firstMatch
            XCTAssertTrue(collapse.waitForExistence(timeout: 10), "the player did not expand")
            collapse.tap()
            Thread.sleep(forTimeInterval: 2.5)
        }
    }

    func testPressedSettingsRows() {
        hold(screen: "settingsCategory.library", label: "Excluded Directories")
        hold(screen: "settingsCategory.library", label: "Artists")
        hold(screen: "settingsCategory.appearance", label: "App Theme")
    }

    // MARK: - Helpers

    private func launch(_ screen: String, ready: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 20),
                      "\(ready) did not appear")
        return app
    }

    /// Holds the row down for 2.5 s, then slides off it (the row's action doesn't run), and lets the page settle.
    private func hold(screen: String, label: String) {
        let app = launch(screen, ready: "screen.\(screen)")
        // Rows inside the page's identified scroll view keep only their labels.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] %@", label))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no \(label) row")
        Thread.sleep(forTimeInterval: 2.0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "pressRest-\(screen)-\(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 2.5, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 260)))
        Thread.sleep(forTimeInterval: 2.0)
        app.terminate()
    }
}
