// The networking half of `InnerTubeClient.kt`: YouTube Music search and the `player` call, over an injected
// `HTTPClient`. Two invariants from the Android client hold here:
// - the cookie is only ever sent to clients that accept it (`supportsCookies`) — the native clients answer 400;
// - a visitorData is always sent, anonymous requests included (otherwise LOGIN_REQUIRED "not a bot").

import Foundation
import PixlFoundation

/// What the InnerTube client needs from the app's YouTube session (`YouTubeAuthManager` +
/// `PixelPlayPoTokenProvider` on Android).
public protocol YouTubeSessionProviding: Sendable {
    /// The signed-in music.youtube.com cookie, or nil.
    func cookie() async -> String?
    /// The visitorData captured at sign-in (or the InnerTune placeholder).
    func storedVisitorData() async -> String
    /// A fresh anonymous visitorData (fetched once per process), or nil when unavailable.
    func anonymousVisitorData() async -> String?
    /// A WEB_REMIX PoToken for an authenticated request (BotGuard via WebView), or nil.
    func webClientPoToken(videoId: String) async -> PoTokenResult?
    /// Seconds since the epoch, for SAPISIDHASH.
    func nowSeconds() -> Int64
}

extension YouTubeSessionProviding {
    public func webClientPoToken(videoId: String) async -> PoTokenResult? { nil }
    public func nowSeconds() -> Int64 { Int64(Date().timeIntervalSince1970) }
}

/// An anonymous session (no cookie, the placeholder visitorData) with an optional fresh visitorData source.
public struct AnonymousYouTubeSession: YouTubeSessionProviding {
    public let visitorData: VisitorDataProvider?

    public init(visitorData: VisitorDataProvider? = nil) {
        self.visitorData = visitorData
    }

    public func cookie() async -> String? { nil }
    public func storedVisitorData() async -> String { YouTubeCookieAuth.defaultVisitorData }
    public func anonymousVisitorData() async -> String? { await visitorData?.visitorData() }
}

/// InnerTube failures surfaced to callers that asked to throw (search).
public struct InnerTubeError: Error, Sendable, Hashable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Fetches a fresh anonymous visitorData once per process (`anonymousVisitorData`), from `visitor_id`.
public actor VisitorDataProvider {
    private let http: any HTTPClient
    private var cached: String?
    private var inFlight: Task<String?, Never>?

    public init(http: any HTTPClient) {
        self.http = http
    }

    /// The cached value, fetching it on first use (failures are not cached).
    public func visitorData() async -> String? {
        if let cached { return cached }
        if let inFlight { return await inFlight.value }
        let http = self.http
        let task = Task<String?, Never> {
            let request = InnerTubeRequests.post(path: "visitor_id", body: InnerTubeRequests.visitorIdBody(),
                                                 profile: InnerTubeContexts.web)
            guard let response = try? await http.send(request), response.isSuccessful,
                  let json = OrgJSON.parse(response.body)?.objectValue else { return nil }
            return InnerTubeParsing.visitorData(json)
        }
        inFlight = task
        let value = await task.value
        inFlight = nil
        if let value { cached = value }
        return value
    }
}

/// `InnerTubeClient`.
public actor InnerTubeClient: YouTubeMusicSearching {
    private let http: any HTTPClient
    private let session: any YouTubeSessionProviding
    /// Why the last request failed, for the diagnostics report.
    public private(set) var lastFailureReason: String?

    public init(http: any HTTPClient, session: any YouTubeSessionProviding) {
        self.http = http
        self.session = session
    }

    // MARK: Search

    public func searchSongs(_ query: String, limit: Int = 10) async throws -> [YouTubeSearchResult] {
        try await searchFiltered(query, limit: limit, params: InnerTubeContexts.songsSearchParams, isVideo: false)
    }

    /// Music videos stay audio-only during playback.
    public func searchVideos(_ query: String, limit: Int = 10) async throws -> [YouTubeSearchResult] {
        try await searchFiltered(query, limit: limit, params: InnerTubeContexts.videosSearchParams, isVideo: true)
    }

    /// `searchMusic`: songs and videos interleaved (one failed shelf never discards the other).
    public func searchMusic(_ query: String, limit: Int = 12, includeVideos: Bool = true) async throws -> [YouTubeSearchResult] {
        if !includeVideos { return try await searchSongs(query, limit: limit) }
        var failure: (any Error)?
        var songs: [YouTubeSearchResult] = []
        var videos: [YouTubeSearchResult] = []
        do { songs = try await searchSongs(query, limit: limit) } catch is CancellationError { throw CancellationError() } catch { failure = error }
        do { videos = try await searchVideos(query, limit: limit) } catch is CancellationError { throw CancellationError() } catch { failure = error }
        if songs.isEmpty && videos.isEmpty, let failure { throw failure }
        return Self.interleave(songs: songs, videos: videos, limit: limit)
    }

    /// The `searchMusic` merge: alternate song/video by index, first occurrence of a video id wins, at most
    /// `limit` (1…50).
    public static func interleave(songs: [YouTubeSearchResult], videos: [YouTubeSearchResult], limit: Int) -> [YouTubeSearchResult] {
        var seen = Set<String>()
        var out: [YouTubeSearchResult] = []
        for index in 0..<max(songs.count, videos.count) {
            if index < songs.count, seen.insert(songs[index].videoId).inserted { out.append(songs[index]) }
            if index < videos.count, seen.insert(videos[index].videoId).inserted { out.append(videos[index]) }
        }
        return Array(out.prefix(min(max(limit, 1), 50)))
    }

    private func searchFiltered(_ query: String, limit: Int, params: String, isVideo: Bool) async throws -> [YouTubeSearchResult] {
        if NetText.isBlank(query) || limit <= 0 { return [] }
        let profile = InnerTubeContexts.searchProfile
        let anonymous = await session.anonymousVisitorData()
        let visitorData: String
        if let anonymous { visitorData = anonymous } else { visitorData = await session.storedVisitorData() }
        let body = InnerTubeRequests.searchBody(query: query, params: params, visitorData: visitorData, profile: profile)
        // A transport/API error differs from an empty search: it propagates so matching retries later.
        guard let json = try await post(path: "search", body: body, profile: profile, throwOnFailure: true) else {
            throw InnerTubeError("YouTube search returned no response")
        }
        switch InnerTubeParsing.searchResults(json, limit: limit, isVideo: isVideo) {
        case .results(let results): return results
        case .notAResultsPage: throw InnerTubeError("YouTube search response did not contain a results page")
        }
    }

    // MARK: Player

    /// `fetchPlayer(videoId, profile)`: nil when the request failed (see `lastFailureReason`).
    public func fetchPlayer(videoId: String, profile: InnerTubeClientProfile) async throws -> YouTubePlayerResponse? {
        // Only clients in yt-dlp's SUPPORTS_COOKIES get the cookie; the native ones are spoken to anonymously.
        let sessionCookie = await session.cookie()
        let cookie = profile.supportsCookies ? sessionCookie : nil
        // WEB_REMIX is the only profile a real PoToken can be generated for; it is tied to its own visitorData.
        var poToken: PoTokenResult?
        if cookie != nil && profile == InnerTubeContexts.webRemix {
            poToken = await session.webClientPoToken(videoId: videoId)
        }
        var visitorData = poToken?.visitorData
        if visitorData == nil { visitorData = await session.anonymousVisitorData() }
        if visitorData == nil { visitorData = await session.storedVisitorData() }

        let body = InnerTubeRequests.playerBody(videoId: videoId, profile: profile, visitorData: visitorData,
                                                authenticated: cookie != nil,
                                                playerRequestPoToken: poToken?.playerRequestPoToken)
        let origin = InnerTubeContexts.originFor(profile)
        let sapisid = cookie != nil
            ? YouTubeCookieAuth.sapisidHashAuthorization(cookie: cookie, origin: origin, timestampSeconds: session.nowSeconds())
            : nil
        guard let json = try await post(path: "player", body: body, profile: profile, cookie: cookie,
                                        sapisidAuthorization: sapisid, origin: origin) else { return nil }
        return InnerTubeParsing.playerResponse(json, streamingPoToken: poToken?.streamingDataPoToken)
    }

    // MARK: Transport

    private func post(path: String, body: JSONObject, profile: InnerTubeClientProfile, cookie: String? = nil,
                      sapisidAuthorization: String? = nil, origin: String? = nil,
                      throwOnFailure: Bool = false) async throws -> JSONObject? {
        let authenticated = cookie != nil && sapisidAuthorization != nil
        let request = InnerTubeRequests.post(path: path, body: body, profile: profile,
                                             cookie: authenticated ? cookie : nil,
                                             sapisidAuthorization: authenticated ? sapisidAuthorization : nil, origin: origin)
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let reason = Self.failureText(profile: profile, error: error)
            lastFailureReason = reason
            if throwOnFailure { throw InnerTubeError(reason) }
            return nil
        }
        if !response.isSuccessful {
            let reason = "\(profile.name) respondió HTTP \(response.statusCode)"
            lastFailureReason = reason
            if throwOnFailure { throw InnerTubeError(reason) }
            return nil
        }
        lastFailureReason = nil
        let text = response.text
        if NetText.isBlank(text) { return nil }
        guard let json = OrgJSON.parse(text)?.objectValue else {
            let reason = "\(profile.name): JSONException Value is not a JSON object"
            lastFailureReason = reason
            if throwOnFailure { throw InnerTubeError(reason) }
            return nil
        }
        return json
    }

    static func failureText(profile: InnerTubeClientProfile, error: any Error) -> String {
        if let transport = error as? HTTPTransportError {
            return NetText.trim("\(profile.name): \(transport.kind) \(transport.message)")
        }
        return NetText.trim("\(profile.name): \(error)")
    }
}
