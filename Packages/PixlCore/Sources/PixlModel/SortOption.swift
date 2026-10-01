// Port of `data/model/SortOption.kt`: every library sort option with its persisted storage key, English label,
// String Catalog keys (Android string resource names), sort method and direction, plus the direction-flipping
// helpers. Raw value = Android `storageKey`, so stored preferences are interchangeable.

import Foundation
import PixlFoundation

public enum SortDirection: String, Sendable, Hashable, Codable, CaseIterable {
    case ascending = "Ascending"
    case descending = "Descending"

    public var flipped: SortDirection { self == .ascending ? .descending : .ascending }
}

public enum SortOption: String, Sendable, Hashable, Codable, CaseIterable {
    // Songs
    case songDefaultOrder = "song_default_order"
    case songTitleAZ = "song_title_az"
    case songTitleZA = "song_title_za"
    case songArtist = "song_artist"
    case songArtistDesc = "song_artist_desc"
    case songAlbum = "song_album"
    case songAlbumDesc = "song_album_desc"
    case songDateAdded = "song_date_added"
    case songDateAddedAsc = "song_date_added_asc"
    case songDuration = "song_duration"
    case songDurationAsc = "song_duration_asc"
    // Albums
    case albumTitleAZ = "album_title_az"
    case albumTitleZA = "album_title_za"
    case albumArtist = "album_artist"
    case albumArtistDesc = "album_artist_desc"
    case albumReleaseYear = "album_release_year"
    case albumReleaseYearAsc = "album_release_year_asc"
    case albumDateAdded = "album_date_added"
    case albumSizeAsc = "album_size_asc"
    case albumSizeDesc = "album_size_desc"
    // Artists
    case artistNameAZ = "artist_name_az"
    case artistNameZA = "artist_name_za"
    case artistNumSongsDesc = "artist_num_songs_desc"
    case artistNumSongsAsc = "artist_num_songs_asc"
    // Playlists
    case playlistCustomOrder = "playlist_custom_order"
    case playlistNameAZ = "playlist_name_az"
    case playlistNameZA = "playlist_name_za"
    case playlistDateCreated = "playlist_date_created"
    case playlistDateCreatedAsc = "playlist_date_created_asc"
    // Folders
    case folderNameAZ = "folder_name_az"
    case folderNameZA = "folder_name_za"
    case folderSongCountAsc = "folder_song_count_asc"
    case folderSongCountDesc = "folder_song_count_desc"
    case folderSubdirCountAsc = "folder_subdir_count_asc"
    case folderSubdirCountDesc = "folder_subdir_count_desc"
    // Liked
    case likedSongTitleAZ = "liked_title_az"
    case likedSongTitleZA = "liked_title_za"
    case likedSongArtist = "liked_artist"
    case likedSongArtistDesc = "liked_artist_desc"
    case likedSongAlbum = "liked_album"
    case likedSongAlbumDesc = "liked_album_desc"
    case likedSongDateLiked = "liked_date_liked"
    case likedSongDateLikedAsc = "liked_date_liked_asc"

    // MARK: Descriptor

    struct Descriptor {
        let displayName: String
        let displayNameKey: String
        let methodLabel: String
        let methodLabelKey: String
        let methodKey: String
        let direction: SortDirection?
    }

    private static func d(_ displayName: String, _ displayNameKey: String, _ methodLabel: String,
                          _ methodLabelKey: String, _ methodKey: String, _ direction: SortDirection?) -> Descriptor {
        Descriptor(displayName: displayName, displayNameKey: displayNameKey, methodLabel: methodLabel,
                   methodLabelKey: methodLabelKey, methodKey: methodKey, direction: direction)
    }

    var descriptor: Descriptor {
        switch self {
        case .songDefaultOrder:
            // No method label/key of its own on Android: they default to the display name / storage key.
            Self.d("Default Order", "sort_display_default_order", "Default Order", "sort_display_default_order",
                   "song_default_order", nil)
        case .songTitleAZ: Self.d("Title (A-Z)", "sort_display_title_az", "Title", "sort_method_title", "song_title", .ascending)
        case .songTitleZA: Self.d("Title (Z-A)", "sort_display_title_za", "Title", "sort_method_title", "song_title", .descending)
        case .songArtist: Self.d("Artist", "sort_display_artist", "Artist", "sort_method_artist", "song_artist", .ascending)
        case .songArtistDesc: Self.d("Artist (Z-A)", "sort_display_artist_za", "Artist", "sort_method_artist", "song_artist", .descending)
        case .songAlbum: Self.d("Album", "sort_display_album", "Album", "sort_method_album", "song_album", .ascending)
        case .songAlbumDesc: Self.d("Album (Z-A)", "sort_display_album_za", "Album", "sort_method_album", "song_album", .descending)
        case .songDateAdded: Self.d("Date Added", "sort_display_date_added", "Date Added", "sort_method_date_added", "song_date_added", .descending)
        case .songDateAddedAsc: Self.d("Date Added (Oldest First)", "sort_display_date_added_oldest", "Date Added", "sort_method_date_added", "song_date_added", .ascending)
        case .songDuration: Self.d("Duration", "sort_display_duration", "Duration", "sort_method_duration", "song_duration", .descending)
        case .songDurationAsc: Self.d("Duration (Shortest First)", "sort_display_duration_shortest", "Duration", "sort_method_duration", "song_duration", .ascending)
        case .albumTitleAZ: Self.d("Title (A-Z)", "sort_display_title_az", "Title", "sort_method_title", "album_title", .ascending)
        case .albumTitleZA: Self.d("Title (Z-A)", "sort_display_title_za", "Title", "sort_method_title", "album_title", .descending)
        case .albumArtist: Self.d("Artist", "sort_display_artist", "Artist", "sort_method_artist", "album_artist", .ascending)
        case .albumArtistDesc: Self.d("Artist (Z-A)", "sort_display_artist_za", "Artist", "sort_method_artist", "album_artist", .descending)
        case .albumReleaseYear: Self.d("Release Year", "sort_display_release_year", "Release Year", "sort_method_release_year", "album_release_year", .descending)
        case .albumReleaseYearAsc: Self.d("Release Year (Oldest First)", "sort_display_release_year_oldest", "Release Year", "sort_method_release_year", "album_release_year", .ascending)
        case .albumDateAdded: Self.d("Date Added", "sort_display_date_added", "Date Added", "sort_method_date_added", "album_date_added", .descending)
        case .albumSizeAsc: Self.d("Fewest Songs", "sort_display_fewest_songs", "Song Count", "sort_method_song_count", "album_size", .ascending)
        case .albumSizeDesc: Self.d("Most Songs", "sort_display_most_songs", "Song Count", "sort_method_song_count", "album_size", .descending)
        case .artistNameAZ: Self.d("Name (A-Z)", "sort_display_name_az", "Name", "sort_method_name", "artist_name", .ascending)
        case .artistNameZA: Self.d("Name (Z-A)", "sort_display_name_za", "Name", "sort_method_name", "artist_name", .descending)
        case .artistNumSongsDesc: Self.d("Number of Songs (Most)", "sort_display_num_songs_most", "Number of Songs", "sort_method_num_songs", "artist_num_songs", .descending)
        case .artistNumSongsAsc: Self.d("Number of Songs (Fewest)", "sort_display_num_songs_fewest", "Number of Songs", "sort_method_num_songs", "artist_num_songs", .ascending)
        case .playlistNameAZ: Self.d("Name (A-Z)", "sort_display_name_az", "Name", "sort_method_name", "playlist_name", .ascending)
        case .playlistNameZA: Self.d("Name (Z-A)", "sort_display_name_za", "Name", "sort_method_name", "playlist_name", .descending)
        case .playlistDateCreated: Self.d("Date Created", "sort_display_date_created", "Date Created", "sort_method_date_created", "playlist_date_created", .descending)
        case .playlistDateCreatedAsc: Self.d("Date Created (Oldest First)", "sort_display_date_created_oldest", "Date Created", "sort_method_date_created", "playlist_date_created", .ascending)
        case .playlistCustomOrder: Self.d("Custom Order", "sort_display_custom_order", "Custom Order", "sort_method_custom_order", "playlist_custom_order", .ascending)
        case .likedSongTitleAZ: Self.d("Title (A-Z)", "sort_display_title_az", "Title", "sort_method_title", "liked_title", .ascending)
        case .likedSongTitleZA: Self.d("Title (Z-A)", "sort_display_title_za", "Title", "sort_method_title", "liked_title", .descending)
        case .likedSongArtist: Self.d("Artist", "sort_display_artist", "Artist", "sort_method_artist", "liked_artist", .ascending)
        case .likedSongArtistDesc: Self.d("Artist (Z-A)", "sort_display_artist_za", "Artist", "sort_method_artist", "liked_artist", .descending)
        case .likedSongAlbum: Self.d("Album", "sort_display_album", "Album", "sort_method_album", "liked_album", .ascending)
        case .likedSongAlbumDesc: Self.d("Album (Z-A)", "sort_display_album_za", "Album", "sort_method_album", "liked_album", .descending)
        case .likedSongDateLiked: Self.d("Date Liked", "sort_display_date_liked", "Date Liked", "sort_method_date_liked", "liked_date_liked", .descending)
        case .likedSongDateLikedAsc: Self.d("Date Liked (Oldest First)", "sort_display_date_liked_oldest", "Date Liked", "sort_method_date_liked", "liked_date_liked", .ascending)
        case .folderNameAZ: Self.d("Name (A-Z)", "sort_display_name_az", "Name", "sort_method_name", "folder_name", .ascending)
        case .folderNameZA: Self.d("Name (Z-A)", "sort_display_name_za", "Name", "sort_method_name", "folder_name", .descending)
        case .folderSongCountAsc: Self.d("Fewest Songs", "sort_display_fewest_songs", "Song Count", "sort_method_song_count", "folder_song_count", .ascending)
        case .folderSongCountDesc: Self.d("Most Songs", "sort_display_most_songs", "Song Count", "sort_method_song_count", "folder_song_count", .descending)
        case .folderSubdirCountAsc: Self.d("Fewest Subfolders", "sort_display_fewest_subfolders", "Subfolder Count", "sort_method_subfolder_count", "folder_subdir_count", .ascending)
        case .folderSubdirCountDesc: Self.d("Most Subfolders", "sort_display_most_subfolders", "Subfolder Count", "sort_method_subfolder_count", "folder_subdir_count", .descending)
        }
    }

    // MARK: Properties (Android names)

    /// Persisted key.
    public var storageKey: String { rawValue }
    /// English label (`displayName`); also the legacy persisted value.
    public var displayName: String { descriptor.displayName }
    /// String Catalog key (the Android string resource name).
    public var displayNameKey: String { descriptor.displayNameKey }
    /// English label of the sort method without direction ("Title").
    public var methodLabel: String { descriptor.methodLabel }
    public var methodLabelKey: String { descriptor.methodLabelKey }
    /// Groups the ascending/descending pair of one method.
    public var methodKey: String { descriptor.methodKey }
    /// Nil for options without a direction (`songDefaultOrder`).
    public var direction: SortDirection? { descriptor.direction }

    // MARK: Groups (Android companion lists, same order)

    public static let songs: [SortOption] = [
        .songDefaultOrder, .songTitleAZ, .songTitleZA, .songArtist, .songArtistDesc, .songAlbum, .songAlbumDesc,
        .songDateAdded, .songDateAddedAsc, .songDuration, .songDurationAsc,
    ]
    public static let albums: [SortOption] = [
        .albumTitleAZ, .albumTitleZA, .albumArtist, .albumArtistDesc, .albumReleaseYear, .albumReleaseYearAsc,
        .albumDateAdded, .albumSizeAsc, .albumSizeDesc,
    ]
    public static let artists: [SortOption] = [.artistNameAZ, .artistNameZA, .artistNumSongsDesc, .artistNumSongsAsc]
    public static let playlists: [SortOption] = [
        .playlistCustomOrder, .playlistNameAZ, .playlistNameZA, .playlistDateCreated, .playlistDateCreatedAsc,
    ]
    public static let folders: [SortOption] = [
        .folderNameAZ, .folderNameZA, .folderSongCountAsc, .folderSongCountDesc, .folderSubdirCountAsc,
        .folderSubdirCountDesc,
    ]
    public static let liked: [SortOption] = [
        .likedSongTitleAZ, .likedSongTitleZA, .likedSongArtist, .likedSongArtistDesc, .likedSongAlbum,
        .likedSongAlbumDesc, .likedSongDateLiked, .likedSongDateLikedAsc,
    ]
    /// `ALL` = songs + albums + artists + playlists + folders + liked.
    public static let all: [SortOption] = songs + albums + artists + playlists + folders + liked

    /// First option of each method in `all` order (`groupBy(methodKey).first()`).
    private static let defaultOptionByMethodKey: [String: SortOption] = {
        var map: [String: SortOption] = [:]
        for option in all where map[option.methodKey] == nil { map[option.methodKey] = option }
        return map
    }()

    private struct MethodDirection: Hashable {
        let methodKey: String
        let direction: SortDirection
    }

    /// Option per (method, direction); later options win like Kotlin's `associateBy`.
    private static let optionByMethodAndDirection: [MethodDirection: SortOption] = {
        var map: [MethodDirection: SortOption] = [:]
        for option in all {
            guard let direction = option.direction else { continue }
            map[MethodDirection(methodKey: option.methodKey, direction: direction)] = option
        }
        return map
    }()

    // MARK: Behaviour

    /// Whether the opposite direction exists for this method.
    public var canFlipDirection: Bool { direction != nil && flipDirection().storageKey != storageKey }

    /// The representative option of this sort method.
    public func methodOption() -> SortOption { Self.defaultOptionByMethodKey[methodKey] ?? self }

    /// The option with this method and `targetDirection` (the method's representative when nil or missing).
    public func resolveForDirection(_ targetDirection: SortDirection?) -> SortOption {
        guard let targetDirection else { return methodOption() }
        return Self.optionByMethodAndDirection[MethodDirection(methodKey: methodKey, direction: targetDirection)]
            ?? methodOption()
    }

    /// The same method in the other direction (self when there is no direction).
    public func flipDirection() -> SortOption {
        guard let direction else { return self }
        return resolveForDirection(direction.flipped)
    }

    /// `SortOption.fromStorageKey`: the allowed option with this storage key, else (legacy values) the one whose
    /// display name matches, else `fallback`. Nil/blank input and an empty `allowed` give `fallback`.
    public static func fromStorageKey<C: Collection>(_ rawValue: String?, allowed: C, fallback: SortOption) -> SortOption
    where C.Element == SortOption {
        guard let rawValue, !rawValue.isKotlinBlank, !allowed.isEmpty else { return fallback }
        if let matched = allowed.first(where: { $0.storageKey.isIdentical(to: rawValue) }) { return matched }
        return allowed.first(where: { $0.displayName.isIdentical(to: rawValue) }) ?? fallback
    }
}
