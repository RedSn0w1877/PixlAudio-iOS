import XCTest

/// Screenshot tests: each test launches the app straight into one screen with demo data
/// (`-uiTest -screen <id> -appearance light|dark`) and attaches a screenshot named `<screen>-<appearance>`.
/// CI exports the attachments (`ci/export-shots.sh`) into the `shots-<sha>` artifact.
@MainActor
final class ScreenshotTests: XCTestCase {
    // MARK: Home (tab bar + expanded mini-player accessory)

    func testHomeLight() throws { try capture(.home, "light") }
    func testHomeDark() throws { try capture(.home, "dark") }

    // MARK: Library

    func testLibraryLight() throws { try capture(.library, "light") }
    func testLibraryDark() throws { try capture(.library, "dark") }

    // MARK: Search (empty: genre grid; with a query: results)

    func testSearchLight() throws { try capture(.search, "light") }
    func testSearchDark() throws { try capture(.search, "dark") }
    func testSearchResultsLight() throws { try capture(.searchResults, "light") }
    func testSearchResultsDark() throws { try capture(.searchResults, "dark") }

    // MARK: Search placement experiments (temporary)

    func testSearchExperimentStackLight() throws { try capture(.searchResults, "light", extra: ["-searchOnStack"], suffix: "stack") }
    func testSearchExperimentNoAccessoryLight() throws { try capture(.searchResults, "light", extra: ["-hideAccessory"], suffix: "noacc") }
    func testSearchExperimentStackNoAccessoryLight() throws {
        try capture(.searchResults, "light", extra: ["-searchOnStack", "-hideAccessory"], suffix: "stack-noacc")
    }

    // MARK: Mini player inline (tab bar minimized after scrolling down)

    func testMiniPlayerLight() throws { try capture(.miniPlayer, "light") }
    func testMiniPlayerDark() throws { try capture(.miniPlayer, "dark") }

    // MARK: Diagnostics

    func testDiagnosticsLight() throws { try capture(.diagnostics, "light") }
    func testDiagnosticsDark() throws { try capture(.diagnostics, "dark") }

    // MARK: - Helpers

    private enum Screen: String {
        case home, library, search, searchResults, miniPlayer, diagnostics

        /// Accessibility identifier of the view that must exist before the screenshot.
        var readyIdentifier: String {
            switch self {
            case .home: "screen.home"
            case .library, .miniPlayer: "screen.library"
            case .search, .searchResults: "screen.search"
            case .diagnostics: "screen.diagnostics"
            }
        }
    }

    private func capture(_ screen: Screen, _ appearance: String, extra: [String] = [], suffix: String? = nil) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen.rawValue, "-appearance", appearance] + extra
        app.launch()

        let ready = app.descendants(matching: .any)[screen.readyIdentifier].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "\(screen.readyIdentifier) did not appear")

        if screen == .search || screen == .searchResults {
            // The search tab turns into a bottom search field when the user selects it, so select Home and
            // then Search like a user would (tab items are buttons; on iOS 26+ they may not sit in `tabBars`).
            let home = app.buttons["Home"].firstMatch
            let search = app.buttons["Search"].firstMatch
            if home.waitForExistence(timeout: 5) { home.tap() }
            Thread.sleep(forTimeInterval: 0.5)
            if search.waitForExistence(timeout: 5) { search.tap() }
            _ = app.searchFields.firstMatch.waitForExistence(timeout: 5)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(screen.rawValue)-\(appearance)\(suffix.map { "-" + $0 } ?? "")-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }

        if screen == .miniPlayer {
            // Scroll down so the tab bar minimizes and the accessory moves inline.
            let list = app.collectionViews.firstMatch
            let target = list.exists ? list : app.windows.firstMatch
            target.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            target.swipeUp()
            Thread.sleep(forTimeInterval: 1.0)
        }

        // Let glass, symbol effects and navigation transitions settle.
        Thread.sleep(forTimeInterval: 1.5)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(screen.rawValue)-\(appearance)\(suffix.map { "-" + $0 } ?? "")"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
    }
}
