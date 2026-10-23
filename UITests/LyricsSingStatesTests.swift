import XCTest

/// Sing's in-flight states on the lyrics screen, from demo data (`TaisDemo`, no network): the cloud making the
/// instrumental, the cloud waiting for Wi-Fi, and the switch waiting for a gap between sung words. The button's
/// accessibility label stays "Sing" in all of them; the state is its value.
@MainActor
final class LyricsSingStatesTests: XCTestCase {
    /// The cloud is uploading the song (40 %): "Preparing…" with the job's progress filling the segment.
    func testSingPreparingInTheCloud() throws {
        try capture("lyricsSingPreparingCloud", screen: "tais.singPreparingCloud") { sing in
            XCTAssertEqual(sing.value as? String, "Preparing in the cloud — Uploading 40%",
                           "Sing is not showing the cloud job's step")
        }
    }

    /// Cellular data is off and the phone is not on Wi-Fi: the upload waits and the button says so.
    func testSingWaitingForWiFi() throws {
        try capture("lyricsSingWaitingForWiFi", screen: "tais.singWaitingForWiFi") { sing in
            XCTAssertEqual(sing.value as? String, "Waiting for Wi-Fi", "Sing is not waiting for Wi-Fi")
        }
    }

    /// The instrumental is here and the swap waits a moment for a gap between sung words.
    func testSingWaitingForAQuietMoment() throws {
        try capture("lyricsSingWaitingGap", screen: "tais.singWaitingGap") { sing in
            XCTAssertEqual(sing.value as? String, "Waiting for a quiet moment", "Sing is not waiting for a gap")
        }
    }

    /// The card shown when a song has no lyrics asks for the instrumental the same way: while the cloud makes it, the
    /// bar and the line under it follow the job.
    func testNoLyricsCardWhileTheCloudPreparesTheInstrumental() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", "tais.singPreparingCloud", "-appearance", "dark", "-lyricsDemo", "none"]
        app.launch()

        let button = app.descendants(matching: .any)["lyrics.instrumental"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "the instrumental card did not appear")
        let detail = app.descendants(matching: .any)["lyrics.instrumental.detail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "the card does not show the job's step")
        XCTAssertEqual(detail.label, "Uploading 40%")
        // Let the artwork bake and the background crossfade settle.
        Thread.sleep(forTimeInterval: 3.0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "lyricsNoLyricsSingPreparingCloud-dark"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func capture(_ name: String, screen: String, then check: (XCUIElement) -> Void) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", "dark", "-lyricsDemo", "words",
                               "-lyricsFreezeMs", "42300"]
        app.launch()

        let ready = app.descendants(matching: .any)["screen.lyrics"].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "screen.lyrics did not appear for \(name)")
        let sing = app.buttons.matching(NSPredicate(format: "label == %@", "Sing")).firstMatch
        XCTAssertTrue(sing.waitForExistence(timeout: 10), "Sing is missing for \(name)")
        // Let the cascade, the artwork bake and the background crossfade settle.
        Thread.sleep(forTimeInterval: 3.0)
        check(sing)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(name)-dark"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
