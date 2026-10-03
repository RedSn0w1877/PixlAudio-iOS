import PixlLibrary
import PixlModel
import XCTest
@testable import PixlAudio

/// Stage 7a logic behind the Library and detail screens: genre colours (ported `GenreThemeUtilsTest`), ordered
/// selection, the per-playlist song order, the playlist cover form, the Library lists and the detail groupings.
@MainActor
final class LibraryScreensTests: XCTestCase {
    // MARK: GenreThemeUtilsTest (Android ui/theme)

    func testGenreDetailSchemeUsesTheCardContainerAsSeedInLightTheme() {
        let card = GenreTheme.color(genreId: "rock", isDark: false)
        let actual = GenreTheme.scheme(genreId: "rock", isDark: false, style: .vibrant)
        XCTAssertEqual(actual.roles, ArtworkTheme.schemePair(seed: card.container, style: .vibrant).light)
        XCTAssertFalse(actual.isDark)
    }

    func testGenreDetailSchemeUsesTheCardContainerAsSeedInDarkTheme() {
        let card = GenreTheme.color(genreId: "hip_hop", isDark: true)
        let actual = GenreTheme.scheme(genreId: "hip_hop", isDark: true, style: .expressive)
        XCTAssertEqual(actual.roles, ArtworkTheme.schemePair(seed: card.container, style: .expressive).dark)
    }

    func testUnknownGenreUsesTheMonochromeScheme() {
        let actual = GenreTheme.scheme(genreId: "unknown", isDark: false, style: .fruitSalad)
        XCTAssertEqual(actual.roles, ArtworkTheme.monochromePair(seed: 0xFF7C7D84).light)
        XCTAssertTrue(GenreTheme.isUnknown(" Unknown Genre "))
        XCTAssertEqual(GenreTheme.color(genreId: "unknown_genre", isDark: true), GenreTheme.unknownDark)
    }

    func testGenreColourIndexFollowsJavaHashCode() {
        // "rock".hashCode() = 3506021 → 3506021 % 20 = 1.
        XCTAssertEqual(GenreTheme.color(genreId: "rock", isDark: true), GenreTheme.dark[1])
        XCTAssertEqual(GenreTheme.color(genreId: "rock", isDark: false), GenreTheme.light[1])
    }

    // MARK: Selection

    func testOrderedSelectionKeepsSelectionOrder() {
        let selection = OrderedSelection<String>()
        selection.toggle("b")
        selection.toggle("a")
        selection.toggle("c")
        XCTAssertEqual(selection.ids, ["b", "a", "c"])
        XCTAssertEqual(selection.index(of: "a"), 2)
        selection.toggle("b")
        XCTAssertEqual(selection.ids, ["a", "c"])
        XCTAssertEqual(selection.index(of: "c"), 2)
        XCTAssertNil(selection.index(of: "b"))
        selection.selectAll(["c", "d", "a", "e"])
        XCTAssertEqual(selection.ids, ["a", "c", "d", "e"])
        selection.clear()
        XCTAssertFalse(selection.isActive)
    }

    // MARK: Preferences

    func testPlaylistSongOrderModesUseAndroidValues() throws {
        let name = "pixlaudio.tests.library"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let prefs = LibraryPreferences(defaults: defaults)
        XCTAssertEqual(prefs.songOrder(forPlaylist: "p1"), .songDefaultOrder, "manual is the default")
        prefs.setSongOrder(.songArtistDesc, forPlaylist: "p1")
        prefs.setSongOrder(.songDefaultOrder, forPlaylist: "p2")
        let reloaded = LibraryPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.songOrder(forPlaylist: "p1"), .songArtistDesc)
        XCTAssertEqual(reloaded.playlistSongOrderModes["p1"], "song_artist_desc")
        XCTAssertEqual(reloaded.playlistSongOrderModes["p2"], "manual")
        prefs.songSort = .songDurationAsc
        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.songsSortOption), "song_duration_asc")
        prefs.cycleStorageFilter()
        XCTAssertEqual(prefs.storageFilter, .online, "Android toggles all → online → offline")
        defaults.removePersistentDomain(forName: name)
    }

    // MARK: Playlist cover form

    func testCoverFormSavesOnlyTheSelectedTab() {
        var form = PlaylistCoverForm()
        form.name = "Mix"
        form.imageUri = "file:///tmp/a.img"
        form.colorArgb = 0xFF112233
        XCTAssertNil(form.coverFields.imageUri, "the Default tab saves no cover")
        form.tab = .image
        XCTAssertEqual(form.coverFields.imageUri, "file:///tmp/a.img")
        XCTAssertNil(form.coverFields.colorArgb)
        form.tab = .icon
        form.shape = .star
        form.starSides = 7
        let fields = form.coverFields
        XCTAssertNil(fields.imageUri)
        XCTAssertEqual(fields.colorArgb, Int32(bitPattern: 0xFF112233))
        XCTAssertEqual(fields.shapeType, "Star")
        XCTAssertEqual(fields.details, [0.15, 0, 1, 7])
    }

    func testEditFormPicksTheTabLikeAndroid() {
        let image = Playlist(id: "1", name: "A", songIds: [], coverImageUri: "file:///x.img")
        XCTAssertEqual(PlaylistCoverForm(playlist: image, fallbackColor: 0).tab, .image)
        let icon = Playlist(id: "2", name: "B", songIds: [], coverColorArgb: 5, coverShapeType: "SmoothRect",
                            coverShapeDetail1: 30)
        let iconForm = PlaylistCoverForm(playlist: icon, fallbackColor: 0)
        XCTAssertEqual(iconForm.tab, .icon)
        XCTAssertEqual(iconForm.shape, .smoothRect)
        XCTAssertEqual(iconForm.cornerRadius, 30)
        XCTAssertEqual(PlaylistCoverForm(playlist: Playlist(id: "3", name: "C", songIds: []), fallbackColor: 0).tab,
                       .standard)
    }

    // MARK: Library lists

    func testLibraryListsSortAndGroupTheDemoLibrary() {
        let snapshot = DemoLibrary.snapshot
        let inputs = LibraryModel.Inputs(snapshot: snapshot, songSort: .songTitleZA, albumSort: .albumTitleAZ,
                                         artistSort: .artistNumSongsDesc, playlistSort: .playlistNameAZ,
                                         folderSort: .folderNameAZ, likedSort: .likedSongTitleAZ,
                                         storageFilter: .all, likedAt: [:])
        let lists = LibraryModel.compute(inputs)
        XCTAssertEqual(lists.songs.count, snapshot.songs.count)
        XCTAssertEqual(lists.songs.first?.title, "Wildflower Radio")
        XCTAssertEqual(lists.albums.first?.title, "Aurora")
        XCTAssertEqual(lists.playlists.map(\.name), ["Indie Favourites", "Late Night Drive", "Sunday Morning"])
        XCTAssertEqual(lists.liked.count, snapshot.songs.filter(\.isFavorite).count)
        // The tree lists the root's folders (one per demo artist), name A-Z, holding every song between them.
        XCTAssertEqual(lists.folders.map(\.name), Set(snapshot.songs.map(\.artist)).sorted())
        XCTAssertEqual(lists.folders.reduce(0) { $0 + $1.totalSongCount }, snapshot.songs.count)
        XCTAssertFalse(lists.folderPlaylists.isEmpty)
        XCTAssertTrue(lists.folderPlaylists.allSatisfy { !$0.songs.isEmpty })

        var online = inputs
        online.storageFilter = .online
        XCTAssertTrue(LibraryModel.compute(online).songs.isEmpty, "demo songs are local files")
    }

    func testFolderPlaylistIds() {
        let id = FolderPlaylist.id(for: "/Demo/Luma Vale")
        XCTAssertEqual(id, "folder_playlist:/Demo/Luma Vale")
        XCTAssertEqual(FolderPlaylist.path(from: id), "/Demo/Luma Vale")
        XCTAssertNil(FolderPlaylist.path(from: "demo-playlist-1"))
    }

    /// Select all in an open folder adds the folder's songs in the tree's order (Android `currentFolder?.songs`), not
    /// in the order the page shows them: with Name (Z-A) the page lists the folder backwards, the selection does not.
    func testFolderSelectAllKeepsTheTreeOrder() throws {
        let tree = LibraryModel.folderTree(DemoLibrary.songs)
        let folder = try XCTUnwrap(LibraryModel.flatten(tree).first { Set($0.songs.map(\.title)).count > 1 },
                                   "a demo folder with two differently named songs")
        let treeOrder = folder.songs.map(\.id)
        let shown = LibraryModel.folderContents(tree, sort: .folderNameZA)[folder.path]?.songs.map(\.id)
        XCTAssertNotNil(shown)
        XCTAssertNotEqual(shown, treeOrder, "Name (Z-A) shows the folder's songs in another order")
        let sorted = LibrarySorting.sortFolders(tree, by: .folderNameZA)
        XCTAssertEqual(LibraryModel.selectAllSongIds(inFolder: folder.path, of: sorted), treeOrder)
        XCTAssertNil(LibraryModel.selectAllSongIds(inFolder: "/Demo/No such folder", of: sorted))
    }

    func testArtistAlbumSectionsNewestFirst() {
        let songs = DemoLibrary.songs.filter { $0.artist == "Luma Vale" }
        let sections = ArtistDetailGrouping.albumSections(songs)
        XCTAssertEqual(sections.map(\.title), ["Aurora", "City of Glass"].sorted { a, b in
            let year: (String) -> Int = { title in songs.filter { $0.album == title }.map(\.year).max() ?? 0 }
            return year(a) != year(b) ? year(a) > year(b) : a < b
        })
        XCTAssertEqual(sections.flatMap(\.songs).count, songs.count)
    }

    func testGenreItemsGroupByArtistThenAlbum() {
        let songs = GenreGrouping.songs(of: "indie", in: DemoLibrary.songs)
        XCTAssertEqual(songs.count, DemoLibrary.songs.filter { $0.genre == "Indie" }.count)
        let items = GenreGrouping.items(songs, sort: .artist)
        let headers = items.compactMap { item -> String? in
            if case .artistHeader(_, let name) = item { return name }
            return nil
        }
        XCTAssertEqual(headers, headers.sorted())
        let songRows = items.filter { if case .song = $0 { return true } else { return false } }
        XCTAssertEqual(songRows.count, songs.count)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "list ids are unique")
    }

    func testPlaylistExportFileNames() {
        XCTAssertEqual(PlaylistExport.sanitizeFileName("Late/Night: Drive?"), "Late_Night_ Drive_")
        XCTAssertEqual(PlaylistExport.sanitizeFileName("  "), "playlist")
    }
}
