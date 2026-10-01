import XCTest

/// Stage 7c screenshots: Search empty (browse grid), typing, and results per filter, light + dark. Compare with
/// Android's `SearchScreen` (docs/design.md › Screenshot ids). These live in an extension of `ScreenshotTests` so the
/// CI shots job (`-only-testing:PixlAudioUITests/ScreenshotTests`) runs them without workflow changes; `@objc` keeps
/// them visible to XCTest's discovery.
extension ScreenshotTests {
    // MARK: Empty query: browse categories + genres

    @objc func testSearchEmptyLight() { captureSearch("searchEmpty", "light") }
    @objc func testSearchEmptyDark() { captureSearch("searchEmpty", "dark") }

    // MARK: Typing (field focused, keyboard up)

    @objc func testSearchTypingLight() { captureSearch("searchTyping", "light", typing: "Lu") }
    @objc func testSearchTypingDark() { captureSearch("searchTyping", "dark", typing: "Lu") }

    // MARK: Results per filter (library + demo "More on Spotify" / "From YouTube Music" sections)

    @objc func testSearchAllLight() { captureSearch("searchAll", "light", query: "Luma", filter: "all") }
    @objc func testSearchAllDark() { captureSearch("searchAll", "dark", query: "Luma", filter: "all") }
    @objc func testSearchSongsLight() { captureSearch("searchSongs", "light", query: "Li", filter: "songs") }
    @objc func testSearchSongsDark() { captureSearch("searchSongs", "dark", query: "Li", filter: "songs") }
    @objc func testSearchAlbumsLight() { captureSearch("searchAlbums", "light", query: "Luma", filter: "albums") }
    @objc func testSearchAlbumsDark() { captureSearch("searchAlbums", "dark", query: "Luma", filter: "albums") }
    @objc func testSearchArtistsLight() { captureSearch("searchArtists", "light", query: "Pi", filter: "artists") }
    @objc func testSearchArtistsDark() { captureSearch("searchArtists", "dark", query: "Pi", filter: "artists") }
    @objc func testSearchPlaylistsLight() {
        captureSearch("searchPlaylists", "light", query: "e", filter: "playlists")
    }
    @objc func testSearchPlaylistsDark() {
        captureSearch("searchPlaylists", "dark", query: "e", filter: "playlists")
    }

    // MARK: No results

    @objc func testSearchNoResultsLight() { captureSearch("searchNoResults", "light", query: "Zzyzx") }
    @objc func testSearchNoResultsDark() { captureSearch("searchNoResults", "dark", query: "Zzyzx") }

    // MARK: - Helper

    private func captureSearch(_ name: String, _ appearance: String, query: String? = nil, filter: String? = nil,
                               typing: String? = nil) {
        continueAfterFailure = false
        let app = XCUIApplication()
        var arguments = ["-uiTest", "-screen", "search", "-appearance", appearance]
        if let query { arguments += ["-searchQuery", query] }
        if let filter { arguments += ["-searchFilter", filter] }
        app.launchArguments = arguments
        app.launch()

        let screen = app.descendants(matching: .any)["screen.search"].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 20), "screen.search did not appear")

        if let typing {
            let field = app.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10), "the search field is not visible")
            field.tap()
            field.typeText(typing)
        }

        if query != nil || typing != nil {
            let expected = name == "searchNoResults" ? "search.empty" : "search.results"
            XCTAssertTrue(app.descendants(matching: .any)[expected].firstMatch.waitForExistence(timeout: 10),
                          "\(expected) did not appear")
        } else {
            XCTAssertTrue(app.descendants(matching: .any)["search.genreGrid"].firstMatch.waitForExistence(timeout: 10),
                          "the browse grid did not appear")
        }

        // Debounced searches (160 / 420 ms), artwork, album colours and glass settle.
        Thread.sleep(forTimeInterval: 2.0)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(name)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
    }
}
