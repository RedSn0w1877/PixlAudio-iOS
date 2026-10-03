import XCTest

/// EXPERIMENT (not for main): the full player is pre-built and kept hidden while collapsed. Does it miss play / pause
/// changes made from the mini player while it is hidden? After each toggle the app reports "STALE" when the hidden
/// NowPlayingView last rendered another play state than the store's.
@MainActor
final class StaleToggleProbeTests: XCTestCase {
    func testTogglesWhileCollapsed() {
        continueAfterFailure = true
        var checks = 0, stale = 0, persisted = 0
        for index in 0..<16 {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTest", "-screen", "miniPlayer", "-appearance", "dark"]
            app.launch()
            let button = app.buttons["miniPlayer.playPause"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 20))
            Thread.sleep(forTimeInterval: 2.0)
            for toggle in 0..<10 {
                button.tap()
                Thread.sleep(forTimeInterval: Double(toggle % 3) * 0.3 + 0.4)
                let state = state(app)
                checks += 1
                if state.hasPrefix("STALE") {
                    stale += 1
                    note(state, "\(index)-\(toggle)-stale")
                    Thread.sleep(forTimeInterval: 1.5)
                    let later = state(app)
                    note(later, "\(index)-\(toggle)-after1.5s")
                    if later.hasPrefix("STALE") { persisted += 1 }
                }
            }
            app.terminate()
        }
        note("\(stale) stale of \(checks) checks, \(persisted) still stale 1.5 s later",
             "summary-\(stale)-stale-of-\(checks)-persisted-\(persisted)")
    }

    private func state(_ app: XCUIApplication) -> String {
        let label = app.descendants(matching: .any)["debug.sheet"].firstMatch
        return label.waitForExistence(timeout: 2) ? label.label : "missing"
    }

    private func note(_ text: String, _ name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "toggle-\(name).txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
