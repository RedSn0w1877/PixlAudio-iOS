import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

/// Stage 11: the PoToken helpers (Android `JavaScriptUtil.kt`), the streaming cache's range bookkeeping, remote
/// client profiles, the resolver's strategy provider and the playback test (Android `PlaybackDiagnostics.kt`).
@Suite("PoToken helpers")
struct PoTokenJSTests {
    /// Scrambles a challenge the way the `Create` endpoint does (bytes − 97, URL-safe base64).
    static func scramble(_ text: String) -> String {
        let bytes = Array(text.utf8).map { $0 &- 97 }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    static let innerChallenge = #"["msg-1",[null,"(function(){var vm=1})()"],[null,"https://www.google.com/js/bg/x.js"],"hash-9","PROGRAM==","trayride",null,"blob-7"]"#
    static let expected = #"{"messageId":"msg-1","interpreterJavascript":{"privateDoNotAccessOrElseSafeScriptWrappedValue":"(function(){var vm=1})()","privateDoNotAccessOrElseTrustedResourceUrlWrappedValue":"https://www.google.com/js/bg/x.js"},"interpreterHash":"hash-9","program":"PROGRAM==","globalName":"trayride","clientExperimentsStateBlob":"blob-7"}"#

    @Test func scrambledChallengeIsDescrambled() throws {
        let raw = "[\"ignored\",\"\(Self.scramble(Self.innerChallenge))\"]"
        #expect(try PoTokenJS.parseChallengeData(raw) == Self.expected)
    }

    @Test func plainChallengeIsTheFirstArray() throws {
        let raw = "[\(Self.innerChallenge)]"
        #expect(try PoTokenJS.parseChallengeData(raw) == Self.expected)
    }

    @Test func missingChallengeFieldsBecomeNull() throws {
        let raw = #"[["only-id"]]"#
        let out = try PoTokenJS.parseChallengeData(raw)
        #expect(out == #"{"messageId":"only-id","interpreterJavascript":{"privateDoNotAccessOrElseSafeScriptWrappedValue":null,"privateDoNotAccessOrElseTrustedResourceUrlWrappedValue":null},"interpreterHash":null,"program":null,"globalName":null,"clientExperimentsStateBlob":null}"#)
    }

    @Test func garbageChallengeThrows() {
        #expect(throws: PoTokenJS.ParseError.self) { try PoTokenJS.parseChallengeData("{}") }
        #expect(throws: PoTokenJS.ParseError.self) { try PoTokenJS.parseChallengeData(#"["a","%%%"]"#) }
    }

    @Test func integrityTokenDecodesUrlSafeBase64WithoutPadding() throws {
        // bytes 251, 255, 0, 1 → standard "+/8AAQ==" → URL-safe "-_8AAQ" (no padding, as YouTube sends it).
        let parsed = try PoTokenJS.parseIntegrityTokenData(#"["-_8AAQ",43200,"extra"]"#)
        #expect(parsed.token == [251, 255, 0, 1])
        #expect(parsed.expiresInSeconds == 43200)
        let dotted = try PoTokenJS.parseIntegrityTokenData(#"["-_8AAQ..",3600]"#)
        #expect(dotted.token == [251, 255, 0, 1])
    }

    @Test func tokensAreUrlSafeBase64WithPadding() {
        #expect(PoTokenJS.bytesToBase64URL([251, 255, 0, 1]) == "-_8AAQ==")
        #expect(PoTokenJS.u8StringToBase64URL("251,255,0,1") == "-_8AAQ==")
        #expect(PoTokenJS.u8StringToBase64URL("256,1") == nil)
        #expect(PoTokenJS.stringToU8("ab") == "new Uint8Array([97,98])")
    }

    @Test func requestsCarryTheBotGuardHeaders() {
        let create = PoTokenJS.createRequest()
        #expect(create.url == "https://www.youtube.com/api/jnn/v1/Create")
        #expect(create.method == .post)
        #expect(create.bodyText == #"[ "O43z0dpjhgX20SCx4KAo" ]"#)
        #expect(create.header("x-goog-api-key") == PoTokenJS.googleAPIKey)
        #expect(create.header("x-user-agent") == "grpc-web-javascript/0.1")
        #expect(create.header("Content-Type") == "application/json+protobuf; charset=utf-8")
        let generate = PoTokenJS.generateITRequest(botguardResponse: "bg-resp")
        #expect(generate.bodyText == #"[ "O43z0dpjhgX20SCx4KAo", "bg-resp" ]"#)
    }

    @Test func generatorsExpireTenMinutesEarly() {
        #expect(!PoTokenJS.isExpired(createdAtSeconds: 1000, lifetimeSeconds: 3600, nowSeconds: 1000 + 3000))
        #expect(PoTokenJS.isExpired(createdAtSeconds: 1000, lifetimeSeconds: 3600, nowSeconds: 1000 + 3001))
    }
}

@Suite("Streaming cache ranges")
struct ByteRangeSetTests {
    @Test func insertMergesOverlappingAndTouchingRanges() {
        var set = ByteRangeSet()
        set.insert(10..<20)
        set.insert(30..<40)
        #expect(set.spans.map(\.range) == [10..<20, 30..<40])
        set.insert(20..<25) // touches the first
        #expect(set.spans.map(\.range) == [10..<25, 30..<40])
        set.insert(0..<5) // before everything
        #expect(set.spans.map(\.range) == [0..<5, 10..<25, 30..<40])
        set.insert(4..<31) // bridges all three
        #expect(set.spans.map(\.range) == [0..<40])
        set.insert(50..<50) // empty is ignored
        #expect(set.coveredBytes == 40)
    }

    @Test func containsAndContiguousLength() {
        let set = ByteRangeSet([0..<100, 200..<300])
        #expect(set.contains(10..<90))
        #expect(!set.contains(90..<110))
        #expect(set.contains(5..<5))
        #expect(set.contiguousLength(from: 50) == 50)
        #expect(set.contiguousLength(from: 50, limit: 10) == 10)
        #expect(set.contiguousLength(from: 150) == 0)
        #expect(set.contiguousLength(from: 100) == 0)
    }

    @Test func gapsAndNextGap() {
        let set = ByteRangeSet([0..<100, 200..<300])
        #expect(set.gaps(in: 50..<350) == [100..<200, 300..<350])
        #expect(set.gaps(in: 0..<100).isEmpty)
        #expect(set.gaps(in: 120..<150) == [120..<150])
        #expect(set.nextGap(from: 0, length: 400, maxLength: 64) == 100..<164)
        #expect(set.nextGap(from: 250, length: 400, maxLength: 1000) == 300..<400)
        #expect(ByteRangeSet([0..<400]).nextGap(from: 0, length: 400, maxLength: 10) == nil)
    }

    @Test func completeness() {
        #expect(ByteRangeSet([0..<10]).isComplete(length: 10))
        #expect(!ByteRangeSet([0..<9]).isComplete(length: 10))
        #expect(!ByteRangeSet().isComplete(length: 0))
    }

    @Test func codableRoundTripNormalises() throws {
        let set = ByteRangeSet([5..<9, 0..<5, 20..<30])
        let data = try JSONEncoder().encode(set)
        #expect(String(decoding: data, as: UTF8.self) == "[[0,9],[20,30]]")
        let messy = Data("[[20,30],[0,5],[4,9],[7,3],[-2,1]]".utf8)
        #expect(try JSONDecoder().decode(ByteRangeSet.self, from: messy) == set)
    }

    @Test func contentRangeParsing() {
        let value = ContentRange.parse("bytes 0-1/4031289")
        #expect(value?.start == 0)
        #expect(value?.endInclusive == 1)
        #expect(value?.total == 4031289)
        #expect(ContentRange.parse("bytes 100-199/*")?.total == nil)
        #expect(ContentRange.parse("bytes 5-1/10") == nil)
        #expect(ContentRange.parse("bytes 0-9/9") == nil)
        #expect(ContentRange.parse("items 0-1/2") == nil)
        #expect(ContentRange.parse(nil) == nil)
        #expect(ContentRange.requestHeader(0..<524_288) == "bytes=0-524287")
    }
}

@Suite("Remote client config")
struct RemoteClientConfigTests {
    @Test func builtInChainMatchesTheResolverDefault() {
        for signedIn in [false, true] {
            #expect(RemoteClientConfig.builtIn.chain(signedIn: signedIn) == YouTubeStreamStrategy.chain(signedIn: signedIn))
        }
        #expect(RemoteClientConfig.builtIn.chain(signedIn: false).first?.name == "VISIONOS")
    }

    @Test func overridesVersionsAndOrder() throws {
        let text = """
        {"schema": 1, "innertube": {
          "note": "IOS bump",
          "profiles": {"IOS": {"clientVersion": "21.30.1", "userAgent": "com.google.ios.youtube/21.30.1 (iPhone16,2)"},
                       "TVHTML5": {"clientVersion": "7.20261001"}},
          "preSignedOrder": ["IOS", "VISIONOS", "IOS", "NOPE"],
          "cipheredOrder": ["WEB_REMIX", "WEB"]}}
        """
        let config = try #require(RemoteClientConfig.parse(text))
        #expect(config.note == "IOS bump")
        #expect(config.profiles["IOS"]?.clientVersion == "21.30.1")
        #expect(config.profiles["IOS"]?.userAgent == "com.google.ios.youtube/21.30.1 (iPhone16,2)")
        #expect(config.profiles["IOS"]?.apiKey == InnerTubeContexts.iOS.apiKey)
        #expect(config.chain(signedIn: false).map(\.name) == ["IOS", "VISIONOS", "WEB_REMIX (deciphered)"])
        #expect(config.chain(signedIn: true).map(\.name) == ["IOS", "VISIONOS", "WEB_REMIX (deciphered)", "WEB (deciphered)"])
    }

    @Test func nativeClientsNeverGetCookiesAndHostsAreAllowListed() throws {
        let text = """
        {"innertube": {"profiles": {
          "VISIONOS": {"supportsCookies": true, "baseUrl": "https://evil.example/youtubei/v1/"},
          "TVHTML5": {"supportsCookies": false},
          "NEWTV": {"clientName": "TVHTML5_SIMPLY", "clientVersion": "1.0", "userAgent": "UA", "clientNameId": 75,
                    "expectsPreSignedUrls": true, "supportsCookies": true},
          "BADHOST": {"clientName": "X", "clientVersion": "1", "userAgent": "UA", "clientNameId": 3, "baseUrl": "http://localhost/"},
          "bad name": {"clientName": "X", "clientVersion": "1", "userAgent": "UA", "clientNameId": 3},
          "NOFIELDS": {"clientVersion": "1"}},
          "preSignedOrder": ["NEWTV", "VISIONOS"]}}
        """
        let config = try #require(RemoteClientConfig.parse(text))
        #expect(config.profiles["VISIONOS"]?.supportsCookies == false)
        #expect(config.profiles["VISIONOS"]?.baseUrl == InnerTubeContexts.baseURL)
        #expect(config.profiles["TVHTML5"]?.supportsCookies == false)
        #expect(config.profiles["NEWTV"]?.supportsCookies == true)
        #expect(config.profiles["NEWTV"]?.clientNameId == 75)
        #expect(config.profiles["BADHOST"] == nil)
        #expect(config.profiles["bad name"] == nil)
        #expect(config.profiles["NOFIELDS"] == nil)
        #expect(config.chain(signedIn: false).prefix(2).map(\.name) == ["NEWTV", "VISIONOS"])
    }

    @Test func malformedOrNewerFilesAreIgnored() {
        #expect(RemoteClientConfig.parse("not json") == nil)
        #expect(RemoteClientConfig.parse("[]") == nil)
        #expect(RemoteClientConfig.parse(#"{"schema": 2, "innertube": {}}"#) == nil)
        #expect(RemoteClientConfig.parse(#"{"schema": 1}"#) == nil)
        let empty = RemoteClientConfig.parse(#"{"innertube": {"preSignedOrder": ["NOPE"]}}"#)
        #expect(empty?.preSignedOrder == nil)
        #expect(empty?.chain(signedIn: false) == YouTubeStreamStrategy.chain(signedIn: false))
    }

    @Test func theRepositoryFileParses() throws {
        // remote/config.json in the repo root is what the app fetches.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let file = url.appendingPathComponent("remote").appendingPathComponent("config.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        let config = try #require(RemoteClientConfig.parse(text))
        #expect(config.chain(signedIn: false).first?.name == "VISIONOS")
    }
}

@Suite("Resolver strategies")
struct ResolverStrategyProviderTests {
    struct Player: YouTubePlayerFetching {
        let log: Box<[String]>
        func fetchPlayer(videoId: String, profile: InnerTubeClientProfile) async throws -> YouTubePlayerResponse? {
            log.mutate { $0.append(profile.name + "/" + profile.clientVersion) }
            if profile.name == "IOS" {
                return YouTubePlayerResponse(status: "OK", reason: nil, formats: [
                    YouTubeAudioFormat(itag: 18, mimeType: "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", bitrate: 500_000,
                                       url: "https://r1.googlevideo.com/videoplayback?itag=18", signatureCipher: nil,
                                       contentLength: 10, approxDurationMs: 1000, isMuxedFallback: true),
                ])
            }
            return YouTubePlayerResponse(status: "LOGIN_REQUIRED", reason: "bot", formats: [])
        }
        var lastFailureReason: String? { get async { nil } }
    }

    struct NoCipher: CipherResolving {
        func resolveCipheredUrl(_ signatureCipher: String) async -> String? { nil }
        func applyNTransform(_ url: String) async -> String { url }
    }

    @Test func remoteChainDrivesTheResolver() async throws {
        let log = Box<[String]>([])
        let config = try #require(RemoteClientConfig.parse(#"{"innertube": {"profiles": {"IOS": {"clientVersion": "99.0"}}, "preSignedOrder": ["VISIONOS", "IOS"]}}"#))
        let resolver = ChainedYouTubeStreamResolver(player: Player(log: log), cipher: NoCipher(), validator: nil,
                                                    strategies: { config.chain(signedIn: $0) })
        let stream = try await resolver.resolveStream(videoId: "dQw4w9WgXcQ", validate: false)
        #expect(stream?.strategyName == "IOS")
        #expect(stream?.url == "https://r1.googlevideo.com/videoplayback?itag=18")
        #expect(log.value == ["VISIONOS/1.02", "IOS/99.0"])
        #expect(await resolver.lastAttempts.first == "VISIONOS: LOGIN_REQUIRED — bot")
    }
}

@Suite("Playback diagnostics")
struct PlaybackDiagnosticsTests {
    struct Search: YouTubeMusicSearching {
        let results: [YouTubeSearchResult]
        func searchSongs(_ query: String, limit: Int) async throws -> [YouTubeSearchResult] { results }
        func searchVideos(_ query: String, limit: Int) async throws -> [YouTubeSearchResult] { [] }
    }

    static let hit = YouTubeSearchResult(videoId: "abcdefghijk", title: "Northern Lights", artist: "Nova", album: "First Light",
                                         durationSeconds: 180)
    static let track = DiagnosticsTrack(title: "Northern Lights", artist: "Nova, Guest", album: "First Light",
                                        durationMs: 180_000, videoId: nil)

    func diagnostics(results: [YouTubeSearchResult] = [hit], outcome: StreamResolutionOutcome,
                     probe: StreamProbe = StreamProbe(ok: true, httpStatus: 206, contentType: "audio/mp4")) -> PlaybackDiagnostics {
        PlaybackDiagnostics(search: Search(results: results), lastSearchFailure: { "WEB_REMIX respondió HTTP 403" },
                            resolve: { _ in outcome }, probeLoader: { _, _ in probe })
    }

    static let okOutcome = StreamResolutionOutcome(
        stream: ResolvedStream(url: "https://r1.googlevideo.com/videoplayback", userAgent: "UA", strategyName: "VISIONOS"),
        attempts: ["VISIONOS: playable (audio/mp4)"], successfulStrategy: "VISIONOS")

    @Test func noTrackFailsFirst() async {
        let report = await diagnostics(outcome: Self.okOutcome).run(track: nil)
        #expect(!report.succeeded)
        #expect(report.steps.map(\.title) == ["Imported tracks"])
    }

    @Test func everyStepGreen() async {
        let report = await diagnostics(outcome: Self.okOutcome).run(track: Self.track)
        #expect(report.succeeded)
        #expect(report.steps.map(\.title) == ["Imported tracks", "YouTube Music search", "Track matching", "Audio stream", "Streaming loader"])
        let allGreen = report.steps.allSatisfy { $0.ok }
        #expect(allGreen)
        #expect(report.steps[1].detail == "1 candidates, top one: \"Northern Lights\".")
        #expect(report.steps[2].detail.hasPrefix("Matched \"Northern Lights\" (score "))
        #expect(report.steps[3].detail == "Playable via VISIONOS.")
        #expect(report.steps[4].detail == "Audio reaches the player (audio/mp4).")
        #expect(report.asPlainText().hasPrefix("OK  Imported tracks — Testing with \"Northern Lights\" by Nova, Guest.\n"))
    }

    @Test func searchFailureUsesTheClientReason() async {
        let report = await diagnostics(results: [], outcome: Self.okOutcome).run(track: Self.track)
        #expect(report.steps.last?.title == "YouTube Music search")
        #expect(report.steps.last?.detail == "WEB_REMIX respondió HTTP 403")
    }

    @Test func weakMatchReportsTheBestScore() async {
        let other = YouTubeSearchResult(videoId: "zzzzzzzzzzz", title: "Something Else", artist: "Nobody", album: nil, durationSeconds: 30)
        let report = await diagnostics(results: [other], outcome: Self.okOutcome).run(track: Self.track)
        #expect(report.steps.last?.title == "Track matching")
        #expect(report.steps.last?.detail == "Found results but none scored high enough (best 0.00, need 0.55).")
    }

    @Test func youTubeSongsSkipMatching() async {
        var track = Self.track
        track.videoId = "dQw4w9WgXcQ"
        let report = await diagnostics(outcome: Self.okOutcome).run(track: track)
        #expect(report.steps[2].detail == "Already linked to video dQw4w9WgXcQ (picked in YouTube Music search).")
    }

    @Test func streamFailureListsEveryClient() async {
        let failed = StreamResolutionOutcome(stream: nil, attempts: ["VISIONOS: HTTP 400", "IOS: LOGIN_REQUIRED"], successfulStrategy: nil)
        let report = await diagnostics(outcome: failed).run(track: Self.track)
        #expect(report.steps.last?.detail == "Every YouTube client refused:\n• VISIONOS: HTTP 400\n• IOS: LOGIN_REQUIRED")
        let silent = StreamResolutionOutcome(stream: nil, attempts: [], successfulStrategy: nil)
        #expect(await diagnostics(outcome: silent).run(track: Self.track).steps.last?.detail
                == "No YouTube client responded at all — check the internet connection.")
    }

    @Test func rejectedClientsAreListedOnSuccess() async {
        let outcome = StreamResolutionOutcome(stream: Self.okOutcome.stream, attempts: ["VISIONOS: HTTP 400", "IOS: playable"],
                                              successfulStrategy: "IOS")
        let report = await diagnostics(outcome: outcome).run(track: Self.track)
        #expect(report.steps[3].detail == "Playable via IOS.\nTried first:\n• VISIONOS: HTTP 400")
    }

    @Test func loaderFailureIsTheLastRedLine() async {
        let report = await diagnostics(outcome: Self.okOutcome, probe: StreamProbe(ok: false, httpStatus: 403)).run(track: Self.track)
        #expect(!report.succeeded)
        #expect(report.steps.last?.ok == false)
        #expect(report.steps.last?.detail.hasPrefix("The player's own route failed: HTTP 403.") == true)
    }

    @Test func scoresFormatLikeKotlin() {
        #expect(PlaybackDiagnostics.twoDecimals(0.55) == "0.55")
        #expect(PlaybackDiagnostics.twoDecimals(0.005) == "0.00") // 0.005f is 0.00499999988… as a double, like Java
        #expect(PlaybackDiagnostics.twoDecimals(1) == "1.00")
        #expect(PlaybackDiagnostics.twoDecimals(0.9049) == "0.90")
    }
}
