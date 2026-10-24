import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

private let now: Int64 = 1_800_000_000_000
private let day: Int64 = 86_400_000

/// `search_library` over the whole library (filters, sorts, paging) and `get_library_overview`.
@Suite struct LibraryQueryTests {
    /// 450 songs: 9 artists × 50 songs; genres, years and play counts follow from the numbers.
    private func library() -> (songs: [Song], stats: [String: SongPlayStats]) {
        let artists = [("Aria", "Pop"), ("Beat", "Hip-Hop"), ("Cove", "Rock"), ("Dune", "Jazz"), ("Echo", "Pop"),
                       ("Fjord", "Electronic"), ("Glow", "Pop"), ("Haze", "Indie"), ("Iris", "Jazz")]
        var songs: [Song] = []
        var stats: [String: SongPlayStats] = [:]
        for (a, entry) in artists.enumerated() {
            for n in 0..<50 {
                let id = "\(entry.0.lowercased())-\(n)"
                var song = testSong(id, title: "\(entry.0) Track \(n)", artist: entry.0, genre: entry.1, isFavorite: n % 10 == 0,
                                    dateAdded: now - Int64(a * 50 + n) * day, album: "\(entry.0) Album \(n / 10)", year: 1980 + a * 4 + n / 10)
                song.artistId = Int64(a + 1)
                songs.append(song)
                if n % 5 != 0 { stats[id] = SongPlayStats(plays: n, lastPlayedMs: now - Int64(n) * day) }
            }
        }
        return (songs, stats)
    }

    @Test func pagesThroughTheWholeLibraryWithoutCaps() {
        let (songs, stats) = library()
        var seen: [String] = []
        var offset = 0
        var pages = 0
        while true {
            let page = LibraryQueryEngine.run(LibraryQuery(sort: .title, limit: 200, offset: offset), songs: songs, stats: stats)
            seen += page.songs.map(\.id)
            pages += 1
            #expect(page.totalMatches == 450)
            guard let next = page.nextOffset else { break }
            offset = next
        }
        #expect(pages == 3 && seen.count == 450 && Set(seen).count == 450, "every song is reachable, once")
        let big = LibraryQueryEngine.run(LibraryQuery(limit: 5_000), songs: songs, stats: stats)
        #expect(big.songs.count == 200, "a page is capped at 200")
        let beyond = LibraryQueryEngine.run(LibraryQuery(limit: 20, offset: 10_000), songs: songs, stats: stats)
        #expect(beyond.songs.isEmpty && beyond.nextOffset == nil && beyond.totalMatches == 450)
        #expect(LibraryQueryEngine.run(LibraryQuery(limit: 0), songs: songs, stats: stats).songs.count == 1, "the limit is at least 1")
    }

    @Test func filtersCombine() {
        let (songs, stats) = library()
        func ids(_ query: LibraryQuery) -> [String] { LibraryQueryEngine.run(query, songs: songs, stats: stats).songs.map(\.id) }
        func count(_ query: LibraryQuery) -> Int { LibraryQueryEngine.run(query, songs: songs, stats: stats).totalMatches }
        #expect(count(LibraryQuery(artist: "aria")) == 50)
        #expect(count(LibraryQuery(artist: "ARIA")) == 50, "case is ignored")
        #expect(count(LibraryQuery(genre: "pop")) == 150, "Aria, Echo and Glow")
        #expect(count(LibraryQuery(genre: "hip hop")) == 50)
        #expect(count(LibraryQuery(album: "Cove Album 2")) == 10)
        #expect(count(LibraryQuery(artist: "Dune", genre: "Jazz")) == 50)
        #expect(count(LibraryQuery(artist: "Dune", genre: "Pop")) == 0)
        #expect(count(LibraryQuery(yearFrom: 1980, yearTo: 1980)) == 10, "Aria's first ten songs")
        let early = LibraryQueryEngine.run(LibraryQuery(yearTo: 1983, limit: 200), songs: songs, stats: stats).songs
        #expect(!early.isEmpty && early.allSatisfy { $0.year > 0 && $0.year <= 1983 })
        let late = LibraryQueryEngine.run(LibraryQuery(yearFrom: 2010, limit: 200), songs: songs, stats: stats).songs
        #expect(late.allSatisfy { $0.year >= 2010 })
        #expect(count(LibraryQuery(likedOnly: true)) == 45)
        // Never played = every fifth song.
        #expect(count(LibraryQuery(neverPlayed: true)) == 90)
        #expect(count(LibraryQuery(minPlays: 45)) == 9 * 4, "plays 46…49 for each artist (45 is a multiple of 5: never played)")
        #expect(count(LibraryQuery(maxPlays: 0)) == 90)
        #expect(count(LibraryQuery(minPlays: 10, maxPlays: 12)) == 9 * 2, "11 and 12 for each artist (10 is never played)")
        #expect(ids(LibraryQuery(artist: "Iris", likedOnly: true, neverPlayed: true, sort: .title, limit: 50))
                == ["iris-0", "iris-10", "iris-20", "iris-30", "iris-40"])
    }

    @Test func sortsAndRandomIsReproducible() {
        let (songs, stats) = library()
        func run(_ sort: LibraryQuery.Sort, seed: Int64 = 1) -> [Song] {
            LibraryQueryEngine.run(LibraryQuery(sort: sort, limit: 5), songs: songs, stats: stats, seed: seed).songs
        }
        #expect(run(.mostPlayed).map(\.id).allSatisfy { (stats[$0]?.plays ?? 0) == 49 })
        #expect(run(.mostPlayed).first.map { stats[$0.id]?.plays } == 49)
        #expect(run(.recentlyPlayed).first.map { stats[$0.id]?.lastPlayedMs } == now - 1 * day, "plays n=1 is the most recent")
        #expect(run(.recentlyAdded).first?.id == "aria-0")
        #expect(run(.title).first?.title == "Aria Track 0")
        #expect(run(.relevance).first?.title == "Aria Track 0", "without words relevance falls back to title order")
        #expect(run(.random, seed: 5).map(\.id) == run(.random, seed: 5).map(\.id))
        #expect(run(.random, seed: 5).map(\.id) != run(.random, seed: 6).map(\.id))
    }

    @Test func wordsSearchTitleArtistAndGenreThenFilterAndPage() {
        let (songs, stats) = library()
        let index = SearchIndex(songs: songs)
        let artist = LibraryQueryEngine.run(LibraryQuery(text: "Fjord", limit: 200), songs: songs, stats: stats, index: index)
        #expect(artist.totalMatches == 50 && artist.songs.allSatisfy { $0.artist == "Fjord" })
        let genre = LibraryQueryEngine.run(LibraryQuery(text: "electronic", limit: 200), songs: songs, stats: stats, index: index)
        #expect(genre.songs.contains { $0.artist == "Fjord" })
        let both = LibraryQueryEngine.run(LibraryQuery(text: "track", likedOnly: true, sort: .mostPlayed, limit: 10), songs: songs, stats: stats,
                                          index: index)
        #expect(both.songs.allSatisfy(\.isFavorite) && both.totalMatches == 45)
        // Words + a filter + a page.
        let page = LibraryQueryEngine.run(LibraryQuery(text: "Glow", minPlays: 30, sort: .mostPlayed, limit: 5, offset: 5), songs: songs,
                                          stats: stats, index: index)
        #expect(page.songs.count == 5 && page.songs.allSatisfy { $0.artist == "Glow" && (stats[$0.id]?.plays ?? 0) >= 30 })
        #expect(page.offset == 5 && page.nextOffset == 10)
        #expect(LibraryQueryEngine.run(LibraryQuery(text: "zzzzqqq"), songs: songs, stats: stats, index: index).songs.isEmpty)
    }

    @Test func overviewDescribesTheLibrary() throws {
        let (songs, stats) = library()
        let overview = LibraryOverview.build(songs: songs, stats: stats, playlists: 4)
        #expect(overview.songs == 450 && overview.artists == 9 && overview.albums == 45 && overview.playlists == 4)
        #expect(overview.liked == 45 && overview.neverPlayed == 90)
        #expect(overview.topGenres.first == LibraryOverview.Bucket(name: "Pop", songs: 150))
        #expect(overview.decades.map(\.name) == overview.decades.map(\.name).sorted())
        let json = overview.json()
        #expect(json["songs"]?.int64Value == 450 && json["paging"]?["pages_for_whole_library"]?.int64Value == 3)
        #expect(json["top_genres"]?.arrayValue?.count == 6)
        let given = LibraryOverview.build(songs: songs, stats: stats, artists: 7, albums: 8)
        #expect(given.artists == 7 && given.albums == 8)
        #expect(LibraryOverview.build(songs: [], stats: [:]).json()["paging"]?["pages_for_whole_library"]?.int64Value == 0)
    }
}
