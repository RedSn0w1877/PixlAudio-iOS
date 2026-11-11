import Foundation
import Testing
@testable import PixlNet

/// iOS plays YouTube's Opus stream from a file repackaged ahead of time: which stream, when, and what is remembered.
@Suite("Opus upgrade: which stream")
struct OpusFormatChoiceTests {
    func fmt(_ itag: Int, _ mime: String?, _ bitrate: Int, url: String? = "u", muxed: Bool = false) -> YouTubeAudioFormat {
        YouTubeAudioFormat(itag: itag, mimeType: mime, bitrate: bitrate, url: url, signatureCipher: url == nil ? "s=1&url=x" : nil,
                           contentLength: nil, approxDurationMs: nil, isMuxedFallback: muxed)
    }

    var opus251: YouTubeAudioFormat { fmt(251, "audio/webm; codecs=\"opus\"", 160_000) }
    var aac140: YouTubeAudioFormat { fmt(140, "audio/mp4; codecs=\"mp4a.40.2\"", 130_000) }
    var aac141: YouTubeAudioFormat { fmt(141, "audio/mp4; codecs=\"mp4a.40.2\"", 256_000) }

    @Test func opus251ReplacesAAC140() throws {
        #expect(AudioFormatSelection.pickOpusUpgrade([aac140, opus251])?.itag == 251)
        // The real-shaped response: 18, 140, 251, a ciphered 139.
        let response = InnerTubeParsing.playerResponse(try Fixtures.json("innertube-player"))
        #expect(AudioFormatSelection.pickOpusUpgrade(response.formats)?.itag == 251)
        #expect(AudioFormatPolicy.opusUpgrade.pick(response.formats, maxBitrateKbps: nil)?.itag == 251)
        // What the other policies pick is unchanged.
        #expect(AudioFormatPolicy.iOS.pick(response.formats, maxBitrateKbps: nil)?.itag == 140)
        #expect(AudioFormatPolicy.android.pick(response.formats, maxBitrateKbps: nil)?.itag == 251)
    }

    @Test func aBetterAACStreamStaysAAC() {
        #expect(AudioFormatSelection.pickOpusUpgrade([aac141, aac140, opus251]) == nil)
        // Under a 160 kbps cap 141 is out, and 251 (160 kbps) beats 140.
        #expect(AudioFormatSelection.pickOpusUpgrade([aac141, aac140, opus251], maxBitrateKbps: 160)?.itag == 251)
        // YouTube Music's 256 kbps Opus against the 256 kbps AAC: equal bitrate, Opus (Android's rule).
        let opus774 = fmt(774, "audio/webm; codecs=\"opus\"", 256_000)
        #expect(AudioFormatSelection.pickOpusUpgrade([aac141, opus251, opus774])?.itag == 774)
    }

    @Test func neverOverTheCapNeverAWorseOrMultichannelOpus() {
        #expect(AudioFormatSelection.pickOpusUpgrade([aac140, opus251], maxBitrateKbps: 128) == nil)
        #expect(AudioFormatSelection.pickOpusUpgrade([aac140, opus251], maxBitrateKbps: 96) == nil)
        let opus250 = fmt(250, "audio/webm; codecs=\"opus\"", 70_000)
        let opus249 = fmt(249, "audio/webm; codecs=\"opus\"", 50_000)
        #expect(AudioFormatSelection.pickOpusUpgrade([aac140, opus250, opus249]) == nil)
        let ambisonic = fmt(338, "audio/webm; codecs=\"opus\"", 480_000)
        #expect(AudioFormatSelection.pickOpusUpgrade([aac140, ambisonic]) == nil)
        #expect(AudioFormatSelection.pickOpusUpgrade([aac140, ambisonic, opus251])?.itag == 251)
    }

    @Test func opusWithoutAnAACStreamStillBeatsTheMuxedFallback() {
        let muxed = fmt(18, "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", 600_000, muxed: true)
        #expect(AudioFormatSelection.pickOpusUpgrade([muxed, opus251])?.itag == 251)
        #expect(AudioFormatSelection.pickOpusUpgrade([muxed]) == nil)
        #expect(AudioFormatSelection.pickOpusUpgrade([]) == nil)
        // An Opus itag without a MIME type still counts; an AAC MIME type under an Opus itag does not.
        #expect(AudioFormatSelection.pickOpusUpgrade([aac140, fmt(251, nil, 160_000)])?.itag == 251)
        #expect(AudioFormatSelection.pickOpusUpgrade([fmt(251, "audio/mp4; codecs=\"mp4a.40.2\"", 160_000)]) == nil)
    }

    actor Player: YouTubePlayerFetching {
        var responses: [String: YouTubePlayerResponse]
        var asked: [String] = []
        var lastFailureReason: String? = "refused"
        init(_ responses: [String: YouTubePlayerResponse]) { self.responses = responses }
        func fetchPlayer(videoId: String, profile: InnerTubeClientProfile) async throws -> YouTubePlayerResponse? {
            asked.append(profile.name)
            return responses[profile.name]
        }
    }

    struct Cipher: CipherResolving {
        func resolveCipheredUrl(_ signatureCipher: String) async -> String? { "https://r1.googlevideo.com/deciphered?itag=251" }
        func applyNTransform(_ url: String) async -> String { url + "&t" }
    }

    @Test func theOpusChainReusesTheAACChainsResponse() async throws {
        let ok = YouTubePlayerResponse(status: "OK", reason: nil, formats: [
            fmt(140, "audio/mp4; codecs=\"mp4a.40.2\"", 130_000, url: "https://r1.googlevideo.com/videoplayback?itag=140&dur=212.091&n=a"),
            fmt(251, "audio/webm; codecs=\"opus\"", 160_000, url: "https://r1.googlevideo.com/videoplayback?itag=251&dur=212.061&clen=3400000&n=b"),
        ])
        let player = Player(["VISIONOS": ok])
        let memo = PlayerResponseMemo(inner: player)
        let aac = ChainedYouTubeStreamResolver(player: memo.live, cipher: Cipher(), validator: nil, policy: .iOS)
        let opus = ChainedYouTubeStreamResolver(player: memo.remembered, cipher: Cipher(), validator: nil, policy: .opusUpgrade)
        let aacStream = try #require(try await aac.resolveStream(videoId: "dQw4w9WgXcQ", validate: false))
        let opusStream = try #require(try await opus.resolveStream(videoId: "dQw4w9WgXcQ", validate: false))
        #expect(await player.asked == ["VISIONOS"])   // one request for both
        #expect(opusStream.url.contains("itag=251") && opusStream.userAgent == InnerTubeContexts.visionOS.userAgent)
        let resolution = OpusStreamResolution(stream: opusStream, aacStreamURL: aacStream.url)
        #expect(resolution.itag == 251)
        #expect(resolution.opusDurationMs == 212_061)
        #expect(resolution.aacDurationMs == 212_091)
        #expect(resolution.contentLength == 3_400_000)
        #expect(OpusStreamPolicy.durationsAgree(resolution.opusDurationMs, resolution.aacDurationMs))
    }

    @Test func noOpusMeansTheNextClientsAreAskedThenNothing() async throws {
        let aacOnly = YouTubePlayerResponse(status: "OK", reason: nil, formats: [
            fmt(140, "audio/mp4; codecs=\"mp4a.40.2\"", 130_000, url: "https://r1.googlevideo.com/videoplayback?itag=140"),
        ])
        let player = Player(["VISIONOS": aacOnly])
        let memo = PlayerResponseMemo(inner: player)
        let opus = ChainedYouTubeStreamResolver(player: memo.remembered, cipher: Cipher(), validator: nil, policy: .opusUpgrade)
        #expect(try await opus.resolveStream(videoId: "dQw4w9WgXcQ", validate: false) == nil)
        #expect(await opus.lastAttempts.first == "VISIONOS: OK but 1 usable formats")
    }
}

@Suite("Opus upgrade: the response memo")
struct PlayerResponseMemoTests {
    actor Counting: YouTubePlayerFetching {
        var calls = 0
        var playable = true
        var lastFailureReason: String? = "HTTP 400"
        func fetchPlayer(videoId: String, profile: InnerTubeClientProfile) async throws -> YouTubePlayerResponse? {
            calls += 1
            return YouTubePlayerResponse(status: playable ? "OK" : "LOGIN_REQUIRED", reason: nil, formats: [])
        }
        func setPlayable(_ value: Bool) { playable = value }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 1_000.0
        var now: Double { lock.withLock { value } }
        func advance(_ seconds: Double) { lock.withLock { value += seconds } }
    }

    @Test func liveAlwaysAsksRememberedReusesForTenMinutes() async throws {
        let inner = Counting()
        let clock = Clock()
        let memo = PlayerResponseMemo(inner: inner, now: { clock.now })
        let profile = InnerTubeContexts.visionOS
        _ = try await memo.live.fetchPlayer(videoId: "a", profile: profile)
        _ = try await memo.live.fetchPlayer(videoId: "a", profile: profile)
        #expect(await inner.calls == 2)
        _ = try await memo.remembered.fetchPlayer(videoId: "a", profile: profile)
        #expect(await inner.calls == 2)
        // Another client or another video is not in memory.
        _ = try await memo.remembered.fetchPlayer(videoId: "a", profile: InnerTubeContexts.tvHTML5)
        _ = try await memo.remembered.fetchPlayer(videoId: "b", profile: profile)
        #expect(await inner.calls == 4)
        clock.advance(PlayerResponseMemo.lifetimeSeconds + 1)
        _ = try await memo.remembered.fetchPlayer(videoId: "a", profile: profile)
        #expect(await inner.calls == 5)
        await memo.forget(videoId: "a")
        _ = try await memo.remembered.fetchPlayer(videoId: "a", profile: profile)
        #expect(await inner.calls == 6)
        #expect(await memo.remembered.lastFailureReason == "HTTP 400")
    }

    @Test func refusalsAreNotRememberedAndMemoryIsBounded() async throws {
        let inner = Counting()
        await inner.setPlayable(false)
        let memo = PlayerResponseMemo(inner: inner)
        _ = try await memo.live.fetchPlayer(videoId: "a", profile: InnerTubeContexts.visionOS)
        _ = try await memo.remembered.fetchPlayer(videoId: "a", profile: InnerTubeContexts.visionOS)
        #expect(await inner.calls == 2)
        await inner.setPlayable(true)
        for i in 0...PlayerResponseMemo.capacity {
            _ = try await memo.live.fetchPlayer(videoId: "v\(i)", profile: InnerTubeContexts.visionOS)
        }
        let before = await inner.calls
        _ = try await memo.remembered.fetchPlayer(videoId: "v0", profile: InnerTubeContexts.visionOS)   // pushed out
        _ = try await memo.remembered.fetchPlayer(videoId: "v\(PlayerResponseMemo.capacity)", profile: InnerTubeContexts.visionOS)
        #expect(await inner.calls == before + 1)
    }
}

@Suite("Opus upgrade: when, and what is remembered")
struct OpusStreamPolicyTests {
    typealias Conditions = StreamPrefetchPolicy.Conditions

    @Test func onlyUnmeteredWiFiOrEthernetWithoutLowPower() {
        func allows(_ c: Conditions, lowPower: Bool = false, memory: Bool = false, launch: Bool = true) -> Bool {
            OpusStreamPolicy.allowsPreparation(c, lowPowerMode: lowPower, recentMemoryPressure: memory, launchWorkAllowed: launch)
        }
        #expect(allows(Conditions(network: .wifi)))
        #expect(allows(Conditions(network: .wired)))
        #expect(!allows(Conditions(network: .wifi, isExpensive: true)))        // a personal hotspot
        #expect(!allows(Conditions(network: .wifi, isConstrained: true)))      // Low Data Mode
        #expect(!allows(Conditions(network: .cellular)))
        #expect(!allows(Conditions(network: .other)))
        #expect(!allows(Conditions(network: .offline)))
        #expect(!allows(.unknown))
        #expect(!allows(Conditions(network: .wifi), lowPower: true))
        #expect(!allows(Conditions(network: .wifi), memory: true))
        #expect(!allows(Conditions(network: .wifi), launch: false))
    }

    @Test func readsYouTubesOwnLengthsSizesAndItags() {
        let url = "https://rr1---sn-x.googlevideo.com/videoplayback?expire=1&itag=251&source=youtube&clen=3409215&dur=212.061&lmt=1"
        #expect(OpusStreamPolicy.durationMs(streamURL: url) == 212_061)
        #expect(OpusStreamPolicy.contentLength(streamURL: url) == 3_409_215)
        #expect(OpusStreamPolicy.itag(streamURL: url) == 251)
        #expect(OpusStreamPolicy.durationMs(streamURL: "https://h/p?dur=abc") == nil)
        #expect(OpusStreamPolicy.durationMs(streamURL: "https://h/p") == nil)
        #expect(OpusStreamPolicy.contentLength(streamURL: "https://h/p?clen=0") == nil)
        #expect(OpusStreamPolicy.durationsAgree(212_061, 212_091))
        #expect(OpusStreamPolicy.durationsAgree(212_061, 212_111))
        #expect(!OpusStreamPolicy.durationsAgree(212_061, 212_112))
        #expect(OpusStreamPolicy.durationsAgree(nil, 212_000))
        #expect(OpusStreamPolicy.durationsAgree(212_000, nil))
    }

    @Test func theDecodeMustLoseThePreSkipAndMayKeepTheEndPadding() {
        // The 1 s app fixture: 48,000 valid frames, 312 pre-skip, 648 padded at the end.
        #expect(OpusStreamPolicy.acceptsDecodedFrames(48_000, validSamples: 48_000, endTrim: 648))
        #expect(OpusStreamPolicy.acceptsDecodedFrames(48_648, validSamples: 48_000, endTrim: 648))   // what AVAssetReader does
        #expect(OpusStreamPolicy.acceptsDecodedFrames(48_040, validSamples: 48_000, endTrim: 648))
        #expect(!OpusStreamPolicy.acceptsDecodedFrames(48_312, validSamples: 48_000, endTrim: 648))  // pre-skip not cut
        #expect(!OpusStreamPolicy.acceptsDecodedFrames(48_960, validSamples: 48_000, endTrim: 648))  // nothing cut
        #expect(!OpusStreamPolicy.acceptsDecodedFrames(47_000, validSamples: 48_000, endTrim: 648))
        #expect(!OpusStreamPolicy.acceptsDecodedFrames(0, validSamples: 48_000, endTrim: 0))
    }

    @Test func failuresHoldForTheirKindsWindow() {
        var ledger = OpusFailureLedger()
        let t = 1_000_000.0
        ledger.record(.network, detail: "timed out", videoId: "a", now: t, os: "26.1")
        ledger.record(.remux, detail: "odd file", videoId: "b", now: t, os: "26.1")
        ledger.record(.noOpusOffered, detail: "VISIONOS: OK but 1 usable formats", videoId: "c", now: t, os: "26.1")
        #expect(ledger.failure(videoId: "a", now: t + 60)?.kind == .network)
        #expect(ledger.failure(videoId: "a", now: t + 31 * 60) == nil)
        #expect(ledger.failure(videoId: "b", now: t + 29 * 86_400)?.detail == "odd file")
        #expect(ledger.failure(videoId: "b", now: t + 31 * 86_400) == nil)
        #expect(ledger.failure(videoId: "c", now: t + 6 * 86_400) != nil)
        #expect(ledger.failure(videoId: "c", now: t + 8 * 86_400) == nil)
        #expect(ledger.failure(videoId: "z", now: t) == nil)
        ledger.recordSuccess(videoId: "b", os: "26.1")
        #expect(ledger.failure(videoId: "b", now: t) == nil)
        ledger.forget(videoId: "a")
        #expect(ledger.failure(videoId: "a", now: t) == nil)
    }

    @Test func fiveSongsWithoutOpusPauseForADay() {
        var ledger = OpusFailureLedger()
        let t = 5_000.0
        for _ in 0..<4 { ledger.recordResolution(found: false, now: t) }
        ledger.recordResolution(found: true, now: t)
        for _ in 0..<4 { ledger.recordResolution(found: false, now: t) }
        #expect(ledger.pauseReason(os: "26.1", now: t) == nil)
        ledger.recordResolution(found: false, now: t)
        #expect(ledger.pauseReason(os: "26.1", now: t + 3600) != nil)
        #expect(ledger.pauseReason(os: "26.1", now: t + OpusFailureLedger.pauseSeconds + 1) == nil)
    }

    @Test func theDecoderRefusingTwoFilesSwitchesOpusOffUntilTheOSChanges() {
        var ledger = OpusFailureLedger()
        ledger.record(.verify, detail: "read as lpcm", videoId: "a", now: 1, os: "26.1")
        #expect(ledger.pauseReason(os: "26.1", now: 2) == nil)
        ledger.record(.verify, detail: "read as lpcm", videoId: "b", now: 2, os: "26.1")
        #expect(ledger.pauseReason(os: "26.1", now: 3) == "the system decoder refused the files on this iOS version")
        #expect(ledger.pauseReason(os: "27.0", now: 3) == nil)
        // Once a file passed on an OS version, a refusal there is that file's problem only.
        var accepted = OpusFailureLedger()
        accepted.recordSuccess(videoId: "ok", os: "26.1")
        accepted.record(.verify, detail: "x", videoId: "a", now: 1, os: "26.1")
        accepted.record(.verify, detail: "x", videoId: "b", now: 1, os: "26.1")
        #expect(accepted.pauseReason(os: "26.1", now: 2) == nil)
        // Other kinds never count.
        var network = OpusFailureLedger()
        for id in ["a", "b", "c"] { network.record(.network, detail: "x", videoId: id, now: 1, os: "26.1") }
        #expect(network.pauseReason(os: "26.1", now: 2) == nil)
    }

    @Test func theLedgerStaysSmallAndRoundTrips() throws {
        var ledger = OpusFailureLedger()
        for i in 0..<(OpusFailureLedger.maxEntries + 10) {
            ledger.record(.remux, detail: "x", videoId: "v\(i)", now: Double(i), os: "26.1")
        }
        #expect(ledger.videos.count == OpusFailureLedger.maxEntries)
        #expect(ledger.videos["v0"] == nil)
        #expect(ledger.videos["v\(OpusFailureLedger.maxEntries + 9)"] != nil)
        let decoded = try JSONDecoder().decode(OpusFailureLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded == ledger)
    }

    @Test func diagnosticsShowTheOpusLineOnlyWhenThereIsOne() async {
        let stream = ResolvedStream(url: "https://r1.googlevideo.com/videoplayback", userAgent: "UA", strategyName: "VISIONOS")
        let track = DiagnosticsTrack(title: "Northern Lights", artist: "Nova", album: "First Light", durationMs: 180_000,
                                     videoId: "dQw4w9WgXcQ")
        struct Search: YouTubeMusicSearching {
            func searchSongs(_ query: String, limit: Int) async throws -> [YouTubeSearchResult] {
                [YouTubeSearchResult(videoId: "dQw4w9WgXcQ", title: "Northern Lights", artist: "Nova", album: nil, durationSeconds: 180)]
            }
            func searchVideos(_ query: String, limit: Int) async throws -> [YouTubeSearchResult] { [] }
        }
        func run(_ status: String?) async -> PlaybackDiagnosticsReport {
            let outcome = StreamResolutionOutcome(stream: stream, attempts: ["VISIONOS: playable"], successfulStrategy: "VISIONOS",
                                                  opusStatus: status)
            return await PlaybackDiagnostics(search: Search(), lastSearchFailure: { nil }, resolve: { _ in outcome },
                                             probeLoader: { _, _ in StreamProbe(ok: true, httpStatus: 206, contentType: "audio/mp4") })
                .run(track: track)
        }
        #expect(await run(nil).steps.map(\.title).last == "Streaming loader")
        let report = await run("Opus file ready: this song plays Opus from its next start.")
        #expect(report.succeeded)
        #expect(report.steps.last == PlaybackDiagnosticsReport.Step(
            title: "Opus stream", ok: true, detail: "Opus file ready: this song plays Opus from its next start."))
    }
}
