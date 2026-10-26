import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlNet

/// The automatic listening-history sync (spec B1): Spotify's recently played / top lists / followed artists, and the
/// YouTube Music history page (cookie only on WEB_REMIX).
@Suite("Listening history sync")
struct ListeningHistorySyncTests {
    actor Tokens: SpotifyTokenStore {
        var tokens: SpotifyTokens? = SpotifyTokens(accessToken: "t", refreshToken: "R", expiresAtMs: Int64.max / 2)
        func load() async -> SpotifyTokens? { tokens }
        func save(_ tokens: SpotifyTokens) async throws { self.tokens = tokens }
        func clear() async { tokens = nil }
    }

    private func client(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse)
        -> (SpotifyListeningHistoryClient, FixtureHTTPClient) {
        let http = FixtureHTTPClient(handler)
        let session = SpotifySession(http: http, store: Tokens(), clientId: { "cid" }, sha256: { TestSHA256.hash($0) },
                                     randomBytes: { Array(repeating: 0, count: $0) }, nowMs: { 0 })
        let api = SpotifyWebAPI(http: http, session: session, nowMs: { 0 }, sleep: { _ in })
        return (SpotifyListeningHistoryClient(api: api), http)
    }

    static let recent = #"{"items":[{"track":{"id":"0VjIjW4GlUZAMYd2vXMi3b","name":"Blinding Lights","duration_ms":200040,"type":"track","artists":[{"id":"a","name":"The Weeknd"},{"name":"Other"}],"album":{"name":"After Hours"}},"played_at":"2024-03-01T12:00:00.123Z"},{"track":{"id":"x","name":"Local","is_local":true},"played_at":"2024-03-01T11:00:00Z"},{"track":null,"played_at":"2024-03-01T10:00:00Z"}],"cursors":{"after":"1709294400123"}}"#

    @Test func scopesAndRequests() {
        #expect(SpotifyAuth.scopes.contains("user-read-recently-played") && SpotifyAuth.scopes.contains("user-follow-read"))
        #expect(SpotifyListeningHistoryClient.lacksScopes(granted: "user-top-read user-library-read"))
        #expect(!SpotifyListeningHistoryClient.lacksScopes(granted: "user-follow-read user-read-recently-played user-top-read"))
        #expect(!SpotifyListeningHistoryClient.lacksScopes(granted: nil))
        #expect(SpotifyAPI.recentlyPlayed(authorization: "B").url == "https://api.spotify.com/v1/me/player/recently-played?limit=50")
        #expect(SpotifyAPI.followedArtists(authorization: "B", after: "abc").url
                == "https://api.spotify.com/v1/me/following?type=artist&limit=50&after=abc")
    }

    @Test func recentlyPlayedItemsBecomePlays() throws {
        let json = try #require(OrgJSON.parse(Self.recent))
        let page = try #require(SpotifyRecentlyPlayedPage(json: json))
        let plays = page.items.compactMap(SpotifyListeningHistoryMapping.play)
        #expect(plays.count == 1)
        #expect(plays[0] == ImportedPlay(source: .spotifyAPI, timestampMs: 1_709_294_400_123, title: "Blinding Lights",
                                         artist: "The Weeknd", album: "After Hours", spotifyTrackId: "0VjIjW4GlUZAMYd2vXMi3b",
                                         durationMs: 200_040))
    }

    @Test func aSyncReadsPlaysTopListsAndFollowedArtists() async throws {
        let (client, http) = client { request in
            let url = request.url
            if url.contains("recently-played") { return HTTPResponse(statusCode: 200, text: Self.recent) }
            if url.contains("/top/tracks") {
                return HTTPResponse(statusCode: 200, text: #"{"items":[{"id":"t1","name":"Song One","artists":[{"name":"A1"}]}]}"#)
            }
            if url.contains("/top/artists") {
                return HTTPResponse(statusCode: 200, text: #"{"items":[{"id":"a1","name":"A1","genres":["pop"]}]}"#)
            }
            if url.contains("following") {
                if url.contains("after=f1") {
                    return HTTPResponse(statusCode: 200, text: #"{"artists":{"items":[{"id":"f2","name":"F2"}],"next":null,"cursors":{"after":null}}}"#)
                }
                return HTTPResponse(statusCode: 200, text: #"{"artists":{"items":[{"id":"f1","name":"F1"}],"next":"https://x","cursors":{"after":"f1"}}}"#)
            }
            return HTTPResponse(statusCode: 404, text: "")
        }
        let fetch = try await client.fetch(nowMs: 42)
        #expect(fetch.plays.count == 1 && !fetch.needsReconnect)
        let taste = try #require(fetch.taste)
        #expect(taste.fetchedAtMs == 42)
        #expect(taste.topTracks.count == 3 && taste.topTracks.map(\.range) == [.shortTerm, .mediumTerm, .longTerm])
        #expect(taste.topTracks[0] == .init(range: .shortTerm, rank: 0, title: "Song One", artist: "A1", spotifyTrackId: "t1"))
        #expect(taste.topArtists.count == 3 && taste.topArtists[0].genres == ["pop"])
        #expect(taste.followedArtists == ["F1", "F2"])
        #expect(http.requests.filter { $0.url.contains("time_range=long_term") }.count == 2)
    }

    @Test func aMissingScopeAsksForAReconnectAndKeepsTheRest() async throws {
        let (client, _) = client { request in
            if request.url.contains("recently-played") || request.url.contains("following") {
                return HTTPResponse(statusCode: 403, text: #"{"error":{"status":403,"message":"Insufficient client scope"}}"#)
            }
            return HTTPResponse(statusCode: 200, text: #"{"items":[]}"#)
        }
        let fetch = try await client.fetch(nowMs: 1)
        #expect(fetch.recentlyPlayedDenied && fetch.followedDenied && fetch.needsReconnect)
        #expect(fetch.plays.isEmpty)
        // The top lists still arrived (empty here); the followed artists did not, so they are not replaced.
        #expect(fetch.taste != nil && fetch.taste?.followedArtists == [])
    }

    // MARK: YouTube Music

    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func historyPageParsesSectionsAndTheContinuation() throws {
        let text = try fixture("ytmusic-history")
        let json = try #require(OrgJSON.parse(text)?.objectValue)
        let parsed = YouTubeMusicHistoryParsing.entries(json)
        #expect(parsed.entries.map(\.section) == ["Today", "Today", "Last week"])
        #expect(parsed.entries.map(\.item.videoId) == ["5NV6Rdv1a3I", "4NRXx6U8ABQ", "FGBhQbmPwH8"])
        #expect(parsed.entries[0].item.artist == "Daft Punk" && parsed.entries[0].item.album == "Random Access Memories")
        #expect(parsed.continuation == "NEXT_TOKEN")
        let utc = TimeZone(identifier: "UTC")!
        let now: Int64 = 1_709_294_400_000 // 2024-03-01T12:00Z
        let plays = YouTubeMusicHistoryParsing.plays(parsed.entries, nowMs: now, timeZone: utc)
        #expect(plays.map(\.timestampMs) == [now, now - 60_000, now - 10 * 86_400_000])
        #expect(plays.allSatisfy { $0.source == .ytmusic } && plays[0].durationMs == 370_000)
    }

    @Test func sectionTimes() {
        let utc = TimeZone(identifier: "UTC")!
        let day: Int64 = 86_400_000
        let now: Int64 = 1_709_294_400_000 // 2024-03-01T12:00Z
        #expect(YouTubeMusicHistoryParsing.sectionTime("Yesterday", nowMs: now, timeZone: utc) == now - day)
        #expect(YouTubeMusicHistoryParsing.sectionTime("This week", nowMs: now, timeZone: utc) == now - 3 * day)
        // 2024-01-15T12:00Z
        #expect(YouTubeMusicHistoryParsing.sectionTime("January 2024", nowMs: now, timeZone: utc) == 1_705_320_000_000)
        #expect(YouTubeMusicHistoryParsing.sectionTime("January", nowMs: now, timeZone: utc) == 1_705_320_000_000)
        // A bare month later than now is last year's: 2023-12-15T12:00Z.
        #expect(YouTubeMusicHistoryParsing.sectionTime("December", nowMs: now, timeZone: utc) == 1_702_641_600_000)
        #expect(YouTubeMusicHistoryParsing.sectionTime("Something else", nowMs: now, timeZone: utc) == now - 30 * day)
    }

    struct Session: YouTubeSessionProviding {
        let cookieValue: String?
        func cookie() async -> String? { cookieValue }
        func storedVisitorData() async -> String { "VD" }
        func anonymousVisitorData() async -> String? { "ANON" }
        func nowSeconds() -> Int64 { 1_000 }
    }

    @Test func historyGoesToWebRemixWithTheCookieAndFollowsTheContinuation() async throws {
        let page = try fixture("ytmusic-history")
        let http = FixtureHTTPClient { request in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            return body.contains("NEXT_TOKEN") ? HTTPResponse(statusCode: 200, text: #"{"continuationContents":{}}"#)
                                               : HTTPResponse(statusCode: 200, text: page)
        }
        let client = YouTubeMusicHistoryClient(http: http, session: Session(cookieValue: "SAPISID=abc; SID=x"))
        let plays = try #require(await client.fetchPlays(nowMs: 1_709_294_400_000, timeZone: TimeZone(identifier: "UTC")!))
        #expect(plays.count == 3)
        let requests = http.requests
        #expect(requests.count == 2)
        let first = requests[0]
        #expect(first.url.hasPrefix("https://music.youtube.com/youtubei/v1/browse"))
        #expect(first.header("cookie") == "SAPISID=abc; SID=x")
        #expect(first.header("Authorization")?.hasPrefix("SAPISIDHASH 1000_") == true)
        #expect(first.header("X-YouTube-Client-Name") == "67")
        let body = String(decoding: first.body ?? Data(), as: UTF8.self)
        #expect(body.contains("\"browseId\":\"FEmusic_history\"") && body.contains("\"clientName\":\"WEB_REMIX\""))
        #expect(body.contains("\"visitorData\":\"VD\""))
    }

    @Test func noCookieNoRequest() async {
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: "{}") }
        let client = YouTubeMusicHistoryClient(http: http, session: Session(cookieValue: nil))
        #expect(await client.fetchPlays(nowMs: 0, timeZone: .current) == nil)
        #expect(http.requests.isEmpty)
        let refused = YouTubeMusicHistoryClient(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 401, text: "") },
                                                session: Session(cookieValue: "SAPISID=a"))
        #expect(await refused.fetchPlays(nowMs: 0, timeZone: .current) == nil)
    }
}
