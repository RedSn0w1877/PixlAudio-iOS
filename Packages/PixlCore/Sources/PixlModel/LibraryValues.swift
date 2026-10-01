// Smaller value types from the Android `data/model` package: search history and filters, storage filter, lyrics
// source preference, the persisted playback queue snapshot, catalogue/YouTube search results and folders.

import Foundation
import PixlFoundation

/// A past search (`SearchHistoryItem`).
public struct SearchHistoryItem: Sendable, Hashable, Codable {
    public var id: Int64?
    public var query: String
    /// Milliseconds since 1970.
    public var timestamp: Int64

    public init(id: Int64? = nil, query: String, timestamp: Int64) {
        self.id = id
        self.query = query
        self.timestamp = timestamp
    }
}

/// Search result groups (`SearchFilterType`). `catalog` and `youtubeMusic` are result sections, not user filters.
public enum SearchFilterType: String, Sendable, Hashable, Codable, CaseIterable {
    case all = "ALL"
    case songs = "SONGS"
    case albums = "ALBUMS"
    case artists = "ARTISTS"
    case playlists = "PLAYLISTS"
    case catalog = "CATALOG"
    case youtubeMusic = "YOUTUBE_MUSIC"
}

/// Which songs a list shows (`StorageFilter`); `value` is the persisted integer.
public enum StorageFilter: Int, Sendable, Hashable, Codable, CaseIterable {
    case all = 0
    case offline = 1
    case online = 2

    public var value: Int { rawValue }
}

/// Lyrics source priority (`LyricsSourcePreference`); raw value = Kotlin constant name.
public enum LyricsSourcePreference: String, Sendable, Hashable, Codable, CaseIterable {
    /// Online, then embedded, then local `.lrc`.
    case apiFirst = "API_FIRST"
    /// Embedded, then online, then local `.lrc`.
    case embeddedFirst = "EMBEDDED_FIRST"
    /// Local `.lrc`, then embedded, then online.
    case localFirst = "LOCAL_FIRST"

    public var displayName: String {
        switch self {
        case .apiFirst: "Online First"
        case .embeddedFirst: "Embedded First"
        case .localFirst: "Local First"
        }
    }

    /// `fromOrdinal`: out-of-range gives `.embeddedFirst`.
    public static func fromOrdinal(_ ordinal: Int) -> LyricsSourcePreference {
        allCases.indices.contains(ordinal) ? allCases[ordinal] : .embeddedFirst
    }

    /// `fromName`: unknown or nil gives `.embeddedFirst`.
    public static func fromName(_ name: String?) -> LyricsSourcePreference {
        guard let name else { return .embeddedFirst }
        return allCases.first { $0.rawValue.isIdentical(to: name) } ?? .embeddedFirst
    }
}

/// One queued item as persisted across launches (`PlaybackQueueItemSnapshot`).
public struct PlaybackQueueItemSnapshot: Sendable, Hashable, Codable {
    public var mediaId: String
    public var uri: String
    public var title: String?
    public var artist: String?
    public var albumTitle: String?
    public var artworkUri: String?
    public var durationMs: Int64?

    public init(mediaId: String, uri: String, title: String? = nil, artist: String? = nil, albumTitle: String? = nil,
                artworkUri: String? = nil, durationMs: Int64? = nil) {
        self.mediaId = mediaId
        self.uri = uri
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.artworkUri = artworkUri
        self.durationMs = durationMs
    }
}

/// The queue as persisted across launches (`PlaybackQueueSnapshot`). `repeatMode`: 0 off, 1 one, 2 all.
public struct PlaybackQueueSnapshot: Sendable, Hashable, Codable {
    public var items: [PlaybackQueueItemSnapshot]
    public var currentMediaId: String?
    public var currentIndex: Int
    public var currentPositionMs: Int64
    public var playWhenReady: Bool
    public var repeatMode: Int
    public var shuffleEnabled: Bool
    public var savedAtEpochMs: Int64

    public init(items: [PlaybackQueueItemSnapshot], currentMediaId: String? = nil, currentIndex: Int = 0,
                currentPositionMs: Int64 = 0, playWhenReady: Bool = false, repeatMode: Int = 0,
                shuffleEnabled: Bool = false, savedAtEpochMs: Int64 = currentTimeMillis()) {
        self.items = items
        self.currentMediaId = currentMediaId
        self.currentIndex = currentIndex
        self.currentPositionMs = currentPositionMs
        self.playWhenReady = playWhenReady
        self.repeatMode = repeatMode
        self.shuffleEnabled = shuffleEnabled
        self.savedAtEpochMs = savedAtEpochMs
    }

    enum CodingKeys: String, CodingKey {
        case items, currentMediaId, currentIndex, currentPositionMs, playWhenReady, repeatMode, shuffleEnabled,
             savedAtEpochMs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([PlaybackQueueItemSnapshot].self, forKey: .items)
        currentMediaId = try c.decodeIfPresent(String.self, forKey: .currentMediaId)
        currentIndex = try c.decodeIfPresent(Int.self, forKey: .currentIndex) ?? 0
        currentPositionMs = try c.decodeIfPresent(Int64.self, forKey: .currentPositionMs) ?? 0
        playWhenReady = try c.decodeIfPresent(Bool.self, forKey: .playWhenReady) ?? false
        repeatMode = try c.decodeIfPresent(Int.self, forKey: .repeatMode) ?? 0
        shuffleEnabled = try c.decodeIfPresent(Bool.self, forKey: .shuffleEnabled) ?? false
        savedAtEpochMs = try c.decodeIfPresent(Int64.self, forKey: .savedAtEpochMs) ?? currentTimeMillis()
    }
}

/// A Spotify catalogue track that is not in the library yet (`CatalogTrack`); tapping imports it.
public struct CatalogTrack: Sendable, Hashable, Codable {
    public var spotifyId: String
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtUrl: String?
    public var durationMs: Int64

    public init(spotifyId: String, title: String, artist: String, album: String, albumArtUrl: String?, durationMs: Int64) {
        self.spotifyId = spotifyId
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtUrl = albumArtUrl
        self.durationMs = durationMs
    }
}

/// A track found by searching YouTube Music directly (`YouTubeMusicTrack`); playable as is.
public struct YouTubeMusicTrack: Sendable, Hashable, Codable {
    public var videoId: String
    public var title: String
    public var artist: String
    public var album: String?
    public var thumbnailUrl: String?
    public var durationMs: Int64

    public init(videoId: String, title: String, artist: String, album: String?, thumbnailUrl: String?, durationMs: Int64) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.album = album
        self.thumbnailUrl = thumbnailUrl
        self.durationMs = durationMs
    }
}

/// One search result (`SearchResultItem`).
public enum SearchResultItem: Sendable, Hashable {
    case song(Song)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    /// Spotify catalogue result (imported on tap).
    case catalog(CatalogTrack)
    /// YouTube Music result (imported and played on tap).
    case youtubeMusic(YouTubeMusicTrack)
}

/// A folder in the library's folder tree (`MusicFolder`).
public struct MusicFolder: Sendable, Hashable {
    public var path: String
    public var name: String
    public var songs: [Song]
    public var subFolders: [MusicFolder]

    public init(path: String, name: String, songs: [Song] = [], subFolders: [MusicFolder] = []) {
        self.path = path
        self.name = name
        self.songs = songs
        self.subFolders = subFolders
    }

    /// Songs here and in every subfolder.
    public var totalSongCount: Int { songs.count + subFolders.reduce(0) { $0 + $1.totalSongCount } }

    /// Subfolders at every depth.
    public var totalSubFolderCount: Int { subFolders.count + subFolders.reduce(0) { $0 + $1.totalSubFolderCount } }
}
