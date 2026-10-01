import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Swift-only tests for the in-memory search (the SQLite behaviour itself is covered by `searchMatchesAndroidSQLite`).
@Suite struct SearchIndexTests {
    private func song(_ id: String, _ title: String, artist: String = "", genre: String? = nil) -> Song {
        testSong(id, title: title, artist: artist, genre: genre)
    }

    private var index: SearchIndex {
        SearchIndex(
            songs: [song("1", "Café del Mar", artist: "Energy 52", genre: "Chillout"), song("2", "Crazy in Love", artist: "Beyoncé"),
                    song("3", "Halo", artist: "Beyoncé", genre: "Pop"), song("4", "東京事変"), song("5", "100% Pure"),
                    song("6", "Ünïcode Song", artist: "Bänd")],
            albums: [Album(id: 1, title: "Dangerously in Love", artist: "Beyoncé", year: 2003, dateAdded: 0, albumArtUriString: nil, songCount: 2),
                     Album(id: 2, title: "Single", artist: "Beyoncé", year: 2004, dateAdded: 0, albumArtUriString: nil, songCount: 1)],
            artists: [Artist(id: 1, name: "Beyoncé", songCount: 2), Artist(id: 2, name: "Ghost", songCount: 0)],
            playlists: [Playlist(id: "p1", name: "Love Songs", songIds: [], createdAt: 0, lastModified: 0),
                        Playlist(id: "p2", name: "Workout", songIds: [], createdAt: 0, lastModified: 0)])
    }

    @Test func tokenizerFoldsCaseAndLatinDiacritics() {
        #expect(Unicode61.tokenStrings("Café del MAR!") == ["cafe", "del", "mar"])
        #expect(Unicode61.tokenStrings("Cafe\u{301}") == ["cafe"])
        #expect(Unicode61.tokenStrings("東京事変 x²") == ["東京事変", "x²"])
        #expect(Unicode61.tokenStrings("  ") == [])
    }

    @Test func matchQueryMatchesTheDao() {
        #expect(SearchIndex.matchQuery("rock & roll", titleOnly: false) == "rock* AND roll*")
        #expect(SearchIndex.matchQuery("rock & roll", titleOnly: true) == "title:rock* AND title:roll*")
        #expect(SearchIndex.matchQuery("!!!", titleOnly: false) == "pixelplayemptyquery*")
        #expect(SearchIndex.matchQuery("a b c d e f g h", titleOnly: false) == "a* AND b* AND c* AND d* AND e* AND f*")
    }

    @Test func songsMatchByPrefixAcrossTitleArtistAndGenre() {
        #expect(index.searchSongs("cafe").map(\.id) == ["1"])
        #expect(index.searchSongs("beyon").map(\.id) == ["2", "3"])
        #expect(index.searchSongs("chill").map(\.id) == ["1"])
        #expect(index.searchSongs("unicode band").map(\.id) == ["6"])
        // Title-only (the Songs filter) ignores artists.
        #expect(index.searchSongs("beyon", titleOnly: true).isEmpty)
    }

    @Test func likeFallbackFindsSubstringsFTSMisses() {
        // FTS has no token starting with "京" but LIKE finds the substring.
        #expect(index.searchSongs("京").map(\.id) == ["4"])
        // `%` is a LIKE wildcard, as on Android.
        #expect(index.searchSongs("0%").map(\.id) == ["5"])
        #expect(index.searchSongs("  ").isEmpty)
        #expect(index.searchSongs("love", limit: 1).count == 1)
    }

    @Test func albumsArtistsAndPlaylists() {
        #expect(index.searchAlbums("love").map(\.id) == [1])
        #expect(index.searchAlbums("beyonc", minTracks: 2).map(\.id) == [1])
        #expect(index.searchArtists("ghost").isEmpty)
        #expect(index.searchArtists("BEYON").map(\.id) == [1])
        #expect(index.searchPlaylists("LOVE").map(\.id) == ["p1"])
    }

    @Test func searchAllGroupsResultsLikeTheRepository() {
        let all = index.searchAll("love", filter: .all)
        #expect(all.count == 3)
        guard case .song(let first) = all[0], case .album = all[1], case .playlist = all[2] else {
            Issue.record("unexpected order \(all)")
            return
        }
        #expect(first.id == "2")
        #expect(index.searchAll("love", filter: .catalog).isEmpty)
        #expect(index.searchAll("", filter: .all).isEmpty)
        #expect(index.searchAll("halo", filter: .songs).count == 1)
    }

    @Test func likeMatcherHandlesWildcards() {
        let p = SQLiteLike.containsPattern("a_c")
        #expect(SQLiteLike.matches("xxABCxx", pattern: p))
        #expect(!SQLiteLike.matches("ac", pattern: p))
        #expect(SQLiteLike.matches("anything", pattern: SQLiteLike.containsPattern("")))
        #expect(!SQLiteLike.matches("É", pattern: SQLiteLike.containsPattern("é")))
    }
}

/// Swift-only tests for the k-means album-art palette.
@Suite struct PaletteExtractorTests {
    private func image(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let p = pixel(x, y)
                out += [p.0, p.1, p.2, p.3]
            }
        }
        return out
    }

    @Test func solidColourIsDominantAndAccent() throws {
        let px = image(width: 8, height: 8) { _, _ in (200, 30, 40, 255) }
        let palette = try #require(PaletteExtractor.extract(rgba: px, width: 8, height: 8))
        #expect(palette.swatches.count == 1)
        #expect(palette.dominant.color.hex == "#C81E28")
        #expect(palette.accent == palette.dominant)
        #expect(abs(palette.dominant.population - 1) < 1e-9)
    }

    @Test func populationsFollowAreas() throws {
        let px = image(width: 16, height: 16) { x, _ in x < 12 ? (20, 20, 20, 255) : (30, 90, 220, 255) }
        let palette = try #require(PaletteExtractor.extract(rgba: px, width: 16, height: 16, clusterCount: 2))
        #expect(palette.swatches.count == 2)
        #expect(abs(palette.swatches[0].population - 0.75) < 1e-9)
        #expect(palette.dominant.color.hex == "#141414")
        // The accent prefers the saturated blue over the larger near-black area.
        #expect(palette.accent.color.hex == "#1E5ADC")
    }

    @Test func greyArtUsesTheDominantColour() throws {
        let px = image(width: 10, height: 10) { x, _ in x < 7 ? (128, 128, 128, 255) : (240, 240, 240, 255) }
        let palette = try #require(PaletteExtractor.extract(rgba: px, width: 10, height: 10))
        #expect(palette.accent == palette.dominant)
    }

    @Test func transparentPixelsAreIgnoredAndPremultipliedIsUndone() throws {
        let px = image(width: 4, height: 4) { x, _ in x < 2 ? (0, 0, 0, 0) : (50, 100, 25, 128) }
        let palette = try #require(PaletteExtractor.extract(rgba: px, width: 4, height: 4, premultipliedAlpha: true))
        #expect(palette.swatches.count == 1)
        // 50/128, 100/128, 25/128 of full scale.
        #expect(palette.dominant.color.hex == "#64C732")
        #expect(PaletteExtractor.extract(rgba: image(width: 2, height: 2) { _, _ in (255, 0, 0, 10) }, width: 2, height: 2) == nil)
        #expect(PaletteExtractor.extract(rgba: [], width: 0, height: 0) == nil)
    }

    @Test func largeImagesAreDownsampledAndRowPaddingIsRespected() throws {
        let width = 100, height = 60, stride = width * 4 + 12
        var px = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                px[i] = 250; px[i + 1] = 200; px[i + 2] = 10; px[i + 3] = 255
            }
        }
        let palette = try #require(PaletteExtractor.extract(rgba: px, width: width, height: height, bytesPerRow: stride))
        #expect(palette.dominant.color.hex == "#FAC80A")
        #expect(palette.isBright)
        #expect(palette.dominant.color.argb == 0xFFFA_C80A)
    }

    @Test func extractionIsDeterministic() {
        let px = image(width: 32, height: 32) { x, y in (UInt8(x * 8), UInt8(y * 8), UInt8((x * y) % 256), 255) }
        let a = PaletteExtractor.extract(rgba: px, width: 32, height: 32)
        let b = PaletteExtractor.extract(rgba: px, width: 32, height: 32)
        #expect(a == b)
        #expect(a?.swatches.count == 5)
        #expect(abs((a?.swatches.reduce(0) { $0 + $1.population } ?? 0) - 1) < 1e-9)
    }

    @Test func luminanceDetectsBrightAndDarkArt() throws {
        let white = try #require(PaletteExtractor.extract(rgba: image(width: 4, height: 4) { _, _ in (255, 255, 255, 255) }, width: 4, height: 4))
        let black = try #require(PaletteExtractor.extract(rgba: image(width: 4, height: 4) { _, _ in (0, 0, 0, 255) }, width: 4, height: 4))
        #expect(abs(white.averageLuminance - 1) < 1e-9)
        #expect(black.averageLuminance == 0)
        #expect(!black.isBright)
    }
}
