// Port of `data/network/spotify/SpotifyApiService.kt` (endpoints, query parameters, the `/items` field filter) and
// the pure parts of `data/spotify/SpotifyRepository.kt`: the request pacing/retry policy (`apiCall`), catalogue
// search paging, the snapshot pagination guard, track → row mapping, and the unified-library ids (FNV-1a).

import Foundation
import PixlFoundation
import PixlModel

/// `api.spotify.com` request builders (the access token goes explicitly on each call).
public enum SpotifyAPI {
    /// `/items` replaced the retired `/tracks` (Feb/Mar 2026); its row field is `item`, so the filter asks for it.
    public static let playlistTrackFields =
        "total,next,items(added_at,item(id,name,duration_ms,is_local,type,artists(id,name),album(id,name,images(url,width,height)),external_ids(isrc)))"

    public static let likedPageSize = 50
    public static let playlistPageSize = 50
    public static let trackPageSize = 100

    private static func get(_ path: String, authorization: String, query: [(name: String, value: String?)] = []) -> HTTPRequest {
        HTTPRequest(url: URLCoding.url(SpotifyAuth.apiBaseURL + path, query: query),
                    headers: [HTTPHeader("Authorization", authorization)])
    }

    public static func profile(authorization: String) -> HTTPRequest { get("v1/me", authorization: authorization) }

    /// Liked songs (max 50 per page).
    public static func savedTracks(authorization: String, limit: Int = 50, offset: Int = 0) -> HTTPRequest {
        get("v1/me/tracks", authorization: authorization, query: [("limit", String(limit)), ("offset", String(offset))])
    }

    public static func userPlaylists(authorization: String, limit: Int = 50, offset: Int = 0) -> HTTPRequest {
        get("v1/me/playlists", authorization: authorization, query: [("limit", String(limit)), ("offset", String(offset))])
    }

    /// `fields = nil` asks for the whole response (the escape hatch when the filter itself fails).
    public static func playlistTracks(authorization: String, playlistId: String, limit: Int = 100, offset: Int = 0,
                                      fields: String? = playlistTrackFields) -> HTTPRequest {
        get("v1/playlists/\(URLCoding.pathSegment(playlistId))/items", authorization: authorization,
            query: [("limit", String(limit)), ("offset", String(offset)), ("fields", fields)])
    }

    /// `/v1/search`. Spotify answers `400 Invalid limit` to any request with `limit`, so callers page with
    /// `offset` instead; nil parameters are omitted.
    public static func search(authorization: String, query: String, type: String = "track,artist,album", limit: Int? = nil,
                              market: String? = nil, offset: Int? = nil) -> HTTPRequest {
        get("v1/search", authorization: authorization,
            query: [("q", query), ("type", type), ("limit", limit.map(String.init)), ("market", market), ("offset", offset.map(String.init))])
    }

    public static func artist(authorization: String, artistId: String) -> HTTPRequest {
        get("v1/artists/\(URLCoding.pathSegment(artistId))", authorization: authorization)
    }

    /// Batch lookup of up to 50 comma-separated ids (genre backfill).
    public static func artists(authorization: String, ids: String) -> HTTPRequest {
        get("v1/artists", authorization: authorization, query: [("ids", ids)])
    }

    /// `market` is required; `from_token` uses the account's country.
    public static func artistTopTracks(authorization: String, artistId: String, market: String = "from_token") -> HTTPRequest {
        get("v1/artists/\(URLCoding.pathSegment(artistId))/top-tracks", authorization: authorization, query: [("market", market)])
    }

    /// Own albums and singles only (no compilations/appearances).
    public static func artistAlbums(authorization: String, artistId: String, includeGroups: String = "album,single",
                                    limit: Int = 50, offset: Int = 0) -> HTTPRequest {
        get("v1/artists/\(URLCoding.pathSegment(artistId))/albums", authorization: authorization,
            query: [("include_groups", includeGroups), ("limit", String(limit)), ("offset", String(offset))])
    }

    /// Album tracks come without `album`: fill it from the requested album.
    public static func albumTracks(authorization: String, albumId: String, limit: Int = 50, offset: Int = 0) -> HTTPRequest {
        get("v1/albums/\(URLCoding.pathSegment(albumId))/tracks", authorization: authorization,
            query: [("limit", String(limit)), ("offset", String(offset))])
    }

    public static func album(authorization: String, albumId: String) -> HTTPRequest {
        get("v1/albums/\(URLCoding.pathSegment(albumId))", authorization: authorization)
    }

    /// `timeRange`: `short_term` (~4 weeks), `medium_term` (~6 months), `long_term`.
    public static func myTopTracks(authorization: String, timeRange: String = "medium_term", limit: Int = 50, offset: Int = 0) -> HTTPRequest {
        get("v1/me/top/tracks", authorization: authorization,
            query: [("time_range", timeRange), ("limit", String(limit)), ("offset", String(offset))])
    }

    public static func myTopArtists(authorization: String, timeRange: String = "medium_term", limit: Int = 50, offset: Int = 0) -> HTTPRequest {
        get("v1/me/top/artists", authorization: authorization,
            query: [("time_range", timeRange), ("limit", String(limit)), ("offset", String(offset))])
    }
}

// MARK: - Call policy

/// `apiCall`'s pacing and retry rules.
public enum SpotifyCallPolicy {
    public static let maxAttempts = 3
    public static let minRequestIntervalMs: Int64 = 120
    public static let retryBackoffMs: Int64 = 800

    /// What to do with a response.
    public enum Decision: Sendable, Hashable {
        case success
        /// 401: the token expired early — force a refresh and try again.
        case refreshAndRetry
        /// 429: wait this long (Retry-After clamped to 1…60 s, default 5 s) before the next request.
        case waitAndRetry(ms: Int64)
        /// Anything else: give up (403 = a missing permission, never retried).
        case fail(forbidden: Bool)
    }

    public static func decision(statusCode: Int, retryAfter: String?) -> Decision {
        if (200...299).contains(statusCode) { return .success }
        if statusCode == 401 { return .refreshAndRetry }
        if statusCode == 429 {
            let seconds = retryAfter.flatMap { NetText.toLong($0) } ?? 5
            return .waitAndRetry(ms: min(max(seconds, 1), 60) * 1000)
        }
        return .fail(forbidden: statusCode == 403)
    }

    /// The pause after a transport failure on attempt `attempt` (1-based).
    public static func backoffMs(attempt: Int) -> Int64 { retryBackoffMs * Int64(attempt) }
}

/// Executes Spotify calls with `apiCall`'s rules: one request per 120 ms, up to 3 attempts, a refresh on 401, the
/// server's Retry-After on 429, a linear backoff on transport errors.
public actor SpotifyWebAPI {
    private let http: any HTTPClient
    private let session: SpotifySession
    private let nowMs: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private var nextRequestAllowedAtMs: Int64 = 0

    /// The last failing status + body (diagnostics; Spotify explains bad parameters there).
    public private(set) var lastFailure: String?

    public init(http: any HTTPClient, session: SpotifySession, nowMs: @escaping @Sendable () -> Int64 = { currentTimeMillis() },
                sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) }) {
        self.http = http
        self.session = session
        self.nowMs = nowMs
        self.sleep = sleep
    }

    /// Runs `build(authorization)` and decodes the body; nil when signed out or the call failed for good.
    /// `onForbidden` is called on a 403.
    public func call<T: Sendable>(_ label: String = "spotify", onForbidden: (@Sendable () -> Void)? = nil,
                                  build: @Sendable (String) -> HTTPRequest,
                                  decode: @Sendable (JSONValue) -> T?) async throws -> T? {
        var attempt = 0
        while attempt < SpotifyCallPolicy.maxAttempts {
            attempt += 1
            let wait = nextRequestAllowedAtMs - nowMs()
            if wait > 0 { try await sleep(wait) }
            nextRequestAllowedAtMs = nowMs() + SpotifyCallPolicy.minRequestIntervalMs

            guard let authorization = await session.authorizationHeader() else { return nil }
            let response: HTTPResponse
            do {
                response = try await http.send(build(authorization))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt >= SpotifyCallPolicy.maxAttempts { return nil }
                try await sleep(SpotifyCallPolicy.backoffMs(attempt: attempt))
                continue
            }
            switch SpotifyCallPolicy.decision(statusCode: response.statusCode, retryAfter: response.header("Retry-After")) {
            case .success:
                return OrgJSON.parse(response.body).flatMap(decode)
            case .refreshAndRetry:
                _ = await session.forceRefresh()
            case .waitAndRetry(let ms):
                nextRequestAllowedAtMs = nowMs() + ms
            case .fail(let forbidden):
                if forbidden { onForbidden?() }
                let body = response.text
                lastFailure = "[\(label)] Spotify respondió HTTP \(response.statusCode)" + (NetText.isBlank(body) ? "" : " — \(body)")
                return nil
            }
        }
        return nil
    }

    // MARK: Catalogue search

    /// `searchCatalog`: pages with `offset` (each `/v1/search` page without `limit` holds ~5 per type) until no
    /// section has more, a page is empty, every type reached `limit`, or 4 pages were spent. Each page tries a
    /// plain request, then one with `market=US`.
    public func searchCatalog(query: String, types: String = "track,artist,album", limit: Int = 20) async throws -> SpotifyCatalogResults {
        if NetText.isBlank(query) { return SpotifyCatalogResults() }
        var tracks: [SpotifyTrack] = [], artists: [SpotifyArtistFull] = [], albums: [SpotifyAlbumFull] = []
        var offset = 0
        var page = 0
        while page < SpotifyCatalogSearch.maxPages {
            guard let response = try await fetchSearchPage(query: query, types: types, offset: offset) else { break }
            let step = SpotifyCatalogSearch.accumulate(response, tracks: &tracks, artists: &artists, albums: &albums)
            if !step.anyHasMore || step.pageWasEmpty { break }
            if tracks.count >= limit && artists.count >= limit && albums.count >= limit { break }
            offset += SpotifyCatalogSearch.pageSizeGuess
            page += 1
        }
        return SpotifyCatalogSearch.results(tracks: tracks, artists: artists, albums: albums)
    }

    private func fetchSearchPage(query: String, types: String, offset: Int) async throws -> SpotifySearchResponse? {
        let pageOffset = offset > 0 ? offset : nil
        if let plain = try await call("search:plain@\(offset)", build: { SpotifyAPI.search(authorization: $0, query: query, type: types, offset: pageOffset) },
                                      decode: SpotifySearchResponse.init(json:)) {
            return plain
        }
        return try await call("search:market@\(offset)", build: { SpotifyAPI.search(authorization: $0, query: query, type: types, market: "US", offset: pageOffset) },
                              decode: SpotifySearchResponse.init(json:))
    }
}

/// `CatalogSearchResults`.
public struct SpotifyCatalogResults: Sendable, Hashable {
    public var tracks: [SpotifyTrack]
    public var artists: [SpotifyArtistFull]
    public var albums: [SpotifyAlbumFull]

    public init(tracks: [SpotifyTrack] = [], artists: [SpotifyArtistFull] = [], albums: [SpotifyAlbumFull] = []) {
        self.tracks = tracks
        self.artists = artists
        self.albums = albums
    }

    public var isEmpty: Bool { tracks.isEmpty && artists.isEmpty && albums.isEmpty }
}

/// The paging arithmetic of `searchCatalog`.
public enum SpotifyCatalogSearch {
    public static let maxPages = 4
    /// Spotify's page size when `limit` is omitted (observed, not documented).
    public static let pageSizeGuess = 5

    /// Adds a page's items with ids; reports whether any section has a `next` and whether the page was empty.
    public static func accumulate(_ response: SpotifySearchResponse, tracks: inout [SpotifyTrack],
                                  artists: inout [SpotifyArtistFull], albums: inout [SpotifyAlbumFull]) -> (anyHasMore: Bool, pageWasEmpty: Bool) {
        let pageTracks = (response.tracks?.items ?? []).filter { !($0.id.map(NetText.isBlank) ?? true) }
        let pageArtists = (response.artists?.items ?? []).filter { !($0.id.map(NetText.isBlank) ?? true) }
        let pageAlbums = (response.albums?.items ?? []).filter { !($0.id.map(NetText.isBlank) ?? true) }
        tracks += pageTracks
        artists += pageArtists
        albums += pageAlbums
        let anyHasMore = response.tracks?.next != nil || response.artists?.next != nil || response.albums?.next != nil
        return (anyHasMore, pageTracks.isEmpty && pageArtists.isEmpty && pageAlbums.isEmpty)
    }

    /// Distinct by id, first occurrence kept.
    public static func results(tracks: [SpotifyTrack], artists: [SpotifyArtistFull], albums: [SpotifyAlbumFull]) -> SpotifyCatalogResults {
        var t = Set<String?>(), a = Set<String?>(), b = Set<String?>()
        return SpotifyCatalogResults(tracks: tracks.filter { t.insert($0.id).inserted },
                                     artists: artists.filter { a.insert($0.id).inserted },
                                     albums: albums.filter { b.insert($0.id).inserted })
    }
}

// MARK: - Library snapshot rules

/// A pagination anomaly: the saved library is kept untouched.
public struct SpotifyPaginationError: Error, Sendable, Hashable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// The pure rules of `SpotifyRepository`'s sync and import.
public enum SpotifyLibrary {
    public static let likedSongsPlaylistId = "spotify_liked_songs"
    /// Where tracks found while exploring the catalogue (or YouTube Music) land.
    public static let browsePlaylistId = "spotify_browse"
    public static let browsePlaylistName = "Saved from Spotify"
    public static let playlistSource = "SPOTIFY"

    static let songIdOffset: Int64 = 3_000_000_000_000
    static let albumIdOffset: Int64 = 4_000_000_000_000
    static let artistIdOffset: Int64 = 5_000_000_000_000
    static let idBandSize: Int64 = 1_000_000_000_000

    /// `nextSnapshotOffset`: only a complete, advancing page sequence may replace a saved snapshot. Returns the next
    /// offset, nil when done, or throws on a repeated/skipped page, early end, empty continuation or no progress.
    public static func nextSnapshotOffset(current: Int, reportedOffset: Int?, reportedLimit: Int?, count: Int,
                                          next: String?, total: Int?) throws(SpotifyPaginationError) -> Int? {
        if let reportedOffset, reportedOffset != current {
            throw SpotifyPaginationError(message: "Spotify repeated or skipped a page; existing songs were kept")
        }
        guard let next, !NetText.isBlank(next) else {
            if let total, Int64(current) + Int64(count) < Int64(total) {
                throw SpotifyPaginationError(message: "Spotify ended pagination before all entries arrived; existing songs were kept")
            }
            return nil
        }
        if count == 0 { throw SpotifyPaginationError(message: "Spotify returned an empty continuation page") }
        // The API may return a short page while still providing `next`: follow its cursor.
        let fromNext = offsetParameter(next)
        var following = fromNext
        if following == nil {
            let step = Int64((reportedLimit.flatMap { $0 > 0 ? $0 : nil }) ?? count)
            let candidate = Int64(current) + step
            following = candidate <= Int64(Int32.max) ? Int(candidate) : nil
        }
        guard let following, following > current else { throw SpotifyPaginationError(message: "Spotify pagination did not advance") }
        return following
    }

    /// `Regex("""[?&]offset=(\d+)""").find(next)?.groupValues?.get(1)?.toIntOrNull()`.
    static func offsetParameter(_ url: String) -> Int? {
        let s = Array(url.unicodeScalars)
        let key = Array("offset=".unicodeScalars)
        var i = 0
        while i < s.count {
            if s[i] == "?" || s[i] == "&" {
                var k = 0
                while k < key.count, i + 1 + k < s.count, s[i + 1 + k] == key[k] { k += 1 }
                if k == key.count {
                    var j = i + 1 + k
                    var digits = String.UnicodeScalarView()
                    while j < s.count, NetText.isAsciiDigit(s[j]) {
                        digits.append(s[j])
                        j += 1
                    }
                    if !digits.isEmpty { return NetText.toInt(String(digits)) }
                }
            }
            i += 1
        }
        return nil
    }

    /// `unifiedId(offset, key)`: a stable negative id from FNV-1a 64 over the key's UTF-16 code units, bounded below
    /// 10^12 so the song/album/artist bands never overlap.
    public static func unifiedId(offset: Int64, key: String) -> Int64 {
        var hash: Int64 = -0x340d631b7bdddcdb // FNV-1a offset basis
        for unit in key.utf16 {
            hash ^= Int64(unit)
            hash = hash &* 0x100000001b3
        }
        let bounded = (hash & Int64.max) % idBandSize
        return -(offset + bounded)
    }

    public static func unifiedSongId(_ spotifyId: String) -> Int64 { unifiedId(offset: songIdOffset, key: spotifyId) }
    public static func unifiedAlbumId(_ key: String) -> Int64 { unifiedId(offset: albumIdOffset, key: key) }
    public static func unifiedArtistId(_ key: String) -> Int64 { unifiedId(offset: artistIdOffset, key: key) }

    /// `appPlaylistId`.
    public static func appPlaylistId(_ spotifyPlaylistId: String) -> String { "spotify_playlist:\(spotifyPlaylistId)" }

    /// `youTubeMusicSyntheticId`: the first 22 hex characters of SHA-256(videoId) — matches the 22-character
    /// Spotify id shape the stream layer validates.
    public static func youTubeMusicSyntheticId(_ videoId: String, sha256: SHA256Function) -> String {
        NetText.take(NetText.hex(sha256(Array(videoId.utf8))), 22)
    }

    /// `toSpotifySongEntity`: nil for tracks without id, local files and non-track items (podcast episodes). The
    /// first artist with a known genre gives the genre.
    public static func record(for track: SpotifyTrack?, playlistId: String, addedAt: String?,
                              genreByArtistId: [String: String] = [:], nowMs: Int64) -> SpotifyTrackRecord? {
        guard let track, let id = track.id else { return nil }
        if track.isLocal == true { return nil }
        if let type = track.type, type != "track" { return nil }
        let artists = track.artists ?? []
        let artistNames = artists.compactMap { $0.name.flatMap { NetText.isBlank($0) ? nil : $0 } }
        let genre = artists.lazy.compactMap { $0.id.flatMap { genreByArtistId[$0] } }.first
        let joined = artistNames.joined(separator: ", ")
        return SpotifyTrackRecord(
            id: "\(playlistId)_\(id)", spotifyId: id, playlistId: playlistId,
            title: track.name.flatMap { NetText.isBlank($0) ? nil : $0 } ?? "Unknown title",
            artist: NetText.isBlank(joined) ? "Unknown Artist" : joined,
            album: track.album?.name.flatMap { NetText.isBlank($0) ? nil : $0 } ?? "Unknown Album",
            albumId: track.album?.id, durationMs: track.durationMs ?? 0,
            albumArtUrl: track.album?.images?.first?.url, isrc: track.isrc,
            dateAdded: parseAddedAt(addedAt, nowMs: nowMs), genre: genre)
    }

    /// `toYouTubeMusicSongEntity`: a YouTube Music search result stored as an already MATCHED browse row.
    public static func record(forYouTubeResult result: YouTubeSearchResult, sha256: SHA256Function, nowMs: Int64) -> SpotifyTrackRecord {
        let syntheticId = youTubeMusicSyntheticId(result.videoId, sha256: sha256)
        return SpotifyTrackRecord(
            id: "\(browsePlaylistId)_\(syntheticId)", spotifyId: syntheticId, playlistId: browsePlaylistId,
            title: result.title, artist: NetText.isBlank(result.artist) ? "Unknown Artist" : result.artist,
            album: result.album.flatMap { NetText.isBlank($0) ? nil : $0 } ?? "Unknown Album",
            albumId: nil, durationMs: Int64(result.durationSeconds ?? 0) * 1000, albumArtUrl: result.thumbnailUrl,
            isrc: nil, dateAdded: nowMs, matchedVideoId: result.videoId, matchScore: 1, matchState: .matched)
    }

    /// `parseAddedAt`: ISO-8601 instant (`Instant.parse`) in ms, else now.
    public static func parseAddedAt(_ value: String?, nowMs: Int64) -> Int64 {
        guard let value, !NetText.isBlank(value), let ms = parseInstant(value) else { return nowMs }
        return ms
    }

    /// `Instant.parse` for `YYYY-MM-DDTHH:MM:SS[.fraction]Z` (Spotify's form) and `±HH:MM` offsets.
    static func parseInstant(_ s: String) -> Int64? {
        let c = Array(s.utf8)
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= c.count else { return nil }
            var v = 0
            for i in from..<(from + len) {
                guard c[i] >= 48 && c[i] <= 57 else { return nil }
                v = v * 10 + Int(c[i] - 48)
            }
            return v
        }
        guard c.count >= 20, let y = num(0, 4), c[4] == 45, let mo = num(5, 2), c[7] == 45, let d = num(8, 2),
              c[10] == 84 || c[10] == 116, let h = num(11, 2), c[13] == 58, let mi = num(14, 2), c[16] == 58, let sec = num(17, 2),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, sec < 60 else { return nil }
        var i = 19
        var nanos: Int64 = 0
        if i < c.count, c[i] == 46 {
            i += 1
            var digits = 0
            while i < c.count, c[i] >= 48, c[i] <= 57 {
                if digits < 9 { nanos = nanos * 10 + Int64(c[i] - 48) }
                digits += 1
                i += 1
            }
            guard digits > 0, digits <= 9 else { return nil }
            for _ in digits..<9 { nanos *= 10 }
        }
        var offsetSeconds = 0
        guard i < c.count else { return nil }
        if c[i] == 90 || c[i] == 122 {
            i += 1
        } else if c[i] == 43 || c[i] == 45 {
            let sign = c[i] == 45 ? -1 : 1
            guard let oh = num(i + 1, 2), i + 3 < c.count, c[i + 3] == 58, let om = num(i + 4, 2) else { return nil }
            offsetSeconds = sign * (oh * 3600 + om * 60)
            i += 6
        } else {
            return nil
        }
        guard i == c.count else { return nil }
        // Days from civil (proleptic Gregorian).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = Int64(era * 146097 + doe - 719468)
        let seconds = days * 86400 + Int64(h * 3600 + mi * 60 + sec) - Int64(offsetSeconds)
        return seconds * 1000 + nanos / 1_000_000
    }
}

/// `SpotifyMatchState`.
public enum SpotifyMatchState: Int, Sendable, Hashable, Codable {
    /// Not tried yet.
    case pending = 0
    /// `matchedVideoId` is playable.
    case matched = 1
    /// Searched, no acceptable candidate.
    case unmatched = 2
    /// The user picked the video; never re-match automatically.
    case manual = 3
}

/// One imported Spotify track (`SpotifySongEntity`): metadata plus the YouTube Music match.
public struct SpotifyTrackRecord: Sendable, Hashable, Codable {
    /// `<playlistId>_<spotifyId>` (the same track can be in several playlists).
    public var id: String
    public var spotifyId: String
    public var playlistId: String
    public var title: String
    public var artist: String
    public var album: String
    public var albumId: String?
    public var durationMs: Int64
    public var albumArtUrl: String?
    /// The most reliable recording key Spotify gives.
    public var isrc: String?
    public var dateAdded: Int64
    public var matchedVideoId: String?
    public var matchScore: Float?
    public var matchState: SpotifyMatchState
    public var genre: String?

    public init(id: String, spotifyId: String, playlistId: String, title: String, artist: String, album: String, albumId: String?,
                durationMs: Int64, albumArtUrl: String?, isrc: String?, dateAdded: Int64, matchedVideoId: String? = nil,
                matchScore: Float? = nil, matchState: SpotifyMatchState = .pending, genre: String? = nil) {
        self.id = id
        self.spotifyId = spotifyId
        self.playlistId = playlistId
        self.title = title
        self.artist = artist
        self.album = album
        self.albumId = albumId
        self.durationMs = durationMs
        self.albumArtUrl = albumArtUrl
        self.isrc = isrc
        self.dateAdded = dateAdded
        self.matchedVideoId = matchedVideoId
        self.matchScore = matchScore
        self.matchState = matchState
        self.genre = genre
    }

    /// What the matcher scores.
    public var matchable: MatchableTrack { MatchableTrack(title: title, artist: artist, album: album, durationMs: durationMs) }

    /// `SpotifySongEntity.toSong()` (iOS id prefix `sp:`; Android used `spotify_<id>`).
    public func toSong(idPrefix: String = "sp:") -> Song {
        Song(id: idPrefix + spotifyId, title: title, artist: artist, artistId: -1, album: album, albumId: -1, path: "",
             contentUriString: "spotify://\(spotifyId)", albumArtUriString: albumArtUrl, duration: durationMs,
             dateAdded: dateAdded, mimeType: nil, bitrate: nil, sampleRate: nil, spotifyId: spotifyId)
    }
}
