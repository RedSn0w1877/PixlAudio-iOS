import XCTest

/// Cloud Studio screenshots (iOS-first; demo data from `CloudDemo`, no network): Settings › Developer › Experimental ›
/// Cloud processing filled in, with a passed Test connection further down; the queue in every state; the confirm sheet
/// for a 12-song batch. Each in light and dark.
@MainActor
final class CloudStudioScreenshotTests: XCTestCase {
    func testCloudProcessingLight() throws { try capture("cloud.settings", "light", ready: "screen.cloudProcessing") }
    func testCloudProcessingDark() throws { try capture("cloud.settings", "dark", ready: "screen.cloudProcessing") }

    /// Scrolled to Test connection: RunPod and storage each with their own result.
    func testCloudProcessingTestedLight() throws {
        try capture("cloud.settings", "light", ready: "screen.cloudProcessing", suffix: "-tested") { app in
            self.scroll(app, until: "cloud.test")
        }
    }

    func testCloudProcessingTestedDark() throws {
        try capture("cloud.settings", "dark", ready: "screen.cloudProcessing", suffix: "-tested") { app in
            self.scroll(app, until: "cloud.test")
        }
    }

    func testQueueLight() throws { try capture("cloud.queue", "light", ready: "screen.cloudQueue") }
    func testQueueDark() throws { try capture("cloud.queue", "dark", ready: "screen.cloudQueue") }

    /// Further down the queue: what needs the person (Retry) and what came back.
    func testQueueDoneLight() throws {
        try capture("cloud.queue", "light", ready: "screen.cloudQueue", suffix: "-done") { app in
            self.scroll(app, until: "cloud.clearDone")
        }
    }

    func testConfirmLight() throws { try capture("cloud.confirm", "light", ready: "screen.cloudConfirm") }
    func testConfirmDark() throws { try capture("cloud.confirm", "dark", ready: "screen.cloudConfirm") }

    /// The Experimental row that opens Cloud processing.
    func testExperimentalRowLight() throws {
        try capture("experimental", "light", ready: "screen.experimental", suffix: "-cloudRow") { app in
            self.scroll(app, until: "experimental.cloudProcessing")
        }
    }

    // MARK: - Helpers

    /// Scrolls in short, slow, held drags along the leading margin (no momentum, so it can't overshoot; never on a
    /// field or a switch) until `identifier` sits in the upper part of the screen, below the collapsed header.
    private func scroll(_ app: XCUIApplication, until identifier: String) {
        let target = app.descendants(matching: .any)[identifier].firstMatch
        let height = app.windows.firstMatch.frame.height
        for _ in 0..<24 {
            if target.exists, target.frame.minY > height * 0.12, target.frame.minY < height * 0.4 { break }
            let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.7))
            let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(target.exists, "\(identifier) is missing")
    }

    private func capture(_ screen: String, _ appearance: String, ready: String, suffix: String = "",
                         interact: ((XCUIApplication) -> Void)? = nil) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance]
        app.launch()
        let element = app.descendants(matching: .any)[ready].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(ready) did not appear")
        interact?(app)
        // Let glass, transitions and the first measurements settle.
        Thread.sleep(forTimeInterval: 1.5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(screen)-\(appearance)\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
