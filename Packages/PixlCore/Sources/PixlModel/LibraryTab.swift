// Library tabs. Two Android types are mirrored:
// - `presentation/library/LibraryTabId.kt` → `LibraryTab` (stable keys, per-tab sort options, and the persisted
//   tab order decoder `decodeLibraryTabOrder`), which the reorderable library categories build on;
// - `data/model/LibraryTabId.kt` → `LibraryTabId` (storage key, title and default sort per tab).

import Foundation
import PixlFoundation

/// A library tab with a persisted stable key.
public enum LibraryTab: String, Sendable, Hashable, Codable, CaseIterable {
    case songs = "SONGS"
    case albums = "ALBUMS"
    case artists = "ARTIST"
    case playlists = "PLAYLISTS"
    case folders = "FOLDERS"
    case liked = "LIKED"

    /// Persisted key (never change).
    public var stableKey: String { rawValue }

    /// Android label (upper case; the app shows localised titles).
    public var label: String { rawValue }

    /// String Catalog key (Android string resource name).
    public var labelKey: String {
        switch self {
        case .songs: "library_tab_songs"
        case .albums: "library_tab_albums"
        case .artists: "library_tab_artists"
        case .playlists: "library_tab_playlists"
        case .folders: "library_tab_folders"
        case .liked: "library_tab_liked"
        }
    }

    /// Sort options offered on the tab, in menu order.
    public var sortOptions: [SortOption] {
        switch self {
        case .songs:
            [.songTitleAZ, .songTitleZA, .songArtist, .songArtistDesc, .songAlbum, .songAlbumDesc, .songDateAdded,
             .songDateAddedAsc, .songDuration, .songDurationAsc]
        case .albums:
            [.albumTitleAZ, .albumTitleZA, .albumArtist, .albumArtistDesc, .albumReleaseYear, .albumReleaseYearAsc,
             .albumDateAdded]
        case .artists:
            [.artistNameAZ, .artistNameZA, .artistNumSongsDesc, .artistNumSongsAsc]
        case .playlists:
            [.playlistNameAZ, .playlistNameZA, .playlistDateCreated, .playlistDateCreatedAsc]
        case .folders:
            [.folderNameAZ, .folderNameZA, .folderSongCountAsc, .folderSongCountDesc, .folderSubdirCountAsc,
             .folderSubdirCountDesc]
        case .liked:
            [.likedSongTitleAZ, .likedSongTitleZA, .likedSongArtist, .likedSongArtistDesc, .likedSongAlbum,
             .likedSongAlbumDesc, .likedSongDateLiked, .likedSongDateLikedAsc]
        }
    }

    /// Declaration order.
    public static let defaultOrder: [LibraryTab] = allCases

    /// The tab with this stable key.
    public static func fromStableKey(_ key: String) -> LibraryTab? {
        allCases.first { $0.stableKey.isIdentical(to: key) }
    }

    /// `decodeLibraryTabOrder`: the stored JSON array of stable keys in order (unknown keys and duplicates
    /// dropped), followed by any tabs it is missing in default order. Unreadable input gives the default order.
    public static func decodeOrder(_ orderJson: String?) -> [LibraryTab] {
        var storedKeys: [String] = []
        if let orderJson, let value = try? JSONParser(mode: .kotlinx).parse(orderJson), let items = value.arrayValue {
            var keys: [String] = []
            keys.reserveCapacity(items.count)
            var ok = true
            for item in items {
                guard let key = KotlinxJSON.string(item) else {
                    ok = false
                    break
                }
                keys.append(key)
            }
            if ok { storedKeys = keys }
        }
        var ordered: [LibraryTab] = []
        for tab in storedKeys.compactMap(fromStableKey) where !ordered.contains(tab) { ordered.append(tab) }
        for tab in defaultOrder where !ordered.contains(tab) { ordered.append(tab) }
        return ordered
    }

    /// Encodes an order the way Android stores it (a compact JSON array of stable keys).
    public static func encodeOrder(_ order: [LibraryTab]) -> String {
        JSONWriter.write(.array(order.map { .string($0.stableKey) }))
    }
}

/// `data/model/LibraryTabId`: storage key, title and default sort per tab.
public enum LibraryTabId: String, Sendable, Hashable, Codable, CaseIterable {
    case songs = "SONGS"
    case albums = "ALBUMS"
    case artists = "ARTIST"
    case playlists = "PLAYLISTS"
    case folders = "FOLDERS"
    case liked = "LIKED"

    public var storageKey: String { rawValue }
    public var title: String { rawValue }

    /// String Catalog key (Android string resource name).
    public var titleKey: String { LibraryTab(rawValue: rawValue)!.labelKey }

    public var defaultSort: SortOption {
        switch self {
        case .songs: .songTitleAZ
        case .albums: .albumTitleAZ
        case .artists: .artistNameAZ
        case .playlists: .playlistNameAZ
        case .folders: .folderNameAZ
        case .liked: .likedSongDateLiked
        }
    }

    /// `fromStorageKey`: unknown keys give `.songs`.
    public static func fromStorageKey(_ key: String) -> LibraryTabId {
        allCases.first { $0.storageKey.isIdentical(to: key) } ?? .songs
    }
}
