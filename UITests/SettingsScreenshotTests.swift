import XCTest

/// Stage 7d screenshots: the main settings list and every category in light and dark (compare with
/// docs/design-refs/pp_set.png), plus the settings sub-screens. Each test launches straight into its screen
/// (`-uiTest -screen <id> -appearance <mode>`), waits for `screen.<id>`, and attaches `<id>-<mode>`.
@MainActor
final class SettingsScreenshotTests: XCTestCase {
    // MARK: Main list + categories (light and dark)

    func testSettingsDark() throws { try capture("settings", "dark") }
    func testLibraryCategoryLight() throws { try capture("settingsCategory.library", "light") }
    func testLibraryCategoryDark() throws { try capture("settingsCategory.library", "dark") }
    func testAppearanceCategoryLight() throws { try capture("settingsCategory.appearance", "light") }
    func testAppearanceCategoryDark() throws { try capture("settingsCategory.appearance", "dark") }
    func testPlaybackCategoryLight() throws { try capture("settingsCategory.playback", "light") }
    func testPlaybackCategoryDark() throws { try capture("settingsCategory.playback", "dark") }
    func testEqualizerCategoryLight() throws { try capture("settingsCategory.equalizer", "light") }
    func testEqualizerCategoryDark() throws { try capture("settingsCategory.equalizer", "dark") }
    func testBehaviorCategoryLight() throws { try capture("settingsCategory.behavior", "light") }
    func testBehaviorCategoryDark() throws { try capture("settingsCategory.behavior", "dark") }
    func testAICategoryLight() throws { try capture("settingsCategory.ai", "light") }
    func testAICategoryDark() throws { try capture("settingsCategory.ai", "dark") }
    /// AI features with the optional cloud assistant switched on (Gemini, the demo key): provider picker, sign-in.
    func testAICategoryCloudLight() throws {
        try capture("settingsCategory.ai.cloud", "light", ready: "screen.settingsCategory.ai")
    }
    func testAICategoryCloudDark() throws {
        try capture("settingsCategory.ai.cloud", "dark", ready: "screen.settingsCategory.ai")
    }
    /// "Use downloaded AI model" on, the model downloading (42 %): the switch, the progress bar and Cancel.
    func testAICategoryLocalModelDownloadingLight() throws {
        try capture("settingsCategory.ai.localModel", "light", ready: "screen.settingsCategory.ai",
                    suffix: "", interact: Self.scrollToLocalModel)
    }
    func testAICategoryLocalModelDownloadingDark() throws {
        try capture("settingsCategory.ai.localModel", "dark", ready: "screen.settingsCategory.ai",
                    suffix: "", interact: Self.scrollToLocalModel)
    }
    /// The model downloaded: its size on the phone and Delete; the system model's row says it isn't in use.
    func testAICategoryLocalModelReadyLight() throws {
        try capture("settingsCategory.ai.localModelReady", "light", ready: "screen.settingsCategory.ai",
                    suffix: "", interact: Self.scrollToLocalModel)
    }
    func testAICategoryLocalModelReadyDark() throws {
        try capture("settingsCategory.ai.localModelReady", "dark", ready: "screen.settingsCategory.ai",
                    suffix: "", interact: Self.scrollToLocalModel)
    }

    /// Scrolls until the downloaded model's row is on screen (it sits under the two AI cards).
    private static func scrollToLocalModel(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)["settings.ai.localModel"].firstMatch
        for _ in 0..<6 {
            if row.exists && row.isHittable { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(row.exists, "the downloaded model's row is missing")
    }

    /// On-device: Advanced shows only Temperature.
    func testAICategoryAdvancedOnDeviceLight() throws {
        try capture("settingsCategory.ai", "light") { app in
            let advanced = app.descendants(matching: .any)["settings.ai.advanced"].firstMatch
            for _ in 0..<6 {
                if advanced.exists && advanced.isHittable { break }
                app.swipeUp()
            }
            if advanced.exists && advanced.isHittable { advanced.tap() }
            app.swipeUp()
        }
    }
    func testBackupCategoryLight() throws { try capture("settingsCategory.backup_restore", "light") }
    func testBackupCategoryDark() throws { try capture("settingsCategory.backup_restore", "dark") }
    func testDeveloperCategoryLight() throws { try capture("settingsCategory.developer", "light") }
    func testDeveloperCategoryDark() throws { try capture("settingsCategory.developer", "dark") }
    func testDeviceCapabilitiesCategoryLight() throws { try capture("settingsCategory.device_capabilities", "light") }
    func testDeviceCapabilitiesCategoryDark() throws { try capture("settingsCategory.device_capabilities", "dark") }
    func testAboutCategoryLight() throws { try capture("settingsCategory.about", "light") }
    func testAboutCategoryDark() throws { try capture("settingsCategory.about", "dark") }

    // MARK: Accent colour (iOS-only, owner request 2026-10-07)

    /// Appearance with a picked accent (`-accent`): the swatch grid's ring on Red, and the page's captions, switches
    /// and value capsules in the red scheme (vivid in light, pastel in dark); icons and row glass take its hue.
    func testAppearanceAccentRedLight() throws {
        try capture("settingsCategory.appearance", "light", extra: ["-accent", "FF453A"], suffix: "-accentRed")
    }
    func testAppearanceAccentRedDark() throws {
        try capture("settingsCategory.appearance", "dark", extra: ["-accent", "FF453A"], suffix: "-accentRed")
    }
    /// Graphite: a grey scheme (pure greys at the scheme's tones).
    func testAppearanceAccentGraphiteDark() throws {
        try capture("settingsCategory.appearance", "dark", extra: ["-accent", "8E8E93"], suffix: "-accentGraphite")
    }
    /// A custom colour (not a preset): the ring moves to the Custom well.
    func testAppearanceAccentCustomLight() throws {
        try capture("settingsCategory.appearance", "light", extra: ["-accent", "B4502D"], suffix: "-accentCustom")
    }
    /// Tapping a preset re-themes the page live and moves the ring (the default violet → Green).
    func testAppearanceAccentTapGreenLight() throws {
        try capture("settingsCategory.appearance", "light", suffix: "-accentTapGreen") { app in
            let green = app.buttons["settings.accent.green"].firstMatch
            XCTAssertTrue(green.waitForExistence(timeout: 5), "the Green swatch is not on screen")
            XCTAssertTrue(app.buttons["settings.accent.default"].firstMatch.isSelected, "the default is selected")
            green.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: green)
            XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 5), .completed, "Green did not become selected")
        }
    }

    // MARK: Sub-screens

    func testExperimentalLight() throws { try capture("experimental", "light") }
    func testArtistSettingsLight() throws { try capture("artistSettings", "light") }
    func testDelimiterConfigDark() throws { try capture("delimiterConfig", "dark") }
    func testWordDelimiterConfigLight() throws { try capture("wordDelimiterConfig", "light") }
    func testEditTransitionLight() throws { try capture("editTransition", "light") }
    func testEditTransitionDark() throws { try capture("editTransition", "dark") }
    func testOpenSourceLicensesLight() throws { try capture("openSourceLicenses", "light") }
    /// The third-party notices sheet (laid out by paragraph; spacing as one text).
    func testThirdPartyNoticesLight() throws {
        try capture("openSourceLicenses", "light") { app in
            let predicate = NSPredicate(format: "identifier == %@ OR label CONTAINS[c] %@", "licenses.notices", "notices")
            let button = app.buttons.matching(predicate).firstMatch
            if button.waitForExistence(timeout: 5) { button.tap() }
            _ = app.descendants(matching: .any)["licenses.noticesSheet"].firstMatch.waitForExistence(timeout: 5)
        }
    }
    func testEasterEggDark() throws { try capture("easterEgg", "dark") }

    /// The equalizer in its other view modes and the brick game in play.
    func testEqualizerGraphModeLight() throws {
        try capture("equalizer", "light") { app in
            app.descendants(matching: .any)["eq.viewMode"].firstMatch.tap()
        }
    }

    func testEasterEggPlayingLight() throws {
        try capture("easterEgg", "light") { app in
            let play = app.descendants(matching: .any)["brick.play"].firstMatch
            if play.waitForExistence(timeout: 5) { play.tap() }
        }
    }

    // MARK: - Helper

    /// `ready`: the element that marks the screen as loaded (default `screen.<screen>`). `extra`: more launch
    /// arguments (e.g. `-accent RRGGBB`); `suffix` tells such a shot apart from the plain one
    /// (`<screen>-<appearance><suffix>`), so the exported PNGs don't collide.
    private func capture(_ screen: String, _ appearance: String, ready: String? = nil, extra: [String] = [],
                         suffix: String? = nil,
                         interact: ((XCUIApplication) -> Void)? = nil) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance] + extra
        app.launch()

        let identifier = ready ?? "screen.\(screen)"
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(identifier) did not appear")
        interact?(app)

        // Let glass, transitions and the first measurements settle.
        Thread.sleep(forTimeInterval: 2.0)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(screen)-\(appearance)" + (suffix ?? (interact == nil ? "" : "-interacted"))
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
    }
}
