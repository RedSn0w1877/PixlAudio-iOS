import XCTest

/// Stage 10 screenshots: the "sync it yourself" editor (Android `presentation/lyrics/sync/**`), one shot per screen
/// state (`-syncStep`, see App/Features/LyricsSync/LyricsSyncDemo.swift) over the demo song's artwork, plus a live
/// run through Intro → Start → taps and the speed menu.
@MainActor
final class LyricsSyncScreenshotTests: XCTestCase {
    func testIntro() throws { try capture("syncIntro", step: "intro", ready: "sync.start") }
    func testWords() throws { try capture("syncWords", step: "words", ready: "sync.words.next") }
    func testResume() throws { try capture("syncResume", step: "resume") }
    func testManage() throws { try capture("syncManage", step: "manage") }
    func testTap() throws { try capture("syncTap", step: "tap", ready: "sync.pad") }
    func testTapReady() throws { try capture("syncTapReady", step: "tapPaused", ready: "sync.pad") }
    func testMusicBreak() throws { try capture("syncTapBreak", step: "tapBreak", ready: "sync.pad", settle: 2.5) }
    func testRemovedWordsNotice() throws { try capture("syncTapNotice", step: "tapNotice", ready: "sync.pad", settle: 1.5) }
    func testEndedEarly() throws { try capture("syncTapEnded", step: "tapEnded", ready: "sync.pad") }
    func testFixLine() throws { try capture("syncFixLine", step: "fixLine", ready: "sync.pad") }
    func testPreview() throws { try capture("syncPreview", step: "preview", ready: "sync.save", settle: 3.5) }
    func testPreviewPickLine() throws { try capture("syncPreviewFixLine", step: "previewFixLine", settle: 3.5) }
    func testLightAppearanceStaysDark() throws {
        try capture("syncTapLight", step: "tap", ready: "sync.pad", appearance: "light")
    }

    func testSpeedMenu() throws {
        let app = try launch(step: "tap")
        XCTAssertTrue(app.descendants(matching: .any)["sync.pad"].firstMatch.waitForExistence(timeout: 20))
        let speed = app.descendants(matching: .any)["sync.speed"].firstMatch
        XCTAssertTrue(speed.waitForExistence(timeout: 10))
        speed.tap()
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, name: "syncSpeedMenu-dark")
    }

    /// The real flow on the demo engine: the intro (first time), Start, the song starts with the first press, then
    /// three taps stamp words.
    func testLiveTapping() throws {
        let app = try launch(step: nil, extra: ["-lyricsDemo", "lines"])
        let start = app.descendants(matching: .any)["sync.start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 20), "the intro did not appear")
        attach(app, name: "syncLiveIntro-dark")
        start.tap()
        let pad = app.descendants(matching: .any)["sync.pad"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 10), "the tap screen did not appear")
        Thread.sleep(forTimeInterval: 0.8)
        pad.tap() // starts the song
        Thread.sleep(forTimeInterval: 1.0)
        for _ in 0..<3 {
            pad.tap()
            Thread.sleep(forTimeInterval: 0.45)
        }
        Thread.sleep(forTimeInterval: 0.6)
        attach(app, name: "syncLiveTapped-dark")
    }

    // MARK: - Helpers

    private func launch(step: String?, appearance: String = "dark", extra: [String] = []) throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        var arguments = ["-uiTest", "-screen", "lyricsSync", "-appearance", appearance]
        if let step { arguments += ["-syncStep", step] }
        app.launchArguments = arguments + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.lyricsSync"].firstMatch.waitForExistence(timeout: 20),
                      "the sync editor did not open")
        return app
    }

    private func capture(_ name: String, step: String, ready: String? = nil, appearance: String = "dark",
                         settle: TimeInterval = 2.0) throws {
        let app = try launch(step: step, appearance: appearance)
        if let ready {
            XCTAssertTrue(app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 20),
                          "\(ready) did not appear for \(name)")
        }
        // Let the artwork bake and the background crossfade settle.
        Thread.sleep(forTimeInterval: settle)
        attach(app, name: "\(name)-\(appearance)")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
