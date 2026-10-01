import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

@Suite("InnerTube contexts, requests and parsing")
struct InnerTubeTests {
    @Test func visionOSLeadsAndCookieFlagsMatchYtDlp() {
        #expect(InnerTubeContexts.playerProfiles.map(\.name) == ["VISIONOS", "IOS", "TVHTML5", "WEB_REMIX"])
        #expect(InnerTubeContexts.playerProfiles.first?.requiresStreamingPoToken == false)
        #expect(InnerTubeContexts.visionOS.apiKey == nil && InnerTubeContexts.visionOS.expectsPreSignedUrls)
        for native in [InnerTubeContexts.visionOS, InnerTubeContexts.androidVR, InnerTubeContexts.iOS, InnerTubeContexts.androidMusic] {
            #expect(!native.supportsCookies, "\(native.name)")
        }
        for browser in [InnerTubeContexts.tvHTML5, InnerTubeContexts.web, InnerTubeContexts.webRemix] {
            #expect(browser.supportsCookies, "\(browser.name)")
        }
        #expect(InnerTubeContexts.searchProfile == InnerTubeContexts.webRemix)
        #expect(InnerTubeContexts.visionOS.userAgent.contains("Safari/605.1.15"))
        #expect(InnerTubeContexts.iOS.clientNameId == 5 && InnerTubeContexts.visionOS.clientNameId == 101)
        #expect(InnerTubeContexts.allProfiles.count == 7)
    }

    @Test func endpointsHeadersAndOrigins() {
        #expect(InnerTubeContexts.endpoint(InnerTubeContexts.visionOS, "player") == "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
        #expect(InnerTubeContexts.endpoint(InnerTubeContexts.iOS, "player")
                == "https://www.youtube.com/youtubei/v1/player?key=AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc&prettyPrint=false")
        #expect(InnerTubeContexts.endpoint(InnerTubeContexts.iOS, "player", includeKey: false) == "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
        #expect(InnerTubeContexts.endpoint(InnerTubeContexts.webRemix, "search").hasPrefix("https://music.youtube.com/youtubei/v1/search?key="))
        #expect(InnerTubeContexts.originFor(InnerTubeContexts.webRemix) == "https://music.youtube.com")
        #expect(InnerTubeContexts.originFor(InnerTubeContexts.tvHTML5) == "https://www.youtube.com")
        let headers = InnerTubeContexts.headers(InnerTubeContexts.iOS)
        #expect(headers.map(\.name) == ["User-Agent", "Content-Type", "Accept-Language", "X-YouTube-Client-Name", "X-YouTube-Client-Version", "Origin"])
        #expect(headers[3].value == "5" && headers[4].value == "21.26.4")
        #expect(InnerTubeContexts.streamHeaders(userAgent: "UA") == [HTTPHeader("User-Agent", "UA")])
    }

    @Test func playerBodyIsOrgJsonExact() {
        let body = InnerTubeRequests.playerBody(videoId: "dQw4w9WgXcQ", profile: InnerTubeContexts.androidVR, visitorData: "VD%3D", authenticated: false)
        #expect(OrgJSONWriter.write(.object(body)) == """
        {"context":{"client":{"clientName":"ANDROID_VR","clientVersion":"1.65.10","userAgent":"com.google.android.apps.youtube.vr.oculus\\/1.65.10 (Linux; U; Android 12L; eureka-user Build\\/SQ3A.220605.009.A1) gzip","hl":"en","gl":"US","deviceMake":"Oculus","deviceModel":"Quest 3","osName":"Android","osVersion":"12L","androidSdkVersion":32,"visitorData":"VD%3D"}},"videoId":"dQw4w9WgXcQ","contentCheckOk":true,"racyCheckOk":true}
        """)
        let authed = InnerTubeRequests.playerBody(videoId: "v", profile: InnerTubeContexts.webRemix, visitorData: nil, authenticated: true, playerRequestPoToken: "POT")
        #expect(OrgJSONWriter.write(.object(authed)).hasSuffix(#""videoId":"v","contentCheckOk":true,"serviceIntegrityDimensions":{"poToken":"POT"}}"#))
        #expect(!OrgJSONWriter.write(.object(authed)).contains("visitorData"))
    }

    @Test func searchRequestUsesMusicClientAndTrimsQuery() {
        let body = InnerTubeRequests.searchBody(query: "  northern lights nova \n", params: InnerTubeContexts.songsSearchParams, visitorData: "V")
        let request = InnerTubeRequests.post(path: "search", body: body, profile: InnerTubeContexts.searchProfile)
        #expect(request.method == .post)
        #expect(request.url.hasPrefix("https://music.youtube.com/youtubei/v1/search?key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"))
        #expect(request.header("Content-Type") == "application/json; charset=utf-8")
        #expect(request.header("Origin") == "https://music.youtube.com")
        #expect(request.header("cookie") == nil && request.header("Authorization") == nil)
        let text = request.bodyText!
        #expect(text.hasSuffix(#""query":"northern lights nova","params":"EgWKAQIIAWoKEAkQBRAKEAMQBA=="}"#))
    }

    @Test func authenticatedHeadersCarryCookieAndSapisid() {
        let request = InnerTubeRequests.post(path: "player", body: JSONObject(), profile: InnerTubeContexts.webRemix,
                                             cookie: "SID=1; SAPISID=abc", sapisidAuthorization: "SAPISIDHASH 1_x", origin: "https://music.youtube.com")
        #expect(request.header("cookie") == "SID=1; SAPISID=abc")
        #expect(request.header("Authorization") == "SAPISIDHASH 1_x")
        #expect(request.header("x-origin") == "https://music.youtube.com")
        #expect(request.header("X-Goog-Api-Format-Version") == "1")
        #expect(request.header("Origin") == nil)
    }

    @Test func sapisidHashMatchesTheBrowserAlgorithm() {
        let cookie = "HSID=h; SAPISID=abc123/XYZ; APISID=a"
        #expect(YouTubeCookieAuth.sapisidHashAuthorization(cookie: cookie, timestampSeconds: 1_700_000_000)
                == "SAPISIDHASH 1700000000_289fd730e8d0d6300b332703c750af560713e6b1")
        #expect(YouTubeCookieAuth.sapisidHashAuthorization(cookie: cookie, origin: "https://www.youtube.com", timestampSeconds: 1_700_000_000)
                == "SAPISIDHASH 1700000000_e85beba3b688b45be2790d3a5ac789626ea1261e")
        #expect(YouTubeCookieAuth.sapisidHashAuthorization(cookie: "SID=1", timestampSeconds: 1) == nil)
        #expect(YouTubeCookieAuth.sapisidHashAuthorization(cookie: nil, timestampSeconds: 1) == nil)
        #expect(YouTubeCookieAuth.parseCookieString("a=1; b=x=y; ; c; a=2") == ["a": "2", "b": "x=y"])
    }

    @Test func playerResponseParsingKeepsAudioAndMuxedFallback() throws {
        let response = InnerTubeParsing.playerResponse(try Fixtures.json("innertube-player"))
        #expect(response.isPlayable && response.status == "OK" && response.reason == nil)
        #expect(response.formats.map(\.itag) == [140, 251, 139, 18])
        let aac = try #require(response.formats.first { $0.itag == 140 })
        #expect(aac.contentLength == 2_900_000 && aac.approxDurationMs == 180_001 && aac.bitrate == 130_000)
        let opus = try #require(response.formats.first { $0.itag == 251 })
        #expect(opus.contentLength == 3_100_000)
        let ciphered = try #require(response.formats.first { $0.itag == 139 })
        #expect(ciphered.url == nil && ciphered.signatureCipher?.hasPrefix("s=ABCDEF") == true && ciphered.bitrate == 48_000)
        #expect(response.formats.last?.isMuxedFallback == true)
        #expect(!response.hadOnlyUnusableFormats)
        #expect(InnerTubeParsing.visitorData(try Fixtures.json("innertube-player")) == "CgtWSVNJVE9SX0lEKI-test%3D%3D")
    }

    @Test func sabrOnlyResponseIsOkButUnusable() throws {
        let json = try #require(OrgJSON.object("""
        {"playabilityStatus":{"status":"ok"},"streamingData":{"adaptiveFormats":[{"itag":141,"mimeType":"audio/mp4","initRange":{},"contentLength":"9"}],"hlsManifestUrl":"x"}}
        """))
        let response = InnerTubeParsing.playerResponse(json)
        #expect(response.isPlayable && response.formats.isEmpty && response.hadOnlyUnusableFormats)
        #expect(response.rawMimeTypes == ["audio/mp4"] && response.hasHlsManifest)
    }

    @Test func playabilityStatusesAndReasons() throws {
        let login = InnerTubeParsing.playerResponse(try #require(OrgJSON.object(
            #"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you're not a bot"}}"#)))
        #expect(!login.isPlayable && login.statusDetail == "LOGIN_REQUIRED — Sign in to confirm you're not a bot")
        let missing = InnerTubeParsing.playerResponse(JSONObject())
        #expect(missing.status == "UNKNOWN" && missing.reason == nil && missing.statusDetail == "UNKNOWN")
        let blank = InnerTubeParsing.playerResponse(try #require(OrgJSON.object(#"{"playabilityStatus":{"status":"  ","reason":" "}}"#)))
        #expect(blank.status == "UNKNOWN" && blank.reason == nil)
        let nullStatus = InnerTubeParsing.playerResponse(try #require(OrgJSON.object(#"{"playabilityStatus":{"status":null}}"#)))
        #expect(nullStatus.status == "null")
    }

    @Test func formatParsingRules() throws {
        func parse(_ text: String) throws -> YouTubeAudioFormat? { InnerTubeParsing.format(try #require(OrgJSON.object(text))) }
        #expect(try parse(#"{"itag":137,"mimeType":"video/mp4","url":"u"}"#) == nil)
        #expect(try parse(#"{"itag":140,"mimeType":"audio/mp4"}"#) == nil)
        #expect(try parse(#"{"itag":140,"url":"u"}"#)?.mimeType == nil)
        #expect(try parse(#"{"itag":140,"mimeType":"audio/mp4","cipher":"s=1&url=x"}"#)?.signatureCipher == "s=1&url=x")
        #expect(try parse(#"{"itag":140,"mimeType":"audio/mp4","url":" ","signatureCipher":"sc"}"#)?.url == nil)
        #expect(try parse(#"{"mimeType":"audio/mp4","url":"u","bitrate":"oops"}"#)?.itag == -1)
        #expect(try parse(#"{"itag":"18","mimeType":"video/mp4","url":"u"}"#)?.isMuxedFallback == true)
        #expect(try parse(#"{"itag":140,"mimeType":"audio/mp4","url":"u","contentLength":"12x"}"#)?.contentLength == nil)
        #expect(try parse(#"{"itag":140.9,"mimeType":"audio/mp4","url":"u","bitrate":1.5e5}"#).map { ($0.itag, $0.bitrate) } ?? (0, 0) == (140, 150000))
    }

    @Test func searchParsingFollowsDocumentOrder() throws {
        guard case .results(let results) = InnerTubeParsing.searchResults(try Fixtures.json("innertube-search"), limit: 10, isVideo: false) else {
            Issue.record("expected results")
            return
        }
        #expect(results.map(\.videoId) == ["abcdefghijk", "videoIdBBBB", "auroraVideo"])
        let first = results[0]
        #expect(first.title == "Northern Lights" && first.artist == "Nova" && first.album == "First Light" && first.durationSeconds == 183)
        #expect(first.thumbnailUrl == "https://lh3.googleusercontent.com/large" && !first.isMusicVideo)
        let video = results[1]
        #expect(video.artist == "NovaVEVO" && video.album == nil && video.durationSeconds == 3841)
        #expect(results[2].artist == "Single Artist" && results[2].album == nil && results[2].durationSeconds == nil)
    }

    @Test func searchLimitAndVideoFlagAndNonResultsPage() throws {
        guard case .results(let one) = InnerTubeParsing.searchResults(try Fixtures.json("innertube-search"), limit: 1, isVideo: true) else {
            Issue.record("expected results")
            return
        }
        #expect(one.count == 1 && one[0].isMusicVideo)
        #expect(InnerTubeParsing.searchResults(JSONObject(), limit: 5, isVideo: false) == .notAResultsPage)
        let empty = try #require(OrgJSON.object(#"{"contents":{}}"#))
        #expect(InnerTubeParsing.searchResults(empty, limit: 5, isVideo: false) == .results([]))
        let continuation = try #require(OrgJSON.object(#"{"continuationContents":{}}"#))
        #expect(InnerTubeParsing.searchResults(continuation, limit: 5, isVideo: false) == .results([]))
    }

    @Test func durationParsing() {
        #expect(InnerTubeParsing.parseDurationSeconds("3:07") == 187)
        #expect(InnerTubeParsing.parseDurationSeconds("1:02:33") == 3753)
        #expect(InnerTubeParsing.parseDurationSeconds(" 4 : 05 ") == 245)
        #expect(InnerTubeParsing.parseDurationSeconds("3") == nil)
        #expect(InnerTubeParsing.parseDurationSeconds("1:2:3:4") == nil)
        #expect(InnerTubeParsing.parseDurationSeconds("a:07") == nil)
        #expect(InnerTubeParsing.parseDurationSeconds("-1:30") == -30)
        #expect(InnerTubeParsing.parseDurationSeconds("+2:00") == 120)
    }

    @Test func treeWalkingStopsAndSkipsBlankStrings() throws {
        let json = try #require(OrgJSON.parse(#"{"a":{"k":{"n":1}},"b":[{"k":{"n":2}},{"k":"str"},{"x":{"k":{"n":3}}}],"videoId":" ","c":{"videoId":"deep"}}"#))
        var seen: [Int] = []
        InnerTubeParsing.collectByKey(json, "k") { o in
            seen.append(Int(o["n"]!.int64Value!))
            return seen.count < 2
        }
        #expect(seen == [1, 2])
        var all: [Int] = []
        #expect(InnerTubeParsing.collectByKey(json, "k") { all.append(Int($0["n"]!.int64Value!)); return true })
        #expect(all == [1, 2, 3])
        #expect(InnerTubeParsing.findFirstString(json, "videoId") == "deep")
    }

    @Test func visitorDataFromHtmlConfig() {
        #expect(InnerTubeParsing.visitorData(html: #"ytcfg.set({"INNERTUBE_API_KEY":"k","VISITOR_DATA" : "CgtAbc%3D%3D","X":1});"#) == "CgtAbc%3D%3D")
        #expect(InnerTubeParsing.visitorData(html: #"{"VISITOR_DATA":""} {"VISITOR_DATA":"second"}"#) == "second")
        #expect(InnerTubeParsing.visitorData(html: "<html></html>") == nil)
        #expect(InnerTubeParsing.visitorData(JSONObject()) == nil)
    }
}

@Suite("InnerTube client over HTTP")
struct InnerTubeClientTests {
    struct Session: YouTubeSessionProviding {
        var cookieValue: String?
        var anonymous: String?
        var stored = "STORED"
        var poToken: PoTokenResult?
        func cookie() async -> String? { cookieValue }
        func storedVisitorData() async -> String { stored }
        func anonymousVisitorData() async -> String? { anonymous }
        func webClientPoToken(videoId: String) async -> PoTokenResult? { poToken }
        func nowSeconds() -> Int64 { 1_700_000_000 }
    }

    static let playerFixture: String = (try? Fixtures.text("innertube-player", "json")) ?? "{}"

    @Test func nativeClientsNeverReceiveTheCookieButAlwaysAVisitorData() async throws {
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: Self.playerFixture) }
        let client = InnerTubeClient(http: http, session: Session(cookieValue: "SAPISID=abc", anonymous: "FRESH"))
        let response = try #require(try await client.fetchPlayer(videoId: "dQw4w9WgXcQ", profile: InnerTubeContexts.visionOS))
        #expect(response.isPlayable)
        let request = try #require(http.requests.first)
        #expect(request.header("cookie") == nil && request.header("Authorization") == nil)
        #expect(request.bodyText!.contains(#""visitorData":"FRESH""#))
        #expect(request.bodyText!.contains(#""racyCheckOk":true"#))
        #expect(request.url == "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
    }

    @Test func cookieClientsAreAuthenticatedAndWebRemixGetsAPoToken() async throws {
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: Self.playerFixture) }
        let pot = PoTokenResult(visitorData: "POTVD", playerRequestPoToken: "PLAYERPOT", streamingDataPoToken: "STREAMPOT")
        let client = InnerTubeClient(http: http, session: Session(cookieValue: "SAPISID=abc123/XYZ", anonymous: "FRESH", poToken: pot))
        let response = try #require(try await client.fetchPlayer(videoId: "v", profile: InnerTubeContexts.webRemix))
        #expect(response.streamingPoToken == "STREAMPOT")
        let request = try #require(http.requests.first)
        #expect(request.header("cookie") == "SAPISID=abc123/XYZ")
        #expect(request.header("Authorization") == "SAPISIDHASH 1700000000_289fd730e8d0d6300b332703c750af560713e6b1")
        #expect(request.bodyText!.contains(#""visitorData":"POTVD""#))
        #expect(!request.bodyText!.contains("racyCheckOk"))
        #expect(request.bodyText!.contains(#""serviceIntegrityDimensions":{"poToken":"PLAYERPOT"}"#))

        _ = try await client.fetchPlayer(videoId: "v", profile: InnerTubeContexts.tvHTML5)
        let tv = http.requests[1]
        #expect(tv.header("cookie") != nil && !tv.bodyText!.contains("serviceIntegrityDimensions"))
        #expect(tv.header("Authorization") == "SAPISIDHASH 1700000000_e85beba3b688b45be2790d3a5ac789626ea1261e")
    }

    @Test func visitorDataFallsBackToTheStoredValue() async throws {
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: Self.playerFixture) }
        let client = InnerTubeClient(http: http, session: Session(cookieValue: nil, anonymous: nil))
        _ = try await client.fetchPlayer(videoId: "v", profile: InnerTubeContexts.iOS)
        #expect(http.requests[0].bodyText!.contains(#""visitorData":"STORED""#))
    }

    @Test func failuresAreRecordedForDiagnostics() async throws {
        let http = FixtureHTTPClient { request in
            if request.url.contains("player") { return HTTPResponse(statusCode: 400, text: "Precondition check failed") }
            throw HTTPTransportError(kind: "SocketTimeoutException", message: "timeout")
        }
        let client = InnerTubeClient(http: http, session: Session(cookieValue: nil, anonymous: "A"))
        #expect(try await client.fetchPlayer(videoId: "v", profile: InnerTubeContexts.iOS) == nil)
        #expect(await client.lastFailureReason == "IOS respondió HTTP 400")
        await #expect(throws: InnerTubeError.self) { try await client.searchSongs("q") }
        #expect(await client.lastFailureReason == "WEB_REMIX: SocketTimeoutException timeout")
    }

    @Test func searchSendsFilteredBodyAndInterleaves() async throws {
        let search = try Fixtures.text("innertube-search", "json")
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: search) }
        let client = InnerTubeClient(http: http, session: Session(cookieValue: "SAPISID=x", anonymous: "FRESH"))
        let songs = try await client.searchSongs("nova", limit: 10)
        #expect(songs.count == 3 && songs.allSatisfy { !$0.isMusicVideo })
        let request = http.requests[0]
        #expect(request.header("cookie") == nil)
        #expect(request.bodyText!.contains(InnerTubeContexts.songsSearchParams) && request.bodyText!.contains(#""visitorData":"FRESH""#))
        let mixed = try await client.searchMusic("nova", limit: 4)
        #expect(mixed.map(\.videoId) == ["abcdefghijk", "videoIdBBBB", "auroraVideo"])
        #expect(try await client.searchSongs("   ").isEmpty)
        #expect(try await client.searchSongs("x", limit: 0).isEmpty)
    }

    @Test func searchMusicSurvivesOneFailedShelf() async throws {
        let search = try Fixtures.text("innertube-search", "json")
        let http = FixtureHTTPClient { request in
            if request.bodyText!.contains(InnerTubeContexts.videosSearchParams) { return HTTPResponse(statusCode: 500) }
            return HTTPResponse(statusCode: 200, text: search)
        }
        let client = InnerTubeClient(http: http, session: Session(cookieValue: nil, anonymous: "A"))
        #expect(try await client.searchMusic("x", limit: 2).count == 2)
        let failing = InnerTubeClient(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 503) }, session: Session(cookieValue: nil, anonymous: "A"))
        await #expect(throws: InnerTubeError.self) { try await failing.searchMusic("x") }
    }

    @Test func interleaveDeduplicatesAndClamps() {
        func r(_ id: String) -> YouTubeSearchResult { YouTubeSearchResult(videoId: id, title: id, artist: "", album: nil, durationSeconds: nil) }
        #expect(InnerTubeClient.interleave(songs: [r("a"), r("b"), r("c")], videos: [r("b"), r("x")], limit: 10).map(\.videoId) == ["a", "b", "x", "c"])
        #expect(InnerTubeClient.interleave(songs: [r("a"), r("b")], videos: [], limit: 0).map(\.videoId) == ["a"])
    }

    @Test func visitorDataProviderFetchesOnce() async throws {
        let calls = Box(0)
        let http = FixtureHTTPClient { request in
            calls.mutate { $0 += 1 }
            #expect(request.url == "https://www.youtube.com/youtubei/v1/visitor_id?key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX3&prettyPrint=false")
            return HTTPResponse(statusCode: 200, text: #"{"responseContext":{"visitorData":"CgtFRESH"}}"#)
        }
        let provider = VisitorDataProvider(http: http)
        #expect(await provider.visitorData() == "CgtFRESH")
        #expect(await provider.visitorData() == "CgtFRESH")
        #expect(calls.value == 1)
        let failing = VisitorDataProvider(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 500) })
        #expect(await failing.visitorData() == nil)
        let session = AnonymousYouTubeSession(visitorData: provider)
        #expect(await session.anonymousVisitorData() == "CgtFRESH")
        #expect(await session.storedVisitorData() == YouTubeCookieAuth.defaultVisitorData)
    }
}

@Suite("Audio format selection (Android + iOS AAC)")
struct AudioFormatSelectionTests {
    func fmt(_ itag: Int, _ mime: String?, _ bitrate: Int, muxed: Bool = false, url: String? = "u") -> YouTubeAudioFormat {
        YouTubeAudioFormat(itag: itag, mimeType: mime, bitrate: bitrate, url: url, signatureCipher: url == nil ? "s=1&url=x" : nil,
                           contentLength: nil, approxDurationMs: nil, isMuxedFallback: muxed)
    }

    /// Android `TrackMatcherTest.quality cap never promotes a muxed video above real audio`.
    @Test func qualityCapNeverPromotesMuxedVideoAboveRealAudio() {
        let audio = fmt(251, "audio/webm; codecs=opus", 160_000)
        let muxed = fmt(18, "video/mp4", 90_000, muxed: true)
        #expect(AudioFormatSelection.pickBestAudio([muxed, audio], maxBitrateKbps: 96) == audio)
    }

    @Test func iOSPicksAACOnlyThenTheMuxedFallback() throws {
        let response = InnerTubeParsing.playerResponse(try Fixtures.json("innertube-player"))
        #expect(AudioFormatSelection.pickBestIOSAudio(response.formats)?.itag == 140)
        #expect(AudioFormatSelection.pickBestAudio(response.formats)?.itag == 251)
        let set = [fmt(251, "audio/webm; codecs=\"opus\"", 160_000), fmt(141, "audio/mp4; codecs=\"mp4a.40.2\"", 256_000),
                   fmt(140, "audio/mp4; codecs=\"mp4a.40.2\"", 130_000), fmt(139, "audio/mp4; codecs=\"mp4a.40.5\"", 48_000),
                   fmt(18, "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", 600_000, muxed: true)]
        #expect(AudioFormatSelection.pickBestIOSAudio(set)?.itag == 141)
        #expect(AudioFormatSelection.pickBestIOSAudio(set, maxBitrateKbps: 160)?.itag == 140)
        #expect(AudioFormatSelection.pickBestIOSAudio(set, maxBitrateKbps: 64)?.itag == 139)
        #expect(AudioFormatSelection.pickBestIOSAudio(set, maxBitrateKbps: 8)?.itag == 141)
        #expect(AudioFormatSelection.pickBestIOSAudio([set[0], set[4]])?.itag == 18)
        #expect(AudioFormatSelection.pickBestIOSAudio([set[0]]) == nil)
        #expect(AudioFormatSelection.pickBestIOSAudio([fmt(140, nil, 128_000), fmt(141, nil, 128_000)])?.itag == 141)
        #expect(AudioFormatSelection.isPlayableOnIOS(fmt(256, "audio/mp4; codecs=\"mp4a.40.5\"", 192_000)))
        #expect(!AudioFormatSelection.isPlayableOnIOS(fmt(338, "audio/webm; codecs=\"opus\"", 480_000)))
        #expect(!AudioFormatSelection.isPlayableOnIOS(fmt(380, "audio/mp4; codecs=\"ac-3\"", 384_000)))
        #expect(!AudioFormatSelection.isPlayableOnIOS(fmt(999, nil, 1)))
    }

    @Test func poTokenClientsOnlyExposeTheMuxedFallbackWithoutAToken() {
        let formats = [fmt(140, "audio/mp4", 130_000), fmt(18, "video/mp4", 500_000, muxed: true)]
        let response = YouTubePlayerResponse(status: "OK", reason: nil, formats: formats)
        #expect(AudioFormatSelection.eligibleFormats(response, profile: InnerTubeContexts.iOS).map(\.itag) == [18])
        #expect(AudioFormatSelection.eligibleFormats(response, profile: InnerTubeContexts.visionOS).map(\.itag) == [140, 18])
        var withPot = response
        withPot.streamingPoToken = "pot"
        #expect(AudioFormatSelection.eligibleFormats(withPot, profile: InnerTubeContexts.webRemix).count == 2)
    }

    @Test func androidTiesPreferOpusAndKeepTheFirstMaximum() {
        let a = fmt(140, "audio/mp4", 128_000), b = fmt(250, "audio/webm; codecs=OPUS", 128_000), c = fmt(141, "audio/mp4", 128_000)
        #expect(AudioFormatSelection.pickBestAudio([a, b])?.itag == 250)
        #expect(AudioFormatSelection.pickBestAudio([a, c])?.itag == 140)
        #expect(AudioFormatSelection.pickBestAudio([]) == nil)
    }
}
