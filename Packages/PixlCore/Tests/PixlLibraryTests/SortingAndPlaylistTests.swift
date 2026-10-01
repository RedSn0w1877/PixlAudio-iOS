import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Sorting for every SortOption (Swift-only: Android sorts in SQL and view models without unit tests), plus the
/// ported `PlaylistOrderTest` and the album order case of `QueueStateHolderTest`.
@Suite struct LibrarySortingTests {
    private func song(_ id: String, title: String, artist: String = "", album: String = "", dateAdded: Int64 = 0,
                      duration: Int64 = 0, track: Int = 0) -> Song {
        testSong(id, title: title, artist: artist, duration: duration, dateAdded: dateAdded, album: album, trackNumber: track)
    }

    @Test func everySortOptionIsHandledByItsTab() {
        let songs = [song("2", title: "b"), song("1", title: "a")]
        for option in SortOption.songs where option != .songDefaultOrder {
            #expect(LibrarySorting.sortPlaylistSongs(songs, by: option).count == 2)
        }
        let albums = [Album(id: 1, title: "B", artist: "x", year: 1, dateAdded: 1, albumArtUriString: nil, songCount: 1),
                      Album(id: 2, title: "A", artist: "y", year: 2, dateAdded: 2, albumArtUriString: nil, songCount: 2)]
        for option in SortOption.albums { #expect(Set(LibrarySorting.sortAlbums(albums, by: option).map(\.id)) == [1, 2]) }
        #expect(LibrarySorting.sortAlbums(albums, by: .songTitleAZ) == albums)
    }

    @Test func songsTabUsesSQLiteNoCaseThenTitleThenId() {
        let songs = [song("3", title: "beta"), song("1", title: "Alpha"), song("2", title: "alpha"), song("10", title: "Émile"),
                     song("4", title: "Zed")]
        // NOCASE folds ASCII only: "Émile" (0xC3…) sorts after every ASCII title.
        #expect(LibrarySorting.sortSongs(songs, by: .songTitleAZ).map(\.id) == ["1", "2", "3", "4", "10"])
        #expect(LibrarySorting.sortSongs(songs, by: .songTitleZA).map(\.id) == ["10", "4", "3", "1", "2"])
    }

    @Test func songsTabDefaultOrderUsesTrackNumber() {
        let songs = [song("1", title: "b", track: 2), song("2", title: "a", track: 2), song("3", title: "z", track: 1)]
        #expect(LibrarySorting.sortSongs(songs, by: .songDefaultOrder).map(\.id) == ["3", "2", "1"])
    }

    @Test func songsTabDatesAndDurations() {
        let songs = [song("1", title: "a", dateAdded: 5, duration: 300), song("2", title: "b", dateAdded: 9, duration: 100),
                     song("3", title: "c", dateAdded: 5, duration: 300)]
        #expect(LibrarySorting.sortSongs(songs, by: .songDateAdded).map(\.id) == ["2", "1", "3"])
        #expect(LibrarySorting.sortSongs(songs, by: .songDateAddedAsc).map(\.id) == ["1", "3", "2"])
        #expect(LibrarySorting.sortSongs(songs, by: .songDuration).map(\.id) == ["1", "3", "2"])
        #expect(LibrarySorting.sortSongs(songs, by: .songDurationAsc).map(\.id) == ["2", "1", "3"])
        #expect(LibrarySorting.sortSongs(songs, by: .songArtist).map(\.id) == ["1", "2", "3"])
        #expect(LibrarySorting.sortSongs(songs, by: .albumTitleAZ).map(\.id) == ["1", "2", "3"])
    }

    @Test func likedTabSortsByLikeDateWithMissingDatesFirstAscending() {
        let songs = [song("1", title: "a"), song("2", title: "b"), song("3", title: "c")]
        let liked: [String: Int64] = ["1": 100, "2": 300]
        #expect(LibrarySorting.sortLikedSongs(songs, by: .likedSongDateLiked, likedAt: liked).map(\.id) == ["2", "1", "3"])
        #expect(LibrarySorting.sortLikedSongs(songs, by: .likedSongDateLikedAsc, likedAt: liked).map(\.id) == ["3", "1", "2"])
        #expect(LibrarySorting.sortLikedSongs(songs, by: .likedSongTitleZA, likedAt: liked).map(\.id) == ["3", "2", "1"])
    }

    @Test func albumsArtistsAndFoldersUseLowercasedKotlinOrder() {
        let albums = [Album(id: 2, title: "b", artist: "Z", year: 2000, dateAdded: 1, albumArtUriString: nil, songCount: 3),
                      Album(id: 1, title: "B", artist: "a", year: 1990, dateAdded: 2, albumArtUriString: nil, songCount: 1),
                      Album(id: 3, title: "a", artist: "m", year: 2000, dateAdded: 2, albumArtUriString: nil, songCount: 3)]
        #expect(LibrarySorting.sortAlbums(albums, by: .albumTitleAZ).map(\.id) == [3, 1, 2])
        #expect(LibrarySorting.sortAlbums(albums, by: .albumTitleZA).map(\.id) == [1, 2, 3])
        #expect(LibrarySorting.sortAlbums(albums, by: .albumArtist).map(\.id) == [1, 3, 2])
        #expect(LibrarySorting.sortAlbums(albums, by: .albumReleaseYear).map(\.id) == [3, 2, 1])
        #expect(LibrarySorting.sortAlbums(albums, by: .albumDateAdded).map(\.id) == [3, 1, 2])
        #expect(LibrarySorting.sortAlbums(albums, by: .albumSizeDesc).map(\.id) == [3, 2, 1])
        #expect(LibrarySorting.sortAlbums(albums, by: .albumSizeAsc).map(\.id) == [1, 3, 2])

        let artists = [Artist(id: 2, name: "beta", songCount: 1), Artist(id: 1, name: "Alpha", songCount: 5),
                       Artist(id: 3, name: "alpha", songCount: 5)]
        #expect(LibrarySorting.sortArtists(artists, by: .artistNameAZ).map(\.id) == [1, 3, 2])
        #expect(LibrarySorting.sortArtists(artists, by: .artistNameZA).map(\.id) == [2, 1, 3])
        #expect(LibrarySorting.sortArtists(artists, by: .artistNumSongsDesc).map(\.id) == [1, 3, 2])
        #expect(LibrarySorting.sortArtists(artists, by: .artistNumSongsAsc).map(\.id) == [2, 1, 3])

        let folders = [MusicFolder(path: "/b", name: "b", songs: [testSong("1")]),
                       MusicFolder(path: "/a", name: "A", subFolders: [MusicFolder(path: "/a/x", name: "x", songs: [testSong("2"), testSong("3")])])]
        #expect(LibrarySorting.sortFolders(folders, by: .folderNameAZ).map(\.path) == ["/a", "/b"])
        #expect(LibrarySorting.sortFolders(folders, by: .folderNameZA).map(\.path) == ["/b", "/a"])
        #expect(LibrarySorting.sortFolders(folders, by: .folderSongCountDesc).map(\.path) == ["/a", "/b"])
        #expect(LibrarySorting.sortFolders(folders, by: .folderSongCountAsc).map(\.path) == ["/b", "/a"])
        #expect(LibrarySorting.sortFolders(folders, by: .folderSubdirCountDesc).map(\.path) == ["/a", "/b"])
        #expect(LibrarySorting.sortFolders(folders, by: .folderSubdirCountAsc).map(\.path) == ["/b", "/a"])
    }

    @Test func playlistsSortLikeThePlaylistViewModel() {
        let p = [Playlist(id: "b", name: "Mix", songIds: [], createdAt: 0, lastModified: 5, sortOrder: 2),
                 Playlist(id: "a", name: "mix", songIds: [], createdAt: 0, lastModified: 9, sortOrder: 1),
                 Playlist(id: "c", name: "Alpha", songIds: [], createdAt: 0, lastModified: 1, sortOrder: 1)]
        #expect(LibrarySorting.sortPlaylists(p, by: .playlistNameAZ).map(\.id) == ["c", "a", "b"])
        #expect(LibrarySorting.sortPlaylists(p, by: .playlistNameZA).map(\.id) == ["a", "b", "c"])
        #expect(LibrarySorting.sortPlaylists(p, by: .playlistDateCreated).map(\.id) == ["a", "b", "c"])
        #expect(LibrarySorting.sortPlaylists(p, by: .playlistDateCreatedAsc).map(\.id) == ["c", "b", "a"])
        #expect(LibrarySorting.sortPlaylists(p, by: .playlistCustomOrder).map(\.id) == ["c", "a", "b"])
        #expect(LibrarySorting.sortPlaylists(p, by: .songTitleAZ).map(\.id) == ["c", "a", "b"])
    }

    @Test func playlistSongsSortByLowercasedFieldsThenId() {
        let songs = [song("2", title: "B", artist: "x"), song("1", title: "b", artist: "x"), song("3", title: "a", artist: "z")]
        #expect(LibrarySorting.sortPlaylistSongs(songs, by: .songTitleAZ).map(\.id) == ["3", "1", "2"])
        #expect(LibrarySorting.sortPlaylistSongs(songs, by: .songTitleZA).map(\.id) == ["1", "2", "3"])
        #expect(LibrarySorting.sortPlaylistSongs(songs, by: .songArtistDesc).map(\.id) == ["3", "1", "2"])
        #expect(LibrarySorting.sortPlaylistSongs(songs, by: .songDefaultOrder).map(\.id) == ["2", "1", "3"])
    }

    /// Port of `QueueStateHolderTest.playAlbum orders songs by disc then track then title`.
    @Test func playAlbumOrdersSongsByDiscThenTrackThenTitle() {
        let disc2track1 = testSong("a", trackNumber: 1, discNumber: 2)
        let disc1track2 = testSong("b", trackNumber: 2, discNumber: 1)
        let disc1track1 = testSong("c", trackNumber: 1, discNumber: 1)
        #expect(LibrarySorting.albumPlaybackOrder([disc2track1, disc1track2, disc1track1]).map(\.id) == ["c", "b", "a"])
        let untracked = testSong("d", title: "A", trackNumber: 0)
        let tracked = testSong("e", title: "Z", trackNumber: 3)
        #expect(LibrarySorting.albumPlaybackOrder([untracked, tracked]).map(\.id) == ["e", "d"])
    }

    /// Port of `data/playlist/PlaylistOrderTest.kt`.
    @Test func draggingVisibleSongsPreservesUnavailableAndConcurrentlyAddedEntries() {
        #expect(LibrarySorting.mergePlaylistOrder(currentIds: ["a", "unavailable", "c", "new"], requestedIds: ["c", "a"])
            == ["c", "a", "unavailable", "new"])
    }

    @Test func staleDragCannotReintroduceDeletedSongsOrDuplicateEntries() {
        #expect(LibrarySorting.mergePlaylistOrder(currentIds: ["a", "b"], requestedIds: ["deleted", "b", "b", "a"]) == ["b", "a"])
    }

    @Test func storageFilterSeparatesStreamedSongs() {
        let local = testSong("f:abc/x.mp3"), streamed = testSong("yt:dQw4"), spotify = testSong("sp:123")
        #expect(LibrarySorting.matches(local, filter: .offline))
        #expect(!LibrarySorting.matches(streamed, filter: .offline))
        #expect(LibrarySorting.matches(spotify, filter: .online))
        #expect(LibrarySorting.matches(local, filter: .all))
    }
}

/// Swift-only: `PlaylistViewModel.buildSmartPlaylistSongIds` (no Android test exists).
@Suite struct SmartPlaylistRuleTests {
    let now: Int64 = 1_800_000_000_000
    let day: Int64 = 86_400_000

    private var songs: [Song] {
        [testSong("1", title: "One", dateAdded: 10), testSong("2", title: "two", dateAdded: 30),
         testSong("3", title: "Three", dateAdded: 20), testSong("4", title: "four", dateAdded: 40)]
    }

    @Test func topPlayedOrdersByPlaysThenListeningTimeThenRecency() {
        let engagements: [(songId: String, stats: EngagementStats)] = [
            ("1", EngagementStats(playCount: 5, totalPlayDurationMs: 10, lastPlayedTimestamp: 1)),
            ("2", EngagementStats(playCount: 5, totalPlayDurationMs: 20, lastPlayedTimestamp: 1)),
            ("missing", EngagementStats(playCount: 99)),
            ("3", EngagementStats(playCount: 9)),
        ]
        #expect(SmartPlaylistBuilder.songIds(for: .topPlayed, allSongs: songs, engagements: engagements, favoriteIds: [], nowMs: now)
            == ["3", "2", "1"])
        #expect(SmartPlaylistBuilder.songIds(for: .topPlayed, allSongs: songs, engagements: engagements, favoriteIds: [], nowMs: now, limit: 1)
            == ["3"])
    }

    @Test func recentlyPlayedSkipsNeverPlayed() {
        let engagements: [(songId: String, stats: EngagementStats)] = [
            ("1", EngagementStats(playCount: 1, lastPlayedTimestamp: 0)), ("2", EngagementStats(playCount: 1, lastPlayedTimestamp: 50)),
            ("3", EngagementStats(playCount: 1, lastPlayedTimestamp: 70)),
        ]
        #expect(SmartPlaylistBuilder.songIds(for: .recentlyPlayed, allSongs: songs, engagements: engagements, favoriteIds: [], nowMs: now)
            == ["3", "2"])
    }

    @Test func forgottenFavoritesNeedThirtyDaysWithoutAPlay() {
        let engagements: [(songId: String, stats: EngagementStats)] = [
            ("1", EngagementStats(playCount: 1, lastPlayedTimestamp: now - 31 * day)),
            ("2", EngagementStats(playCount: 1, lastPlayedTimestamp: now - day)),
        ]
        #expect(SmartPlaylistBuilder.songIds(for: .forgottenFavorites, allSongs: songs, engagements: engagements,
                                             favoriteIds: ["1", "2", "4"], nowMs: now) == ["4", "1"])
    }

    @Test func newGemsAreRecentAndRarelyPlayedWithNewestFallback() {
        let engagements: [(songId: String, stats: EngagementStats)] = [("4", EngagementStats(playCount: 3)), ("2", EngagementStats(playCount: 2))]
        #expect(SmartPlaylistBuilder.songIds(for: .newGems, allSongs: songs, engagements: engagements, favoriteIds: [], nowMs: now)
            == ["2", "3", "1"])
        // Nothing matches → the newest songs.
        #expect(SmartPlaylistBuilder.songIds(for: .recentlyPlayed, allSongs: songs, engagements: [], favoriteIds: [], nowMs: now, limit: 2)
            == ["4", "2"])
        #expect(SmartPlaylistBuilder.songIds(for: .topPlayed, allSongs: [], engagements: [], favoriteIds: [], nowMs: now).isEmpty)
    }
}

/// Swift-only: `M3uManager` (no Android test exists).
@Suite struct M3UTests {
    private var library: [Song] {
        var a = testSong("1", title: "Song A", artist: "Artist A", duration: 215_900)
        a.path = "/music/Artist A/song-a.mp3"
        a.contentUriString = "f:root/Artist A/song-a.mp3"
        var b = testSong("2", title: "Song B", artist: "Artist B", duration: 999)
        b.path = "/music/b.flac"
        b.contentUriString = "content://media/external/audio/media/42"
        return [a, b]
    }

    @Test func parsesByPathThenFileNameThenContentUriFileName() {
        let text = "#EXTM3U\r\n#EXTINF:215,Artist A - Song A\r\n  /music/Artist A/song-a.mp3  \n\nC:\\elsewhere/b.flac\n42\nmissing.mp3\r"
        let parsed = M3U.parse(text, fileName: "Road trip.m3u8", library: library)
        #expect(parsed.name == "Road trip")
        #expect(parsed.songIds == ["1", "2", "2"])
        #expect(M3U.parse("", fileName: nil, library: library).name == "Imported Playlist")
        #expect(M3U.parse("", fileName: "a.m3u.m3u8", library: library).name == "a.m3u")
    }

    @Test func generatesExtendedM3U() {
        #expect(M3U.generate(songs: library) == "#EXTM3U\n#EXTINF:215,Artist A - Song A\n/music/Artist A/song-a.mp3\n#EXTINF:0,Artist B - Song B\n/music/b.flac\n")
        #expect(M3U.generate(songs: []) == "#EXTM3U\n")
    }

    @Test func roundTripsItsOwnOutput() {
        let parsed = M3U.parse(M3U.generate(songs: library), fileName: "x.m3u", library: library)
        #expect(parsed.songIds == ["1", "2"])
    }

    @Test func readLineSplitsLikeBufferedReader() {
        #expect(M3U.readLines("a\nb") == ["a", "b"])
        #expect(M3U.readLines("a\r\n\r\nb\n") == ["a", "", "b"])
        #expect(M3U.readLines("\n") == [""])
        #expect(M3U.readLines("") == [])
        #expect(M3U.readLines("a\r\rb") == ["a", "", "b"])
    }

    @Test func keepsTheByteOrderMarkLikeJava() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("b.flac\n".utf8)
        #expect(M3U.parse(utf8: bom, fileName: nil, library: library).songIds.isEmpty)
    }
}
