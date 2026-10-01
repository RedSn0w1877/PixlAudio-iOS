import XCTest

/// Stage 6 screenshots: the developer Library Import screen (Diagnostics › Library Import). An extension of
/// `ScreenshotTests` so the CI shots job (`-only-testing:PixlAudioUITests/ScreenshotTests`) picks it up.
extension ScreenshotTests {
    func testLibraryImportDebugLight() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", "diagnostics", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.diagnostics"].firstMatch.waitForExistence(timeout: 20))

        // The row must sit well clear of the bottom: on pushed screens the mini player floats over the last
        // ~100 pt, and a tap there opens Now Playing instead of following the link.
        let link = app.descendants(matching: .any)["diagnostics.libraryImport"].firstMatch
        let safeMaxY = app.windows.firstMatch.frame.height * 0.6
        var swipes = 0
        // Short drags (~30 % of the screen each) so the row cannot overshoot past the top.
        let window = app.windows.firstMatch
        while (!link.exists || link.frame.maxY > safeMaxY) && swipes < 10 {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: end)
            swipes += 1
        }
        XCTAssertTrue(link.isHittable, "diagnostics.libraryImport is not reachable")
        link.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.libraryImportDebug"].firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.0)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "libraryImportDebug-light"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
