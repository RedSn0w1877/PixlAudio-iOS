import XCTest

/// Stage 7b screenshots: Home (top and scrolled: mixes, Your Mix, shelves, Recently Played, the stats card), Daily Mix,
/// Your Mix, Recently Played, Stats (top, scrolled, month range) and Home's sheets, in light and dark where the
/// Android references show both. Compare with docs/design-refs/pp_home.png, pp_shelf.png and pp_shelf2.png.
/// Demo data: the demo library, a deterministic listening history and a pinned clock (Thursday 18:30 UTC).
@MainActor
final class HomeStatsScreenshotTests: XCTestCase {
    // MARK: Home

    func testHomeTopLight() throws { try capture("home", "light", name: "home7b-top") }
    func testHomeTopDark() throws { try capture("home", "dark", name: "home7b-top") }
    func testHomeShelvesLight() throws { try capture("home", "light", name: "home7b-shelves", swipes: 2) }
    func testHomeShelvesDark() throws { try capture("home", "dark", name: "home7b-shelves", swipes: 2) }
    func testHomeBottomLight() throws { try capture("home", "light", name: "home7b-bottom", swipes: 8) }
    func testHomeGreetingExpandedLight() throws {
        try capture("home", "light", name: "home7b-insight") { app in
            app.descendants(matching: .any)["home.greeting.expand"].firstMatch.tap()
        }
    }

    // MARK: Pushed screens

    func testDailyMixLight() throws { try capture("dailyMix", "light") }
    func testYourMixDark() throws { try capture("yourMix", "dark") }
    func testRecentlyPlayedLight() throws { try capture("recentlyPlayed", "light") }
    func testRecentlyPlayedDark() throws { try capture("recentlyPlayed", "dark") }
    func testStatsLight() throws { try capture("stats", "light") }
    func testStatsDark() throws { try capture("stats", "dark") }
    func testStatsScrolledLight() throws { try capture("stats", "light", name: "stats-scrolled", swipes: 3) }
    func testStatsMonthDark() throws {
        try capture("stats", "dark", name: "stats-month") { app in
            app.descendants(matching: .any)["statsRange.Month to Date"].firstMatch.tap()
        }
    }

    // MARK: Sheets

    func testBetaInfoLight() throws { try capture("betaInfo", "light") }
    func testChangelogDark() throws { try capture("changelog", "dark") }
    func testJobsLight() throws { try capture("jobs", "light") }

    // MARK: - Helper

    private func capture(_ screen: String, _ appearance: String, name: String? = nil, swipes: Int = 0,
                         action: ((XCUIApplication) -> Void)? = nil) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance]
        app.launch()

        let identifier = "screen.\(screen)"
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(identifier) did not appear")
        if screen == "home" {
            XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].firstMatch.waitForExistence(timeout: 10),
                          "the greeting card is not visible")
        }

        // Let the Home computation, artwork decoding, album colours and glass settle.
        Thread.sleep(forTimeInterval: 1.5)
        if let action {
            action(app)
            Thread.sleep(forTimeInterval: 1.0)
        }
        for _ in 0..<swipes {
            app.swipeUp(velocity: .slow)
        }
        Thread.sleep(forTimeInterval: swipes > 0 ? 1.5 : 0.5)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(name ?? screen)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
