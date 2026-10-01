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

        let link = app.descendants(matching: .any)["diagnostics.libraryImport"].firstMatch
        var swipes = 0
        while !link.isHittable && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
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
