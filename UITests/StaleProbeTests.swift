import XCTest

/// EXPERIMENT (not for main): is the full player's play state ever stale, and does it heal by itself or on the next
/// play / pause? The app reports "STALE" when NowPlayingView last rendered another play state than the store's.
@MainActor
final class StaleProbeTests: XCTestCase {
    func testLaunchExpanded() {
        probe(runs: 45, name: "launch") { app in
            app.launchArguments = ["-uiTest", "-screen", "nowPlaying", "-appearance", "dark"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["screen.nowPlaying"].firstMatch.waitForExistence(timeout: 20))
        }
    }

    func testExpandAfterPrewarm() {
        probe(runs: 30, name: "prewarm") { app in
            app.launchArguments = ["-uiTest", "-screen", "miniPlayer", "-appearance", "dark"]
            app.launch()
            let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
            XCTAssertTrue(mini.waitForExistence(timeout: 20))
            Thread.sleep(forTimeInterval: 2.5)
            mini.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        }
    }

    private func probe(runs: Int, name: String, open: (XCUIApplication) -> Void) {
        continueAfterFailure = true
        var stale = 0, healedByWaiting = 0, healedByToggle = 0, staleAfterToggle = 0
        for index in 0..<runs {
            let app = XCUIApplication()
            open(app)
            Thread.sleep(forTimeInterval: 2.0)
            let first = state(app)
            if index == 0 { note(first, "\(name)-first") }
            if first.hasPrefix("STALE") {
                stale += 1
                note(first, "\(name)-\(index)-stale")
                attach(app.screenshot(), "\(name)-\(index)-stale")
                Thread.sleep(forTimeInterval: 3.0)
                let waited = state(app)
                note(waited, "\(name)-\(index)-after3s")
                if !waited.hasPrefix("STALE") { healedByWaiting += 1 } else {
                    let button = app.buttons["player.playPause"].firstMatch
                    if button.waitForExistence(timeout: 3) { button.tap() }
                    Thread.sleep(forTimeInterval: 1.5)
                    let toggled = state(app)
                    note(toggled, "\(name)-\(index)-afterToggle")
                    if toggled.hasPrefix("STALE") { staleAfterToggle += 1 } else { healedByToggle += 1 }
                    if button.exists { button.tap() }
                    Thread.sleep(forTimeInterval: 1.5)
                    note(state(app), "\(name)-\(index)-afterSecondToggle")
                }
            }
            app.terminate()
        }
        note("\(name): \(stale) stale of \(runs); healed by waiting \(healedByWaiting), by a toggle \(healedByToggle); "
             + "still stale after a toggle \(staleAfterToggle)",
             "\(name)-summary-\(stale)-stale-of-\(runs)-wait\(healedByWaiting)-toggle\(healedByToggle)-stuck\(staleAfterToggle)")
    }

    private func state(_ app: XCUIApplication) -> String {
        let label = app.descendants(matching: .any)["debug.sheet"].firstMatch
        return label.waitForExistence(timeout: 2) ? label.label : "missing"
    }

    private func note(_ text: String, _ name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "stale-\(name).txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "stale-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
