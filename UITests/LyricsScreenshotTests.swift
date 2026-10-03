import XCTest

/// Stage 9 screenshots: the karaoke lyrics screen with the demo lyrics frozen at chosen song positions
/// (`-lyricsFreezeMs`, `-lyricsDemo`; see App/Features/Lyrics/LyricsDemoContent.swift), plus its sheets and states.
/// Compare with docs/design-refs/pp_lyr.png (the screen's chrome) and docs/research/spec-lyricsView.md (the lines).
@MainActor
final class LyricsScreenshotTests: XCTestCase {
    // Demo timeline (LyricsDemoContent): mid-line 42 300, emphasis peak 47 600, instrumental gap 61 000.

    func testMidLineWordFill() throws { try capture("lyricsWordFill", demo: "words", freezeMs: 42_300) }
    func testEmphasisPeak() throws { try capture("lyricsEmphasis", demo: "words", freezeMs: 47_600) }
    func testInterludeDots() throws { try capture("lyricsInterlude", demo: "words", freezeMs: 61_000) }
    func testDuetBackgroundVocals() throws { try capture("lyricsDuet", demo: "duet", freezeMs: 42_300) }
    func testBrightArt() throws { try capture("lyricsBrightArt", demo: "words", freezeMs: 42_300, extra: ["-lyricsBrightArt"]) }
    func testIncreasedContrast() throws {
        try capture("lyricsHighContrast", demo: "words", freezeMs: 42_300, extra: ["-lyricsHighContrast"])
    }
    func testLineSynced() throws { try capture("lyricsLineSynced", demo: "lines", freezeMs: 42_300) }
    // The screen's "screen.lyrics" identifier is inherited by the scroll views inside it, so the plain list and the
    // status card are recognised by their content (the first plain line; the "Find or import lyrics" button).
    func testPlainLyrics() throws { try capture("lyricsPlain", demo: "plain", readyText: "Under the glow of a paper moon") }
    func testNoLyrics() throws { try capture("lyricsNone", demo: "none", ready: "lyrics.findLyrics") }
    func testImmersive() throws {
        try capture("lyricsImmersive", demo: "words", freezeMs: 42_300, extra: ["-lyricsImmersive"])
    }
    func testLightAppearanceStaysDark() throws {
        try capture("lyricsLight", demo: "words", freezeMs: 42_300, appearance: "light")
    }

    func testMoreSheet() throws {
        try capture("lyricsMoreSheet", demo: "words", freezeMs: 42_300, tap: "Lyrics options", settle: 2.5)
    }

    /// The lyrics screen is always dark, and so is its More sheet — also when the app is light. Until 2026-10-03 the
    /// sheet kept the light palette there (near-black rows on the dark sheet); these shots guard the fix.
    func testMoreSheetInLightApp() throws {
        try capture("lyricsMoreSheet.lightApp", demo: "words", freezeMs: 42_300, appearance: "light", tap: "Lyrics options",
                    settle: 2.5)
    }

    /// The end of the sheet: Controls and the shuffle / repeat / favourite row (part of the sheet, Android
    /// `BottomToggleRow`), light app.
    func testMoreSheetBottomInLightApp() throws {
        try capture("lyricsMoreSheet.lightAppBottom", demo: "words", freezeMs: 42_300, appearance: "light",
                    tap: "Lyrics options", settle: 2.0, swipeUp: true)
    }

    func testFetchDialogInLightApp() throws {
        try capture("lyricsFetchDialog.lightApp", demo: "none", ready: "lyrics.findLyrics", appearance: "light",
                    tap: "lyrics.findLyrics", settle: 1.5)
    }

    func testFetchDialog() throws {
        try capture("lyricsFetchDialog", demo: "none", ready: "lyrics.findLyrics", tap: "lyrics.findLyrics", settle: 1.5)
    }

    func testOptionsSheetRoute() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", "lyricsOptions", "-appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.lyricsOptions"].firstMatch.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 2.0)
        attach(app, name: "lyricsOptions-dark")
    }

    /// The first-show cascade as a frame sequence (the lines rise from below, staggered): live clock from 0.
    func testCascadeFrames() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", "lyrics", "-appearance", "dark", "-lyricsDemo", "words"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.lyrics"].firstMatch.waitForExistence(timeout: 20))
        for frame in 0..<8 {
            attach(app, name: "lyricsCascade.f\(frame)-dark")
        }
    }

    // MARK: - Helper

    private func capture(_ name: String, demo: String, freezeMs: Int? = nil, ready: String = "screen.lyrics",
                         readyText: String? = nil, appearance: String = "dark", extra: [String] = [], tap: String? = nil,
                         settle: TimeInterval = 3.0, swipeUp: Bool = false) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        var arguments = ["-uiTest", "-screen", "lyrics", "-appearance", appearance, "-lyricsDemo", demo]
        if let freezeMs { arguments += ["-lyricsFreezeMs", String(freezeMs)] }
        app.launchArguments = arguments + extra
        app.launch()

        let element = readyText.map { app.staticTexts[$0].firstMatch } ?? app.descendants(matching: .any)[ready].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(readyText ?? ready) did not appear for \(name)")
        if let tap {
            let target = app.buttons[tap].firstMatch
            XCTAssertTrue(target.waitForExistence(timeout: 10), "\(tap) is missing for \(name)")
            target.tap()
        }
        // Let the cascade, the artwork bake and the background crossfade settle.
        Thread.sleep(forTimeInterval: settle)
        if swipeUp {
            app.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 1.5)
        }
        attach(app, name: "\(name)-\(appearance)")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
