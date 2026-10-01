import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlNet

@Suite("Spotify auth (PKCE, rotation)")
struct SpotifyAuthTests {
    let sha256: SHA256Function = { TestSHA256.hash($0) }

    @Test func sha256TestImplementationIsCorrect() {
        #expect(hexString(TestSHA256.hash(Array("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hexString(TestSHA256.hash([])) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// RFC 7636 appendix B.
    @Test func pkceMatchesRFC7636() {
        #expect(SpotifyAuth.codeChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", sha256: sha256)
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let bytes: [UInt8] = [116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186, 22, 212, 37, 77, 105, 214,
                              191, 240, 91, 88, 5, 88, 83, 132, 141, 121]
        #expect(SpotifyAuth.codeVerifier(randomBytes: bytes) == "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let verifier = SpotifyAuth.codeVerifier(randomBytes: Array(0..<64))
        #expect(verifier == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0-Pw")
        #expect(verifier.count == 86)
        #expect(SpotifyAuth.state(randomBytes: Array(0..<64)) == "AAECAwQFBgcICQoLDA0ODxAR")
    }

    @Test func authorizationURLUsesAndroidEncodingAndForcesTheDialog() {
        let url = SpotifyAuth.authorizationURL(clientId: "cid", codeChallenge: "ch_-", state: "st")
        #expect(url == "https://accounts.spotify.com/authorize?client_id=cid&response_type=code&redirect_uri=pixlaudio%3A%2F%2Fspotify-callback"
                + "&code_challenge_method=S256&code_challenge=ch_-&scope=user-library-read%20playlist-read-private%20playlist-read-collaborative"
                + "%20user-read-private%20user-top-read&state=st&show_dialog=true")
        #expect(SpotifyAuth.scopes.contains("user-top-read"))
    }

    @Test func callbackValidation() {
        #expect(SpotifyAuth.isCallbackURL("pixlaudio://spotify-callback?code=1"))
        #expect(!SpotifyAuth.isCallbackURL("pixelplay://spotify-callback?code=1"))
        #expect(!SpotifyAuth.isCallbackURL("pixlaudio://other?code=1"))
        #expect(SpotifyAuth.validateCallback("pixlaudio://spotify-callback?error=access_denied&state=s", expectedState: "s") == .providerError("access_denied"))
        #expect(SpotifyAuth.validateCallback("pixlaudio://spotify-callback?code=c&state=x", expectedState: "s") == .stateMismatch)
        #expect(SpotifyAuth.validateCallback("pixlaudio://spotify-callback?code=c&state=s", expectedState: nil) == .stateMismatch)
        #expect(SpotifyAuth.validateCallback("pixlaudio://spotify-callback?state=s&code=", expectedState: "s") == .missingCode)
        #expect(SpotifyAuth.validateCallback("pixlaudio://spotify-callback?state=s&code=AQ%2Bx", expectedState: "s") == .code("AQ+x"))
    }

    @Test func tokenRequestsAreFormEncoded() {
        let exchange = SpotifyAuth.exchangeCodeRequest(code: "AQ c", clientId: "cid", codeVerifier: "v-_")
        #expect(exchange.url == "https://accounts.spotify.com/api/token" && exchange.method == .post)
        #expect(exchange.bodyText == "grant_type=authorization_code&code=AQ+c&redirect_uri=pixlaudio%3A%2F%2Fspotify-callback&client_id=cid&code_verifier=v-_")
        #expect(exchange.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(SpotifyAuth.refreshRequest(refreshToken: "r/1", clientId: "cid").bodyText == "grant_type=refresh_token&refresh_token=r%2F1&client_id=cid")
    }

    @Test func rotatedRefreshTokenAlwaysWins() {
        let rotated = SpotifyAuth.tokens(from: SpotifyTokenResponse(accessToken: "A2", expiresIn: 3600, refreshToken: "R2", scope: "s"),
                                         previousRefreshToken: "R1", nowMs: 1000)
        #expect(rotated == SpotifyTokens(accessToken: "A2", refreshToken: "R2", expiresAtMs: 3_601_000, scope: "s"))
        let kept = SpotifyAuth.tokens(from: SpotifyTokenResponse(accessToken: "A2", refreshToken: " "), previousRefreshToken: "R1", nowMs: 0)
        #expect(kept?.refreshToken == "R1" && kept?.expiresAtMs == 3_600_000)
        #expect(SpotifyAuth.tokens(from: SpotifyTokenResponse(accessToken: ""), previousRefreshToken: "R1", nowMs: 0) == nil)
        #expect(SpotifyAuth.isAccessTokenValid(SpotifyTokens(accessToken: "a", refreshToken: nil, expiresAtMs: 400_000), nowMs: 99_999))
        #expect(!SpotifyAuth.isAccessTokenValid(SpotifyTokens(accessToken: "a", refreshToken: nil, expiresAtMs: 400_000), nowMs: 100_000))
        #expect(SpotifyTokens(accessToken: "a", refreshToken: nil, expiresAtMs: 0, scope: "user-library-read user-top-read").grants("user-top-read"))
    }

    actor MemoryStore: SpotifyTokenStore {
        var tokens: SpotifyTokens?
        var saves: [SpotifyTokens] = []
        var failSaves = false
        var events: Box<[String]>
        init(_ tokens: SpotifyTokens?, events: Box<[String]> = Box([])) {
            self.tokens = tokens
            self.events = events
        }
        func load() async -> SpotifyTokens? { tokens }
        func save(_ tokens: SpotifyTokens) async throws {
            if failSaves { throw CancellationError() }
            events.mutate { $0.append("save:\(tokens.refreshToken ?? "-")") }
            saves.append(tokens)
            self.tokens = tokens
        }
        func clear() async { tokens = nil }
        func setFailing() { failSaves = true }
    }

    @Test func refreshPersistsTheRotatedTokenBeforeHandingOutTheAccessToken() async throws {
        let events = Box<[String]>([])
        let store = MemoryStore(SpotifyTokens(accessToken: "A1", refreshToken: "R1", expiresAtMs: 0), events: events)
        let http = FixtureHTTPClient { request in
            events.mutate { $0.append("http:\(request.bodyText!)") }
            return HTTPResponse(statusCode: 200, text: #"{"access_token":"A2","token_type":"Bearer","expires_in":3600,"refresh_token":"R2","scope":"x"}"#)
        }
        let session = SpotifySession(http: http, store: store, clientId: { "cid" }, sha256: sha256, randomBytes: { Array(repeating: 1, count: $0) },
                                     nowMs: { 10_000 })
        #expect(await session.authorizationHeader() == "Bearer A2")
        #expect(events.value == ["http:grant_type=refresh_token&refresh_token=R1&client_id=cid", "save:R2"])
        #expect(await store.tokens?.refreshToken == "R2")
        #expect(await session.validAccessToken() == "A2")
        #expect(http.requests.count == 1)
        // The next refresh uses the rotated token.
        _ = await session.forceRefresh()
        #expect(http.requests[1].bodyText == "grant_type=refresh_token&refresh_token=R2&client_id=cid")
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let store = MemoryStore(SpotifyTokens(accessToken: "A1", refreshToken: "R1", expiresAtMs: 0))
        let http = FixtureHTTPClient { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            return HTTPResponse(statusCode: 200, text: #"{"access_token":"A2","refresh_token":"R2"}"#)
        }
        let session = SpotifySession(http: http, store: store, clientId: { "cid" }, sha256: sha256, randomBytes: { Array(repeating: 0, count: $0) })
        async let a = session.validAccessToken()
        async let b = session.validAccessToken()
        async let c = session.validAccessToken()
        let results = await [a, b, c]
        #expect(results == ["A2", "A2", "A2"])
        #expect(http.requests.count == 1)
    }

    @Test func deadRefreshTokenClearsTheSessionAndFailedPersistenceIsReported() async throws {
        let store = MemoryStore(SpotifyTokens(accessToken: "A1", refreshToken: "R1", expiresAtMs: 0))
        let session = SpotifySession(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 400, text: #"{"error":"invalid_grant"}"#) },
                                     store: store, clientId: { "cid" }, sha256: sha256, randomBytes: { Array(repeating: 0, count: $0) })
        let result = await session.forceRefresh()
        #expect(result == .failure(SpotifyAuthError("Refresco de token fallido (HTTP 400)", statusCode: 400)))
        #expect(await store.tokens == nil)
        #expect(!(await session.isLoggedIn()))
        #expect(await session.validAccessToken() == nil)

        let failing = MemoryStore(SpotifyTokens(accessToken: "A1", refreshToken: "R1", expiresAtMs: 0))
        await failing.setFailing()
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: #"{"access_token":"A2","refresh_token":"R2"}"#) }
        let session2 = SpotifySession(http: http, store: failing, clientId: { "cid" }, sha256: sha256, randomBytes: { Array(repeating: 0, count: $0) })
        #expect(await session2.validAccessToken() == nil)
        #expect(await session2.lastError == "No se pudo guardar el refresh token rotado")
        // The rotated token is still remembered in memory for the next attempt.
        _ = await session2.forceRefresh()
        #expect(http.requests[1].bodyText!.contains("refresh_token=R2"))
        #expect(await SpotifySession(http: http, store: MemoryStore(nil), clientId: { "c" }, sha256: sha256, randomBytes: { Array(repeating: 0, count: $0) })
            .forceRefresh() == .failure(SpotifyAuthError("sin refresh token")))
    }

    @Test func fullSignInFlow() async throws {
        let store = MemoryStore(nil)
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: #"{"access_token":"A","expires_in":"3600","refresh_token":"R","scope":"user-top-read"}"#) }
        let session = SpotifySession(http: http, store: store, clientId: { "cid" }, sha256: sha256, randomBytes: { Array(0..<UInt8($0)) }, nowMs: { 0 })
        let pending = try #require(await session.beginAuthorization())
        #expect(pending.codeVerifier.count == 86 && pending.state.count == 24)
        #expect(pending.url.contains("code_challenge=\(SpotifyAuth.codeChallenge(verifier: pending.codeVerifier, sha256: sha256))"))
        let bad = await session.handleCallback("pixlaudio://spotify-callback?code=c&state=wrong")
        #expect(bad == .failure(SpotifyAuthError("state no coincide")))
        #expect(await session.lastError == "Respuesta de login no válida")
        let ok = await session.handleCallback("pixlaudio://spotify-callback?code=CODE&state=\(pending.state)")
        #expect(try ok.get() == SpotifyTokens(accessToken: "A", refreshToken: "R", expiresAtMs: 3_600_000, scope: "user-top-read"))
        #expect(http.requests[0].bodyText!.contains("code=CODE") && http.requests[0].bodyText!.contains("code_verifier=\(pending.codeVerifier)"))
        #expect(await store.tokens?.refreshToken == "R")
        #expect(await session.isLoggedIn())
        #expect(await session.handleCallback("pixlaudio://spotify-callback?code=x&state=\(pending.state)") == .failure(SpotifyAuthError("state no coincide")))

        let noClient = SpotifySession(http: http, store: store, clientId: { " " }, sha256: sha256, randomBytes: { Array(repeating: 0, count: $0) })
        #expect(await noClient.beginAuthorization() == nil)
        #expect(await noClient.lastError == "Falta el client ID de Spotify")
        let rejecting = SpotifySession(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 400, text: "{}") }, store: MemoryStore(nil),
                                       clientId: { "cid" }, sha256: sha256, randomBytes: { Array(repeating: 0, count: $0) })
        let p = try #require(await rejecting.beginAuthorization())
        #expect(await rejecting.handleCallback("pixlaudio://spotify-callback?code=c&state=\(p.state)")
                == .failure(SpotifyAuthError("Canje de código fallido (HTTP 400)", statusCode: 400)))
    }
}

@Suite("Spotify Web API")
struct SpotifyWebAPITests {
    @Test func endpointsMatchTheRetrofitService() {
        let auth = "Bearer T"
        #expect(SpotifyAPI.profile(authorization: auth).url == "https://api.spotify.com/v1/me")
        #expect(SpotifyAPI.profile(authorization: auth).header("Authorization") == "Bearer T")
        #expect(SpotifyAPI.savedTracks(authorization: auth).url == "https://api.spotify.com/v1/me/tracks?limit=50&offset=0")
        #expect(SpotifyAPI.userPlaylists(authorization: auth, offset: 50).url == "https://api.spotify.com/v1/me/playlists?limit=50&offset=50")
        #expect(SpotifyAPI.playlistTracks(authorization: auth, playlistId: "37i9", offset: 100).url
                == "https://api.spotify.com/v1/playlists/37i9/items?limit=100&offset=100&fields=total%2Cnext%2Citems%28added_at%2Citem%28id%2Cname%2Cduration_ms%2Cis_local%2Ctype%2Cartists%28id%2Cname%29%2Calbum%28id%2Cname%2Cimages%28url%2Cwidth%2Cheight%29%29%2Cexternal_ids%28isrc%29%29%29")
        #expect(SpotifyAPI.playlistTracks(authorization: auth, playlistId: "p", fields: nil).url == "https://api.spotify.com/v1/playlists/p/items?limit=100&offset=0")
        #expect(SpotifyAPI.search(authorization: auth, query: "daft punk+1").url == "https://api.spotify.com/v1/search?q=daft%20punk%2B1&type=track%2Cartist%2Calbum")
        #expect(SpotifyAPI.search(authorization: auth, query: "x", type: "track", limit: 5, market: "US", offset: 10).url
                == "https://api.spotify.com/v1/search?q=x&type=track&limit=5&market=US&offset=10")
        #expect(SpotifyAPI.artists(authorization: auth, ids: "a,b").url == "https://api.spotify.com/v1/artists?ids=a%2Cb")
        #expect(SpotifyAPI.artistTopTracks(authorization: auth, artistId: "id").url == "https://api.spotify.com/v1/artists/id/top-tracks?market=from_token")
        #expect(SpotifyAPI.artistAlbums(authorization: auth, artistId: "id").url
                == "https://api.spotify.com/v1/artists/id/albums?include_groups=album%2Csingle&limit=50&offset=0")
        #expect(SpotifyAPI.albumTracks(authorization: auth, albumId: "al").url == "https://api.spotify.com/v1/albums/al/tracks?limit=50&offset=0")
        #expect(SpotifyAPI.album(authorization: auth, albumId: "al").url == "https://api.spotify.com/v1/albums/al")
        #expect(SpotifyAPI.artist(authorization: auth, artistId: "a b").url == "https://api.spotify.com/v1/artists/a%20b")
        #expect(SpotifyAPI.myTopTracks(authorization: auth, timeRange: "short_term").url == "https://api.spotify.com/v1/me/top/tracks?time_range=short_term&limit=50&offset=0")
        #expect(SpotifyAPI.myTopArtists(authorization: auth).url == "https://api.spotify.com/v1/me/top/artists?time_range=medium_term&limit=50&offset=0")
    }

    @Test func callPolicy() {
        #expect(SpotifyCallPolicy.decision(statusCode: 200, retryAfter: nil) == .success)
        #expect(SpotifyCallPolicy.decision(statusCode: 401, retryAfter: nil) == .refreshAndRetry)
        #expect(SpotifyCallPolicy.decision(statusCode: 429, retryAfter: "7") == .waitAndRetry(ms: 7000))
        #expect(SpotifyCallPolicy.decision(statusCode: 429, retryAfter: nil) == .waitAndRetry(ms: 5000))
        #expect(SpotifyCallPolicy.decision(statusCode: 429, retryAfter: "0") == .waitAndRetry(ms: 1000))
        #expect(SpotifyCallPolicy.decision(statusCode: 429, retryAfter: "600") == .waitAndRetry(ms: 60_000))
        #expect(SpotifyCallPolicy.decision(statusCode: 429, retryAfter: "soon") == .waitAndRetry(ms: 5000))
        #expect(SpotifyCallPolicy.decision(statusCode: 403, retryAfter: nil) == .fail(forbidden: true))
        #expect(SpotifyCallPolicy.decision(statusCode: 500, retryAfter: nil) == .fail(forbidden: false))
        #expect(SpotifyCallPolicy.backoffMs(attempt: 2) == 1600)
    }

    actor Store: SpotifyTokenStore {
        var tokens: SpotifyTokens? = SpotifyTokens(accessToken: "A1", refreshToken: "R1", expiresAtMs: Int64.max / 2)
        func load() async -> SpotifyTokens? { tokens }
        func save(_ tokens: SpotifyTokens) async throws { self.tokens = tokens }
        func clear() async { tokens = nil }
    }

    func makeAPI(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) -> (SpotifyWebAPI, FixtureHTTPClient, Box<[Int64]>) {
        let http = FixtureHTTPClient(handler)
        let session = SpotifySession(http: http, store: Store(), clientId: { "cid" }, sha256: { TestSHA256.hash($0) },
                                     randomBytes: { Array(repeating: 0, count: $0) }, nowMs: { 0 })
        let sleeps = Box<[Int64]>([])
        let api = SpotifyWebAPI(http: http, session: session, nowMs: { 0 }, sleep: { ms in sleeps.mutate { $0.append(ms) } })
        return (api, http, sleeps)
    }

    @Test func callRetriesAfter401And429AndGivesUpOnErrors() async throws {
        let replies = Box([401, 429, 200])
        let (api, http, sleeps) = makeAPI { request in
            if request.url.hasPrefix("https://accounts.spotify.com") { return HTTPResponse(statusCode: 200, text: #"{"access_token":"A2","refresh_token":"R2"}"#) }
            var code = 0
            replies.mutate { code = $0.removeFirst() }
            return HTTPResponse(statusCode: code, headers: [HTTPHeader("Retry-After", "3")], text: #"{"id":"me","display_name":"Hoa"}"#)
        }
        let profile = try await api.call(build: { SpotifyAPI.profile(authorization: $0) }, decode: SpotifyUserProfile.init(json:))
        #expect(profile?.displayName == "Hoa")
        let apiCalls = http.requests.filter { $0.url.hasPrefix("https://api.spotify.com") }
        #expect(apiCalls.map { $0.header("Authorization")! } == ["Bearer A1", "Bearer A2", "Bearer A2"])
        #expect(sleeps.value.contains(3000) && sleeps.value.contains(120))

        let forbidden = Box(false)
        let (api2, _, _) = makeAPI { _ in HTTPResponse(statusCode: 403, text: #"{"error":{"status":403,"message":"Insufficient client scope"}}"#) }
        let result = try await api2.call("me", onForbidden: { forbidden.value = true }, build: { SpotifyAPI.profile(authorization: $0) },
                                         decode: SpotifyUserProfile.init(json:))
        #expect(result == nil && forbidden.value)
        #expect(await api2.lastFailure == #"[me] Spotify respondió HTTP 403 — {"error":{"status":403,"message":"Insufficient client scope"}}"#)

        let (api3, http3, sleeps3) = makeAPI { _ in throw HTTPTransportError(message: "reset") }
        #expect(try await api3.call(build: { SpotifyAPI.profile(authorization: $0) }, decode: SpotifyUserProfile.init(json:)) == nil)
        #expect(http3.requests.count == 3 && sleeps3.value.filter { $0 >= 800 } == [800, 1600])
    }

    @Test func catalogSearchPagesWithOffsetsAndFallsBackToMarket() async throws {
        let (api, http, _) = makeAPI { request in
            if request.url.contains("offset=10") {
                return HTTPResponse(statusCode: 200, text: #"{"tracks":{"items":[{"id":"t3","name":"c"}],"next":null},"artists":{"items":[],"next":null},"albums":{"items":[],"next":null}}"#)
            }
            if request.url.contains("offset=5") {
                return HTTPResponse(statusCode: 200, text: #"{"tracks":{"items":[{"id":"t2","name":"b"},{"id":"t1","name":"dup"}],"next":"n"},"artists":{"items":[],"next":null}}"#)
            }
            return HTTPResponse(statusCode: 200, text: #"{"tracks":{"items":[{"id":"t1","name":"a"},{"id":null,"name":"local"}],"next":"n"},"artists":{"items":[{"id":"ar1","name":"A"}],"next":null},"albums":{"items":[{"id":"al1","name":"X","album_group":"album"}],"next":null}}"#)
        }
        let results = try await api.searchCatalog(query: "daft")
        #expect(results.tracks.map(\.id) == ["t1", "t2", "t3"] && results.tracks[0].name == "a")
        #expect(results.artists.map(\.id) == ["ar1"] && results.albums.map(\.albumGroup) == ["album"])
        #expect(http.requests.map(\.url).filter { $0.contains("/v1/search") }.map { $0.contains("offset=") }  == [false, true, true])
        #expect(try await api.searchCatalog(query: " ").isEmpty)

        let (fallback, fbHTTP, _) = makeAPI { request in
            request.url.contains("market=US") ? HTTPResponse(statusCode: 200, text: #"{"tracks":{"items":[{"id":"m1"}],"next":null}}"#)
                                              : HTTPResponse(statusCode: 400, text: "Invalid limit")
        }
        #expect(try await fallback.searchCatalog(query: "x").tracks.map(\.id) == ["m1"])
        #expect(fbHTTP.requests.last?.url == "https://api.spotify.com/v1/search?q=x&type=track%2Cartist%2Calbum&market=US")
    }

    @Test func snapshotPaginationGuard() throws {
        #expect(try SpotifyLibrary.nextSnapshotOffset(current: 0, reportedOffset: 0, reportedLimit: 50, count: 50, next: "https://x?offset=50&limit=50", total: 120) == 50)
        #expect(try SpotifyLibrary.nextSnapshotOffset(current: 0, reportedOffset: nil, reportedLimit: 50, count: 20, next: "https://x?limit=50", total: nil) == 50)
        #expect(try SpotifyLibrary.nextSnapshotOffset(current: 0, reportedOffset: nil, reportedLimit: 0, count: 20, next: "https://x", total: nil) == 20)
        #expect(try SpotifyLibrary.nextSnapshotOffset(current: 100, reportedOffset: 100, reportedLimit: 50, count: 20, next: nil, total: 120) == nil)
        #expect(try SpotifyLibrary.nextSnapshotOffset(current: 0, reportedOffset: nil, reportedLimit: nil, count: 3, next: " ", total: nil) == nil)
        func failure(_ body: () throws -> Int?) -> String? {
            do { _ = try body(); return nil } catch { return (error as? SpotifyPaginationError)?.message }
        }
        #expect(failure { try SpotifyLibrary.nextSnapshotOffset(current: 50, reportedOffset: 0, reportedLimit: 50, count: 50, next: "n", total: nil) }
                == "Spotify repeated or skipped a page; existing songs were kept")
        #expect(failure { try SpotifyLibrary.nextSnapshotOffset(current: 0, reportedOffset: 0, reportedLimit: 50, count: 10, next: nil, total: 30) }
                == "Spotify ended pagination before all entries arrived; existing songs were kept")
        #expect(failure { try SpotifyLibrary.nextSnapshotOffset(current: 0, reportedOffset: 0, reportedLimit: 50, count: 0, next: "n", total: nil) }
                == "Spotify returned an empty continuation page")
        #expect(failure { try SpotifyLibrary.nextSnapshotOffset(current: 100, reportedOffset: 100, reportedLimit: 50, count: 5, next: "https://x?offset=100", total: nil) }
                == "Spotify pagination did not advance")
        #expect(SpotifyLibrary.offsetParameter("https://x?a=1&offset=7&offset=9") == 7)
        #expect(SpotifyLibrary.offsetParameter("https://x?myoffset=7") == nil)
    }

    @Test func playlistItemsDecodeAndMapToRows() throws {
        let page = try #require(SpotifyTracksPage(json: try JSONParser().parse(try Fixtures.text("spotify-playlist-items", "json"))))
        #expect(page.total == 4 && page.items?.count == 5 && page.next?.contains("offset=100") == true)
        let items = page.items!
        let rows = items.compactMap { SpotifyLibrary.record(for: $0.resolvedTrack, playlistId: "pl", addedAt: $0.addedAt,
                                                            genreByArtistId: ["0gxyHStUsqpMadRV0Di1Qt": "dance pop"], nowMs: 42) }
        #expect(rows.count == 2)
        let rick = rows[0]
        #expect(rick.id == "pl_4uLU6hMCjMI75M1A2tKUQC" && rick.title == "Never Gonna Give You Up" && rick.artist == "Rick Astley")
        #expect(rick.album == "Whenever You Need Somebody" && rick.albumId == "6N9PS4QXF1D0OWPk0Sxtb4" && rick.durationMs == 213_573)
        #expect(rick.albumArtUrl == "https://i.scdn.co/image/large" && rick.isrc == "GBARL9300135" && rick.genre == "dance pop")
        #expect(rick.dateAdded == 1_710_074_096_000 && rick.matchState == .pending)
        let legacy = rows[1]
        #expect(legacy.title == "Unknown title" && legacy.artist == "Unknown Artist" && legacy.album == "Unknown Album" && legacy.durationMs == 1000)
        #expect(legacy.dateAdded == 1_710_108_000_123)
        let song = rick.toSong()
        #expect(song.id == "sp:4uLU6hMCjMI75M1A2tKUQC" && song.contentUriString == "spotify://4uLU6hMCjMI75M1A2tKUQC" && song.spotifyId == "4uLU6hMCjMI75M1A2tKUQC")
        #expect(song.artistId == -1 && song.duration == 213_573)
        #expect(rick.matchable == MatchableTrack(title: "Never Gonna Give You Up", artist: "Rick Astley", album: "Whenever You Need Somebody", durationMs: 213_573))
    }

    @Test func youTubeMusicResultsBecomeMatchedBrowseRows() {
        let result = YouTubeSearchResult(videoId: "dQw4w9WgXcQ", title: "Never Gonna Give You Up", artist: "", album: " ", durationSeconds: 213,
                                         thumbnailUrl: "https://thumb")
        let row = SpotifyLibrary.record(forYouTubeResult: result, sha256: { TestSHA256.hash($0) }, nowMs: 5)
        #expect(row.spotifyId == "5f6b0b4e201f2a7e66927a" && row.id == "spotify_browse_5f6b0b4e201f2a7e66927a")
        #expect(row.artist == "Unknown Artist" && row.album == "Unknown Album" && row.durationMs == 213_000)
        #expect(row.matchedVideoId == "dQw4w9WgXcQ" && row.matchScore == 1 && row.matchState == .matched && row.dateAdded == 5)
        #expect(CloudStreamSecurity.validateSpotifyTrackId(row.spotifyId))
    }

    @Test func instantParsing() {
        #expect(SpotifyLibrary.parseInstant("1970-01-01T00:00:00Z") == 0)
        #expect(SpotifyLibrary.parseInstant("2024-02-29T23:59:59.999Z") == 1_709_251_199_999)
        #expect(SpotifyLibrary.parseInstant("2024-03-11T00:00:00.123+02:00") == 1_710_108_000_123)
        #expect(SpotifyLibrary.parseInstant("1969-12-31T23:59:59Z") == -1000)
        #expect(SpotifyLibrary.parseInstant("2024-03-10") == nil)
        #expect(SpotifyLibrary.parseInstant("2024-13-10T00:00:00Z") == nil)
        #expect(SpotifyLibrary.parseInstant("2024-03-10T00:00:00") == nil)
        #expect(SpotifyLibrary.parseAddedAt(nil, nowMs: 9) == 9 && SpotifyLibrary.parseAddedAt("bad", nowMs: 9) == 9)
    }

    @Test func modelsDecodeLeniently() throws {
        let artist = try #require(SpotifyArtistFull(json: try JSONParser().parse(#"{"id":"a","name":"N","genres":["x",1],"popularity":"50","followers":{"total":12}}"#)))
        #expect(artist.genres == ["x", "1"] && artist.popularity == 50 && artist.followers == 12)
        let batch = try #require(SpotifyArtistsBatchResponse(json: try JSONParser().parse(#"{"artists":[null,{"id":"b"}]}"#)))
        #expect(batch.artists?.count == 2 && batch.artists?[0] == nil && batch.artists?[1]?.id == "b")
        let playlists = try #require(SpotifyPlaylistsPage(json: try JSONParser().parse(#"{"items":[{"id":"p","name":"P","tracks":{"total":3},"owner":{"id":"o","display_name":"Own"},"public":"true","collaborative":false}],"next":null}"#)))
        let p = try #require(playlists.items?.first)
        #expect(p.trackTotal == 3 && p.ownerDisplayName == "Own" && p.isPublic == true && p.collaborative == false)
        let top = try #require(SpotifyTopTracksResponse(json: try JSONParser().parse(#"{"tracks":[{"id":"t","duration_ms":1.0e3}]}"#)))
        #expect(top.tracks?.first?.durationMs == 1000)
        let token = try #require(SpotifyTokenResponse(json: try JSONParser().parse(#"{"access_token":"a","expires_in":3600.0}"#)))
        #expect(token.expiresIn == 3600 && token.refreshToken == nil)
        #expect(SpotifyUserProfile(json: try JSONParser().parse("[]")) == nil)
    }

    @Test func unifiedIdBandsAndPlaylistIds() {
        #expect(SpotifyLibrary.unifiedSongId("4uLU6hMCjMI75M1A2tKUQC") < -3_000_000_000_000)
        #expect(SpotifyLibrary.unifiedSongId("4uLU6hMCjMI75M1A2tKUQC") > -4_000_000_000_000)
        #expect(SpotifyLibrary.unifiedAlbumId("x") <= -4_000_000_000_000 && SpotifyLibrary.unifiedArtistId("x") <= -5_000_000_000_000)
        #expect(SpotifyLibrary.appPlaylistId("abc") == "spotify_playlist:abc")
        #expect(SpotifyLibrary.likedSongsPlaylistId == "spotify_liked_songs" && SpotifyLibrary.browsePlaylistId == "spotify_browse")
    }
}
