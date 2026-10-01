import PixlLibrary
import PixlModel
import XCTest
@testable import PixlAudio

/// Stage 7c: Search's library provider, state holder, result grouping, genre list, genre colours and icons,
/// title typography and search history.
@MainActor
final class SearchTests: XCTestCase {
    // MARK: Genres (Android MusicRepositoryImpl.getGenres / buildGenre, GenreThemeUtils, GenreIconProvider)

    func testLibraryGenresSplitTrimDedupeSortAndUnknown() {
        func song(_ id: String, _ genre: String?) -> Song {
            Song(id: id, title: id, artist: "A", artistId: 1, album: "B", albumId: 1, path: "", contentUriString: "",
                 albumArtUriString: nil, duration: 1000, genre: genre, mimeType: nil, bitrate: nil, sampleRate: nil)
        }
        let genres = LibraryGenres.genres(from: [
            song("1", "Rock, Pop"), song("2", " pop "), song("3", "Hip Hop/Rap"), song("4", nil), song("5", "  ,  "),
            song("6", "Électro"),
        ])
        XCTAssertEqual(genres.map(\.id), ["hip_hop_rap", "pop", "rock", "électro", "unknown"])
        XCTAssertEqual(genres.map(\.name), ["Hip Hop/Rap", "Pop", "Rock", "Électro", "Unknown"])
        XCTAssertEqual(genres.first?.lightColorHex, GenreCardPalette.hexString(GenreCardPalette.color(genreId: "hip_hop_rap", isDark: false).container))
    }

    func testDemoLibraryGenres() {
        let ids = LibraryGenres.genres(from: DemoLibrary.songs).map(\.id)
        XCTAssertEqual(ids, ["ambient", "electronic", "folk", "indie", "r&b", "rock", "soul", "synthpop"])
    }

    func testGenrePaletteFollowsJavaHashCode() {
        XCTAssertEqual(KotlinText.hashCode("rock"), 3_506_021)
        // 3506021 % 20 = 1 → Rose.
        XCTAssertEqual(GenreCardPalette.color(genreId: "rock", isDark: true),
                       GenreThemeColor(container: 0xFF7D5260, onContainer: 0xFFFFD8E4))
        XCTAssertEqual(GenreCardPalette.color(genreId: "rock", isDark: false),
                       GenreThemeColor(container: 0xFFFFD8E4, onContainer: 0xFF631835))
        // "indie" → 11 (Indigo), "pop" → 5 (Gold/Orange).
        XCTAssertEqual(GenreCardPalette.color(genreId: "indie", isDark: true).container, 0xFF4F378B)
        XCTAssertEqual(GenreCardPalette.color(genreId: "pop", isDark: false).container, 0xFFFFDEAC)
        XCTAssertEqual(GenreCardPalette.color(genreId: "Unknown Genre", isDark: true), GenreCardPalette.unknownDark)
        XCTAssertEqual(GenreCardPalette.hexString(0xFF004A77), "#FF004A77")
        XCTAssertEqual(GenreCardPalette.parseHex("#004A77"), 0xFF004A77)
        XCTAssertNil(GenreCardPalette.parseHex("nope"))
        let explicit = Genre(id: "x", name: "X", lightColorHex: "#FF112233", onLightColorHex: "#FFFFFFFF")
        XCTAssertEqual(GenreCardPalette.color(for: explicit, isDark: false),
                       GenreThemeColor(container: 0xFF112233, onContainer: 0xFFFFFFFF))
    }

    func testOklabLerpEndpoints() {
        XCTAssertEqual(OklabMix.lerp(0xFF7D5260, 0xFFFFFFFF, 0), 0xFF7D5260)
        XCTAssertEqual(OklabMix.lerp(0xFF7D5260, 0xFFFFFFFF, 1), 0xFFFFFFFF)
        XCTAssertEqual(OklabMix.lerp(0xFF000000, 0xFF000000, 0.5), 0xFF000000)
    }

    func testGenreIconsMatchAndroidTable() {
        XCTAssertEqual(GenreIcon.forGenre("Rock"), .art("genre_rock"))
        XCTAssertEqual(GenreIcon.forGenre("  Hip-Hop "), .art("genre_rapper"))
        XCTAssertEqual(GenreIcon.forGenre("Lo-fi"), .art("genre_idk_indie_ig"))
        XCTAssertEqual(GenreIcon.forGenre("Ambient"), .symbol("alarm"))
        XCTAssertEqual(GenreIcon.forGenre("unknown"), .symbol("questionmark"))
        XCTAssertEqual(GenreIcon.forGenre("Synthpop-not-a-genre"), GenreIconTable.fallback)
        XCTAssertEqual(GenreIconTable.fallback, .symbol("music.note.square.stack"))
        // Every category card has an entry.
        for category in SearchCategory.defaults {
            XCTAssertNotNil(GenreIconTable.byAlias[KotlinText.lowercase(category.name)], category.name)
        }
    }

    func testGenreTitleFitsOrBreaks() {
        let short = GenreTitleTypography.resolve(genreId: "pop", name: "Pop", isGridView: true, cardWidth: 170,
                                                 horizontalPadding: 14)
        XCTAssertEqual(short.firstLine, "Pop")
        XCTAssertNil(short.secondLine)
        let long = GenreTitleTypography.resolve(genreId: "x", name: "Progressive Melodic Death Metal", isGridView: true,
                                                cardWidth: 170, horizontalPadding: 14)
        XCTAssertNotNil(long.secondLine)
        XCTAssertEqual(long.secondLineWidthFraction, 0.56)
        XCTAssertEqual([long.firstLine, long.secondLine ?? ""].joined(separator: " "), "Progressive Melodic Death Metal")
    }

    // MARK: Library provider (SearchIndex)

    func testLibraryProviderSearchesTheSnapshotByFilter() async throws {
        let provider = LibrarySearchProvider()
        let empty = try await provider.search("Luma", filter: .all, limit: .max)
        XCTAssertTrue(empty.isEmpty)
        let rebuilt = await provider.update(snapshot: DemoLibrary.snapshot)
        XCTAssertTrue(rebuilt)
        let again = await provider.update(snapshot: DemoLibrary.snapshot)
        XCTAssertFalse(again)

        let all = try await provider.search("Luma", filter: .all, limit: .max)
        let kinds = all.map(SearchResultSection.kind(of:))
        XCTAssertEqual(kinds, kinds.sorted { SearchResultSection.order.firstIndex(of: $0)! < SearchResultSection.order.firstIndex(of: $1)! })
        XCTAssertEqual(all.filter { SearchResultSection.kind(of: $0) == .songs }.count, 3) // Luma Vale's songs (artist)
        XCTAssertTrue(all.contains(.artist(DemoLibrary.snapshot.artists.first { $0.name == "Luma Vale" }!)))

        // Songs = titles only.
        let titles = try await provider.search("Luma", filter: .songs, limit: .max)
        XCTAssertTrue(titles.isEmpty)
        let night = try await provider.search("Night", filter: .playlists, limit: .max)
        XCTAssertEqual(night, [.playlist(DemoLibrary.snapshot.playlists[0])])

        // min tracks per album.
        await provider.setMinTracksPerAlbum(3)
        let albums = try await provider.search("Luma", filter: .albums, limit: .max)
        XCTAssertTrue(albums.allSatisfy { if case .album(let a) = $0 { a.songCount >= 3 } else { false } })
    }

    // MARK: Grouping and the state holder

    func testSectionsGroupInAndroidOrderWithStableKeys() {
        let snapshot = DemoLibrary.snapshot
        let items: [SearchResultItem] = [
            .youtubeMusic(DemoYouTubeMusicSearchProvider.tracks[0]),
            .playlist(snapshot.playlists[0]), .playlist(snapshot.playlists[0]),
            .catalog(DemoCatalogSearchProvider.tracks[0]),
            .song(snapshot.songs[0]), .album(snapshot.albums[0]),
        ]
        let sections = SearchResultSection.group(items)
        XCTAssertEqual(sections.map(\.kind), [.songs, .albums, .playlists, .catalog, .youtubeMusic])
        XCTAssertEqual(sections.map(\.title), ["Songs", "Albums", "Playlists", "More on Spotify", "From YouTube Music"])
        XCTAssertEqual(sections[2].rows.map(\.id), ["playlist_demo-playlist-1_0", "playlist_demo-playlist-1_1"])
        XCTAssertEqual(sections[0].rows.first?.id, "song_demo:0")
        XCTAssertEqual(SearchFormat.songCount(0), "0 Song")
        XCTAssertEqual(SearchFormat.songCount(1), "1 Song")
        XCTAssertEqual(SearchFormat.songCount(7), "7 Songs")
    }

    func testModelRunsLibraryAndRemoteSearches() async throws {
        let library = LibrarySearchProvider()
        await library.update(snapshot: DemoLibrary.snapshot)
        let model = SearchModel()
        model.attach(providers: [.library: library, .spotify: DemoCatalogSearchProvider(),
                                 .youtubeMusic: DemoYouTubeMusicSearchProvider()], persistence: nil)
        model.performSearch("Luma")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(model.sections.map(\.kind), [.songs, .albums, .artists, .catalog, .youtubeMusic])
        XCTAssertFalse(model.isCatalogSearching)
        XCTAssertFalse(model.showsEmptyState)
        XCTAssertEqual(model.songResults.count, 3)

        // One character: library only (remote searches need two).
        model.performSearch("L")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(model.sections.contains { $0.kind == .catalog || $0.kind == .youtubeMusic })

        // Blank: everything clears.
        model.performSearch("   ")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertTrue(model.sections.isEmpty)

        // Filter change re-runs with title-only songs.
        model.filter = .songs
        model.performSearch("Luma")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(model.sections.map(\.kind), [.catalog, .youtubeMusic])

        // A remote row leaves its section after import (demo providers import nothing).
        let row = try XCTUnwrap(model.sections.first?.rows.first?.item)
        let song = await model.importRemote(row, play: true)
        XCTAssertNil(song)
        XCTAssertEqual(model.sections.first?.rows.count, DemoCatalogSearchProvider.tracks.filter {
            DemoSearchMatch.matches("Luma", $0.title, $0.artist)
        }.count - 1)
    }

    func testNoResultsShowsEmptyState() async throws {
        let library = LibrarySearchProvider()
        await library.update(snapshot: DemoLibrary.snapshot)
        let model = SearchModel()
        model.attach(providers: [.library: library, .spotify: DemoCatalogSearchProvider(),
                                 .youtubeMusic: DemoYouTubeMusicSearchProvider()], persistence: nil)
        model.performSearch("Zzyzx")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertTrue(model.showsEmptyState)
    }

    // MARK: History (Android SearchHistoryDao)

    func testSearchHistoryKeepsOneRowPerQueryNewestFirst() async throws {
        let container = try PersistenceActor.makeContainer(inMemory: true)
        let persistence = PersistenceActor(modelContainer: container)
        try await persistence.addSearchHistoryItem("luma", timestamp: 1)
        try await persistence.addSearchHistoryItem("night", timestamp: 2)
        try await persistence.addSearchHistoryItem("luma", timestamp: 3)
        var recent = try await persistence.recentSearchHistory()
        XCTAssertEqual(recent.map(\.query), ["luma", "night"])
        XCTAssertEqual(recent.first?.timestamp, 3)
        recent = try await persistence.recentSearchHistory(limit: 1)
        XCTAssertEqual(recent.map(\.query), ["luma"])
        try await persistence.deleteSearchHistoryItem(query: "luma")
        recent = try await persistence.recentSearchHistory()
        XCTAssertEqual(recent.map(\.query), ["night"])
        try await persistence.clearSearchHistory()
        recent = try await persistence.recentSearchHistory()
        XCTAssertTrue(recent.isEmpty)
    }

    func testSearchLaunchOptionsDefaultToAll() {
        XCTAssertEqual(SearchLaunchOptions.initialFilter, .all)
        XCTAssertEqual(SearchFilterChips.filters, [.all, .songs, .albums, .artists, .playlists])
    }
}
