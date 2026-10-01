import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Port of `data/worker/AlbumGroupingUtilsTest.kt`.
@Suite struct AlbumGroupingTests {
    private func testSong(artistName: String, albumArtist: String?, albumArtUriString: String? = nil,
                          parentDirectoryPath: String = "/music/default", albumName: String = "Hurry Up Tomorrow",
                          albumId: Int64 = 42) -> ScannedSong {
        ScannedSong(id: String(albumId), title: "Track", artistName: artistName, artistId: 1, albumArtist: albumArtist,
                    albumName: albumName, albumId: albumId, contentUriString: "content://media/\(albumId)",
                    albumArtUriString: albumArtUriString, parentDirectoryPath: parentDirectoryPath)
    }

    @Test func resolveAlbumArtistPrefersEmbeddedAlbumArtist() {
        #expect(AlbumGrouping.resolveAlbumArtist(rawAlbumArtist: nil, metadataAlbumArtist: "The Weeknd") == "The Weeknd")
    }

    @Test func buildAlbumGroupingKeyIgnoresPerTrackArtistWhenTitleAndArtMatch() {
        let solo = testSong(artistName: "The Weeknd", albumArtist: nil, albumArtUriString: "content://art/hurry-up",
                            parentDirectoryPath: "/music/The Weeknd & Justice - Hurry Up Tomorrow")
        let collab = testSong(artistName: "The Weeknd, Justice", albumArtist: nil, albumArtUriString: "content://art/hurry-up",
                              parentDirectoryPath: "/music/The Weeknd & Justice - Hurry Up Tomorrow")
        #expect(AlbumGrouping.groupingKey(for: solo) == AlbumGrouping.groupingKey(for: collab))
    }

    @Test func buildAlbumGroupingKeyKeepsSameTitledAlbumsApartWhenDirectoriesDiffer() {
        let first = testSong(artistName: "Artist A", albumArtist: nil, parentDirectoryPath: "/music/Artist A/Greatest Hits")
        let second = testSong(artistName: "Artist B", albumArtist: nil, parentDirectoryPath: "/music/Artist B/Greatest Hits")
        #expect(AlbumGrouping.groupingKey(for: first) != AlbumGrouping.groupingKey(for: second))
    }

    @Test func buildAlbumGroupingKeyIgnoresReusedArtworkForLocalSameTitledAlbums() {
        let first = testSong(artistName: "Artist A", albumArtist: nil, albumArtUriString: "pixelplay_local_art://song/10",
                             parentDirectoryPath: "/music/Artist A/Feels", albumName: "Unknown Album", albumId: 10)
        let second = testSong(artistName: "Artist B", albumArtist: nil, albumArtUriString: "pixelplay_local_art://song/10",
                              parentDirectoryPath: "/music/Artist B/Feels", albumName: "Unknown Album", albumId: 11)
        #expect(AlbumGrouping.groupingKey(for: first) != AlbumGrouping.groupingKey(for: second))
    }

    @Test func buildAlbumGroupingKeysKeepsMediaFallbackEvenWhenArtworkExists() {
        let album = LibraryAlbum(id: 77, title: "Unknown Album", artistName: "", artistId: 0,
                                 albumArtUriString: "pixelplay_local_art://song/10", songCount: 1, dateAdded: 0, year: 0)
        #expect(AlbumGrouping.groupingKeys(for: album).contains(AlbumGroupingKey(normalizedTitle: "unknown album", identity: "media:77")))
    }

    @Test func chooseAlbumDisplayArtistPrefersDominantTrackArtistWhenGroupingIsOff() {
        let songs = [testSong(artistName: "The Weeknd", albumArtist: "The Weeknd & Justice"),
                     testSong(artistName: "The Weeknd", albumArtist: "The Weeknd & Justice"),
                     testSong(artistName: "The Weeknd, Justice", albumArtist: "The Weeknd & Justice")]
        #expect(AlbumGrouping.chooseAlbumDisplayArtist(songs: songs, preferAlbumArtist: false) == "The Weeknd")
    }

    @Test func chooseAlbumDisplayArtistUsesPrimaryParsedArtistForFeatureHeavyAlbums() {
        let songs = [testSong(artistName: "Gorillaz feat. Stevie Nicks", albumArtist: nil),
                     testSong(artistName: "Gorillaz feat. Thundercat", albumArtist: nil),
                     testSong(artistName: "Gorillaz feat. Tame Impala", albumArtist: nil)]
        #expect(AlbumGrouping.chooseAlbumDisplayArtist(songs: songs, preferAlbumArtist: false, artistDelimiters: [";"],
                                                       wordDelimiters: ["feat."]) == "Gorillaz")
    }

    @Test func chooseAlbumDisplayArtistPrefersAlbumArtistWhenGroupingIsOn() {
        let songs = [testSong(artistName: "The Weeknd", albumArtist: "The Weeknd & Justice"),
                     testSong(artistName: "The Weeknd, Justice", albumArtist: "The Weeknd & Justice")]
        #expect(AlbumGrouping.chooseAlbumDisplayArtist(songs: songs, preferAlbumArtist: true) == "The Weeknd & Justice")
    }

    // Swift-only edge cases.
    @Test func resolveAlbumArtistSkipsBlankAndUnknown() {
        #expect(AlbumGrouping.resolveAlbumArtist(rawAlbumArtist: "Raw", metadataAlbumArtist: "<UNKNOWN>") == "Raw")
        #expect(AlbumGrouping.resolveAlbumArtist(rawAlbumArtist: "  ", metadataAlbumArtist: nil) == nil)
        #expect(AlbumGrouping.chooseAlbumDisplayArtist(songs: [], preferAlbumArtist: true) == "Unknown Artist")
        #expect(AlbumGrouping.mostCommonValue(["bb", "a", "bb", "a"]) == "a")
        #expect(AlbumGrouping.mostCommonValue([" ", ""]) == nil)
    }

    @Test func remoteMediaSkipsTheStableLocalIdentity() {
        let local = testSong(artistName: "A", albumArtist: nil, albumArtUriString: "art://1", parentDirectoryPath: "/m/x")
        #expect(AlbumGrouping.groupingKey(for: local).identity == "dir:/m/x")
        var remote = local
        remote.contentUriString = "gdrive://abc"
        #expect(AlbumGrouping.groupingKey(for: remote).identity == "art:art://1")
    }
}

/// Swift-only: the pure part of `SyncWorker.preProcessAndDeduplicateWithMultiArtist`.
@Suite struct LibraryAssemblerTests {
    private func scanned(_ id: String, artist: String, title: String = "T", album: String = "Album", albumId: Int64,
                         dir: String = "/music/a", albumArtist: String? = nil) -> ScannedSong {
        ScannedSong(id: id, title: title, artistName: artist, artistId: 0, albumArtist: albumArtist, albumName: album,
                    albumId: albumId, contentUriString: "f:\(id)", parentDirectoryPath: dir)
    }

    @Test func splitsArtistsAssignsIdsAndGroupsAlbums() {
        let songs = [scanned("1", artist: "A; B", title: "One (feat. C)", albumId: 10),
                     scanned("2", artist: "A", albumId: 11),
                     scanned("3", artist: "D", album: "Other", albumId: 12, dir: "/music/b")]
        let result = LibraryAssembler.assemble(songs: songs, artistDelimiters: [";"], wordDelimiters: ["feat."],
                                               groupByAlbumArtist: false, initialMaxArtistId: 100)
        #expect(result.artists.map(\.name) == ["A", "B", "C", "D"])
        #expect(result.artists.map(\.id) == [101, 102, 103, 104])
        #expect(result.artists.map(\.songCount) == [2, 1, 1, 1])
        #expect(result.songs[0].artists.map(\.name) == ["A", "B", "C"])
        #expect(result.songs[0].artists.map(\.isPrimary) == [true, false, false])
        #expect(result.songs[0].song.artistId == 101)
        // Songs 1 and 2 share title and folder: one album (the first song's id).
        #expect(result.songs.map(\.song.albumId) == [10, 10, 12])
        #expect(result.albums.map(\.id) == [10, 12])
        #expect(result.albums[0].songCount == 2)
        #expect(result.albums[0].artistName == "A")
        #expect(result.albums[0].artistId == 101)
        #expect(result.links.count == 5)
    }

    @Test func reusesExistingAlbumIdsAndArtistIds() {
        var existing = OrderedStringMap<Int64>()
        existing["A"] = 7
        let album = LibraryAlbum(id: 3, title: "Album", artistName: "A", artistId: 7, albumArtUriString: nil, songCount: 1,
                                 dateAdded: 0, year: 0)
        let songs = [scanned("1", artist: "A", albumId: 99, albumArtist: "A")]
        let result = LibraryAssembler.assemble(songs: songs, artistDelimiters: [";"], groupByAlbumArtist: true,
                                               existingArtistMetadata: [7: (imageUrl: "img", customImageUri: nil)],
                                               existingAlbums: [album], existingArtistIds: existing, initialMaxArtistId: 7)
        #expect(result.songs[0].song.albumId == 3)
        #expect(result.songs[0].song.artistId == 7)
        #expect(result.artists.first?.imageUrl == "img")
        #expect(result.albums.first?.albumArtist == "A")
    }
}

/// Port of `data/repository/FolderTreeBuilderTest.kt` and `utils/DirectoryRuleResolverTest.kt`.
@Suite struct FolderTreeTests {
    private func folderSong(id: String = "1", parentDirectoryPath: String, title: String = "Song") -> FolderSongRow {
        FolderSongRow(id: id, parentDirectoryPath: parentDirectoryPath, title: title, albumArtUriString: nil)
    }

    @Test func inferRemovableStorageRootsUsesSdCardVolumeRoot() {
        let roots = FolderTreeBuilder.inferRemovableStorageRoots(
            folderSongs: [folderSong(parentDirectoryPath: "/storage/1234-5678/Music/Album")],
            internalStorageRoot: "/storage/emulated/0", knownRemovableRoots: [])
        #expect(roots == ["/storage/1234-5678"])
    }

    @Test func buildFolderTreeForRootsIncludesSdCardFolders() {
        let folders = FolderTreeBuilder.buildFolderTreeForRoots(
            folderSongs: [folderSong(id: "1", parentDirectoryPath: "/storage/1234-5678/Music/Album", title: "First Song")],
            selectedRootPaths: ["/storage/1234-5678"])
        #expect(folders.map(\.name) == ["Music"])
        #expect(folders.first?.subFolders.map(\.name) == ["Album"])
        #expect(folders.first?.totalSongCount == 1)
    }

    @Test func buildFolderTreeForRootsDoesNotMatchSiblingPathPrefix() {
        let folders = FolderTreeBuilder.buildFolderTreeForRoots(
            folderSongs: [folderSong(id: "1", parentDirectoryPath: "/storage/emulated/0/Music", title: "Internal Song"),
                          folderSong(id: "2", parentDirectoryPath: "/storage/emulated/0-other/Music", title: "Wrong Prefix Song")],
            selectedRootPaths: ["/storage/emulated/0"])
        #expect(folders.count == 1)
        #expect(folders.first?.songs.map(\.title) == ["Internal Song"])
        #expect(folders.first?.totalSongCount == 1)
    }

    @Test func inferRemovableStorageRootsSupportsMediaRwSdCardPaths() {
        let roots = FolderTreeBuilder.inferRemovableStorageRoots(
            folderSongs: [folderSong(parentDirectoryPath: "/mnt/media_rw/1234-5678/Music")],
            internalStorageRoot: "/storage/emulated/0", knownRemovableRoots: [])
        #expect(roots == ["/mnt/media_rw/1234-5678"])
    }

    @Test func excludeThenIncludePathPathBecomesVisibleAgain() {
        let target = "/storage/emulated/0/Music"
        #expect(DirectoryRuleResolver(allowed: [String](), blocked: [target]).isBlocked(target))
        #expect(!DirectoryRuleResolver(allowed: [String](), blocked: [String]()).isBlocked(target))
    }

    @Test func includeThenExcludePathPathBecomesHidden() {
        let target = "/storage/emulated/0/Music"
        #expect(!DirectoryRuleResolver(allowed: [String](), blocked: [String]()).isBlocked(target))
        #expect(DirectoryRuleResolver(allowed: [String](), blocked: [target]).isBlocked(target))
    }

    @Test func nestedAllowInsideBlockedParentIsRespected() {
        let resolver = DirectoryRuleResolver(allowed: ["/storage/emulated/0/Music/Favorites"], blocked: ["/storage/emulated/0/Music"])
        #expect(resolver.isBlocked("/storage/emulated/0/Music"))
        #expect(resolver.isBlocked("/storage/emulated/0/Music/Albums"))
        #expect(!resolver.isBlocked("/storage/emulated/0/Music/Favorites"))
        #expect(!resolver.isBlocked("/storage/emulated/0/Music/Favorites/Chill"))
    }

    @Test func siblingPathOutsideBlockedTreeStaysVisible() {
        let resolver = DirectoryRuleResolver(allowed: [String](), blocked: ["/storage/emulated/0/Music"])
        #expect(!resolver.isBlocked("/storage/emulated/0/Podcasts"))
    }

    // Swift-only: the filter step of `buildFolderTree` and stub songs.
    @Test func buildFolderTreeFiltersBlockedFoldersAndSortsSongsByTrackThenTitle() {
        let rows = [folderSong(id: "1", parentDirectoryPath: "/root/Keep/", title: "b"),
                    folderSong(id: "2", parentDirectoryPath: "/root/Keep", title: "A"),
                    folderSong(id: "3", parentDirectoryPath: "/root/Hidden", title: "x")]
        let tree = FolderTreeBuilder.buildFolderTree(folderSongs: rows, allowedDirectories: [],
                                                     blockedDirectories: ["/root/hidden"], isFolderFilterActive: true,
                                                     rootPaths: ["/root"])
        #expect(tree.map(\.name) == ["Keep"])
        #expect(tree[0].songs.map(\.title) == ["A", "b"])
        #expect(tree[0].songs[0].path == "/root/Keep/A")
        let unfiltered = FolderTreeBuilder.buildFolderTree(folderSongs: rows, allowedDirectories: [],
                                                           blockedDirectories: ["/root/hidden"], isFolderFilterActive: false,
                                                           rootPaths: ["/root"])
        #expect(unfiltered.map(\.name) == ["Hidden", "Keep"])
        #expect(FolderTreeBuilder.buildFolderTreeForRoots(folderSongs: rows, selectedRootPaths: ["", "/"]).isEmpty)
    }
}
