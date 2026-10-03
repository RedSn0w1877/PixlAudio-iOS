import XCTest

/// Slow, still-separated steps for CI to film (`[record:TransitionRecordingTests]`), so a branch's transitions can be
/// compared frame by frame with main's recording (docs/performance.md › Merge gate): the full player expanding from
/// a tap and collapsing from its button, twice, then a collapse interrupted at once by a tap on the mini player (while
/// the full player is still fading out); and settings rows held down — two interactive rows of one group and a
/// choice row between an item row and a switch row. Opt-in (ci/ui-test-args.sh): full screenshot runs skip it.
/// Its screenshots show each page at rest before the press.
@MainActor
final class TransitionRecordingTests: XCTestCase {
    func testPlayerExpandCollapse() {
        let app = launch("miniPlayer", ready: "miniPlayer")
        let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
        // The mini player's spot in the app, for taps while it is out of the accessibility tree (under the full
        // player, or still fading back in).
        let frame = mini.frame
        let origin = app.frame.origin
        let miniSpot = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + frame.width * 0.35 - origin.x, dy: frame.midY - origin.y))
        // After the full player's pre-warm (a second after the mini player appears).
        Thread.sleep(forTimeInterval: 2.0)
        for _ in 0..<2 {
            miniSpot.tap()
            Thread.sleep(forTimeInterval: 2.5)
            XCTAssertTrue(collapseButton(in: app).waitForExistence(timeout: 10), "the player did not expand")
            collapseButton(in: app).tap()
            Thread.sleep(forTimeInterval: 2.5)
        }
        // Collapse, then tap the mini player at once: the expand takes over the collapse's fade in one transaction
        // (the full player springs back from where the fade had got to, no pop or restart).
        miniSpot.tap()
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(collapseButton(in: app).waitForExistence(timeout: 10), "the player did not expand")
        collapseButton(in: app).tap()
        miniSpot.tap()
        Thread.sleep(forTimeInterval: 2.5)
        // Settle collapsed whichever way the quick tap went (it lands only once the card is under half way).
        if collapseButton(in: app).exists {
            collapseButton(in: app).tap()
            Thread.sleep(forTimeInterval: 2.5)
        }
    }

    func testPressedSettingsRows() {
        hold(screen: "settingsCategory.library", label: "Excluded Directories")
        hold(screen: "settingsCategory.library", label: "Artists")
        hold(screen: "settingsCategory.appearance", label: "App Theme")
    }

    // MARK: - Helpers

    private func collapseButton(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label ==[c] %@", "player.collapse", "Collapse player"))
            .firstMatch
    }

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
