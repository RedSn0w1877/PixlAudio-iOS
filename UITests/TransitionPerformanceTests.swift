import XCTest

/// Transition performance (branch perf-transitions, 2026-10-02). Hoa's first install showed "noticeable stutters
/// between menu or page transitions"; these tests drive the transitions in scope and record XCTest's performance
/// metrics for each, in a demo library of real size (`-demoScale 100`: about 2,400 songs and 1,300 albums):
///
/// - `XCTHitchMetric(application:)` (iOS 26): hitches in the app while the block runs;
/// - `XCTOSSignpostMetric.navigationTransitionMetric` (iOS 14, push/pop tests): the system's navigation transitions;
/// - `XCTClockMetric` and `XCTCPUMetric(application:)`: wall clock, and the app's CPU time and cycles.
///
/// Each iteration returns to the state it started from, so the five iterations measure the same transition. CI copies
/// every "measured [...]" line of the log into `perf-metrics.txt` in the shots artifact and the job summary.
/// Simulator numbers are indicative only: main-thread work shows, the GPU cost of Liquid Glass does not. What each
/// fix targets is in docs/performance.md.
@MainActor
final class TransitionPerformanceTests: XCTestCase {
    /// Copies of the demo library (24 songs, 13 albums each).
    private static let demoScale = "100"

    // MARK: Shell

    /// Home → Search → Library → Home on the glass tab bar (all three stacks stay alive; the selected one fades in).
    func testTabSwitches() {
        let app = launch("home", ready: "screen.home")
        let search = app.descendants(matching: .any)["navBar.search"].firstMatch
        let library = app.descendants(matching: .any)["navBar.library"].firstMatch
        let home = app.descendants(matching: .any)["navBar.home"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "the tab bar is missing")
        measureTransitions(app) {
            search.tap()
            XCTAssertTrue(search.isSelected, "Search was not selected")
            library.tap()
            XCTAssertTrue(library.isSelected, "Library was not selected")
            home.tap()
            XCTAssertTrue(home.isSelected, "Home was not selected")
        }
    }

    // MARK: Pushes

    /// Library › Albums → album detail → back.
    func testAlbumPushPop() {
        let app = launch("libraryAlbums", ready: "library.page.albums")
        pushAndPop(app, from: first(app, prefix: "albumCard."), page: "screen.albumDetail")
    }

    /// Library › Artists → artist detail → back.
    func testArtistPushPop() {
        let app = launch("libraryArtists", ready: "library.page.artists")
        pushAndPop(app, from: first(app, prefix: "artistRow."), page: "screen.artistDetail")
    }

    /// Taps `origin`, waits for `page`, goes back and waits until `origin` can be tapped again.
    private func pushAndPop(_ app: XCUIApplication, from origin: XCUIElement, page: String) {
        XCTAssertTrue(origin.waitForExistence(timeout: 15), "nothing to open")
        measureTransitions(app, navigation: true) {
            origin.tap()
            XCTAssertTrue(app.descendants(matching: .any)[page].firstMatch.waitForExistence(timeout: 10),
                          "\(page) did not open")
            // The page's own identifier covers its header's controls: find Back by label too.
            let back = control(app, "detail.back", label: "Back")
            XCTAssertTrue(back.waitForExistence(timeout: 10), "no Back on \(page)")
            back.tap()
            XCTAssertTrue(origin.wait(for: \.isHittable, toEqual: true, timeout: 10), "\(page) did not close")
        }
    }

    /// Settings → Appearance → back.
    func testSettingsSubpage() {
        let app = launch("settings", ready: "screen.settings")
        let appearance = control(app, "settings.appearance", label: "Appearance", prefixLabel: true)
        XCTAssertTrue(appearance.waitForExistence(timeout: 15), "no Appearance row")
        measureTransitions(app, navigation: true) {
            appearance.tap()
            let page = app.descendants(matching: .any)["screen.settingsCategory.appearance"].firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 10), "Appearance did not open")
            app.descendants(matching: .any)["settings.back"].firstMatch.tap()
            XCTAssertTrue(appearance.waitForExistence(timeout: 10), "Settings did not come back")
        }
    }

    // MARK: Library

    /// The Library category pills: Songs → Albums → Artists → Albums → Songs (pills that stay on screen as the row
    /// scrolls the selected one into view).
    func testLibraryPillSwitches() {
        let app = launch("library", ready: "screen.library")
        let pills = ["Albums", "Artists", "Albums", "Songs"].map {
            control(app, "library.tab.\($0)", label: $0)
        }
        XCTAssertTrue(pills[0].waitForExistence(timeout: 15), "no Albums pill")
        measureTransitions(app) {
            for pill in pills {
                pill.tap()
                XCTAssertTrue(pill.isSelected, "\(pill) was not selected")
            }
        }
    }

    // MARK: Sheets

    /// A song's ⋮ → the song options sheet → dragged down.
    func testSongOptionsSheet() {
        let app = launch("library", ready: "screen.library")
        let more = first(app, prefix: "songCard.more.")
        XCTAssertTrue(more.waitForExistence(timeout: 15), "no song ⋮ button")
        measureTransitions(app) {
            more.tap()
            let sheet = app.descendants(matching: .any)["screen.songInfo"].firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the song options sheet did not open")
            let top = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
            top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "the song options sheet did not close")
        }
    }

    /// The player sheet: mini player → full player → collapse.
    func testPlayerExpandCollapse() {
        let app = launch("miniPlayer", ready: "miniPlayer")
        let mini = app.descendants(matching: .any)["miniPlayer"].firstMatch
        let title = app.descendants(matching: .any)["miniPlayer.title"].firstMatch
        measureTransitions(app) {
            mini.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
            let collapse = control(app, "player.collapse", label: "Collapse player")
            XCTAssertTrue(collapse.waitForExistence(timeout: 10), "the player did not expand")
            collapse.tap()
            XCTAssertTrue(title.waitForExistence(timeout: 10), "the player did not collapse")
        }
    }

    // MARK: - Helpers

    private func launch(_ screen: String, ready: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", "dark", "-demoScale", Self.demoScale]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 30),
                      "\(ready) did not appear on \(screen)")
        // Let launch work (library model, Home, artwork) settle before measuring.
        Thread.sleep(forTimeInterval: 2.0)
        return app
    }

    /// A control by identifier, or by label where a parent passes its own identifier down.
    private func control(_ app: XCUIApplication, _ identifier: String, label: String,
                         prefixLabel: Bool = false) -> XCUIElement {
        let format = prefixLabel ? "identifier == %@ OR label BEGINSWITH[c] %@" : "identifier == %@ OR label ==[c] %@"
        return app.descendants(matching: .any).matching(NSPredicate(format: format, identifier, label)).firstMatch
    }

    private func first(_ app: XCUIApplication, prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    private func measureTransitions(_ app: XCUIApplication, navigation: Bool = false, _ block: () -> Void) {
        var metrics: [any XCTMetric] = [XCTHitchMetric(application: app), XCTClockMetric(),
                                        XCTCPUMetric(application: app)]
        if navigation { metrics.append(XCTOSSignpostMetric.navigationTransitionMetric) }
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: metrics, options: options, block: block)
    }
}
