// The networking half of the Android lyric sources: LRCLIB (`LrcLibApiService` + `LyricsRepositoryImpl`'s fetch
// paths, retries and rate limit), AMLL (`AmllLyricsSource`), NetEase (`NeteaseLyricsSource`), the bounded JSON reader
// (`LyricsHttp.kt`) and `findCatalogLyrics`. Matching, ranking and parsing are PixlLyrics' (wave A); this file only
// builds the requests, performs them through `HTTPClient` and feeds the decoded bodies in.

import Foundation
import PixlFoundation
import PixlModel
import PixlLyrics

/// Lyric request builders.
public enum LyricsRequests {
    public static let lrclibBaseURL = "https://lrclib.net/"
    /// The User-Agent sent to LRCLIB (Android's OkHttp interceptor sent "PixelPlayer/1.0 (Android; Music Player)").
    public static let lrclibUserAgent = "PixlAudio/1.0 (iOS; Music Player)"
    /// Per-request timeouts of the catalog clients (AMLL call timeout 8 s, NetEase 6 s on Android).
    public static let amllTimeoutSeconds: Double = 8
    public static let neteaseTimeoutSeconds: Double = 6

    /// `GET api/get?track_name&artist_name&album_name&duration` (seconds, truncated).
    public static func lrclibGet(song: Song, userAgent: String = lrclibUserAgent) -> HTTPRequest {
        let query: [(name: String, value: String?)] = [("track_name", song.title), ("artist_name", song.displayArtist),
                                                       ("album_name", song.album),
                                                       ("duration", String(Int32(truncatingIfNeeded: song.duration / 1000)))]
        return HTTPRequest(url: URLCoding.url(lrclibBaseURL + "api/get", query: query), headers: [HTTPHeader("User-Agent", userAgent)])
    }

    /// `GET api/search` with the strategy's parameters (nil ones omitted).
    public static func lrclibSearch(_ request: LrcLibSearchRequest, userAgent: String = lrclibUserAgent) -> HTTPRequest {
        HTTPRequest(url: URLCoding.url(lrclibBaseURL + "api/search", query: request.parameters.map { ($0.name, Optional($0.value)) }),
                    headers: [HTTPHeader("User-Agent", userAgent)])
    }

    /// An AMLL `GET https://api.amll.dev/v1/<path>?…`.
    public static func amll(_ path: String, _ parameters: [(name: String, value: String)]) -> HTTPRequest {
        HTTPRequest(url: URLCoding.url(AmllLyricsMatching.baseURL + path, query: parameters.map { ($0.name, Optional($0.value)) }),
                    headers: [HTTPHeader("User-Agent", LyricsHTTP.userAgent)], timeout: amllTimeoutSeconds)
    }

    /// A NetEase `GET https://music.163.com/api/<path>?…`.
    public static func netease(_ path: String, _ parameters: [(name: String, value: String)], baseURL: String = NeteaseLyricsMatching.baseURL) -> HTTPRequest {
        HTTPRequest(url: URLCoding.url(baseURL + path, query: parameters.map { ($0.name, Optional($0.value)) }),
                    headers: [HTTPHeader("User-Agent", LyricsHTTP.userAgent)], timeout: neteaseTimeoutSeconds)
    }

    /// `lyricsJson`: the bounded JSON object of a successful response (nil for failures, oversized or unbounded
    /// bodies); throws when the body is not an object.
    public static func catalogJSON(_ response: HTTPResponse) throws(LyricsCatalogError) -> JSONObject? {
        guard response.isSuccessful else { return nil }
        let declared = response.header("Content-Length").flatMap { Int64($0) }
        return try LyricsHTTP.decodeBody(Array(response.body), declaredContentLength: declared)
    }
}

/// An HTTP failure of an LRCLIB call (Retrofit `HttpException`).
public struct LyricsHTTPError: Error, Sendable, Hashable {
    public let statusCode: Int
}

/// `NetworkRetryUtils.withNetworkRetry`: retries transport errors and HTTP 429/5xx, doubling the delay.
public enum LyricsRetry {
    public static let attempts = 3
    public static let initialDelayMs: Int64 = 500

    public static func isRetryable(_ error: any Error) -> Bool {
        if let http = error as? LyricsHTTPError { return http.statusCode == 429 || http.statusCode >= 500 }
        return error is HTTPTransportError
    }

    public static func run<T: Sendable>(attempts: Int = attempts, initialDelayMs: Int64 = initialDelayMs,
                                        sleep: @Sendable (Int64) async throws -> Void,
                                        _ block: @Sendable () async throws -> T) async throws -> T {
        var delay = initialDelayMs
        var attempt = 0
        while true {
            do {
                return try await block()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                if !isRetryable(error) || attempt >= attempts { throw error }
                try await sleep(delay)
                delay *= 2
            }
        }
    }
}

/// LRCLIB over an `HTTPClient`.
public actor LrcLibClient {
    private let http: any HTTPClient
    private let userAgent: String
    private let romanization: any CJKRomanizationProvider
    private let nowMs: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private var rateLimiter = LyricsRateLimiter()

    public init(http: any HTTPClient, userAgent: String = LyricsRequests.lrclibUserAgent,
                romanization: any CJKRomanizationProvider = NoCJKRomanization(),
                nowMs: @escaping @Sendable () -> Int64 = { currentTimeMillis() },
                sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) }) {
        self.http = http
        self.userAgent = userAgent
        self.romanization = romanization
        self.nowMs = nowMs
        self.sleep = sleep
    }

    /// One `api/search` call with retries; throws on a final failure.
    public func search(_ request: LrcLibSearchRequest) async throws -> [LrcLibResponse] {
        let http = self.http, userAgent = self.userAgent
        return try await LyricsRetry.run(sleep: sleep) {
            let response = try await http.send(LyricsRequests.lrclibSearch(request, userAgent: userAgent))
            guard response.isSuccessful else { throw LyricsHTTPError(statusCode: response.statusCode) }
            guard let json = OrgJSON.parse(response.body), let list = LrcLibResponse.decodeList(json) else { return [] }
            return list
        }
    }

    /// `api/get` with retries (404 → nil).
    public func get(song: Song) async throws -> LrcLibResponse? {
        let http = self.http, userAgent = self.userAgent
        return try await LyricsRetry.run(sleep: sleep) {
            let response = try await http.send(LyricsRequests.lrclibGet(song: song, userAgent: userAgent))
            if response.statusCode == 404 { return nil }
            guard response.isSuccessful else { throw LyricsHTTPError(statusCode: response.statusCode) }
            return OrgJSON.parse(response.body).flatMap(LrcLibResponse.init(json:))
        }
    }

    /// `runSearchStrategiesFast`: every strategy in parallel; the first non-empty batch wins (others cancelled),
    /// de-duplicated by id. Failed strategies count as empty.
    public func runStrategiesFast(_ strategies: [LrcLibSearchRequest]) async -> [LrcLibResponse] {
        if strategies.isEmpty { return [] }
        return await withTaskGroup(of: [LrcLibResponse].self) { group in
            for strategy in strategies {
                group.addTask { (try? await self.search(strategy)) ?? [] }
            }
            for await batch in group where !batch.isEmpty {
                group.cancelAll()
                return LrcLibMatching.distinctById(batch)
            }
            return []
        }
    }

    private func applyRateLimit() async throws {
        let delay = rateLimiter.delayBeforeCall("lrclib", nowMs: nowMs())
        if delay > 0 { try await sleep(delay) }
        rateLimiter.recordCall("lrclib", timestampMs: nowMs())
    }

    /// `fetchLyricsFromAPI(song, skipDiskCache = true, includeAmll = false)`: rate limit, the automatic strategies,
    /// the aggressive title-only fallback, then the top-ranked parseable result.
    public func fetchAutomatic(song: Song) async throws -> LyricsSearchResult? {
        try await applyRateLimit()
        var results = await runStrategiesFast(LrcLibMatching.automaticSearchRequests(song: song, romanization: romanization))
        if results.isEmpty, let fallback = LrcLibMatching.automaticFallbackRequest(song: song) {
            if let fallbackResults = try? await search(fallback), !fallbackResults.isEmpty { results = fallbackResults }
        }
        if results.isEmpty { return nil }
        return LrcLibMatching.automaticResult(song: song, responses: results, romanization: romanization)
    }

    /// `searchRemote`: candidate-mode ranking of the fast strategies; nil when nothing usable was found.
    public func searchCandidates(song: Song) async -> (query: String, results: [LyricsSearchResult]) {
        let (query, strategies) = LrcLibMatching.candidateSearchRequests(song: song)
        let responses = await runStrategiesFast(strategies)
        if responses.isEmpty { return (query, []) }
        return (query, LrcLibMatching.candidateResults(song: song, responses: responses, romanization: romanization))
    }

    /// `searchRemoteByQuery`: unranked, synced first.
    public func searchManual(title: String, artist: String?) async -> (query: String, results: [LyricsSearchResult]) {
        let (query, strategies) = LrcLibMatching.manualSearchRequests(title: title, artist: artist)
        let responses = await runStrategiesFast(strategies)
        return (query, LrcLibMatching.manualResults(responses: responses, romanization: romanization))
    }

    /// `fetchFromRemote` (after the stored-lyrics check, which is the app's): the best candidate, else the exact
    /// `api/get` match when it ranks automatically.
    public func fetchFromRemote(song: Song) async throws -> LyricsSearchResult? {
        let candidates = await searchCandidates(song: song)
        if let best = candidates.results.first { return best }
        return LrcLibMatching.exactMatchResult(song: song, response: try await get(song: song), romanization: romanization)
    }
}

/// `AmllLyricsSource`.
public struct AmllLyricsClient: Sendable {
    public let http: any HTTPClient
    public let romanization: any CJKRomanizationProvider

    public init(http: any HTTPClient, romanization: any CJKRomanizationProvider = NoCJKRomanization()) {
        self.http = http
        self.romanization = romanization
    }

    private func get(_ path: String, _ parameters: [(name: String, value: String)]) async throws -> JSONObject? {
        try Task.checkCancellation()
        let response = try await http.send(LyricsRequests.amll(path, parameters))
        guard let root = try LyricsRequests.catalogJSON(response) else { return nil }
        return try AmllLyricsMatching.data(from: root)
    }

    /// The direct Spotify-id lookup, then a metadata search that must match exactly one item (title, artist and
    /// album). Any failure ends the lookup with no lyrics.
    public func find(song: Song) async -> Lyrics? {
        do {
            if let id = AmllLyricsMatching.spotifyLookupId(song), let data = try await get("lyrics/get", [("spotifyId", id)]),
               let lyrics = try AmllLyricsMatching.lyrics(fromSpotifyLookup: data, song: song, spotifyId: id) {
                return lyrics
            }
            guard let parameters = AmllLyricsMatching.searchParameters(song: song),
                  let searchData = try await get("lyrics/search", parameters),
                  let id = try AmllLyricsMatching.matchingId(searchData: searchData, song: song),
                  let data = try await get("lyrics/get", [("id", id)]) else { return nil }
            return try AmllLyricsMatching.lyrics(from: data, song: song, romanization: romanization)
        } catch {
            return nil
        }
    }
}

/// `NeteaseLyricsSource`.
public struct NeteaseLyricsClient: Sendable {
    public static let overallTimeoutSeconds: Double = 10

    public let http: any HTTPClient
    public let baseURL: String

    public init(http: any HTTPClient, baseURL: String = NeteaseLyricsMatching.baseURL) {
        self.http = http
        self.baseURL = baseURL
    }

    private func get(_ path: String, _ parameters: [(name: String, value: String)]) async throws -> JSONObject? {
        let response = try await http.send(LyricsRequests.netease(path, parameters, baseURL: baseURL))
        guard let json = try LyricsRequests.catalogJSON(response), try NeteaseLyricsMatching.isSuccess(json) else { return nil }
        return json
    }

    /// Search, keep matching recordings (closest duration first, at most two), and take the first word-timed YRC
    /// that fits the song. 10 s overall.
    public func find(song: Song) async -> Lyrics? {
        let client = self
        let found = try? await withTimeout(seconds: Self.overallTimeoutSeconds) { () async -> Lyrics? in
            do {
                guard let parameters = NeteaseLyricsMatching.searchParameters(song: song),
                      let search = try await client.get("search/get", parameters),
                      let candidates = try NeteaseLyricsMatching.candidateTracks(searchResponse: search, song: song) else { return nil }
                for track in candidates {
                    guard let data = try await client.get("song/lyric/v1", NeteaseLyricsMatching.lyricParameters(trackId: try NeteaseLyricsMatching.trackId(track))),
                          let lyrics = try NeteaseLyricsMatching.lyrics(fromLyricResponse: data, song: song) else { continue }
                    return lyrics
                }
                return nil
            } catch {
                return nil
            }
        }
        return found ?? nil
    }
}

/// `findCatalogLyrics`: AMLL (10 s), NetEase and LRCLIB (12 s) concurrently, then PixlLyrics' choice
/// (word-synced, then line-synced, then anything, in that catalog order).
public struct LyricsCatalogSearch: Sendable {
    public static let amllTimeoutSeconds: Double = 10
    public static let lrclibTimeoutSeconds: Double = 12

    public let amll: AmllLyricsClient
    public let netease: NeteaseLyricsClient
    public let lrclib: LrcLibClient

    public init(amll: AmllLyricsClient, netease: NeteaseLyricsClient, lrclib: LrcLibClient) {
        self.amll = amll
        self.netease = netease
        self.lrclib = lrclib
    }

    public func find(song: Song, syncedOnly: Bool) async -> OnlineSyncedLyrics? {
        let amll = self.amll, netease = self.netease, lrclib = self.lrclib
        async let a: Lyrics?? = try? withTimeout(seconds: Self.amllTimeoutSeconds) { await amll.find(song: song) }
        async let n: Lyrics? = netease.find(song: song)
        async let l: LyricsSearchResult?? = try? withTimeout(seconds: Self.lrclibTimeoutSeconds) { try await lrclib.fetchAutomatic(song: song) }
        let amllLyrics = (await a) ?? nil
        let neteaseLyrics = await n
        let lrcResult = (await l) ?? nil
        var candidates: [OnlineSyncedLyrics] = []
        if let amllLyrics { candidates.append(OnlineSyncedLyrics(lyrics: amllLyrics, source: LyricsRepositoryLogic.amllSourceName)) }
        if let neteaseLyrics { candidates.append(OnlineSyncedLyrics(lyrics: neteaseLyrics, source: LyricsRepositoryLogic.neteaseSourceName)) }
        if let lrcResult { candidates.append(OnlineSyncedLyrics(lyrics: lrcResult.lyrics, source: LyricsRepositoryLogic.lrclibSourceName)) }
        return LyricsRepositoryLogic.chooseCatalogResult(candidates, syncedOnly: syncedOnly)
    }
}
