import XCTest

/// EXPERIMENT (not for main): filmed with `[record:PressFadeRecordingTests]` on main and on perf-transitions, to
/// compare frame by frame (1) interactive settings rows held down (the branch draws a group's rows in one
/// `GlassEffectContainer(spacing: 0)`, 2 pt apart) and (2) the full player's expand and collapse. Each step is
/// slow and separated by still pauses so the video can be cut into segments.
@MainActor
final class PressFadeRecordingTests: XCTestCase {
    func testPressedRows() {
        hold(screen: "settingsCategory.library", label: "Excluded Directories")
        hold(screen: "settingsCategory.library", label: "Artists")
        hold(screen: "settingsCategory.appearance", label: "App Theme")
    }

    func testPlayerExpandCollapse() {
        continueAfterFailure = true
        let app = launch("miniPlayer", ready: "miniPlayer")
        let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
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
        app.terminate()
    }

    // MARK: - Helpers

    private func launch(_ screen: String, ready: String) -> XCUIApplication {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 20),
                      "\(ready) did not appear")
        return app
    }

    /// Holds the row down for 2.5 s, then slides off it (so its action doesn't run).
    private func hold(screen: String, label: String) {
        let app = launch(screen, ready: "screen.\(screen)")
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", label)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no \(label) row")
        Thread.sleep(forTimeInterval: 2.0)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "press-rest-\(screen)-\(label)"
        shot.lifetime = .keepAlways
        add(shot)
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 2.5, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 260)))
        Thread.sleep(forTimeInterval: 2.0)
        app.terminate()
    }
}
