import XCTest

/// Stage 13 screenshots with the scripted AI provider (`DemoAiClient`, no network): the AI playlist sheet (Android
/// `AiPlaylistSheet`) empty, with a prompt, and in its error state; the TAIS DJ chat (Android `TaisChatSheet`) empty
/// and with a scripted conversation (a genre request answered from the demo library, then a music question); and
/// the AI Playlist Lab (Android `CreateAiPlaylistDialog`).
@MainActor
final class AIScreenshotTests: XCTestCase {
    // MARK: AI playlist sheet

    func testAiPlaylistLight() throws { try capture("aiPlaylist", "light") }
    func testAiPlaylistDark() throws { try capture("aiPlaylist", "dark") }

    func testAiPlaylistPromptLight() throws {
        try capture("aiPlaylist", "light", name: "aiPlaylist-prompt") { app in
            let field = app.descendants(matching: .any)["aiPlaylist.prompt"].firstMatch
            field.tap()
            field.typeText("Late-night synthwave for a city drive")
            app.descendants(matching: .any)["Playlist size"].firstMatch.tap()
        }
    }

    func testAiPlaylistErrorDark() throws {
        try capture("aiPlaylist", "dark", name: "aiPlaylist-error") { app in
            let field = app.descendants(matching: .any)["aiPlaylist.prompt"].firstMatch
            field.tap()
            field.typeText("Rainy morning jazz #demo-error")
            app.descendants(matching: .any)["Playlist size"].firstMatch.tap()
            app.descendants(matching: .any)["aiPlaylist.generate"].firstMatch.tap()
            XCTAssertTrue(app.descendants(matching: .any)["aiPlaylist.error"].firstMatch.waitForExistence(timeout: 15),
                          "the error card did not appear")
        }
    }

    // MARK: TAIS DJ chat

    func testTaisChatLight() throws { try capture("taisChat", "light") }
    func testTaisChatDark() throws { try capture("taisChat", "dark") }

    func testTaisChatConversationLight() throws {
        try capture("taisChatConversation", "light", name: "taisChat-conversation", wait: "Daft Punk")
    }

    func testTaisChatConversationDark() throws {
        try capture("taisChatConversation", "dark", name: "taisChat-conversation", wait: "Daft Punk")
    }

    /// The conversation scrolled back to Taizo's queue card (artwork stack, count, Play / Add to Queue, the songs).
    func testTaisChatQueueCardLight() throws {
        try capture("taisChatConversation", "light", name: "taisChat-queueCard", swipesDown: 1, wait: "Daft Punk")
    }

    func testTaisChatQueueCardDark() throws {
        try capture("taisChatConversation", "dark", name: "taisChat-queueCard", swipesDown: 1, wait: "Daft Punk")
    }

    /// A prompt being typed: the composer's send button lights up in the accent.
    func testTaisChatTypingDark() throws {
        try capture("taisChat", "dark", name: "taisChat-typing") { app in
            let field = app.textFields["taisChat.input"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), "the composer's field (taisChat.input) is missing")
            field.tap()
            field.typeText("Something mellow for a rainy night")
        }
    }

    // MARK: AI Playlist Lab

    func testAiPlaylistLabLight() throws { try capture("aiPlaylistLab", "light") }
    func testAiPlaylistLabScrolledDark() throws { try capture("aiPlaylistLab", "dark", name: "aiPlaylistLab-scrolled", swipes: 2) }

    // MARK: - Helper

    private func capture(_ screen: String, _ appearance: String, name: String? = nil, swipes: Int = 0, swipesDown: Int = 0,
                         wait text: String? = nil, action: ((XCUIApplication) -> Void)? = nil) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance, "-noSong"]
        app.launch()

        let ready = screen == "taisChatConversation" ? "screen.taisChat" : "screen.\(screen)"
        let element = app.descendants(matching: .any)[ready].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(ready) did not appear")
        // Let the sheet settle and the glass render.
        Thread.sleep(forTimeInterval: 1.5)
        if let text {
            let predicate = NSPredicate(format: "label CONTAINS %@", text)
            XCTAssertTrue(app.staticTexts.containing(predicate).firstMatch.waitForExistence(timeout: 15),
                          "\"\(text)\" did not appear")
            Thread.sleep(forTimeInterval: 1.0)
        }
        if let action {
            action(app)
            Thread.sleep(forTimeInterval: 1.0)
        }
        for _ in 0..<swipes {
            app.swipeUp(velocity: .slow)
        }
        for _ in 0..<swipesDown {
            app.swipeDown(velocity: .slow)
        }
        Thread.sleep(forTimeInterval: swipes + swipesDown > 0 ? 1.5 : 0.5)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(name ?? screen)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }
}
