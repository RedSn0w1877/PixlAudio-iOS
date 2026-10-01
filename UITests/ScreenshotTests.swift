import XCTest

/// Screenshot tests: each test launches the app straight into one screen with demo data
/// (`-uiTest -screen <id> -appearance light|dark`) and attaches a screenshot named `<screen>-<appearance>`.
/// CI exports the attachments (`ci/export-shots.sh`) into the `shots-<sha>` artifact. Compare each with the
/// Android reference in docs/design-refs/ (see docs/design.md › Screenshot ids).
@MainActor
final class ScreenshotTests: XCTestCase {
    // MARK: Shell (stage 4): Home + Library placeholders in PixlAudio's layout, mini player over the glass bar

    func testHomeLight() throws { try capture("home", "light") }
    func testHomeDark() throws { try capture("home", "dark") }
    func testLibraryLight() throws { try capture("library", "light") }
    func testLibraryDark() throws { try capture("library", "dark") }

    /// Library with a vividly coloured song playing: the album-tinted glass mini player (ref: owner-library-songs).
    func testMiniPlayerLight() throws { try capture("miniPlayer", "light") }
    func testMiniPlayerDark() throws { try capture("miniPlayer", "dark") }

    /// A pushed screen: the bottom bar hides and the mini player sits alone with 32 pt corners.
    func testMiniPlayerAloneLight() throws { try capture("miniPlayerAlone", "light") }
    func testMiniPlayerAloneDark() throws { try capture("miniPlayerAlone", "dark") }

    // MARK: Other placeholders

    func testSearchDark() throws { try capture("search", "dark") }
    func testSettingsLight() throws { try capture("settings", "light") }
    func testNowPlayingDark() throws { try capture("nowPlaying", "dark", ready: "screen.nowPlaying") }
    func testDiagnosticsLight() throws { try capture("diagnostics", "light", ready: "screen.diagnostics") }

    // MARK: - Helpers

    private static let readyIdentifiers: [String: String] = [
        "home": "screen.home",
        "library": "screen.library",
        "miniPlayer": "screen.library",
        "miniPlayerAlone": "screen.albumDetail",
        "search": "screen.search",
        "settings": "screen.settings",
    ]

    private func capture(_ screen: String, _ appearance: String, ready: String? = nil) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance]
        app.launch()

        let identifier = ready ?? Self.readyIdentifiers[screen] ?? "screen.\(screen)"
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(identifier) did not appear")

        if screen.hasPrefix("miniPlayer") || screen == "home" || screen == "library" {
            XCTAssertTrue(app.descendants(matching: .any)["miniPlayer"].firstMatch.waitForExistence(timeout: 10),
                          "the mini player is not visible")
        }
        if screen == "home" || screen == "library" || screen == "miniPlayer" {
            XCTAssertTrue(app.descendants(matching: .any)["navBar"].firstMatch.exists, "the bottom bar is not visible")
        }

        // Let artwork decoding, album colour extraction, glass and transitions settle.
        Thread.sleep(forTimeInterval: 2.0)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(screen)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
    }
}
