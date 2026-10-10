import XCTest

/// Crash protection and diagnostics (2026-10-10): Settings > Developer > Diagnostics (build identity, live status, Safe
/// mode, Share logs, Emergency stop) and About (the build line), in light and dark. An extension of `ScreenshotTests`
/// so the CI shots job (`-only-testing:PixlAudioUITests/ScreenshotTests`) picks it up. The Active jobs states live in
/// `ActiveJobsScreenshotTests` (`jobs.interrupted`, `home.safeMode`).
extension ScreenshotTests {
    func testDiagnosticsHealthLight() throws { try captureHealth("diagnostics", "light", ready: "screen.diagnostics") }
    func testDiagnosticsHealthDark() throws { try captureHealth("diagnostics", "dark", ready: "screen.diagnostics") }
    func testAboutBuildLight() throws { try captureHealth("about", "light", ready: "screen.about") }
    func testAboutBuildDark() throws { try captureHealth("about", "dark", ready: "screen.about") }

    /// Emergency stop asks first; "Keep working" changes nothing, "Stop everything" stops and says so.
    func testEmergencyStopAsksThenStops() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", "diagnostics", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.diagnostics"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["diagnostics.build"].firstMatch.waitForExistence(timeout: 10),
                      "the build identity is missing")
        let stop = app.buttons["diagnostics.emergencyStop"].firstMatch
        var swipes = 0
        while !(stop.exists && stop.isHittable) && swipes < 6 {
            app.windows.firstMatch.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "Emergency stop is missing")
        XCTAssertTrue(app.buttons["diagnostics.shareLogs"].firstMatch.exists, "Share logs is missing")
        stop.tap()
        let keep = app.alerts.buttons["Keep working"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 10), "the confirmation did not appear")
        attachHealth(app, "diagnostics.emergencyStop-confirm-light")
        keep.tap()
        XCTAssertFalse(app.descendants(matching: .any)["diagnostics.emergencyStop.note"].firstMatch.exists)
        stop.tap()
        let confirm = app.alerts.buttons["Stop everything"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["diagnostics.emergencyStop.note"].firstMatch.waitForExistence(timeout: 10),
                      "Emergency stop did not report")
        attachHealth(app, "diagnostics.emergencyStop-done-light")
        app.terminate()
    }

    private func captureHealth(_ screen: String, _ appearance: String, ready: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 20), "\(ready) did not appear")
        Thread.sleep(forTimeInterval: 2.0)
        attachHealth(app, "\(screen).health-\(appearance)")
        app.terminate()
    }

    private func attachHealth(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
