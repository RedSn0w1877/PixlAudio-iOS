import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

/// Android `data/youtube/TrackMatcherTest` (6 scoring cases; the 7th, the quality cap, is in
/// `AudioFormatSelectionTests`) plus the matching flow.
@Suite("TrackMatcher")
struct TrackMatcherTests {
    func song(title: String = "Northern Lights", artist: String = "Nova", durationMs: Int64 = 180_000) -> MatchableTrack {
        MatchableTrack(title: title, artist: artist, album: "First Light", durationMs: durationMs)
    }

    @Test func officialVideoWithArtistInTitleIsAValidFallback() {
        let candidate = YouTubeSearchResult(videoId: "abcdefghijk", title: "Nova - Northern Lights [Official Music Video]",
                                            artist: "NovaVEVO", album: nil, durationSeconds: 183, isMusicVideo: true)
        #expect(TrackMatcher.score(song(), candidate) >= TrackMatcher.minAcceptScore)
    }

    @Test func sameTitleAndDurationFromAnotherArtistCannotWin() {
        let candidate = YouTubeSearchResult(videoId: "abcdefghijk", title: "Northern Lights", artist: "Completely Different", album: nil, durationSeconds: 180)
        #expect(TrackMatcher.score(song(), candidate) == 0)
    }

    @Test func artistSubstringIsNotAnArtistMatch() {
        let candidate = YouTubeSearchResult(videoId: "abcdefghijk", title: "Northern Lights", artist: "Supernova", album: nil, durationSeconds: 180)
        #expect(TrackMatcher.score(song(), candidate) == 0)
    }

    @Test func unknownSourceDurationDoesNotRejectAnOtherwiseExactSong() {
        let candidate = YouTubeSearchResult(videoId: "abcdefghijk", title: "Northern Lights", artist: "Nova", album: nil, durationSeconds: 180)
        #expect(TrackMatcher.score(song(durationMs: 0), candidate) >= TrackMatcher.minAcceptScore)
    }

    @Test func nonLatinNamesRetainTheirIdentity() {
        #expect(TrackMatcher.normalize("夜に駆ける") == "夜に駆ける")
        #expect(TrackMatcher.normalize("Café") == "cafe")
        #expect(TrackMatcher.similarity(TrackMatcher.normalize("夜に駆ける"), TrackMatcher.normalize("春の日")) < 0.5)
    }

    @Test func liveVariantLosesToOriginalRecording() {
        let studio = YouTubeSearchResult(videoId: "abcdefghijk", title: "Northern Lights", artist: "Nova", album: nil, durationSeconds: 180)
        var live = studio
        live.title = "Northern Lights (Live)"
        #expect(TrackMatcher.score(song(), studio) > TrackMatcher.score(song(), live))
    }

    @Test func queriesUsePrimaryArtistAndRealAlbumsOnly() {
        #expect(TrackMatcher.buildQueries(MatchableTrack(title: "T", artist: "A, B", album: "Al", durationMs: 0)) == ["T A", "T A Al", "T"])
        #expect(TrackMatcher.buildQueries(MatchableTrack(title: "T", artist: "A", album: "unknown album", durationMs: 0)) == ["T A", "T"])
        #expect(TrackMatcher.buildQueries(MatchableTrack(title: "T", artist: "", album: " ", durationMs: 0)) == ["T ", "T"])
    }

    struct FakeSearch: YouTubeMusicSearching {
        let songs: @Sendable (String) throws -> [YouTubeSearchResult]
        let videos: @Sendable (String) throws -> [YouTubeSearchResult]
        let log: Box<[String]>
        func searchSongs(_ query: String, limit: Int) async throws -> [YouTubeSearchResult] {
            log.mutate { $0.append("song:\(query):\(limit)") }
            return try songs(query)
        }
        func searchVideos(_ query: String, limit: Int) async throws -> [YouTubeSearchResult] {
            log.mutate { $0.append("video:\(query):\(limit)") }
            return try videos(query)
        }
    }

    static let exact = YouTubeSearchResult(videoId: "exactexact1", title: "Northern Lights", artist: "Nova", album: "First Light", durationSeconds: 180)

    @Test func findMatchStopsAtTheFirstConfidentQuery() async throws {
        let log = Box<[String]>([])
        let matcher = TrackMatcher(search: FakeSearch(songs: { _ in [Self.exact] }, videos: { _ in [] }, log: log))
        let match = try #require(try await matcher.findMatch(song()))
        #expect(match.videoId == "exactexact1" && match.score >= TrackMatcher.earlyAcceptScore)
        #expect(log.value == ["song:Northern Lights Nova:8"])
    }

    @Test func findMatchFallsBackToTheVideoShelf() async throws {
        let log = Box<[String]>([])
        let video = YouTubeSearchResult(videoId: "videovideo1", title: "Nova - Northern Lights (Official Video)", artist: "NovaVEVO",
                                        album: nil, durationSeconds: 181, isMusicVideo: true)
        let matcher = TrackMatcher(search: FakeSearch(songs: { _ in [] }, videos: { _ in [video] }, log: log))
        let match = try #require(try await matcher.findMatch(song()))
        #expect(match.videoId == "videovideo1")
        #expect(log.value == ["song:Northern Lights Nova:8", "song:Northern Lights Nova First Light:8", "song:Northern Lights:8",
                              "video:Northern Lights Nova:8"])
    }

    @Test func findMatchThrowsOnlyWhenSearchFailedAndNothingWasAcceptable() async throws {
        struct Down: Error {}
        let failing = TrackMatcher(search: FakeSearch(songs: { _ in throw Down() }, videos: { _ in throw Down() }, log: Box([])))
        await #expect(throws: MusicSearchUnavailableError.self) { try await failing.findMatch(song()) }
        let wrong = YouTubeSearchResult(videoId: "wrongwrong1", title: "Other", artist: "Else", album: nil, durationSeconds: 10)
        let none = TrackMatcher(search: FakeSearch(songs: { _ in [wrong] }, videos: { _ in [] }, log: Box([])))
        #expect(try await none.findMatch(song()) == nil)
        let partial = TrackMatcher(search: FakeSearch(songs: { q in if q == "Northern Lights" { throw Down() }; return [Self.exact] },
                                                      videos: { _ in throw Down() }, log: Box([])))
        #expect(try await partial.findMatch(song())?.videoId == "exactexact1")
    }
}

@Suite("Signature cipher and stream resolution")
struct CipherAndStreamTests {
    struct FakeJS: JavaScriptEvaluating {
        let calls: Box<[String]>
        let result: @Sendable (String) -> String?
        func evaluate(_ script: String) async -> String? {
            calls.mutate { $0.append(script) }
            return result(script)
        }
    }

    static let baseJs = """
    var Xy={AB:function(a,b){a.splice(0,b)}};Sig=function(a){a=a.split("");Xy.AB(a,1);return a.join("")};\
    c&&(c=Sig(decodeURIComponent(c)));x.get("n"))&&(b=Nq(b);Nq=function(a){return a+"!"};
    """

    @Test func callsQuoteLikeOrgJson() {
        #expect(SignatureCipher.signatureCall(functionJs: "F", scrambled: "a\"b/c") == #"(function(){ F; return __ppSig("a\"b\/c"); })()"#)
        #expect(SignatureCipher.nCall(functionJs: "G", n: "x") == #"(function(){ G; return __ppN("x"); })()"#)
        #expect(SignatureCipher.baseJsURL(playerId: "abc") == "https://www.youtube.com/s/player/abc/player_ias.vflset/en_US/base.js")
    }

    @Test func cipherPartsAndSignatureAppending() throws {
        let parts = try #require(SignatureCipher.cipherParts("s=AB%3DC&sp=sig&url=https%3A%2F%2Fr.googlevideo.com%2Fvideoplayback%3Fitag%3D140"))
        #expect(parts.url == "https://r.googlevideo.com/videoplayback?itag=140" && parts.scrambledSignature == "AB=C" && parts.signatureParameter == "sig")
        #expect(SignatureCipher.applySignature(parts, deciphered: "x y/z") == "https://r.googlevideo.com/videoplayback?itag=140&sig=x%20y%2Fz")
        #expect(SignatureCipher.cipherParts("s=1&sp=x")?.url == nil)
        #expect(SignatureCipher.cipherParts("url=u&=skip&s")?.signatureParameter == "signature")
        #expect(SignatureCipher.cipherParts("url=a+b")?.url == "a+b")
    }

    @Test func nTransformRebuildsTheQuery() {
        let url = "https://r.googlevideo.com/videoplayback?expire=1&n=abc&mime=audio%2Fmp4&dup=1&dup=2&sp=a+b#frag"
        #expect(SignatureCipher.nParameter(url) == "abc")
        #expect(SignatureCipher.applyNTransform(url, original: "abc", transformed: "XYZ")
                == "https://r.googlevideo.com/videoplayback?expire=1&n=XYZ&mime=audio%2Fmp4&dup=1&sp=a%20b#frag")
        #expect(SignatureCipher.applyNTransform(url, original: "abc", transformed: "enhanced_except_abc") == url)
        #expect(SignatureCipher.applyNTransform(url, original: "abc", transformed: "abc") == url)
        #expect(SignatureCipher.withStreamingPoToken("https://h/p?a=1", "P/T") == "https://h/p?a=1&pot=P%2FT")
        #expect(SignatureCipher.withStreamingPoToken("https://h/p?a=1", " ") == "https://h/p?a=1")
        #expect(SignatureCipher.withStreamingPoToken(nil, "x") == nil)
    }

    @Test func braceMatchingSkipsStrings() {
        let js = Array(#"{a="}";b='{';c=`}`;d="\"}";{}}"#.utf16)
        #expect(SignatureCipher.matchingBrace(js, 0) == js.count - 1)
        #expect(SignatureCipher.matchingBrace(Array("{{}".utf16), 0) == nil)
        #expect(SignatureCipher.functionBody("var f=function(a){return {x:1}};", name: "f") == "return {x:1}")
        #expect(SignatureCipher.functionBody("o={f:function(a){x}}", name: "f") == "x")
        #expect(SignatureCipher.functionBody("nothing", name: "f") == nil)
        #expect(SignatureCipher.objectLiteral("var H={a:1};", name: "H") == "var H = {a:1};")
    }

    @Test func solverDownloadsOnceAndDeciphers() async throws {
        let iframe = #"x 'https:\/\/www.youtube.com\/s\/player\/0123abcd\/www-widgetapi.vflset' y"#
        let http = FixtureHTTPClient(routes: [
            ("https://www.youtube.com/iframe_api", HTTPResponse(statusCode: 200, text: iframe)),
            ("https://www.youtube.com/s/player/0123abcd/player_ias.vflset/en_US/base.js", HTTPResponse(statusCode: 200, text: Self.baseJs)),
        ])
        let calls = Box<[String]>([])
        let js = FakeJS(calls: calls) { script in script.contains("__ppSig(") ? "DECIPHERED" : "NNN" }
        let solver = SignatureCipherSolver(http: http, evaluator: js)
        let url = await solver.resolveCipheredUrl("s=SCRAMBLED&sp=sig&url=https%3A%2F%2Fr.googlevideo.com%2Fvideoplayback%3Fn%3Dold")
        #expect(url == "https://r.googlevideo.com/videoplayback?n=NNN&sig=DECIPHERED")
        #expect(http.requests.map(\.url) == ["https://www.youtube.com/iframe_api", "https://www.youtube.com/s/player/0123abcd/player_ias.vflset/en_US/base.js"])
        #expect(http.requests.allSatisfy { $0.header("User-Agent") == InnerTubeContexts.webRemix.userAgent })
        #expect(calls.value[0].contains(#"return __ppSig("SCRAMBLED")"#))
        #expect(await solver.applyNTransform("https://h/p?x=1") == "https://h/p?x=1")
        _ = await solver.applyNTransform("https://h/p?n=q")
        #expect(http.requests.count == 2)
        #expect(await solver.currentScript?.playerId == "0123abcd")
        let report = await solver.diagnose()
        #expect(report.contains("playerId: 0123abcd") && report.contains("signature function: found") && report.contains("run n function via JsEvaluator: NNN"))
    }

    @Test func solverWithoutBaseJsLeavesUrlsAlone() async {
        let solver = SignatureCipherSolver(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 503) },
                                           evaluator: FakeJS(calls: Box([])) { _ in "x" })
        #expect(await solver.applyNTransform("https://h/p?n=q") == "https://h/p?n=q")
        #expect(await solver.resolveCipheredUrl("s=1&url=https%3A%2F%2Fh") == nil)
        #expect(await solver.resolveCipheredUrl("url=https%3A%2F%2Fh%2Fp") == "https://h/p")
        #expect(await solver.diagnose().contains("playerId: NOT FOUND"))
    }

    // MARK: Strategies

    actor FakePlayer: YouTubePlayerFetching {
        var responses: [String: YouTubePlayerResponse?] = [:]
        var lastFailureReason: String? = "IOS respondió HTTP 400"
        var asked: [String] = []
        init(_ responses: [String: YouTubePlayerResponse?]) { self.responses = responses }
        func fetchPlayer(videoId: String, profile: InnerTubeClientProfile) async throws -> YouTubePlayerResponse? {
            asked.append(profile.name)
            return responses[profile.name] ?? nil
        }
    }

    struct FakeCipher: CipherResolving {
        func resolveCipheredUrl(_ signatureCipher: String) async -> String? { signatureCipher.contains("ok") ? "https://r.googlevideo.com/deciphered" : nil }
        func applyNTransform(_ url: String) async -> String { url.contains("n=") ? url + "&t" : url }
    }

    struct FakeProbe: StreamProbing {
        let ok: @Sendable (String) -> Bool
        func probe(url: String, userAgent: String, sendRange: Bool) async -> StreamProbe {
            ok(url) ? StreamProbe(ok: true, httpStatus: 206, contentType: "audio/mp4") : StreamProbe(ok: false, httpStatus: 403)
        }
    }

    func fmt(_ itag: Int, _ mime: String, _ bitrate: Int, url: String?, cipher: String? = nil, muxed: Bool = false) -> YouTubeAudioFormat {
        YouTubeAudioFormat(itag: itag, mimeType: mime, bitrate: bitrate, url: url, signatureCipher: cipher, contentLength: nil,
                           approxDurationMs: nil, isMuxedFallback: muxed)
    }

    @Test func chainOrderDependsOnSignIn() {
        #expect(YouTubeStreamStrategy.chain(signedIn: false).map(\.name) == ["VISIONOS", "IOS", "TVHTML5 (deciphered)", "WEB_REMIX (deciphered)"])
        #expect(YouTubeStreamStrategy.chain(signedIn: true).map(\.name)
                == ["VISIONOS", "IOS", "TVHTML5 (deciphered)", "WEB (deciphered)", "WEB_REMIX (deciphered)"])
    }

    @Test func visionOSWinsWithAnAACUrlAndTheRightUserAgent() async throws {
        let ok = YouTubePlayerResponse(status: "OK", reason: nil, formats: [
            fmt(251, "audio/webm; codecs=\"opus\"", 160_000, url: "https://r.googlevideo.com/opus?n=a"),
            fmt(140, "audio/mp4; codecs=\"mp4a.40.2\"", 130_000, url: "https://r.googlevideo.com/aac?n=b"),
        ])
        let player = FakePlayer(["VISIONOS": ok])
        let resolver = ChainedYouTubeStreamResolver(player: player, cipher: FakeCipher(), validator: FakeProbe { _ in true })
        let stream = try #require(try await resolver.resolveStream(videoId: "dQw4w9WgXcQ"))
        #expect(stream.url == "https://r.googlevideo.com/aac?n=b&t" && stream.userAgent == InnerTubeContexts.visionOS.userAgent)
        #expect(stream.strategyName == "VISIONOS")
        #expect(await resolver.lastAttempts == ["VISIONOS: playable (audio/mp4)"])
        let android = ChainedYouTubeStreamResolver(player: player, cipher: FakeCipher(), validator: nil, policy: .android)
        #expect(try await android.resolveStream(videoId: "x")?.url == "https://r.googlevideo.com/opus?n=a&t")
        #expect(await android.lastAttempts == ["VISIONOS: itag 251, 160 kbps, n descifrado (sin validar)"])
    }

    @Test func fallsThroughLoginRequiredAndPoTokenClientsToDeciphering() async throws {
        let login = YouTubePlayerResponse(status: "LOGIN_REQUIRED", reason: "Sign in", formats: [])
        let iosOnlyAudio = YouTubePlayerResponse(status: "OK", reason: nil, formats: [fmt(140, "audio/mp4", 130_000, url: "https://r/x")])
        let tv = YouTubePlayerResponse(status: "OK", reason: nil, formats: [fmt(140, "audio/mp4", 130_000, url: nil, cipher: "s=ok&url=x")])
        let player = FakePlayer(["VISIONOS": login, "IOS": iosOnlyAudio, "TVHTML5": tv])
        let resolver = ChainedYouTubeStreamResolver(player: player, cipher: FakeCipher(), validator: FakeProbe { _ in true })
        let stream = try #require(try await resolver.resolveStream(videoId: "v"))
        #expect(stream.url == "https://r.googlevideo.com/deciphered" && stream.strategyName == "TVHTML5 (deciphered)")
        #expect(await resolver.lastAttempts == ["VISIONOS: LOGIN_REQUIRED — Sign in", "IOS: OK but 1 usable formats",
                                                 "TVHTML5 (deciphered): playable (audio/mp4)"])
    }

    @Test func probeFailuresAndExclusionsAreReported() async throws {
        let ok = YouTubePlayerResponse(status: "OK", reason: nil, formats: [fmt(140, "audio/mp4", 130_000, url: "https://r/dead")])
        let player = FakePlayer(["VISIONOS": ok, "WEB_REMIX": nil])
        let resolver = ChainedYouTubeStreamResolver(player: player, cipher: FakeCipher(), validator: FakeProbe { !$0.contains("dead") })
        #expect(try await resolver.resolveStream(videoId: "v") == nil)
        let attempts = await resolver.lastAttempts
        #expect(attempts.first == "VISIONOS: got URL but HTTP 403")
        #expect(attempts.last == "WEB_REMIX (deciphered): IOS respondió HTTP 400")
        #expect(await resolver.lastSuccessfulStrategy == nil)
        _ = try await resolver.resolveStream(videoId: "v", excludedStrategies: ["VISIONOS", "IOS"])
        #expect(await resolver.lastAttempts.first?.hasPrefix("TVHTML5") == true)
    }

    @Test func cipheredStrategyAppendsTheStreamingPoToken() async throws {
        let response = YouTubePlayerResponse(status: "OK", reason: nil, formats: [fmt(140, "audio/mp4", 1, url: "https://r/p?n=1")], streamingPoToken: "POT")
        let strategy = YouTubeStreamStrategy(kind: .ciphered, profile: InnerTubeContexts.webRemix)
        let outcome = try await strategy.resolve(videoId: "v", player: FakePlayer(["WEB_REMIX": response]), cipher: FakeCipher())
        #expect(outcome.url == "https://r/p?n=1&t&pot=POT" && outcome.detail == "itag 140, plain URL")
        let noCipher = YouTubePlayerResponse(status: "OK", reason: nil, formats: [fmt(140, "audio/mp4", 1, url: nil)], streamingPoToken: "P")
        #expect(try await strategy.resolve(videoId: "v", player: FakePlayer(["WEB_REMIX": noCipher]), cipher: FakeCipher()).detail
                == "itag 140 had neither URL nor cipher")
        let badCipher = YouTubePlayerResponse(status: "OK", reason: nil, formats: [fmt(140, "audio/mp4", 1, url: nil, cipher: "s=bad")], streamingPoToken: "P")
        #expect(try await strategy.resolve(videoId: "v", player: FakePlayer(["WEB_REMIX": badCipher]), cipher: FakeCipher()).detail
                == "could not run base.js")
        let none = YouTubePlayerResponse(status: "OK", reason: nil, formats: [fmt(251, "audio/webm", 1, url: "u")], streamingPoToken: "P")
        #expect(try await strategy.resolve(videoId: "v", player: FakePlayer(["WEB_REMIX": none]), cipher: FakeCipher()).detail
                == "OK but no audio formats")
    }

    @Test func probeClassificationAndRequest() async {
        #expect(StreamProbe.classify(statusCode: 206, contentType: "audio/mp4").describe() == "playable (audio/mp4)")
        #expect(StreamProbe.classify(statusCode: 200, contentType: nil).describe() == "playable (unknown type)")
        #expect(StreamProbe.classify(statusCode: 200, contentType: "application/octet-stream").ok)
        #expect(StreamProbe.classify(statusCode: 200, contentType: "text/html").describe() == "server returned text/html, not audio")
        #expect(StreamProbe.classify(statusCode: 403, contentType: "text/plain").describe() == "HTTP 403")
        #expect(StreamProbe(ok: false).describe() == "unreachable")
        let request = StreamUrlValidator.probeRequest(url: "https://r/v", userAgent: "UA")
        #expect(request.headers == [HTTPHeader("Range", "bytes=0-1"), HTTPHeader("User-Agent", "UA")])
        #expect(StreamUrlValidator.probeRequest(url: "u", userAgent: "UA", sendRange: false).headers == [HTTPHeader("User-Agent", "UA")])
        let validator = StreamUrlValidator(http: FixtureHTTPClient { _ in throw HTTPTransportError(kind: "UnknownHostException", message: "r") })
        #expect(await validator.probe(url: "https://r", userAgent: "UA", sendRange: true).describe() == "UnknownHostException: r")
        let good = StreamUrlValidator(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 206, headers: [HTTPHeader("content-type", "audio/webm")]) })
        #expect(await good.probe(url: "https://r", userAgent: "UA", sendRange: true).ok)
    }

    @Test func timeoutHelperReturnsNilWhenSlow() async throws {
        let slow = try await withTimeout(seconds: 0.05) { () async throws -> Int in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return 1
        }
        #expect(slow == nil)
        #expect(try await withTimeout(seconds: 5) { 7 } == 7)
    }
}

@Suite("Piped")
struct PipedTests {
    @Test func streamsParsingPrefersAudioThenLowestMuxed() throws {
        let body = try Fixtures.text("piped-streams", "json")
        #expect(Piped.choose(streamsBody: body) == .audioOnly("https://pipedproxy.example.org/videoplayback?itag=251&host=rr1.googlevideo.com"))
        #expect(Piped.choose(streamsBody: body, aacOnly: true) == .audioOnly("https://pipedproxy.example.org/videoplayback?itag=140&host=rr1.googlevideo.com"))
        let json = try #require(OrgJSON.object(body))
        #expect(Piped.bestMuxedUrl(json) == "https://pipedproxy.example.org/videoplayback?itag=18")
        #expect(Piped.choose(streamsBody: #"{"audioStreams":[],"videoStreams":[{"url":"https://p/videoplayback?a","mimeType":"video/mp4","quality":"1080p60","videoOnly":false}]}"#)
                == .muxed("https://p/videoplayback?a"))
        #expect(Piped.choose(streamsBody: #"{"audioStreams":[{"url":""}],"videoStreams":[]}"#) == .nothing(audioCount: 1, videoCount: 0))
        #expect(Piped.choose(streamsBody: #"{"error":"bad"}"#) == .invalid)
        #expect(Piped.choose(streamsBody: "<html>") == .invalid)
        #expect(Piped.qualityHeight("720p60") == 720 && Piped.qualityHeight("audio") == nil && Piped.qualityHeight("12 3p") == 3)
    }

    @Test func registryAndCandidates() {
        let hosts = Piped.liveInstances(registryBody: #"[{"api_url":"https://pipedapi.one.org"},{"api_url":""},{"name":"x"},{"api_url":"https://user@two.net:8443/api"},"str"]"#)
        #expect(hosts == ["pipedapi.one.org", "two.net"])
        #expect(Piped.liveInstances(registryBody: "{}").isEmpty)
        #expect(Piped.candidateInstances(live: ["a", "pipedapi.kavin.rocks", "b", "c", "d", "e", "f"])
                == ["a", "pipedapi.kavin.rocks", "b", "c", "d", "e", "f", "api.piped.private.coffee"])
    }

    @Test func resolverFallsBackCoolsDownAndTrustsProxyHosts() async throws {
        let now = Box<Int64>(1_000_000)
        let streams = try Fixtures.text("piped-streams", "json")
        let http = FixtureHTTPClient { request in
            if request.url == Piped.registryURL { return HTTPResponse(statusCode: 200, text: #"[{"api_url":"https://dead.example"},{"api_url":"https://live.example"}]"#) }
            if request.url.hasPrefix("https://live.example/streams/") { return HTTPResponse(statusCode: 200, text: streams) }
            return HTTPResponse(statusCode: 500)
        }
        let resolver = PipedStreamResolver(http: http, nowMs: { now.value })
        let stream = try #require(await resolver.resolve(videoId: "dQw4w9WgXcQ"))
        #expect(stream.url.contains("itag=140") && stream.userAgent == Piped.userAgent)
        #expect(await resolver.lastDetail == "live.example (dQw4w9WgXcQ)")
        #expect(await resolver.trustedHosts.isSuperset(of: ["live.example", "dead.example", "pipedproxy.example.org", "pipedapi.kavin.rocks"]))
        #expect(http.requests.map(\.url).prefix(3) == [Piped.registryURL, "https://dead.example/streams/dQw4w9WgXcQ", "https://live.example/streams/dQw4w9WgXcQ"])

        let down = PipedStreamResolver(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 500) }, nowMs: { now.value })
        #expect(await down.resolve(videoId: "v") == nil)
        #expect(await down.lastDetail == "no Piped instance resolved v")
        now.value += 5_000
        #expect(await down.resolve(videoId: "v") == nil)
        #expect(await down.lastDetail == "cooling down after recent failures, 15s left")
    }
}

@Suite("Google device-code sign-in")
struct GoogleDeviceAuthTests {
    actor MemoryStore: GoogleTokenStore {
        var tokens: GoogleTokens?
        init(_ tokens: GoogleTokens? = nil) { self.tokens = tokens }
        func load() async -> GoogleTokens? { tokens }
        func save(_ tokens: GoogleTokens) async { self.tokens = tokens }
        func clear() async { tokens = nil }
    }

    @Test func requestsAreFormEncodedWithTheTVClient() {
        let code = GoogleDeviceAuth.deviceCodeRequest()
        #expect(code.url == "https://oauth2.googleapis.com/device/code" && code.method == .post)
        #expect(code.bodyText == "client_id=861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com&scope=http%3A%2F%2Fgdata.youtube.com+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fyoutube-paid-content")
        #expect(GoogleDeviceAuth.pollRequest(deviceCode: "DC").bodyText!.hasSuffix("&device_code=DC&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
        #expect(GoogleDeviceAuth.refreshRequest(refreshToken: "1//r").bodyText!.hasSuffix("&refresh_token=1%2F%2Fr&grant_type=refresh_token"))
    }

    @Test func deviceCodeDecoding() throws {
        let code = try #require(GoogleDeviceCode(json: try JSONParser().parse(#"{"device_code":"d","user_code":"ABCD-EFGH","verification_uri":"https://g.co/x","expires_in":"1800","interval":5}"#)))
        #expect(code.verification == "https://g.co/x" && code.expiresIn == 1800 && code.interval == 5)
        #expect(GoogleDeviceCode(json: try JSONParser().parse(#"{"device_code":"d","user_code":"u","expires_in":1}"#))?.verification == "https://www.google.com/device")
        #expect(GoogleDeviceCode(json: try JSONParser().parse(#"{"user_code":"u","expires_in":1}"#)) == nil)
    }

    @Test func pollStepsFollowRFC8628() {
        #expect(GoogleDeviceAuth.pollStep(statusCode: 428, body: GoogleTokenResponse(error: "authorization_pending"), nowMs: 0) == .pending)
        #expect(GoogleDeviceAuth.pollStep(statusCode: 400, body: GoogleTokenResponse(error: "slow_down"), nowMs: 0) == .slowDown)
        #expect(GoogleDeviceAuth.pollStep(statusCode: 400, body: GoogleTokenResponse(error: "access_denied"), nowMs: 0) == .failed("Sign-in was denied."))
        #expect(GoogleDeviceAuth.pollStep(statusCode: 400, body: GoogleTokenResponse(error: "expired_token"), nowMs: 0) == .failed("The code expired. Try again."))
        #expect(GoogleDeviceAuth.pollStep(statusCode: 401, body: GoogleTokenResponse(error: "invalid_client"), nowMs: 0) == .failed("invalid_client"))
        #expect(GoogleDeviceAuth.pollStep(statusCode: 200, body: GoogleTokenResponse(error: "weird"), nowMs: 0) == .pending)
        #expect(GoogleDeviceAuth.pollStep(statusCode: 500, body: nil, nowMs: 0) == .pending)
        #expect(GoogleDeviceAuth.pollStep(statusCode: 200, body: GoogleTokenResponse(accessToken: "a", refreshToken: "r", expiresIn: 10), nowMs: 5)
                == .success(GoogleTokens(accessToken: "a", refreshToken: "r", expiresAtMs: 10_005)))
        #expect(GoogleDeviceAuth.pollStep(statusCode: 200, body: GoogleTokenResponse(accessToken: "a"), nowMs: 0)
                == .success(GoogleTokens(accessToken: "a", refreshToken: nil, expiresAtMs: 3_600_000)))
    }

    @Test func pollingWaitsSlowsDownAndSaves() async throws {
        let replies = Box([#"{"error":"authorization_pending"}"#, #"{"error":"slow_down"}"#, #"{"access_token":"AT","refresh_token":"RT","expires_in":3599}"#])
        let http = FixtureHTTPClient { _ in
            var reply = ""
            replies.mutate { reply = $0.removeFirst() }
            return HTTPResponse(statusCode: reply.contains("access") ? 200 : 428, text: reply)
        }
        let clock = Box<Int64>(0)
        let sleeps = Box<[Int64]>([])
        let store = MemoryStore()
        let client = GoogleDeviceAuthClient(http: http, store: store, nowMs: { clock.value }, sleep: { ms in
            sleeps.mutate { $0.append(ms) }
            clock.mutate { $0 += ms }
        })
        let device = GoogleDeviceCode(deviceCode: "DC", userCode: "U", verificationUrl: nil, verificationUri: nil, expiresIn: 600, interval: nil)
        #expect(try await client.pollForToken(device) == .success)
        #expect(sleeps.value == [5000, 5000, 7000])
        #expect(await store.tokens == GoogleTokens(accessToken: "AT", refreshToken: "RT", expiresAtMs: 17_000 + 3_599_000))
        let expiring = GoogleDeviceAuthClient(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 428, text: #"{"error":"authorization_pending"}"#) },
                                              store: MemoryStore(), nowMs: { clock.value }, sleep: { ms in clock.mutate { $0 += ms } })
        #expect(try await expiring.pollForToken(GoogleDeviceCode(deviceCode: "d", userCode: "u", verificationUrl: nil, verificationUri: nil, expiresIn: 12, interval: 5))
                == .failed("Timed out waiting for sign-in."))
    }

    @Test func refreshKeepsTheRefreshTokenAndSignsOutOnInvalidGrant() async throws {
        let store = MemoryStore(GoogleTokens(accessToken: "old", refreshToken: "RT", expiresAtMs: 0))
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: #"{"access_token":"new","expires_in":100}"#) }
        let client = GoogleDeviceAuthClient(http: http, store: store, nowMs: { 1000 }, sleep: { _ in })
        #expect(await client.validAccessToken() == "new")
        #expect(await store.tokens == GoogleTokens(accessToken: "new", refreshToken: "RT", expiresAtMs: 101_000))
        let fresh = MemoryStore(GoogleTokens(accessToken: "valid", refreshToken: "RT", expiresAtMs: 10_000_000))
        #expect(await GoogleDeviceAuthClient(http: http, store: fresh, nowMs: { 0 }, sleep: { _ in }).validAccessToken() == "valid")
        let dead = MemoryStore(GoogleTokens(accessToken: "x", refreshToken: "RT", expiresAtMs: 0))
        let rejecting = GoogleDeviceAuthClient(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 400, text: #"{"error":"invalid_grant"}"#) },
                                               store: dead, nowMs: { 0 }, sleep: { _ in })
        #expect(await rejecting.validAccessToken() == nil)
        #expect(await dead.tokens == nil)
        #expect(GoogleDeviceAuth.authorizationHeader(accessToken: "t") == "Bearer t")
        #expect(GoogleDeviceAuth.refreshOutcome(GoogleTokenResponse(error: "temporarily_unavailable"), previousRefreshToken: "r", nowMs: 0) == .failed)
    }
}
