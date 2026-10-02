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
    func testBackupCategoryLight() throws { try capture("settingsCategory.backup_restore", "light") }
    func testBackupCategoryDark() throws { try capture("settingsCategory.backup_restore", "dark") }
    func testDeveloperCategoryLight() throws { try capture("settingsCategory.developer", "light") }
    func testDeveloperCategoryDark() throws { try capture("settingsCategory.developer", "dark") }
    func testDeviceCapabilitiesCategoryLight() throws { try capture("settingsCategory.device_capabilities", "light") }
    func testDeviceCapabilitiesCategoryDark() throws { try capture("settingsCategory.device_capabilities", "dark") }
    func testAboutCategoryLight() throws { try capture("settingsCategory.about", "light") }
    func testAboutCategoryDark() throws { try capture("settingsCategory.about", "dark") }

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

    private func capture(_ screen: String, _ appearance: String, interact: ((XCUIApplication) -> Void)? = nil) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance]
        app.launch()

        let identifier = "screen.\(screen)"
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(identifier) did not appear")
        interact?(app)

        // Let glass, transitions and the first measurements settle.
        Thread.sleep(forTimeInterval: 2.0)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(screen)-\(appearance)" + (interact == nil ? "" : "-interacted")
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
    }
}
