// Automatic Spotify listening-history sync (spec B1): the last 50 plays (`/v1/me/player/recently-played`, scope
// `user-read-recently-played`), the top tracks and artists for each time range (`/v1/me/top/*`, `user-top-read`) and
// the followed artists (`/v1/me/following?type=artist`, `user-follow-read`). All three are still in the Web API after
// the February 2026 changes. Spotify keeps only the 50 most recent plays for the API, so syncing every few hours (and the
// data export for everything older) is what makes the history deep; overlaps are de-duplicated by the store.

import Foundation
import PixlFoundation
import PixlModel

extension SpotifyAPI {
    /// The scopes this feature adds; accounts linked before they existed reconnect once.
    public static let listeningHistoryScopes = ["user-read-recently-played", "user-follow-read"]

    /// `GET /v1/me/player/recently-played` (at most 50; `after` = a Unix ms cursor).
    public static func recentlyPlayed(authorization: String, limit: Int = 50, afterMs: Int64? = nil) -> HTTPRequest {
        HTTPRequest(url: URLCoding.url(SpotifyAuth.apiBaseURL + "v1/me/player/recently-played",
                                       query: [("limit", String(limit)), ("after", afterMs.map(String.init))]),
                    headers: [HTTPHeader("Authorization", authorization)])
    }

    /// `GET /v1/me/following?type=artist` (cursor paging with the last artist id).
    public static func followedArtists(authorization: String, limit: Int = 50, after: String? = nil) -> HTTPRequest {
        HTTPRequest(url: URLCoding.url(SpotifyAuth.apiBaseURL + "v1/me/following",
                                       query: [("type", "artist"), ("limit", String(limit)), ("after", after)]),
                    headers: [HTTPHeader("Authorization", authorization)])
    }
}

/// One item of `recently-played`.
public struct SpotifyPlayHistoryItem: Sendable, Hashable {
    public var track: SpotifyTrack?
    public var playedAt: String?

    public init(track: SpotifyTrack?, playedAt: String?) {
        self.track = track
        self.playedAt = playedAt
    }

    init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(track: o["track"].flatMap(SpotifyTrack.init(json:)), playedAt: LenientJSON.string(o["played_at"]))
    }
}

/// `recently-played`'s page.
public struct SpotifyRecentlyPlayedPage: Sendable, Hashable {
    public var items: [SpotifyPlayHistoryItem]

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        items = LenientJSON.array(o["items"])?.compactMap(SpotifyPlayHistoryItem.init(json:)) ?? []
    }
}

/// `following?type=artist`: `{"artists": {"items": [...], "next": ..., "cursors": {"after": ...}}}`.
public struct SpotifyFollowedArtistsPage: Sendable, Hashable {
    public var artists: [SpotifyArtistFull]
    public var next: String?
    public var after: String?

    public init?(json: JSONValue) {
        guard let o = json.objectValue, let a = LenientJSON.object(o["artists"]) else { return nil }
        artists = SpotifyArtistFull.list(a["items"]) ?? []
        next = LenientJSON.string(a["next"])
        after = LenientJSON.string(LenientJSON.object(a["cursors"])?["after"])
    }
}

/// What one automatic sync read.
public struct SpotifyListeningFetch: Sendable {
    public var plays: [ImportedPlay] = []
    /// nil when neither the top lists nor the followed artists could be read (keep the stored snapshot).
    public var taste: ExternalTasteSnapshot?
    /// Spotify refused the recent plays / followed artists with 403: the login predates their scopes.
    public var recentlyPlayedDenied = false
    public var followedDenied = false
    /// Whether Spotify answered any of the requests (recent plays, a top list, followed artists). False when offline
    /// or every call failed: nothing was read, so the sync must not count as done.
    public var anyResponded = false

    public init() {}

    public var needsReconnect: Bool { recentlyPlayedDenied || followedDenied }
}

public enum SpotifyListeningHistoryMapping {
    /// A `recently-played` item as a play (nil without a track id or a time; not a song: podcasts, local files).
    public static func play(_ item: SpotifyPlayHistoryItem) -> ImportedPlay? {
        guard let track = item.track, let id = track.id, !NetText.isBlank(id), track.isLocal != true,
              track.type == nil || track.type == "track",
              let title = track.name, !NetText.isBlank(title),
              let playedAt = item.playedAt, let ts = SpotifyLibrary.parseInstant(playedAt) else { return nil }
        let artist = track.artists?.first?.name ?? ""
        return ImportedPlay(source: .spotifyAPI, timestampMs: ts, title: title, artist: artist, album: track.album?.name,
                            spotifyTrackId: id, durationMs: track.durationMs ?? 0)
    }

    public static func rankedTracks(_ tracks: [SpotifyTrack], range: ExternalTasteSnapshot.Range) -> [ExternalTasteSnapshot.RankedTrack] {
        tracks.enumerated().compactMap { index, track in
            guard let title = track.name, !NetText.isBlank(title) else { return nil }
            return ExternalTasteSnapshot.RankedTrack(range: range, rank: index, title: title,
                                                     artist: track.artists?.first?.name ?? "", spotifyTrackId: track.id)
        }
    }

    public static func rankedArtists(_ artists: [SpotifyArtistFull], range: ExternalTasteSnapshot.Range) -> [ExternalTasteSnapshot.RankedArtist] {
        artists.enumerated().compactMap { index, artist in
            guard let name = artist.name, !NetText.isBlank(name) else { return nil }
            return ExternalTasteSnapshot.RankedArtist(range: range, rank: index, name: name, genres: artist.genres ?? [])
        }
    }
}

/// Reads the history and taste over an existing `SpotifyWebAPI` (its pacing, refresh and retry rules).
public struct SpotifyListeningHistoryClient: Sendable {
    public static let maxFollowedPages = 10

    private let api: SpotifyWebAPI

    public init(api: SpotifyWebAPI) { self.api = api }

    /// One sync. Each part fails on its own: a missing scope or an error just means less data this time.
    public func fetch(nowMs: Int64) async throws -> SpotifyListeningFetch {
        var result = SpotifyListeningFetch()

        let recentDenied = ForbiddenFlag()
        let recent = try await api.call("recently-played", onForbidden: { recentDenied.raise() },
                                        build: { SpotifyAPI.recentlyPlayed(authorization: $0) },
                                        decode: SpotifyRecentlyPlayedPage.init(json:))
        result.recentlyPlayedDenied = recentDenied.isRaised
        result.plays = (recent?.items ?? []).compactMap(SpotifyListeningHistoryMapping.play)
        if recent != nil { result.anyResponded = true }

        var taste = ExternalTasteSnapshot(fetchedAtMs: nowMs)
        var anyTaste = false
        for range in ExternalTasteSnapshot.Range.allCases {
            if let page = try await api.call("top-tracks:\(range.rawValue)", build: {
                SpotifyAPI.myTopTracks(authorization: $0, timeRange: range.rawValue, limit: 50)
            }, decode: { SpotifyTracksListPage(tracksJSON: $0) }) {
                taste.topTracks += SpotifyListeningHistoryMapping.rankedTracks(page.items ?? [], range: range)
                anyTaste = true
            }
            if let page = try await api.call("top-artists:\(range.rawValue)", build: {
                SpotifyAPI.myTopArtists(authorization: $0, timeRange: range.rawValue, limit: 50)
            }, decode: { SpotifyArtistsPage(artistsJSON: $0) }) {
                taste.topArtists += SpotifyListeningHistoryMapping.rankedArtists(page.items ?? [], range: range)
                anyTaste = true
            }
        }

        let followDenied = ForbiddenFlag()
        var after: String?
        var followed: [String] = []
        var followedRead = false
        for _ in 0..<Self.maxFollowedPages {
            let cursor = after
            guard let page = try await api.call("following", onForbidden: { followDenied.raise() },
                                                build: { SpotifyAPI.followedArtists(authorization: $0, after: cursor) },
                                                decode: SpotifyFollowedArtistsPage.init(json:)) else { break }
            followedRead = true
            followed += page.artists.compactMap { $0.name.flatMap { NetText.isBlank($0) ? nil : $0 } }
            guard page.next != nil, let next = page.after, next != cursor else { break }
            after = next
        }
        result.followedDenied = followDenied.isRaised
        if followedRead {
            taste.followedArtists = followed
            anyTaste = true
        }
        if anyTaste {
            result.taste = taste
            result.anyResponded = true
        }
        return result
    }

    /// Whether a granted scope string lacks one of this feature's scopes (an account linked before them).
    public static func lacksScopes(granted: String?) -> Bool {
        guard let granted else { return false }
        let scopes = Set(granted.split(separator: " ").map(String.init))
        return SpotifyAPI.listeningHistoryScopes.contains { !scopes.contains($0) }
    }
}
