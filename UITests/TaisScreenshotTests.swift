import XCTest

/// Stage 14 screenshots (demo states from `TaisDemo`, no network or Core ML): Experimental's Remaster Song card
/// (Android `TaisStudioProgressCard` with a running lyric sync, a finished instrumental and a failed BS-RoFormer render)
/// and the iOS on-device models panel mid-download; the song sheet's Remaster card; the lyrics screen's instrumental
/// UI (Android `InstrumentalRenderAction` + `FloatingInstrumentalToggle`): ready, rendering, and playing.
@MainActor
final class TaisScreenshotTests: XCTestCase {
    // MARK: Experimental

    func testStudioLight() throws { try captureExperimental("tais.studio", "light", until: "tais.roformer.start") }
    func testStudioDark() throws { try captureExperimental("tais.studio", "dark", until: "tais.roformer.start") }
    func testModelDownloadLight() throws { try captureExperimental("tais.models", "light", until: "tais.model.mdxnet.remove") }
    func testModelDownloadDark() throws { try captureExperimental("tais.models", "dark", until: "tais.model.mdxnet.remove") }

    // MARK: Song sheet

    func testSongSheetLight() throws { try captureSheet("light") }
    func testSongSheetDark() throws { try captureSheet("dark") }

    // MARK: Lyrics screen

    func testInstrumentalReady() throws { try captureLyrics("tais.instrumental") }
    func testInstrumentalRendering() throws { try captureLyrics("tais.instrumentalRendering") }
    func testInstrumentalPlaying() throws { try captureLyrics("tais.instrumentalActive") }

    // MARK: - Helpers

    private func launch(_ screen: String, _ appearance: String, extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance] + extra
        app.launch()
        return app
    }

    /// Experimental is long: scrolls until `identifier` sits in the upper half of the screen.
    private func captureExperimental(_ screen: String, _ appearance: String, until identifier: String) throws {
        let app = launch(screen, appearance)
        XCTAssertTrue(app.descendants(matching: .any)["screen.experimental"].firstMatch.waitForExistence(timeout: 20),
                      "Experimental did not appear")
        Thread.sleep(forTimeInterval: 1.0)
        let target = app.descendants(matching: .any)[identifier].firstMatch
        let height = app.windows.firstMatch.frame.height
        for _ in 0..<12 {
            if target.exists, target.isHittable, target.frame.minY < height * 0.62 { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(target.exists, "\(identifier) is missing")
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, "\(screen)-\(appearance)")
    }

    private func captureSheet(_ appearance: String) throws {
        let app = launch("tais.songSheet", appearance)
        XCTAssertTrue(app.descendants(matching: .any)["screen.songInfo"].firstMatch.waitForExistence(timeout: 20),
                      "the song sheet did not appear")
        Thread.sleep(forTimeInterval: 1.0)
        let card = app.descendants(matching: .any)["tais.lyrics.start"].firstMatch
        let height = app.windows.firstMatch.frame.height
        for _ in 0..<4 {
            if card.exists, card.isHittable, card.frame.maxY < height * 0.95 { break }
            app.swipeUp(velocity: .slow)
        }
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, "tais.songSheet-\(appearance)")
    }

    private func captureLyrics(_ screen: String) throws {
        let app = launch(screen, "dark", extra: ["-lyricsDemo", "none"])
        XCTAssertTrue(app.descendants(matching: .any)["lyrics.instrumental"].firstMatch.waitForExistence(timeout: 20),
                      "the instrumental card did not appear")
        // Let the artwork bake and the background crossfade settle.
        Thread.sleep(forTimeInterval: 3.0)
        attach(app, "\(screen)-dark")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
