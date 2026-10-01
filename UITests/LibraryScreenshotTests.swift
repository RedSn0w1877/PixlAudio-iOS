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
    func testLibraryFoldersLight() throws { try capture("libraryFolders", "light", ready: "library.page.folders") }
    func testLibraryLikedDark() throws { try capture("libraryLiked", "dark", ready: "library.page.liked") }

    // MARK: Library sheets and selection

    func testLibrarySelectionLight() throws { try capture("librarySelection", "light", ready: "screen.library") }
    func testLibrarySortLight() throws { try capture("librarySort", "light", ready: "sheet.sort") }
    func testLibrarySortDark() throws { try capture("librarySort", "dark", ready: "sheet.sort") }
    func testLibraryReorderTabsDark() throws { try capture("libraryReorderTabs", "dark", ready: "sheet.reorderTabs") }
    func testLibraryMultiSelectionLight() throws { try capture("libraryMultiSelection", "light", ready: "sheet.songSelection") }
    func testLibraryCreatePlaylistLight() throws { try capture("libraryCreatePlaylist", "light", ready: "sheet.createPlaylist") }
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
    func testGenreDetailLight() throws { try capture("genreDetail", "light", ready: "screen.genreDetail") }
    func testGenreDetailDark() throws { try capture("genreDetail", "dark", ready: "screen.genreDetail") }
    func testGenreSortLight() throws { try capture("genreSort", "light", ready: "screen.genreDetail", tap: "Options") }
    func testFolderExplorerLight() throws { try capture("folderExplorer", "light", ready: "screen.folderExplorer") }

    // MARK: Playlists

    func testPlaylistDetailLight() throws { try capture("playlistDetail", "light", ready: "screen.playlistDetail") }
    func testPlaylistDetailDark() throws { try capture("playlistDetail", "dark", ready: "screen.playlistDetail") }
    func testPlaylistReorderLight() throws { try capture("playlistReorder", "light", ready: "screen.playlistDetail") }
    func testPlaylistOptionsLight() throws { try capture("playlistOptions", "light", ready: "sheet.playlistOptions") }
    func testPlaylistAddSongsDark() throws { try capture("playlistAddSongs", "dark", ready: "sheet.songPicker") }
    func testPlaylistEditorLight() throws { try capture("playlistEditor", "light", ready: "screen.playlistEditor") }
    func testPlaylistEditorDark() throws { try capture("playlistEditor", "dark", ready: "screen.playlistEditor") }
    func testPlaylistEditDark() throws { try capture("playlistEdit", "dark", ready: "screen.playlistEditor") }

    // MARK: - Helper

    private func capture(_ screen: String, _ appearance: String, ready: String, tap: String? = nil) throws {
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

        // Let artwork decoding, album colour extraction, glass and sheet presentations settle.
        Thread.sleep(forTimeInterval: 2.0)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(screen)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
    }
}
