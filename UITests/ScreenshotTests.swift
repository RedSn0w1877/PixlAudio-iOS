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

    // MARK: Accent colour (iOS-only, owner request 2026-10-07): the chrome takes the accent, the player its album

    /// Home in Green (dark): the tab bar's pill, Home's chrome and cards; the mini player keeps its album colours.
    func testHomeAccentGreenDark() throws {
        try capture("home", "dark", extra: ["-accent", "34C759"], suffix: "-accentGreen")
    }
    /// Library in Blue (light, the vivid tone): the pill, the library tabs and chips.
    func testLibraryAccentBlueLight() throws {
        try capture("library", "light", extra: ["-accent", "0A84FF"], suffix: "-accentBlue")
    }
    /// The settings list in Pink (light): icons and row glass take the accent's hue.
    func testSettingsAccentPinkLight() throws {
        try capture("settings", "light", extra: ["-accent", "FF2D55"], suffix: "-accentPink")
    }

    // MARK: Tab bar (owner change 2026-10-01: iOS-style glass bar, accent pill gliding between tabs)

    /// A tap switches tabs and marks the tab selected; the shot shows the pill under Library.
    func testTabBarTapLight() throws {
        let app = launchHome("light")
        let library = app.descendants(matching: .any)["navBar.library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10), "the Library tab is missing")
        library.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.library"].firstMatch.waitForExistence(timeout: 5),
                      "tapping Library did not switch tabs")
        XCTAssertTrue(library.isSelected, "the Library tab is not marked selected")
        attachScreenshot(app, "tabBarTap-light")
    }

    /// Press and drag from Home to Search: the pill follows the finger and Search is selected on release.
    func testTabBarDragDark() throws {
        let app = launchHome("dark")
        let home = app.descendants(matching: .any)["navBar.home"].firstMatch
        let search = app.descendants(matching: .any)["navBar.search"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 10) && search.exists, "the tab bar items are missing")
        home.press(forDuration: 0.2, thenDragTo: search)
        XCTAssertTrue(app.descendants(matching: .any)["screen.search"].firstMatch.waitForExistence(timeout: 5),
                      "dragging to Search did not switch tabs")
        XCTAssertTrue(search.isSelected, "the Search tab is not marked selected")
        attachScreenshot(app, "tabBarDrag-dark")
    }

    /// Scrolling Home down minimizes the bar (symbols only, narrow, lower); scrolling back up restores it.
    func testTabBarMinimizesOnScrollLight() throws {
        let app = launchHome("light")
        // Drag the page by coordinates, clear of the top bar (a swipe from the screen element's centre can land on
        // the Beta pill and open its sheet).
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        lower.press(forDuration: 0.05, thenDragTo: upper)
        Thread.sleep(forTimeInterval: 1.0)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "tabBarMinimized-light"
        shot.lifetime = .keepAlways
        add(shot)
        let library = app.descendants(matching: .any)["navBar.library"].firstMatch
        XCTAssertTrue(library.isHittable, "the minimized bar's Library tab is not tappable")
        upper.press(forDuration: 0.05, thenDragTo: lower)
        attachScreenshot(app, "tabBarRestored-light")
    }

    // MARK: - Helpers

    private func launchHome(_ appearance: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", "home", "-appearance", appearance]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.home"].firstMatch.waitForExistence(timeout: 20),
                      "screen.home did not appear")
        return app
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        // Let the pill settle and the next tab's artwork and glass render.
        Thread.sleep(forTimeInterval: 1.5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    private static let readyIdentifiers: [String: String] = [
        "home": "screen.home",
        "library": "screen.library",
        "miniPlayer": "screen.library",
        "miniPlayerAlone": "screen.albumDetail",
        "search": "screen.search",
        "settings": "screen.settings",
    ]

    /// `extra`: more launch arguments (e.g. `-accent RRGGBB`); `suffix` tells such a shot apart from the plain one
    /// (`<screen>-<appearance><suffix>`), so the exported PNGs don't collide.
    private func capture(_ screen: String, _ appearance: String, ready: String? = nil, extra: [String] = [],
                         suffix: String = "") throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance] + extra
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
        attachment.name = "\(screen)-\(appearance)" + suffix
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
    }
}
