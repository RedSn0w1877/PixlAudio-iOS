import Foundation
import Observation
import PixlModel

/// The Library screen's own preferences (Android `UserPreferencesRepository` library keys, same names and defaults):
/// tab order, per-tab sort options, folder view mode and the storage filter. Values that other screens share
/// (`last_library_tab_index`, `is_albums_list_view`, `hide_local_media`) stay on `SettingsStore.library`.
///
/// One instance per process (`shared(isUITest:)`); UI tests use the same throwaway suite as `SettingsStore.ephemeral()`.
@Observable
final class LibraryPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    /// `library_tabs_order` (JSON array of stable keys; missing tabs appended in default order).
    var tabOrder: [LibraryTab] {
        didSet { defaults.set(LibraryTab.encodeOrder(tabOrder), forKey: PreferenceKeys.libraryTabsOrder) }
    }
    var songSort: SortOption { didSet { defaults.set(songSort.storageKey, forKey: PreferenceKeys.songsSortOption) } }
    var albumSort: SortOption { didSet { defaults.set(albumSort.storageKey, forKey: PreferenceKeys.albumsSortOption) } }
    var artistSort: SortOption { didSet { defaults.set(artistSort.storageKey, forKey: PreferenceKeys.artistsSortOption) } }
    var playlistSort: SortOption {
        didSet { defaults.set(playlistSort.storageKey, forKey: PreferenceKeys.playlistsSortOption) }
    }
    var folderSort: SortOption { didSet { defaults.set(folderSort.storageKey, forKey: PreferenceKeys.foldersSortOption) } }
    var likedSort: SortOption {
        didSet { defaults.set(likedSort.storageKey, forKey: PreferenceKeys.likedSongsSortOption) }
    }
    /// `is_folders_playlist_view`: the Folders tab lists every folder with songs as a playlist card.
    var isFoldersPlaylistView: Bool {
        didSet { defaults.set(isFoldersPlaylistView, forKey: PreferenceKeys.isFoldersPlaylistView) }
    }
    /// `last_storage_filter` (0 all, 1 offline, 2 online).
    var storageFilter: StorageFilter {
        didSet { defaults.set(storageFilter.value, forKey: PreferenceKeys.lastStorageFilter) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        tabOrder = LibraryTab.decodeOrder(defaults.string(forKey: PreferenceKeys.libraryTabsOrder))
        func sort(_ key: String, _ allowed: [SortOption], _ fallback: SortOption) -> SortOption {
            SortOption.fromStorageKey(defaults.string(forKey: key), allowed: allowed, fallback: fallback)
        }
        songSort = sort(PreferenceKeys.songsSortOption, SortOption.songs, LibraryTabId.songs.defaultSort)
        albumSort = sort(PreferenceKeys.albumsSortOption, SortOption.albums, LibraryTabId.albums.defaultSort)
        artistSort = sort(PreferenceKeys.artistsSortOption, SortOption.artists, LibraryTabId.artists.defaultSort)
        playlistSort = sort(PreferenceKeys.playlistsSortOption, SortOption.playlists, LibraryTabId.playlists.defaultSort)
        folderSort = sort(PreferenceKeys.foldersSortOption, SortOption.folders, LibraryTabId.folders.defaultSort)
        likedSort = sort(PreferenceKeys.likedSongsSortOption, SortOption.liked, LibraryTabId.liked.defaultSort)
        isFoldersPlaylistView = defaults.bool(PreferenceKeys.isFoldersPlaylistView, default: false)
        storageFilter = StorageFilter(rawValue: defaults.int(PreferenceKeys.lastStorageFilter, default: 0)) ?? .all
    }

    /// The process-wide instance.
    static func shared(isUITest: Bool) -> LibraryPreferences {
        if let instance { return instance }
        let defaults = isUITest ? (UserDefaults(suiteName: "pixlaudio.uitest") ?? .standard) : .standard
        let created = LibraryPreferences(defaults: defaults)
        instance = created
        return created
    }

    private static var instance: LibraryPreferences?

    // MARK: Per-tab sort

    func sort(for tab: LibraryTab) -> SortOption {
        switch tab {
        case .songs: songSort
        case .albums: albumSort
        case .artists: artistSort
        case .playlists: playlistSort
        case .folders: folderSort
        case .liked: likedSort
        }
    }

    func setSort(_ option: SortOption, for tab: LibraryTab) {
        switch tab {
        case .songs: songSort = option
        case .albums: albumSort = option
        case .artists: artistSort = option
        case .playlists: playlistSort = option
        case .folders: folderSort = option
        case .liked: likedSort = option
        }
    }

    /// Android `toggleStorageFilter`: all → online → offline → all.
    func cycleStorageFilter() {
        switch storageFilter {
        case .all: storageFilter = .online
        case .online: storageFilter = .offline
        case .offline: storageFilter = .all
        }
    }

    /// Android `resetLibraryTabsOrder` (removes the key: default order).
    func resetTabOrder() {
        defaults.removeObject(forKey: PreferenceKeys.libraryTabsOrder)
        tabOrder = LibraryTab.defaultOrder
        defaults.removeObject(forKey: PreferenceKeys.libraryTabsOrder)
    }
}

extension LibraryTab {
    /// The sort menu of a tab: Android `availableSortOptions` (`SortOption.SONGS` …, the companion lists).
    var menuSortOptions: [SortOption] {
        switch self {
        case .songs: SortOption.songs
        case .albums: SortOption.albums
        case .artists: SortOption.artists
        case .playlists: SortOption.playlists
        case .folders: SortOption.folders
        case .liked: SortOption.liked
        }
    }

    var defaultSort: SortOption { LibraryTabId(rawValue: rawValue)?.defaultSort ?? .songTitleAZ }

    /// SF Symbols for Android's tab icons (`rounded_music_note_24`, `rounded_album_24`, …).
    var systemImage: String {
        switch self {
        case .songs: "music.note"
        case .albums: "opticaldisc"
        case .artists: "music.mic"
        case .playlists: "music.note.list"
        case .folders: "folder.fill"
        case .liked: "heart.fill"
        }
    }
}
