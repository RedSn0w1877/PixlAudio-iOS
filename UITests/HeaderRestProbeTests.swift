import XCTest

/// EXPERIMENT (not for main): do About and the Equalizer open with their collapsing header fully expanded (scroll
/// offset 0)? Some screenshots catch them scrolled a few points with the header part-collapsed. Reports the frames
/// of the page's first static texts, launched straight into the page and pushed from Settings by a tap (right after
/// launch, after the launch work has settled, and on a second visit), as text attachments.
@MainActor
final class HeaderRestProbeTests: XCTestCase {
    private let pages = [("settingsCategory.about", "About"), ("settingsCategory.equalizer", "Equalizer")]

    func testLaunchedIntoThePage() {
        continueAfterFailure = true
        for (screen, _) in pages {
            var lines: [String] = []
            for index in 1...6 {
                let app = launch(screen, ready: "screen.\(screen)")
                Thread.sleep(forTimeInterval: 2.0)
                lines.append(report(app, "launch \(index) @2s"))
                Thread.sleep(forTimeInterval: 2.0)
                lines.append(report(app, "launch \(index) @4s"))
                if index <= 2 { attach(app.screenshot(), "hdr-launch-\(screen)-\(index)") }
                app.terminate()
            }
            note(lines.joined(separator: "\n"), "hdr-launch-\(screen)")
        }
    }

    func testPushedByTap() {
        continueAfterFailure = true
        for (screen, label) in pages {
            var lines: [String] = []
            for index in 1...5 {
                // Right after launch: tap as soon as Settings is up, then go back and come again.
                var app = launch("settings", ready: "screen.settings")
                if open(app, label, screen) {
                    Thread.sleep(forTimeInterval: 2.0)
                    lines.append(report(app, "early \(index)"))
                    if index <= 2 { attach(app.screenshot(), "hdr-early-\(screen)-\(index)") }
                    back(app)
                    if open(app, label, screen) {
                        Thread.sleep(forTimeInterval: 2.0)
                        lines.append(report(app, "revisit \(index)"))
                    }
                }
                app.terminate()
                // After the launch work has settled (the full player's pre-warm runs about 1 s after launch).
                app = launch("settings", ready: "screen.settings")
                Thread.sleep(forTimeInterval: 3.0)
                if open(app, label, screen) {
                    Thread.sleep(forTimeInterval: 2.0)
                    lines.append(report(app, "settled \(index)"))
                    if index <= 2 { attach(app.screenshot(), "hdr-settled-\(screen)-\(index)") }
                }
                app.terminate()
            }
            note(lines.joined(separator: "\n"), "hdr-tap-\(screen)")
        }
    }

    // MARK: - Helpers

    private func launch(_ screen: String, ready: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 20),
                      "\(ready) did not appear")
        return app
    }

    private func open(_ app: XCUIApplication, _ label: String, _ screen: String) -> Bool {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH[c] %@",
                                  "settings.\(label.lowercased())", label)).firstMatch
        guard row.waitForExistence(timeout: 10) else { XCTFail("no \(label) row"); return false }
        var tries = 0
        while !row.isHittable && tries < 4 { app.swipeUp(); tries += 1 }
        row.tap()
        let page = app.descendants(matching: .any)["screen.\(screen)"].firstMatch
        guard page.waitForExistence(timeout: 10) else { XCTFail("\(screen) did not open"); return false }
        return true
    }

    private func back(_ app: XCUIApplication) {
        let back = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label ==[c] %@", "settings.back", "Back")).firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() }
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// The first six static texts top to bottom: "label@minY".
    private func report(_ app: XCUIApplication, _ name: String) -> String {
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(10).compactMap { element -> (String, CGFloat)? in
            guard element.exists else { return nil }
            return (String(element.label.prefix(18)), element.frame.minY)
        }.sorted { $0.1 < $1.1 }.prefix(6)
        return "\(name): " + texts.map { "\($0.0)@\(String(format: "%.1f", $0.1))" }.joined(separator: " | ")
    }

    private func note(_ text: String, _ name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(name).txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
