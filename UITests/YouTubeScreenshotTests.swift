import XCTest

/// Stage 11 screenshots: the YouTube sign-in screen (sign-in page stand-in, the device-code sheet, the cookie paste
/// sheet, signed in) and the playback test (all green, and failing at the audio step), light + dark. Compare with
/// Android's `YouTubeLoginScreen`, `YouTubeSignInDialog`, `YouTubeAccountCard` and `DiagnosticsCard`.
@MainActor
final class YouTubeScreenshotTests: XCTestCase {
    func testLoginLight() throws { try capture("youTubeLogin", "light", ready: "youtube.signInPage") }
    func testLoginDark() throws { try capture("youTubeLogin", "dark", ready: "youtube.signInPage") }
    func testLoginCodeLight() throws { try capture("youTubeLoginCode", "light", ready: "youtube.userCode") }
    func testLoginCodeDark() throws { try capture("youTubeLoginCode", "dark", ready: "youtube.userCode") }
    func testLoginCookieLight() throws { try capture("youTubeLoginCookie", "light", ready: "youtube.cookieField") }
    func testLoginCookieDark() throws { try capture("youTubeLoginCookie", "dark", ready: "youtube.cookieField") }
    func testLoginSignedInLight() throws { try capture("youTubeLoginSignedIn", "light", ready: "youtube.disconnect") }
    func testLoginSignedInDark() throws { try capture("youTubeLoginSignedIn", "dark", ready: "youtube.disconnect") }
    func testPlaybackDiagnosticsLight() throws { try capture("playbackDiagnostics", "light", ready: "diagnostics.card") }
    func testPlaybackDiagnosticsDark() throws { try capture("playbackDiagnostics", "dark", ready: "diagnostics.card") }
    func testPlaybackDiagnosticsFailedLight() throws {
        try capture("playbackDiagnosticsFailed", "light", ready: "diagnostics.card")
    }
    func testPlaybackDiagnosticsFailedDark() throws {
        try capture("playbackDiagnosticsFailed", "dark", ready: "diagnostics.card")
    }

    // MARK: - Helper

    private func capture(_ screen: String, _ appearance: String, ready: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance]
        app.launch()

        let element = app.descendants(matching: .any)[ready].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(ready) did not appear on \(screen)")

        // Let glass, sheet presentation and the first measurements settle.
        Thread.sleep(forTimeInterval: 2.0)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(screen)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
    }
}
