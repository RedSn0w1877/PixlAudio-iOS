import XCTest

/// Home's active-jobs button and sheet (demo rows from `ActiveJobsDemo`, no services): Home with the button showing,
/// the sheet with jobs running (`jobs`), with finished and failed ones too (`jobs.mixed`) and empty (`jobs.none`),
/// in light and dark; plus the tap from the button to the sheet and the button's VoiceOver words.
@MainActor
final class ActiveJobsScreenshotTests: XCTestCase {
    func testHomeWithJobsLight() throws { try capture("home.jobs", "light", ready: "screen.home", home: true) }
    func testHomeWithJobsDark() throws { try capture("home.jobs", "dark", ready: "screen.home", home: true) }

    func testSheetRunningLight() throws { try capture("jobs", "light", ready: "screen.jobs") }
    func testSheetRunningDark() throws { try capture("jobs", "dark", ready: "screen.jobs") }
    func testSheetMixedLight() throws { try capture("jobs.mixed", "light", ready: "screen.jobs", expand: true) }
    func testSheetMixedDark() throws { try capture("jobs.mixed", "dark", ready: "screen.jobs", expand: true) }
    func testSheetEmptyLight() throws { try capture("jobs.none", "light", ready: "screen.jobs") }

    /// Home with nothing running: the button is not there.
    func testHomeWithoutJobsHasNoButton() throws {
        continueAfterFailure = false
        let app = launch("home", "light")
        XCTAssertTrue(app.descendants(matching: .any)["screen.home"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["home.settings"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["home.jobs"].firstMatch.exists)
        app.terminate()
    }

    /// The button says how many jobs there are, and a tap opens the sheet with its rows.
    func testTappingTheButtonOpensTheSheet() throws {
        continueAfterFailure = false
        let app = launch("home.jobs", "light")
        let button = app.descendants(matching: .any)["home.jobs"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "the jobs button is missing")
        XCTAssertEqual(button.label, "Active jobs")
        XCTAssertEqual(button.value as? String, "5 active jobs")
        button.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.jobs"].firstMatch.waitForExistence(timeout: 10),
                      "the sheet did not open")
        XCTAssertTrue(app.descendants(matching: .any)["jobs.row.cloud.demo"].firstMatch.waitForExistence(timeout: 10),
                      "the cloud row is missing")
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "tap-open-light")
        app.terminate()
    }

    // MARK: - Helpers

    private func launch(_ screen: String, _ appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance]
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func capture(_ screen: String, _ appearance: String, ready: String, home: Bool = false,
                         expand: Bool = false) throws {
        continueAfterFailure = false
        let app = launch(screen, appearance)
        XCTAssertTrue(app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 20),
                      "\(ready) did not appear")
        if home {
            XCTAssertTrue(app.descendants(matching: .any)["home.jobs"].firstMatch.waitForExistence(timeout: 10),
                          "the jobs button is not visible")
            XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].firstMatch.waitForExistence(timeout: 10),
                          "the greeting card is not visible")
        }
        // Let the glass, the rings and (on Home) the shelves settle.
        Thread.sleep(forTimeInterval: 2.0)
        if expand {
            // Pull the sheet up from its grabber so the "Recently finished" part is in the picture.
            let grabber = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.49))
            grabber.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
            Thread.sleep(forTimeInterval: 1.5)
        }
        attach(app, "\(screen)-\(appearance)")
        app.terminate()
    }
}
