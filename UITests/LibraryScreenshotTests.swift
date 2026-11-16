import XCTest

/// Stage 7a screenshots: the Library tabs, its sheets and selection mode, the song options sheet, and the album,
/// artist, genre and playlist screens plus the playlist editor — each in demo data (`-uiTest -screen <id>`).
/// Compare with docs/design-refs/ (pp_lib, pp_songs, pp_card, owner-library-songs-2026-09-30).
@MainActor
final class LibraryScreenshotTests: XCTestCase {
    // MARK: Library tabs (ref: pp_lib = Playlists, pp_songs / owner-library-songs = Songs)

    func testLibraryPlaylistsLight() throws { try capture("libraryPlaylists", "light", ready: "library.page.playlists") }
    func testLibraryPlaylistsDark() throws { try capture("libraryPlaylists", "dark", ready: "library.page.playlists") }
    func testLibraryAlbumsLight() throws { try capture("libraryAlbums", "light", ready: "library.page.albums") }
    func testLibraryAlbumsDark() throws { try capture("libraryAlbums", "dark", ready: "library.page.albums") }
    func testLibraryAlbumsListDark() throws { try capture("libraryAlbumsList", "dark", ready: "library.page.albums") }
    func testLibraryArtistsLight() throws { try capture("libraryArtists", "light", ready: "library.page.artists") }
    func testLibraryLikedDark() throws { try capture("libraryLiked", "dark", ready: "library.page.liked") }
    func testLibraryCompactNavLight() throws { try capture("libraryCompactNav", "light", ready: "library.page.albums") }
    func testLibraryCompactNavDark() throws { try capture("libraryCompactNav", "dark", ready: "library.page.albums") }

    // MARK: Library sheets and selection

    func testLibrarySelectionLight() throws { try capture("librarySelection", "light", ready: "screen.library") }
    func testLibrarySortLight() throws { try capture("librarySort", "light", ready: "sheet.sort") }
    func testLibrarySortDark() throws { try capture("librarySort", "dark", ready: "sheet.sort") }
    func testLibraryReorderTabsDark() throws { try capture("libraryReorderTabs", "dark", ready: "sheet.reorderTabs") }
    func testLibraryMultiSelectionLight() throws { try capture("libraryMultiSelection", "light", ready: "sheet.songSelection") }
    func testLibraryCreatePlaylistLight() throws { try capture("libraryCreatePlaylist", "light", ready: "sheet.createPlaylist") }
    /// "With AI" while the selected on-device model can't answer (its system switch is off): the reason, and "Open AI
    /// settings" instead of "Set up API key".
    func testLibraryCreatePlaylistOnDeviceOffDark() throws {
        try capture("libraryCreatePlaylist.onDeviceOff", "dark", ready: "sheet.createPlaylist")
    }
    func testLibraryAddToPlaylistDark() throws { try capture("libraryAddToPlaylist", "dark", ready: "sheet.addToPlaylist") }

    // MARK: Song options sheet (ref: pp_card)

    func testSongOptionsLight() throws { try capture("songInfo", "light", ready: "screen.songInfo") }
    func testSongOptionsDark() throws { try capture("songInfo", "dark", ready: "screen.songInfo") }
    func testSongOptionsInfoLight() throws { try capture("songOptionsInfo", "light", ready: "screen.songInfo") }

    // MARK: Detail screens

    func testAlbumDetailLight() throws { try capture("albumDetail", "light", ready: "screen.albumDetail") }
    func testAlbumDetailDark() throws { try capture("albumDetail", "dark", ready: "screen.albumDetail") }
    func testArtistDetailLight() throws { try capture("artistDetail", "light", ready: "screen.artistDetail") }
    func testArtistDetailDark() throws { try capture("artistDetail", "dark", ready: "screen.artistDetail") }
    /// New UI (stage 4): Play and Shuffle on the hero, then scrolled until the name has collapsed into the bar.
    func testArtistDetailCollapsedDark() throws {
        try capture("artistDetail", "dark", ready: "screen.artistDetail", suffix: "-collapsed") { app in
            // By label: controls inside a glass container keep only their labels.
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Play")).firstMatch
                              .waitForExistence(timeout: 10), "Play is missing on the artist hero")
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Shuffle play")).firstMatch
                              .exists, "Shuffle is missing on the artist hero")
            app.swipeUp()
        }
    }
    /// The ⋯ menu: the artist image actions (Android's pencil) and Block artist.
    func testArtistDetailMenuLight() throws {
        try capture("artistDetail", "light", ready: "screen.artistDetail", tap: "More options", suffix: "-menu") { app in
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Choose")).firstMatch
                              .waitForExistence(timeout: 10), "the artist image action is missing from the menu")
        }
    }
    func testGenreDetailLight() throws { try capture("genreDetail", "light", ready: "screen.genreDetail") }
    func testGenreDetailDark() throws { try capture("genreDetail", "dark", ready: "screen.genreDetail") }
    func testGenreSortLight() throws { try capture("genreSort", "light", ready: "screen.genreDetail", tap: "Options") }
    /// Genre Quick Fill, opened by the genre page on launch (`genre.quickFill`): the floating bar's Select all · Clear
    /// pair and Next pill as separate glass (2026-10-07), the gap between them empty as on Android.
    func testGenreQuickFillLight() throws {
        try capture("genre.quickFill", "light", ready: "screen.quickFill.genre")
    }
    /// The same bar on the genre step (Select all, then Next): the pair has left and the status capsule takes its room.
    func testGenreQuickFillGenreStepDark() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", "genre.quickFill", "-appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.quickFill.genre"].firstMatch.waitForExistence(timeout: 20),
                      "Quick Fill did not appear")
        // By label: controls inside a glass container keep only their labels.
        let selectAll = app.buttons.matching(NSPredicate(format: "label == %@", "Select all")).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10), "Select all is missing")
        selectAll.tap()
        let next = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Next")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10), "Next is missing")
        next.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Quick Fill")).firstMatch
                          .waitForExistence(timeout: 10), "the genre step did not open")
        Thread.sleep(forTimeInterval: 2.0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "genre.quickFill.genreStep-dark"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    // MARK: Playlists

    func testPlaylistDetailLight() throws { try capture("playlistDetail", "light", ready: "screen.playlistDetail") }
    func testPlaylistDetailDark() throws { try capture("playlistDetail", "dark", ready: "screen.playlistDetail") }
    func testPlaylistReorderLight() throws { try capture("playlistReorder", "light", ready: "screen.playlistDetail") }
    /// New UI stage 5: the cover hero with Play and Shuffle, then swiped up to the collapsed bar over the song card.
    func testPlaylistDetailCollapsedDark() throws {
        try capture("playlistDetail", "dark", ready: "screen.playlistDetail", suffix: "-collapsed") { app in
            // By label: controls inside a glass container keep only their labels.
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Play")).firstMatch
                              .waitForExistence(timeout: 10), "Play is missing on the playlist hero")
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Shuffle")).firstMatch
                              .exists, "Shuffle is missing on the playlist hero")
            app.swipeUp()
        }
    }
    func testPlaylistOptionsLight() throws { try capture("playlistOptions", "light", ready: "sheet.playlistOptions") }
    /// The options sheet pulled up to its large detent: "Process all on-device" and "Process all in cloud" under
    /// "Download all songs".
    func testPlaylistOptionsExpandedLight() throws {
        try capture("playlistOptions", "light", ready: "sheet.playlistOptions", suffix: "-expanded") { $0.swipeUp() }
    }
    func testPlaylistAddSongsDark() throws { try capture("playlistAddSongs", "dark", ready: "sheet.songPicker") }

    func testPlaylistEditorLight() throws { try capture("playlistEditor", "light", ready: "screen.playlistEditor") }
    func testPlaylistEditorDark() throws { try capture("playlistEditor", "dark", ready: "screen.playlistEditor") }
    func testPlaylistEditDark() throws { try capture("playlistEdit", "dark", ready: "screen.playlistEditor") }

    // MARK: - Helper

    private func capture(_ screen: String, _ appearance: String, ready: String, tap: String? = nil, suffix: String = "",
                         interact: ((XCUIApplication) -> Void)? = nil) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest", "-screen", screen, "-appearance", appearance]
        app.launch()

        let element = app.descendants(matching: .any)[ready].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "\(ready) did not appear on \(screen)")
        if let tap {
            let button = app.buttons[tap].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), "\(tap) is missing on \(screen)")
            button.tap()
        }
        interact?(app)

        // Let artwork decoding, album colour extraction, glass and sheet presentations settle.
        Thread.sleep(forTimeInterval: 2.0)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(screen)-\(appearance)\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
    }
}
