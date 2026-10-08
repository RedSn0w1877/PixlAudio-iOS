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

    /// The More sheet opens at half height, where iOS draws it as floating Liquid Glass over the lyrics (Hoa,
    /// 2026-10-07: "that page has 0 liquid glass"; at full height the sheet turns opaque).
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
    /// `BottomToggleRow`; the full player's liquid segments since 2026-10-07), light app. Swipes on the sheet (the first
    /// grows it from half height) until its heart is on screen.
    func testMoreSheetBottomInLightApp() throws {
        try capture("lyricsMoreSheet.lightAppBottom", demo: "words", freezeMs: 42_300, appearance: "light",
                    tap: "Lyrics options", settle: 2.0) { app in
            let sheet = app.descendants(matching: .any)["screen.lyricsOptions"].firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the More sheet did not open")
            // Inside the sheet: the full player under the lyrics has the same heart.
            let heart = sheet.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Add to favorites",
                                                           "Remove from favorites")).firstMatch
            XCTAssertTrue(heart.waitForExistence(timeout: 10), "the sheet has no shuffle / repeat / favourite row")
            self.reveal(heart, in: sheet, app: app, clearOfBottom: 0)
            XCTAssertTrue(heart.isHittable, "the sheet's bottom row can't be reached")
        }
    }

    // MARK: Translate · Sing (owner, 2026-10-07: they replace Synced · Static)

    /// Sing while the instrumental plays: the segment reads "Vocals off" in the accent (demo render, active).
    func testSingActive() throws {
        try capture("lyricsSingActive", screen: "tais.instrumentalActive", demo: "words", freezeMs: 42_300) { app in
            let sing = app.buttons.matching(NSPredicate(format: "label == %@", "Sing")).firstMatch
            XCTAssertTrue(sing.waitForExistence(timeout: 10), "Sing is missing")
            XCTAssertEqual(sing.value as? String, "Vocals off", "Sing is not showing the instrumental")
        }
    }

    /// Sing while the vocals are being removed: "Removing vocals 48 %" with the progress filling the segment.
    func testSingRendering() throws {
        try capture("lyricsSingRendering", screen: "tais.instrumentalRendering", demo: "words", freezeMs: 42_300) { app in
            let sing = app.buttons.matching(NSPredicate(format: "label == %@", "Sing")).firstMatch
            XCTAssertTrue(sing.waitForExistence(timeout: 10), "Sing is missing")
            XCTAssertTrue((sing.value as? String ?? "").hasPrefix("Removing vocals"),
                          "Sing is not showing the render's progress")
        }
    }

    /// Touch and hold Translate: Translate via AI, and Show romanization when the lyrics need it. The hold must open
    /// the menu, not run the tap (until 2026-10-07 it hid the demo's translations instead).
    func testTranslateMenu() throws {
        try capture("lyricsTranslateMenu", demo: "words", freezeMs: 42_300, settle: 2.0) { app in
            let translate = app.buttons.matching(NSPredicate(format: "label == %@", "Translate")).firstMatch
            XCTAssertTrue(translate.waitForExistence(timeout: 10), "Translate is missing")
            XCTAssertEqual(translate.value as? String, "Showing translations", "the demo lyrics show a translation")
            translate.press(forDuration: 1.2)
            let viaAI = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Translate via AI")).firstMatch
            XCTAssertTrue(viaAI.waitForExistence(timeout: 5), "the long-press menu has no Translate via AI")
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    /// "Show as plain text" in the More sheet's Controls (synced vs plain is automatic now): turning it on shows the
    /// song as plain text, so the karaoke-only row (Adjust sync) leaves the sheet.
    func testShowAsPlainText() throws {
        try capture("lyricsShowAsPlainText", demo: "words", freezeMs: 42_300, tap: "Lyrics options", settle: 1.5) { app in
            let sheet = app.descendants(matching: .any)["screen.lyricsOptions"].firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the More sheet did not open")
            let plain = sheet.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Show as plain text")).firstMatch
            XCTAssertTrue(plain.waitForExistence(timeout: 10), "Show as plain text is missing")
            // Well clear of the screen's bottom edge, and settled: a tap on a row still sliding in (or under the home
            // indicator) is lost.
            self.reveal(plain, in: sheet, app: app, clearOfBottom: 120)
            XCTAssertEqual(plain.value as? String, "0", "Show as plain text should start off")
            let adjustSync = sheet.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Adjust sync")).firstMatch
            XCTAssertTrue(adjustSync.exists, "karaoke lyrics should offer Adjust sync")
            // The switch sits at the row's trailing end; the row's centre is its title.
            let knob = plain.switches.firstMatch
            if knob.exists, knob.isHittable {
                knob.tap()
            } else {
                plain.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            }
            XCTAssertTrue(adjustSync.waitForNonExistence(timeout: 5), "the lyrics did not switch to plain text")
            Thread.sleep(forTimeInterval: 1.0)
        }
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

    /// `screen`: the lyrics cover's demo screen (`lyrics`, or a `tais.instrumental*` state). `swipes`: swipes up after
    /// settling (a half-height sheet grows on the first). `then` runs before the shot.
    private func capture(_ name: String, screen: String = "lyrics", demo: String, freezeMs: Int? = nil,
                         ready: String = "screen.lyrics", readyText: String? = nil, appearance: String = "dark",
                         extra: [String] = [], tap: String? = nil, settle: TimeInterval = 3.0, swipes: Int = 0,
                         then: ((XCUIApplication) -> Void)? = nil) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        var arguments = ["-uiTest", "-screen", screen, "-appearance", appearance, "-lyricsDemo", demo]
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
        for _ in 0..<swipes {
            app.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 1.5)
        }
        then?(app)
        attach(app, name: "\(name)-\(appearance)")
    }

    /// Swipes the More sheet up (the first swipe grows a half-height sheet) until `element` can take a tap at least
    /// `clearOfBottom` points above the screen's bottom edge, letting each swipe settle.
    private func reveal(_ element: XCUIElement, in sheet: XCUIElement, app: XCUIApplication, clearOfBottom: CGFloat) {
        let limit = app.frame.maxY - clearOfBottom
        var swipes = 0
        while !(element.isHittable && element.frame.maxY <= limit), swipes < 5 {
            sheet.swipeUp()
            Thread.sleep(forTimeInterval: 1.2)
            swipes += 1
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
