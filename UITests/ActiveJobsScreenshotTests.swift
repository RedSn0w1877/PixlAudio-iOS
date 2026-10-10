import XCTest

/// Home's active-jobs button and sheet (demo rows from `ActiveJobsDemo`, no services): Home with the button showing,
/// the sheet with jobs running (`jobs`), with finished and failed ones too (`jobs.mixed`) and empty (`jobs.none`),
/// in light and dark; plus the tap from the button to the sheet and the button's VoiceOver words. The failure states
/// (`jobs.failed`: a model with no source, a download with no connection, a cloud batch, the matcher, a lyric sync) show
/// Retry, Dismiss, Clear finished and Cancel all, and the tests press them; a failed model download in Settings shows
/// "Try again" and "Delete download".
@MainActor
final class ActiveJobsScreenshotTests: XCTestCase {
    func testHomeWithJobsLight() throws { try capture("home.jobs", "light", ready: "screen.home", home: true) }
    func testHomeWithJobsDark() throws { try capture("home.jobs", "dark", ready: "screen.home", home: true) }

    func testSheetRunningLight() throws { try capture("jobs", "light", ready: "screen.jobs") }
    func testSheetRunningDark() throws { try capture("jobs", "dark", ready: "screen.jobs") }
    func testSheetMixedLight() throws { try capture("jobs.mixed", "light", ready: "screen.jobs", expand: true) }
    func testSheetMixedDark() throws { try capture("jobs.mixed", "dark", ready: "screen.jobs", expand: true) }
    func testSheetEmptyLight() throws { try capture("jobs.none", "light", ready: "screen.jobs") }

    func testSheetFailedLight() throws { try capture("jobs.failed", "light", ready: "screen.jobs", expand: true) }
    func testSheetFailedDark() throws { try capture("jobs.failed", "dark", ready: "screen.jobs", expand: true) }

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

    // MARK: - Clearing things out

    /// "Clear finished" empties "Recently finished" (every finished and failed row) and leaves what is running.
    func testClearFinishedEmptiesTheSheetAndLeavesRunningWork() throws {
        continueAfterFailure = false
        let app = launch("jobs.failed", "light")
        XCTAssertTrue(app.descendants(matching: .any)["screen.jobs"].firstMatch.waitForExistence(timeout: 20))
        expandSheet(app)
        let clear = app.buttons["jobs.clearFinished"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "Clear finished is missing")
        XCTAssertTrue(app.descendants(matching: .any)["jobs.row.model.failed.llm"].firstMatch.exists)
        attach(app, "jobs.failed-before-clear-light")
        clear.tap()
        waitForDisappearance(app.descendants(matching: .any)["jobs.row.model.failed.llm"].firstMatch)
        waitForDisappearance(clear)
        XCTAssertFalse(app.descendants(matching: .any)["jobs.row.cloud.failed"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["jobs.row.library"].firstMatch.exists, "running work stays")
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "jobs.failed-cleared-light")
        app.terminate()
    }

    /// "Cancel all" asks first; "Keep running" changes nothing; "Cancel all" stops everything that runs.
    func testCancelAllAsksFirstThenStopsEverything() throws {
        continueAfterFailure = false
        let app = launch("jobs.failed", "light")
        XCTAssertTrue(app.descendants(matching: .any)["screen.jobs"].firstMatch.waitForExistence(timeout: 20))
        expandSheet(app)
        let cancelAll = app.buttons["jobs.cancelAll"].firstMatch
        XCTAssertTrue(cancelAll.waitForExistence(timeout: 10), "Cancel all is missing")
        cancelAll.tap()
        let alert = app.alerts["Cancel all jobs?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the confirmation did not appear")
        Thread.sleep(forTimeInterval: 0.6)
        attach(app, "jobs.cancelAll-alert-light")
        alert.buttons["Keep running"].tap()
        waitForDisappearance(alert)
        XCTAssertTrue(app.descendants(matching: .any)["jobs.row.library"].firstMatch.exists, "Keep running keeps it")
        cancelAll.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["Cancel all"].tap()
        waitForDisappearance(app.descendants(matching: .any)["jobs.row.library"].firstMatch)
        waitForDisappearance(cancelAll)
        XCTAssertTrue(app.descendants(matching: .any)["jobs.empty"].firstMatch.waitForExistence(timeout: 10),
                      "nothing is left running")
        XCTAssertTrue(app.descendants(matching: .any)["jobs.row.model.failed.llm"].firstMatch.exists,
                      "finished rows stay until they are cleared")
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "jobs.cancelAll-done-light")
        app.terminate()
    }

    /// Dismiss takes one failed row; Retry puts a failed row back in the queue (its Retry and Dismiss go).
    func testDismissAndRetryActOnOneRow() throws {
        continueAfterFailure = false
        let app = launch("jobs.failed", "light")
        XCTAssertTrue(app.descendants(matching: .any)["screen.jobs"].firstMatch.waitForExistence(timeout: 20))
        expandSheet(app)
        let dismiss = app.buttons["jobs.dismiss.model.failed.llm"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10), "a failed row has a Dismiss")
        dismiss.tap()
        waitForDisappearance(app.descendants(matching: .any)["jobs.row.model.failed.llm"].firstMatch)
        XCTAssertTrue(app.descendants(matching: .any)["jobs.row.download.failed.demo1"].firstMatch.exists,
                      "the other failed rows stay")
        let retry = app.buttons["jobs.retry.download.failed.demo1"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "a failed row that can be retried has Retry")
        attach(app, "jobs.retry-before-light")
        retry.tap()
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "jobs.retry-after-light")
        waitForDisappearance(retry)
        XCTAssertTrue(app.descendants(matching: .any)["jobs.row.download.failed.demo1"].firstMatch.exists,
                      "the retried job is back in the list")
        app.terminate()
    }

    // MARK: - A failed model download

    func testFailedModelDownloadLight() throws { try captureFailedModel("light") }
    func testFailedModelDownloadDark() throws { try captureFailedModel("dark") }

    /// The reason, "Try again" and "Delete download" under the model's row; Delete download goes back to "not downloaded".
    private func captureFailedModel(_ appearance: String) throws {
        continueAfterFailure = false
        let app = launch("settingsCategory.ai.localModelFailed", appearance)
        XCTAssertTrue(app.descendants(matching: .any)["screen.settingsCategory.ai"].firstMatch.waitForExistence(timeout: 20))
        let row = app.descendants(matching: .any)["settings.ai.localModel"].firstMatch
        let limit = app.windows.firstMatch.frame.maxY - 130
        for _ in 0..<8 {
            if row.exists && row.frame.maxY <= limit { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.7))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(row.exists, "the model's row is missing")
        let retry = app.buttons["settings.ai.localModel.retry"].firstMatch
        let reset = app.buttons["settings.ai.localModel.reset"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 10), "Try again is missing")
        XCTAssertTrue(reset.exists, "Delete download is missing")
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, "settingsCategory.ai.localModelFailed-\(appearance)")
        if appearance == "light" {
            reset.tap()
            waitForDisappearance(reset)
            XCTAssertTrue(app.buttons["settings.ai.localModel.download"].firstMatch.waitForExistence(timeout: 10),
                          "after Delete download the row offers Download again")
            Thread.sleep(forTimeInterval: 1.0)
            attach(app, "settingsCategory.ai.localModelFailed-reset-light")
        }
        app.terminate()
    }

    // MARK: - Helpers

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, "\(element) did not go away")
    }

    /// Pulls the sheet up from its grabber so the part below the first rows is on screen.
    private func expandSheet(_ app: XCUIApplication) {
        let grabber = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.49))
        grabber.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
        Thread.sleep(forTimeInterval: 1.5)
    }

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
            expandSheet(app)
        }
        attach(app, "\(screen)-\(appearance)")
        app.terminate()
    }
}
