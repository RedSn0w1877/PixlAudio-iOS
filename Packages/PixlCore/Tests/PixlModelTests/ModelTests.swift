import Foundation
import Testing
import PixlFoundation
@testable import PixlModel

/// Ported from Android `data/model/SortOptionTest`.
@Suite("SortOption")
struct SortOptionTests {
    // method option keeps a single representative per sort method
    @Test func methodOptionKeepsASingleRepresentativePerSortMethod() {
        #expect(SortOption.songTitleZA.methodOption() == .songTitleAZ)
        #expect(SortOption.songArtistDesc.methodOption() == .songArtist)
        #expect(SortOption.songDateAddedAsc.methodOption() == .songDateAdded)
        #expect(SortOption.songDefaultOrder.methodOption() == .songDefaultOrder)
    }

    // resolve for direction keeps method while switching order
    @Test func resolveForDirectionKeepsMethodWhileSwitchingOrder() {
        #expect(SortOption.songArtist.resolveForDirection(.descending) == .songArtistDesc)
        #expect(SortOption.songArtistDesc.resolveForDirection(.ascending) == .songArtist)
        #expect(SortOption.songDateAdded.resolveForDirection(.ascending) == .songDateAddedAsc)
        #expect(SortOption.playlistDateCreatedAsc.resolveForDirection(.descending) == .playlistDateCreated)
        #expect(SortOption.songArtistDesc.resolveForDirection(nil) == .songArtist)
    }

    // flip direction swaps paired sort options
    @Test func flipDirectionSwapsPairedSortOptions() {
        #expect(SortOption.songTitleAZ.flipDirection() == .songTitleZA)
        #expect(SortOption.songTitleZA.flipDirection() == .songTitleAZ)
        #expect(SortOption.likedSongDateLiked.flipDirection() == .likedSongDateLikedAsc)
        #expect(SortOption.folderSongCountDesc.flipDirection() == .folderSongCountAsc)
        #expect(SortOption.songDefaultOrder.flipDirection() == .songDefaultOrder)
    }

    // from storage key still resolves legacy display names
    @Test func fromStorageKeyStillResolvesLegacyDisplayNames() {
        #expect(SortOption.fromStorageKey(SortOption.songArtist.displayName, allowed: SortOption.songs,
                                          fallback: .songTitleAZ) == .songArtist)
        #expect(SortOption.fromStorageKey("album_title_az", allowed: SortOption.albums, fallback: .albumTitleZA) == .albumTitleAZ)
        // A key outside the allowed group falls back, even though the option exists.
        #expect(SortOption.fromStorageKey("album_title_az", allowed: SortOption.songs, fallback: .songTitleAZ) == .songTitleAZ)
        #expect(SortOption.fromStorageKey(nil, allowed: SortOption.songs, fallback: .songDuration) == .songDuration)
        #expect(SortOption.fromStorageKey("  ", allowed: SortOption.songs, fallback: .songDuration) == .songDuration)
        #expect(SortOption.fromStorageKey("song_title_az", allowed: [SortOption](), fallback: .songDuration) == .songDuration)
        // "Title (A-Z)" is shared by several groups: the allowed group decides.
        #expect(SortOption.fromStorageKey("Title (A-Z)", allowed: SortOption.liked, fallback: .likedSongDateLiked) == .likedSongTitleAZ)
    }

    @Test func tablesMatchAndroid() {
        #expect(SortOption.all.count == 43)
        #expect(Set(SortOption.all) == Set(SortOption.allCases))
        #expect(SortOption.playlists.first == .playlistCustomOrder)
        #expect(SortOption.songDefaultOrder.direction == nil)
        #expect(SortOption.songDefaultOrder.methodKey == "song_default_order")
        #expect(SortOption.songDefaultOrder.methodLabel == "Default Order")
        #expect(!SortOption.songDefaultOrder.canFlipDirection)
        #expect(!SortOption.playlistCustomOrder.canFlipDirection) // no descending custom order
        #expect(SortOption.songTitleAZ.canFlipDirection)
        #expect(SortOption.songDateAdded.direction == .descending)
        #expect(SortOption.albumSizeAsc.displayName == "Fewest Songs")
        #expect(SortOption.albumSizeAsc.methodLabelKey == "sort_method_song_count")
        #expect(SortOption.likedSongDateLikedAsc.storageKey == "liked_date_liked_asc")
        // Every directional option flips back to itself.
        for option in SortOption.all where option.canFlipDirection {
            #expect(option.flipDirection().flipDirection() == option)
            #expect(option.flipDirection().methodKey == option.methodKey)
        }
        // Codable uses the storage key.
        #expect(String(decoding: try! JSONEncoder().encode([SortOption.songArtistDesc]), as: UTF8.self) == #"["song_artist_desc"]"#)
    }
}

/// Ported from Android `presentation/library/LibraryTabIdTest`.
@Suite("Library tabs")
struct LibraryTabTests {
    // decodeLibraryTabOrder returns default order when stored value is null
    @Test func decodeReturnsDefaultOrderWhenStoredValueIsNull() {
        #expect(LibraryTab.decodeOrder(nil) == LibraryTab.defaultOrder)
    }

    // decodeLibraryTabOrder preserves known order and restores missing tabs
    @Test func decodePreservesKnownOrderAndRestoresMissingTabs() {
        let storedKeys = [LibraryTab.liked.stableKey, "UNKNOWN", LibraryTab.playlists.stableKey, LibraryTab.liked.stableKey]
        let order = LibraryTab.decodeOrder(JSONWriter.write(.array(storedKeys.map { .string($0) })))
        #expect(order.first == .liked)
        #expect(Set(order) == Set(LibraryTab.defaultOrder))
        #expect(order.count == LibraryTab.defaultOrder.count)
        #expect(order == [.liked, .playlists, .songs, .albums, .artists, .folders])
    }

    // sort associations remain tied to tab ids after reordering
    @Test func sortAssociationsRemainTiedToTabIdsAfterReordering() {
        let persistedSorts = Dictionary(uniqueKeysWithValues: LibraryTab.defaultOrder.map { tab in
            (tab, tab.sortOptions.first ?? .songTitleAZ)
        })
        let shuffled = LibraryTab.decodeOrder(LibraryTab.encodeOrder([.folders, .songs, .playlists]))
        #expect(shuffled.prefix(3) == [.folders, .songs, .playlists])
        for tab in shuffled { #expect(persistedSorts[tab] == tab.sortOptions.first) }
    }

    @Test func malformedOrderFallsBackToDefault() {
        #expect(LibraryTab.decodeOrder("not json") == LibraryTab.defaultOrder)
        #expect(LibraryTab.decodeOrder(#"["LIKED", 5]"#) == LibraryTab.defaultOrder) // kotlinx fails the whole list
        #expect(LibraryTab.decodeOrder(#"{"a":1}"#) == LibraryTab.defaultOrder)
        #expect(LibraryTab.encodeOrder(LibraryTab.defaultOrder) == #"["SONGS","ALBUMS","ARTIST","PLAYLISTS","FOLDERS","LIKED"]"#)
    }

    @Test func dataModelTabIds() {
        #expect(LibraryTabId.fromStorageKey("ARTIST") == .artists)
        #expect(LibraryTabId.fromStorageKey("nope") == .songs)
        #expect(LibraryTabId.liked.defaultSort == .likedSongDateLiked)
        #expect(LibraryTabId.albums.titleKey == "library_tab_albums")
        #expect(LibraryTab.albums.sortOptions.count == 7)
    }
}

@Suite("Library models")
struct LibraryModelTests {
    @Test func displayArtistPutsPrimaryArtistsFirst() {
        var song = Song.emptySong()
        song.artist = "Legacy"
        #expect(song.displayArtist == "Legacy")
        #expect(song.primaryArtist == ArtistRef(id: -1, name: "Legacy", isPrimary: true))
        song.artists = [ArtistRef(id: 1, name: "Feat"), ArtistRef(id: 2, name: "Main", isPrimary: true), ArtistRef(id: 3, name: "Other")]
        #expect(song.displayArtist == "Main, Feat, Other")
        #expect(song.primaryArtist.name == "Main")
        song.artists = [ArtistRef(id: 1, name: "A"), ArtistRef(id: 2, name: "B")]
        #expect(song.primaryArtist.name == "A")
    }

    @Test func emptyValuesMatchAndroid() {
        let empty = Song.emptySong()
        #expect(empty.id == "-1")
        #expect(empty.mimeType == "-")
        #expect(empty.bitrate == 0)
        #expect(Album.empty().id == -1)
        #expect(Artist.empty().songCount == 0)
    }

    @Test func artistEffectiveImagePrefersNonBlankCustomImage() {
        #expect(Artist(id: 1, name: "A", songCount: 1, imageUrl: "remote", customImageUri: "custom").effectiveImageUrl == "custom")
        #expect(Artist(id: 1, name: "A", songCount: 1, imageUrl: "remote", customImageUri: "  ").effectiveImageUrl == "remote")
        #expect(Artist(id: 1, name: "A", songCount: 1, imageUrl: "", customImageUri: nil).effectiveImageUrl == nil)
    }

    @Test func smartRulesAndPresets() {
        #expect(SmartPlaylistRule.fromStorageKey("new_gems") == .newGems)
        #expect(SmartPlaylistRule.fromStorageKey(" ") == nil)
        #expect(SmartPlaylistRule.fromStorageKey(nil) == nil)
        #expect(SmartPlaylistRule.fromStorageKey("NEW_GEMS") == nil)
        #expect(SmartPlaylistRule.forgottenFavorites.title == "Forgotten Favorites")
        #expect(SmartPlaylistRule.allCases.map(\.kotlinName) == ["TOP_PLAYED", "RECENTLY_PLAYED", "FORGOTTEN_FAVORITES", "NEW_GEMS"])
        #expect(SmartPlaylistPreset.allCases.count == 6)
        #expect(SmartPlaylistPreset.discover.displayName == "Deep discovery")
    }

    @Test func playlistDecodingFillsAndroidDefaults() throws {
        let json = #"{"id":"p1","name":"Mix","songIds":["a","b"],"createdAt":42,"sortOrder":7}"#
        let playlist = try JSONDecoder().decode(Playlist.self, from: Data(json.utf8))
        #expect(playlist.createdAt == 42)
        #expect(playlist.sortOrder == 7)
        #expect(playlist.source == "LOCAL")
        #expect(!playlist.isAiGenerated)
        #expect(playlist.lastModified > 1_600_000_000_000)
        #expect(try JSONDecoder().decode(Playlist.self, from: JSONEncoder().encode(playlist)) == playlist)
    }

    @Test func transitionDefaults() throws {
        let settings = TransitionSettings()
        #expect(settings.mode == .overlap)
        #expect(settings.durationMs == 2000)
        #expect(settings.curveIn == .sCurve && settings.curveOut == .sCurve)
        #expect(TransitionMode.allCases.map(\.rawValue) == ["NONE", "FADE_IN_OUT", "OVERLAP", "SMOOTH"])
        #expect(TransitionCurve.allCases.map(\.rawValue) == ["LINEAR", "EXP", "LOG", "S_CURVE"])
        let rule = TransitionRule(playlistId: "p", settings: TransitionSettings(mode: .smooth, durationMs: 6000))
        #expect(rule.isPlaylistDefault)
        #expect(try JSONDecoder().decode(TransitionRule.self, from: JSONEncoder().encode(rule)) == rule)
        let partial = try JSONDecoder().decode(TransitionSettings.self, from: Data(#"{"mode":"FADE_IN_OUT"}"#.utf8))
        #expect(partial == TransitionSettings(mode: .fadeInOut))
    }

    @Test func equalizerPresetsMatchAndroid() throws {
        #expect(EqualizerPreset.allPresets.count == 10)
        #expect(EqualizerPreset.allPresets.allSatisfy { $0.bandLevels.count == EqualizerPreset.bandFrequencies.count })
        #expect(EqualizerPreset.allPresets.allSatisfy { $0.bandLevels.allSatisfy { (-15...15).contains($0) } })
        #expect(EqualizerPreset.fromName("hip_hop").bandLevels == [6, 8, 4, 1, -1, -1, 1, 1, 3, 4])
        #expect(EqualizerPreset.fromName("unknown") == .flat)
        let custom = EqualizerPreset.custom(bandLevels: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(custom.isCustom && custom.name == "custom" && custom.displayName == "CUSTOM")
        let decoded = try JSONDecoder().decode(EqualizerPreset.self,
                                               from: Data(#"{"name":"rock","displayName":"ROCK","bandLevels":[5,4,3,1,-1,-1,1,3,4,5]}"#.utf8))
        #expect(decoded == .rock)
    }

    @Test func smallEnums() throws {
        #expect(LyricsSourcePreference.fromOrdinal(0) == .apiFirst)
        #expect(LyricsSourcePreference.fromOrdinal(9) == .embeddedFirst)
        #expect(LyricsSourcePreference.fromName("LOCAL_FIRST") == .localFirst)
        #expect(LyricsSourcePreference.fromName(nil) == .embeddedFirst)
        #expect(StorageFilter(rawValue: 2) == .online)
        #expect(SearchFilterType.youtubeMusic.rawValue == "YOUTUBE_MUSIC")
        let snapshot = try JSONDecoder().decode(PlaybackQueueSnapshot.self,
                                                from: Data(#"{"items":[{"mediaId":"m","uri":"u"}],"repeatMode":2}"#.utf8))
        #expect(snapshot.repeatMode == 2 && snapshot.currentIndex == 0 && !snapshot.shuffleEnabled)
        #expect(snapshot.items.first?.durationMs == nil)
        let folder = MusicFolder(path: "/a", name: "a", songs: [.emptySong()], subFolders: [
            MusicFolder(path: "/a/b", name: "b", songs: [.emptySong(), .emptySong()], subFolders: [MusicFolder(path: "/a/b/c", name: "c")]),
        ])
        #expect(folder.totalSongCount == 3)
        #expect(folder.totalSubFolderCount == 2)
    }
}
