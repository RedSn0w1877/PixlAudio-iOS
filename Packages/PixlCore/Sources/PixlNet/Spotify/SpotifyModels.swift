// Port of `data/network/spotify/SpotifyModels.kt`: the Spotify Web API DTOs the app uses. Everything optional is
// optional on purpose (local files have no `id`, a removed track arrives as `track: null`). Decoding is lenient like
// Gson: numbers may arrive as strings and vice versa; a field of the wrong shape reads as absent.

import Foundation
import PixlFoundation

/// `SpotifyTokenResponse`. Under PKCE Spotify returns a **new** refresh token on every refresh.
public struct SpotifyTokenResponse: Sendable, Hashable {
    public var accessToken: String?
    public var tokenType: String?
    public var expiresIn: Int64?
    public var refreshToken: String?
    public var scope: String?

    public init(accessToken: String?, tokenType: String? = nil, expiresIn: Int64? = nil, refreshToken: String? = nil, scope: String? = nil) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.scope = scope
    }

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(accessToken: LenientJSON.string(o["access_token"]), tokenType: LenientJSON.string(o["token_type"]),
                  expiresIn: LenientJSON.long(o["expires_in"]), refreshToken: LenientJSON.string(o["refresh_token"]),
                  scope: LenientJSON.string(o["scope"]))
    }
}

public struct SpotifyImage: Sendable, Hashable, Codable {
    public var url: String?
    public var width: Int?
    public var height: Int?

    public init(url: String?, width: Int? = nil, height: Int? = nil) {
        self.url = url
        self.width = width
        self.height = height
    }

    init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(url: LenientJSON.string(o["url"]), width: LenientJSON.int(o["width"]), height: LenientJSON.int(o["height"]))
    }

    static func list(_ value: JSONValue?) -> [SpotifyImage]? { LenientJSON.array(value)?.compactMap(SpotifyImage.init(json:)) }
}

public struct SpotifyUserProfile: Sendable, Hashable {
    public var id: String?
    public var displayName: String?
    public var email: String?
    public var product: String?
    public var images: [SpotifyImage]?

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        id = LenientJSON.string(o["id"])
        displayName = LenientJSON.string(o["display_name"])
        email = LenientJSON.string(o["email"])
        product = LenientJSON.string(o["product"])
        images = SpotifyImage.list(o["images"])
    }
}

public struct SpotifyArtistRef: Sendable, Hashable, Codable {
    public var id: String?
    public var name: String?

    public init(id: String?, name: String?) {
        self.id = id
        self.name = name
    }

    init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(id: LenientJSON.string(o["id"]), name: LenientJSON.string(o["name"]))
    }

    static func list(_ value: JSONValue?) -> [SpotifyArtistRef]? { LenientJSON.array(value)?.compactMap(SpotifyArtistRef.init(json:)) }
}

public struct SpotifyAlbumRef: Sendable, Hashable, Codable {
    public var id: String?
    public var name: String?
    public var images: [SpotifyImage]?
    public var releaseDate: String?

    public init(id: String?, name: String?, images: [SpotifyImage]? = nil, releaseDate: String? = nil) {
        self.id = id
        self.name = name
        self.images = images
        self.releaseDate = releaseDate
    }

    init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(id: LenientJSON.string(o["id"]), name: LenientJSON.string(o["name"]), images: SpotifyImage.list(o["images"]),
                  releaseDate: LenientJSON.string(o["release_date"]))
    }
}

public struct SpotifyTrack: Sendable, Hashable, Codable {
    public var id: String?
    public var name: String?
    public var durationMs: Int64?
    public var artists: [SpotifyArtistRef]?
    public var album: SpotifyAlbumRef?
    public var isrc: String?
    public var isLocal: Bool?
    public var type: String?

    public init(id: String?, name: String?, durationMs: Int64? = nil, artists: [SpotifyArtistRef]? = nil,
                album: SpotifyAlbumRef? = nil, isrc: String? = nil, isLocal: Bool? = nil, type: String? = nil) {
        self.id = id
        self.name = name
        self.durationMs = durationMs
        self.artists = artists
        self.album = album
        self.isrc = isrc
        self.isLocal = isLocal
        self.type = type
    }

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(id: LenientJSON.string(o["id"]), name: LenientJSON.string(o["name"]),
                  durationMs: LenientJSON.long(o["duration_ms"]), artists: SpotifyArtistRef.list(o["artists"]),
                  album: o["album"].flatMap(SpotifyAlbumRef.init(json:)),
                  isrc: LenientJSON.string(LenientJSON.object(o["external_ids"])?["isrc"]),
                  isLocal: LenientJSON.bool(o["is_local"]), type: LenientJSON.string(o["type"]))
    }

    static func list(_ value: JSONValue?) -> [SpotifyTrack]? { LenientJSON.array(value)?.compactMap(SpotifyTrack.init(json:)) }
}

/// An item of `/v1/me/tracks` (`track`) or `/v1/playlists/{id}/items` (`item`, the renamed field).
public struct SpotifyPlaylistTrackItem: Sendable, Hashable {
    public var addedAt: String?
    public var item: SpotifyTrack?
    public var track: SpotifyTrack?

    public init(addedAt: String? = nil, item: SpotifyTrack? = nil, track: SpotifyTrack? = nil) {
        self.addedAt = addedAt
        self.item = item
        self.track = track
    }

    init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(addedAt: LenientJSON.string(o["added_at"]), item: o["item"].flatMap(SpotifyTrack.init(json:)),
                  track: o["track"].flatMap(SpotifyTrack.init(json:)))
    }

    public var resolvedTrack: SpotifyTrack? { item ?? track }
}

public struct SpotifyTracksPage: Sendable, Hashable {
    public var items: [SpotifyPlaylistTrackItem]?
    public var total: Int?
    public var limit: Int?
    public var offset: Int?
    public var next: String?

    public init(items: [SpotifyPlaylistTrackItem]? = nil, total: Int? = nil, limit: Int? = nil, offset: Int? = nil, next: String? = nil) {
        self.items = items
        self.total = total
        self.limit = limit
        self.offset = offset
        self.next = next
    }

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(items: LenientJSON.array(o["items"])?.compactMap(SpotifyPlaylistTrackItem.init(json:)),
                  total: LenientJSON.int(o["total"]), limit: LenientJSON.int(o["limit"]),
                  offset: LenientJSON.int(o["offset"]), next: LenientJSON.string(o["next"]))
    }
}

public struct SpotifyPlaylist: Sendable, Hashable {
    public var id: String?
    public var name: String?
    public var images: [SpotifyImage]?
    /// `tracks.total`.
    public var trackTotal: Int?
    public var ownerId: String?
    public var ownerDisplayName: String?
    public var isPublic: Bool?
    public var collaborative: Bool?

    public init(id: String?, name: String?, images: [SpotifyImage]? = nil, trackTotal: Int? = nil, ownerId: String? = nil,
                ownerDisplayName: String? = nil, isPublic: Bool? = nil, collaborative: Bool? = nil) {
        self.id = id
        self.name = name
        self.images = images
        self.trackTotal = trackTotal
        self.ownerId = ownerId
        self.ownerDisplayName = ownerDisplayName
        self.isPublic = isPublic
        self.collaborative = collaborative
    }

    init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        let owner = LenientJSON.object(o["owner"])
        self.init(id: LenientJSON.string(o["id"]), name: LenientJSON.string(o["name"]), images: SpotifyImage.list(o["images"]),
                  trackTotal: LenientJSON.int(LenientJSON.object(o["tracks"])?["total"]),
                  ownerId: LenientJSON.string(owner?["id"]), ownerDisplayName: LenientJSON.string(owner?["display_name"]),
                  isPublic: LenientJSON.bool(o["public"]), collaborative: LenientJSON.bool(o["collaborative"]))
    }
}

public struct SpotifyPlaylistsPage: Sendable, Hashable {
    public var items: [SpotifyPlaylist]?
    public var total: Int?
    public var limit: Int?
    public var offset: Int?
    public var next: String?

    public init(items: [SpotifyPlaylist]? = nil, total: Int? = nil, limit: Int? = nil, offset: Int? = nil, next: String? = nil) {
        self.items = items
        self.total = total
        self.limit = limit
        self.offset = offset
        self.next = next
    }

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(items: LenientJSON.array(o["items"])?.compactMap(SpotifyPlaylist.init(json:)), total: LenientJSON.int(o["total"]),
                  limit: LenientJSON.int(o["limit"]), offset: LenientJSON.int(o["offset"]), next: LenientJSON.string(o["next"]))
    }
}

/// A full artist (`/v1/artists`, with images and genres).
public struct SpotifyArtistFull: Sendable, Hashable {
    public var id: String?
    public var name: String?
    public var images: [SpotifyImage]?
    public var genres: [String]?
    public var popularity: Int?
    public var followers: Int64?

    public init(id: String?, name: String?, images: [SpotifyImage]? = nil, genres: [String]? = nil, popularity: Int? = nil, followers: Int64? = nil) {
        self.id = id
        self.name = name
        self.images = images
        self.genres = genres
        self.popularity = popularity
        self.followers = followers
    }

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(id: LenientJSON.string(o["id"]), name: LenientJSON.string(o["name"]), images: SpotifyImage.list(o["images"]),
                  genres: LenientJSON.strings(o["genres"]), popularity: LenientJSON.int(o["popularity"]),
                  followers: LenientJSON.long(LenientJSON.object(o["followers"])?["total"]))
    }

    static func list(_ value: JSONValue?) -> [SpotifyArtistFull]? { LenientJSON.array(value)?.compactMap(SpotifyArtistFull.init(json:)) }
}

/// `GET /v1/artists?ids=…`: unknown/removed ids come back null.
public struct SpotifyArtistsBatchResponse: Sendable, Hashable {
    public var artists: [SpotifyArtistFull?]?

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        artists = LenientJSON.array(o["artists"])?.map { SpotifyArtistFull(json: $0) }
    }
}

/// A catalogue album (`album_group` tells own records from compilations/appearances).
public struct SpotifyAlbumFull: Sendable, Hashable {
    public var id: String?
    public var name: String?
    public var images: [SpotifyImage]?
    public var releaseDate: String?
    public var totalTracks: Int?
    public var albumType: String?
    public var albumGroup: String?
    public var artists: [SpotifyArtistRef]?

    public init(id: String?, name: String?, images: [SpotifyImage]? = nil, releaseDate: String? = nil, totalTracks: Int? = nil,
                albumType: String? = nil, albumGroup: String? = nil, artists: [SpotifyArtistRef]? = nil) {
        self.id = id
        self.name = name
        self.images = images
        self.releaseDate = releaseDate
        self.totalTracks = totalTracks
        self.albumType = albumType
        self.albumGroup = albumGroup
        self.artists = artists
    }

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(id: LenientJSON.string(o["id"]), name: LenientJSON.string(o["name"]), images: SpotifyImage.list(o["images"]),
                  releaseDate: LenientJSON.string(o["release_date"]), totalTracks: LenientJSON.int(o["total_tracks"]),
                  albumType: LenientJSON.string(o["album_type"]), albumGroup: LenientJSON.string(o["album_group"]),
                  artists: SpotifyArtistRef.list(o["artists"]))
    }

    static func list(_ value: JSONValue?) -> [SpotifyAlbumFull]? { LenientJSON.array(value)?.compactMap(SpotifyAlbumFull.init(json:)) }
}

/// `{items, next}` pages of artists, albums or tracks.
public struct SpotifyListPage<Item: Sendable & Hashable>: Sendable, Hashable {
    public var items: [Item]?
    public var next: String?

    public init(items: [Item]?, next: String?) {
        self.items = items
        self.next = next
    }
}

public typealias SpotifyArtistsPage = SpotifyListPage<SpotifyArtistFull>
public typealias SpotifyAlbumsPage = SpotifyListPage<SpotifyAlbumFull>
public typealias SpotifyTracksListPage = SpotifyListPage<SpotifyTrack>

extension SpotifyListPage where Item == SpotifyArtistFull {
    public init?(artistsJSON json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(items: SpotifyArtistFull.list(o["items"]), next: LenientJSON.string(o["next"]))
    }
}

extension SpotifyListPage where Item == SpotifyAlbumFull {
    public init?(albumsJSON json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(items: SpotifyAlbumFull.list(o["items"]), next: LenientJSON.string(o["next"]))
    }
}

extension SpotifyListPage where Item == SpotifyTrack {
    public init?(tracksJSON json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(items: SpotifyTrack.list(o["items"]), next: LenientJSON.string(o["next"]))
    }
}

/// `{"tracks": [...]}` (artist top tracks).
public struct SpotifyTopTracksResponse: Sendable, Hashable {
    public var tracks: [SpotifyTrack]?

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        tracks = SpotifyTrack.list(o["tracks"])
    }
}

/// `/v1/search`: only the sections asked for in `type` arrive.
public struct SpotifySearchResponse: Sendable, Hashable {
    public var tracks: SpotifyTracksListPage?
    public var artists: SpotifyArtistsPage?
    public var albums: SpotifyAlbumsPage?

    public init(tracks: SpotifyTracksListPage? = nil, artists: SpotifyArtistsPage? = nil, albums: SpotifyAlbumsPage? = nil) {
        self.tracks = tracks
        self.artists = artists
        self.albums = albums
    }

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(tracks: o["tracks"].flatMap { SpotifyTracksListPage(tracksJSON: $0) },
                  artists: o["artists"].flatMap { SpotifyArtistsPage(artistsJSON: $0) },
                  albums: o["albums"].flatMap { SpotifyAlbumsPage(albumsJSON: $0) })
    }
}
