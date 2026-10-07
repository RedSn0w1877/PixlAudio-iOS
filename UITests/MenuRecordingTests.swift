import XCTest

/// Opens the small menus slowly so CI can film them. With `[record:MenuRecordingTests]` in the commit message, the
/// CI step "Record UI video" runs this class under `simctl io recordVideo`, and the frames are compared with a
/// recording of the system's own menu morph (Messages' Edit menu, owner reference 2026-10-02). It is opt-in
/// (ci/ui-test-args.sh), so full screenshot runs skip it; its screenshots show each menu open.
@MainActor
final class MenuRecordingTests: XCTestCase {
    /// Library › Sort by: a system menu on PixlAudio's own segmented glass (`ShapedGlassMenu`).
    func testLibrarySortMenu() throws {
        let app = launch("library", ready: "screen.library")
        openAndClose(app, button: "Sort options", shot: "menuLibrarySort-light")
    }

    /// Playlist › Sort Songs and ⋯: system menus on Apple's glass button style (`GlassCircleMenu`).
    func testPlaylistMenus() throws {
        let app = launch("playlistDetail", ready: "Sort Songs")
        openAndClose(app, button: "Sort Songs", shot: "menuPlaylistSort-light")
        openAndClose(app, button: "More options", shot: "menuPlaylistMore-light")
    }

    /// The queue's own ⋯ menu (2026-10-07): the ⋯ circle liquid-morphs into "Save as playlist" while Locate and Clear
    /// materialise, and back. Closed by tapping the scrim above the pills (a tap low on the screen would hit them).
    func testQueueMenuMorph() throws {
        let app = launch("queue", ready: "screen.queue")
        let more = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "queue.more",
                                                    "More actions")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "More actions is missing")
        more.tap()
        Thread.sleep(forTimeInterval: 2.0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "menuQueue-light"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the menu did not close back into the ⋯ circle")
    }

    // MARK: - Helpers

    private func launch(_ screen: String, ready: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 20),
                      "\(ready) did not appear")
        Thread.sleep(forTimeInterval: 1.5)
        return app
    }

    /// Taps the button by its label (screen containers hide inner identifiers), holds the open menu on screen, screenshots it, then closes it by tapping
    /// outside and lets the close animation play.
    private func openAndClose(_ app: XCUIApplication, button: String, shot: String) {
        let element = app.descendants(matching: .any)[button].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(button) is missing")
        element.tap()
        Thread.sleep(forTimeInterval: 2.0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = shot
        attachment.lifetime = .keepAlways
        add(attachment)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap()
        Thread.sleep(forTimeInterval: 1.5)
    }
}
