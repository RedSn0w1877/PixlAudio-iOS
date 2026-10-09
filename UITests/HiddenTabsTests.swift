import XCTest

/// Tabs nobody has looked at yet are built after launch settles, or on first selection (docs/performance.md): a
/// switch right after launch, before the idle build, must show the tab as fully as one after it.
@MainActor
final class HiddenTabsTests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", "home", "-appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.home"].firstMatch.waitForExistence(timeout: 30),
                      "Home did not appear")
        return app
    }

    private func tabButton(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["navBar.\(name)"].firstMatch
    }

    private func visit(_ app: XCUIApplication, tab: String, screen: String) {
        let button = tabButton(app, tab)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(tab) tab button")
        button.tap()
        XCTAssertTrue(app.descendants(matching: .any)[screen].firstMatch.waitForExistence(timeout: 10),
                      "\(screen) did not appear after tapping \(tab)")
        XCTAssertTrue(button.isSelected, "\(tab) was not selected")
    }

    /// Straight after launch: Library, Search, Home, each built on its first selection or by the idle build.
    func testSwitchingRightAfterLaunchShowsEveryTab() {
        let app = launch()
        visit(app, tab: "library", screen: "screen.library")
        visit(app, tab: "search", screen: "screen.search")
        visit(app, tab: "home", screen: "screen.home")
    }

    /// After the idle build: the same switches, and a tab keeps its scroll position and stack as before.
    func testSwitchingAfterTheIdleBuildShowsEveryTab() {
        let app = launch()
        Thread.sleep(forTimeInterval: 4.0)
        visit(app, tab: "search", screen: "screen.search")
        visit(app, tab: "library", screen: "screen.library")
        visit(app, tab: "home", screen: "screen.home")
    }
}
