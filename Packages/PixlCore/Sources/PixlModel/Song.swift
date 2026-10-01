// Library value types mirroring the Android app's `data/model/Song.kt`, `LibraryModels.kt` and `Genre.kt`.
// Property names match the Kotlin properties (they are also the Codable keys).

import Foundation
import PixlFoundation

/// A track in the library. iOS ids are strings with a source prefix (`f:` folder file, `mp:` media library,
/// `yt:` YouTube, `sp:` Spotify), like Android's string ids.
public struct Song: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var title: String
    /// Legacy artist display string: usually only the primary artist. Use `displayArtist` / `artists` for display.
    public var artist: String
    /// Primary artist id (backward compatibility with single-artist code).
    public var artistId: Int64
    /// All artists (multi-artist support).
    public var artists: [ArtistRef]
    public var album: String
    public var albumId: Int64
    public var albumArtist: String?
    /// File path (iOS: path relative to the folder bookmark, or empty for non-file sources).
    public var path: String
    /// Playable item URL as a string (Android: content URI).
    public var contentUriString: String
    public var albumArtUriString: String?
    /// Duration in milliseconds.
    public var duration: Int64
    public var genre: String?
    public var lyrics: String?
    public var isFavorite: Bool
    public var trackNumber: Int
    public var discNumber: Int?
    public var year: Int
    /// Milliseconds since 1970 (Android MediaStore stores seconds on some paths; iOS always ms).
    public var dateAdded: Int64
    public var dateModified: Int64
    public var mimeType: String?
    public var bitrate: Int?
    public var sampleRate: Int?
    /// Spotify track id (base62, 22 chars) for Spotify-imported songs.
    public var spotifyId: String?

    public init(id: String, title: String, artist: String, artistId: Int64, artists: [ArtistRef] = [],
                album: String, albumId: Int64, albumArtist: String? = nil, path: String, contentUriString: String,
                albumArtUriString: String?, duration: Int64, genre: String? = nil, lyrics: String? = nil,
                isFavorite: Bool = false, trackNumber: Int = 0, discNumber: Int? = nil, year: Int = 0,
                dateAdded: Int64 = 0, dateModified: Int64 = 0, mimeType: String?, bitrate: Int?, sampleRate: Int?,
                spotifyId: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artistId = artistId
        self.artists = artists
        self.album = album
        self.albumId = albumId
        self.albumArtist = albumArtist
        self.path = path
        self.contentUriString = contentUriString
        self.albumArtUriString = albumArtUriString
        self.duration = duration
        self.genre = genre
        self.lyrics = lyrics
        self.isFavorite = isFavorite
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.mimeType = mimeType
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.spotifyId = spotifyId
    }

    /// All artists joined with ", ", primary artists first (stable order otherwise); falls back to `artist`.
    public var displayArtist: String {
        guard !artists.isEmpty else { return artist }
        let ordered = artists.filter(\.isPrimary) + artists.filter { !$0.isPrimary }
        return ordered.map(\.name).joined(separator: ", ")
    }

    /// The primary artist, else the first artist, else one built from the legacy fields.
    public var primaryArtist: ArtistRef {
        artists.first(where: \.isPrimary) ?? artists.first ?? ArtistRef(id: artistId, name: artist, isPrimary: true)
    }

    /// Android `Song.emptySong()`.
    public static func emptySong() -> Song {
        Song(id: "-1", title: "", artist: "", artistId: -1, artists: [], album: "", albumId: -1, albumArtist: nil,
             path: "", contentUriString: "", albumArtUriString: nil, duration: 0, genre: nil, lyrics: nil,
             isFavorite: false, trackNumber: 0, discNumber: nil, year: 0, dateAdded: 0, dateModified: 0,
             mimeType: "-", bitrate: 0, sampleRate: 0, spotifyId: nil)
    }
}

/// A lightweight artist reference on a song (multi-artist support).
public struct ArtistRef: Sendable, Hashable, Codable {
    public var id: Int64
    public var name: String
    public var isPrimary: Bool

    public init(id: Int64, name: String, isPrimary: Bool = false) {
        self.id = id
        self.name = name
        self.isPrimary = isPrimary
    }
}

/// An album in the library.
public struct Album: Sendable, Hashable, Codable, Identifiable {
    public var id: Int64
    public var title: String
    public var artist: String
    public var year: Int
    public var dateAdded: Int64
    public var albumArtUriString: String?
    public var songCount: Int
    public var albumArtist: String?

    public init(id: Int64, title: String, artist: String, year: Int, dateAdded: Int64, albumArtUriString: String?,
                songCount: Int, albumArtist: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.year = year
        self.dateAdded = dateAdded
        self.albumArtUriString = albumArtUriString
        self.songCount = songCount
        self.albumArtist = albumArtist
    }

    /// Android `Album.empty()`.
    public static func empty() -> Album {
        Album(id: -1, title: "", artist: "", year: 0, dateAdded: 0, albumArtUriString: nil, songCount: 0, albumArtist: nil)
    }
}

/// An artist in the library.
public struct Artist: Sendable, Hashable, Codable, Identifiable {
    public var id: Int64
    public var name: String
    public var songCount: Int
    /// Remote artist image URL.
    public var imageUrl: String?
    /// User-chosen image (local file).
    public var customImageUri: String?

    public init(id: Int64, name: String, songCount: Int, imageUrl: String? = nil, customImageUri: String? = nil) {
        self.id = id
        self.name = name
        self.songCount = songCount
        self.imageUrl = imageUrl
        self.customImageUri = customImageUri
    }

    /// Android `Artist.empty()`.
    public static func empty() -> Artist { Artist(id: -1, name: "", songCount: 0, imageUrl: nil, customImageUri: nil) }

    /// The image to show: the custom image if set (not blank), else the remote one (not blank).
    public var effectiveImageUrl: String? {
        if let custom = customImageUri, !custom.isKotlinBlank { return custom }
        if let url = imageUrl, !url.isKotlinBlank { return url }
        return nil
    }
}

/// A genre. Android's `iconResId` (a drawable resource) becomes `symbolName` (an SF Symbol name) on iOS.
public struct Genre: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var symbolName: String?
    public var lightColorHex: String?
    public var onLightColorHex: String?
    public var darkColorHex: String?
    public var onDarkColorHex: String?

    public init(id: String, name: String, symbolName: String? = nil, lightColorHex: String? = nil,
                onLightColorHex: String? = nil, darkColorHex: String? = nil, onDarkColorHex: String? = nil) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.lightColorHex = lightColorHex
        self.onLightColorHex = onLightColorHex
        self.darkColorHex = darkColorHex
        self.onDarkColorHex = onDarkColorHex
    }
}
