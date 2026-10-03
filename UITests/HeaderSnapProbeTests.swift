import XCTest

/// EXPERIMENT (not for main): the settings header's snap, old (`-probeOldSnap`: the behaviour also acts when the
/// scroll view's size changes) against the fix (only while the user scrolls), in the same build. Reports the header
/// title's minY (it moves up as the header collapses) as text attachments: launched straight into a page, pushed
/// from Settings by a tap, and slow drags released with no velocity after a tap into Music Management (both modes
/// start from the same resting page, so the release behaviour can be compared).
@MainActor
final class HeaderSnapProbeTests: XCTestCase {
    private let modes: [(String, [String])] = [("old", ["-probeOldSnap"]), ("fix", [])]

    func testLaunchedIntoThePage() {
        continueAfterFailure = true
        var lines: [String] = []
        for (mode, extra) in modes {
            for (screen, title) in [("settingsCategory.about", "About"), ("settingsCategory.equalizer", "Equalizer"),
                                    ("settingsCategory.library", "Music Management")] {
                var values: [String] = []
                for _ in 1...4 {
                    let app = launch(screen, ready: "screen.\(screen)", extra)
                    Thread.sleep(forTimeInterval: 2.5)
                    values.append(titleY(app, title))
                    app.terminate()
                }
                lines.append("launch \(mode) \(screen): " + values.joined(separator: " "))
            }
        }
        note(lines.joined(separator: "\n"), "snap3-launch")
    }

    func testPushedByTap() {
        continueAfterFailure = true
        var lines: [String] = []
        for (mode, extra) in modes {
            for (screen, label, title) in [("equalizer", "Equalizer", "Equalizer"),
                                           ("settingsCategory.library", "Music Management", "Music Management")] {
                var early: [String] = [], settled: [String] = []
                for _ in 1...3 {
                    var app = launch("settings", ready: "screen.settings", extra)
                    early.append(open(app, label, screen) ? waitThenTitle(app, title) : "noopen")
                    app.terminate()
                    app = launch("settings", ready: "screen.settings", extra)
                    Thread.sleep(forTimeInterval: 3.0)
                    settled.append(open(app, label, screen) ? waitThenTitle(app, title) : "noopen")
                    app.terminate()
                }
                lines.append("tap \(mode) \(screen): early " + early.joined(separator: " ")
                             + " | settled " + settled.joined(separator: " "))
            }
        }
        note(lines.joined(separator: "\n"), "snap3-tap")
    }

    func testSlowDragRelease() {
        continueAfterFailure = true
        var lines: [String] = []
        for (mode, extra) in modes {
            for drag in [12.0, 20.0, 30.0, 46.0] {
                var values: [String] = []
                for index in 1...2 {
                    let app = launch("settings", ready: "screen.settings", extra)
                    Thread.sleep(forTimeInterval: 2.0)
                    guard open(app, "Music Management", "settingsCategory.library") else {
                        values.append("noopen"); app.terminate(); continue
                    }
                    let before = waitThenTitle(app, "Music Management")
                    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -drag)),
                                withVelocity: .slow, thenHoldForDuration: 0.4)
                    Thread.sleep(forTimeInterval: 2.0)
                    values.append("\(before)->\(titleY(app, "Music Management"))")
                    if index == 1 { attach(app.screenshot(), "snap3-drag-\(mode)-\(Int(drag))") }
                    app.terminate()
                }
                lines.append("drag \(mode) \(Int(drag)) pt: " + values.joined(separator: "  "))
            }
        }
        note(lines.joined(separator: "\n"), "snap3-drag")
    }

    // MARK: - Helpers

    private func launch(_ screen: String, ready: String, _ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", "light"] + extra
        app.launch()
        _ = app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 20)
        return app
    }

    private func open(_ app: XCUIApplication, _ label: String, _ screen: String) -> Bool {
        let id = screen.hasPrefix("settingsCategory.") ? "settings." + screen.dropFirst("settingsCategory.".count)
            : "settings.\(screen)"
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH[c] %@", id, label)).firstMatch
        guard row.waitForExistence(timeout: 10) else { return false }
        var tries = 0
        while !row.isHittable && tries < 4 { app.swipeUp(); tries += 1 }
        row.tap()
        return app.descendants(matching: .any)["screen.\(screen)"].firstMatch.waitForExistence(timeout: 10)
    }

    private func waitThenTitle(_ app: XCUIApplication, _ title: String) -> String {
        Thread.sleep(forTimeInterval: 2.0)
        return titleY(app, title)
    }

    /// minY of every static text labelled `title` ("a/b" when there are several).
    private func titleY(_ app: XCUIApplication, _ title: String) -> String {
        let matches = app.staticTexts.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex
        let ys = matches.filter(\.exists).map { String(format: "%.1f", $0.frame.minY) }
        return ys.isEmpty ? "none" : ys.joined(separator: "/")
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
