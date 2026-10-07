import Foundation
import Testing
@testable import PixlNet

/// Streaming speed (2026-10-07, iOS first): the pure rules behind the app's streaming loader — GET sizes (R2).
@Suite("Stream chunk policy")
struct StreamChunkPolicyTests {
    @Test func fetchesGrowFrom128KiBTo2MiB() {
        #expect(StreamChunkPolicy.startFetchBytes == 131_072)
        #expect(StreamChunkPolicy.maxFetchBytes == 2_097_152)
        var size = StreamChunkPolicy.startFetchBytes
        var sizes = [size]
        for _ in 0..<4 {
            size = StreamChunkPolicy.nextFetchSize(after: size)
            sizes.append(size)
        }
        #expect(sizes == [131_072, 524_288, 2_097_152, 2_097_152, 2_097_152])
        // Never below the start size, never above the cap (yt-dlp asks for 10 MiB ranges).
        #expect(StreamChunkPolicy.nextFetchSize(after: 1) == 524_288)
        #expect(StreamChunkPolicy.nextFetchSize(after: 50 << 20) == 2_097_152)
    }

    @Test func theFirstRequestReadsAheadOfAVFoundationsTwoBytes() {
        // Nothing cached and the size unknown: the 2-byte request becomes bytes=0-131071.
        let first = StreamChunkPolicy.requestRange(for: 0..<2, readAhead: StreamChunkPolicy.startFetchBytes,
                                                   nextCachedStart: nil, contentLength: nil)
        #expect(first == 0..<131_072)
        #expect(ContentRange.requestHeader(first) == "bytes=0-131071")
        // Never past the end of a short file, never into bytes already on disk.
        #expect(StreamChunkPolicy.requestRange(for: 0..<2, readAhead: 131_072, nextCachedStart: nil,
                                               contentLength: 50_000) == 0..<50_000)
        #expect(StreamChunkPolicy.requestRange(for: 0..<2, readAhead: 131_072, nextCachedStart: 4_096,
                                               contentLength: nil) == 0..<4_096)
        // Without read-ahead (or when the cached span starts inside the range) the range is asked for as is.
        #expect(StreamChunkPolicy.requestRange(for: 10..<20, readAhead: 0, nextCachedStart: nil,
                                               contentLength: 100) == 10..<20)
        #expect(StreamChunkPolicy.requestRange(for: 10..<20, readAhead: 1_000, nextCachedStart: 15,
                                               contentLength: nil) == 10..<20)
        // A cached span that starts before the range is no limit.
        #expect(StreamChunkPolicy.requestRange(for: 10..<20, readAhead: 1_000, nextCachedStart: 5,
                                               contentLength: nil) == 10..<1_010)
    }

    @Test func aFetchStopsAtItsSizeTheEndOrCachedBytes() {
        #expect(StreamChunkPolicy.fetchEnd(offset: 0, end: 10_000_000, fetchSize: 131_072, nextCachedStart: nil) == 131_072)
        #expect(StreamChunkPolicy.fetchEnd(offset: 100, end: 300, fetchSize: 131_072, nextCachedStart: nil) == 300)
        #expect(StreamChunkPolicy.fetchEnd(offset: 100, end: 10_000, fetchSize: 131_072, nextCachedStart: 400) == 400)
        // A cached span at or before the offset is ignored; at least one byte is always fetched.
        #expect(StreamChunkPolicy.fetchEnd(offset: 100, end: 10_000, fetchSize: 1_000, nextCachedStart: 100) == 1_100)
        #expect(StreamChunkPolicy.fetchEnd(offset: 100, end: 100, fetchSize: 1_000, nextCachedStart: nil) == 101)
    }
}

/// R3: what the prefetcher prepares ahead (owner decision: next 1 on cellular, next 2 on Wi-Fi, 512 KB each, none in
/// Low Data Mode, only while playing).
@Suite("Stream prefetch policy")
struct StreamPrefetchPolicyTests {
    typealias Policy = StreamPrefetchPolicy

    @Test func depthFollowsTheNetwork() {
        #expect(Policy.depth(.init(network: .wifi), isPlaying: true) == 2)
        #expect(Policy.depth(.init(network: .wired), isPlaying: true) == 2)
        #expect(Policy.depth(.init(network: .cellular, isExpensive: true), isPlaying: true) == 1)
        #expect(Policy.depth(.init(network: .cellular), isPlaying: true) == 1)
        // A personal hotspot is Wi-Fi but metered: treated like cellular.
        #expect(Policy.depth(.init(network: .wifi, isExpensive: true), isPlaying: true) == 1)
        #expect(Policy.depth(.init(network: .other), isPlaying: true) == 1)
        #expect(Policy.depth(.unknown, isPlaying: true) == 1)
        #expect(Policy.depth(.init(network: .offline), isPlaying: true) == 0)
    }

    @Test func nothingInLowDataModeOrWhilePaused() {
        #expect(Policy.depth(.init(network: .wifi, isConstrained: true), isPlaying: true) == 0)
        #expect(Policy.depth(.init(network: .cellular, isConstrained: true, isExpensive: true), isPlaying: true) == 0)
        #expect(Policy.depth(.init(network: .wifi), isPlaying: false) == 0)
        #expect(Policy.depth(.init(network: .cellular), isPlaying: false) == 0)
    }

    @Test func sizesAndTimings() {
        #expect(Policy.headBytes == 524_288)
        #expect(Policy.topUpBytes == 1_048_576)
        #expect(Policy.topUpLeadMs == 30_000)
        #expect(Policy.prepareDelayMs == 1_500)
        #expect(Policy.headStartPositionMs == 3_000)
        #expect(Policy.maxDepth == 2)
    }

    @Test func upcomingSongsInSkipOrder() {
        #expect(Policy.upcomingIndices(current: 0, count: 5, wraps: false, depth: 2) == [1, 2])
        #expect(Policy.upcomingIndices(current: 3, count: 5, wraps: false, depth: 2) == [4])
        #expect(Policy.upcomingIndices(current: 4, count: 5, wraps: false, depth: 2) == [])
        // Repeat-all wraps to the start.
        #expect(Policy.upcomingIndices(current: 4, count: 5, wraps: true, depth: 2) == [0, 1])
        #expect(Policy.upcomingIndices(current: 3, count: 5, wraps: true, depth: 2) == [4, 0])
        // Never the current song, never twice.
        #expect(Policy.upcomingIndices(current: 0, count: 1, wraps: true, depth: 2) == [])
        #expect(Policy.upcomingIndices(current: 1, count: 2, wraps: true, depth: 2) == [0])
        #expect(Policy.upcomingIndices(current: 0, count: 5, wraps: false, depth: 0) == [])
        #expect(Policy.upcomingIndices(current: 7, count: 5, wraps: false, depth: 2) == [])
    }
}

/// R5a: Android oct3's upstream retry rules (`CloudStreamProxy.fetch`; Android has no unit test for them).
@Suite("Stream retry policy")
struct StreamRetryPolicyTests {
    typealias Policy = StreamRetryPolicy

    @Test func theFirstRejectionRetriesTheSameClient() {
        for status in [401, 403, 404, 410] {
            #expect(Policy.decide(status: status, attempt: 0, hasCachedBytes: false) == .retry(switchClient: false, delayMs: 0))
            #expect(Policy.decide(status: status, attempt: 1, hasCachedBytes: false) == .retry(switchClient: true, delayMs: 0))
            #expect(Policy.decide(status: status, attempt: 2, hasCachedBytes: false) == .retry(switchClient: true, delayMs: 0))
        }
    }

    @Test func cachedBytesKeepTheClient() {
        // Another client may serve another itag: never switch once bytes of the file are on disk.
        #expect(Policy.decide(status: 403, attempt: 1, hasCachedBytes: true) == .retry(switchClient: false, delayMs: 0))
        #expect(Policy.decide(status: 503, attempt: 2, hasCachedBytes: true) == .retry(switchClient: false, delayMs: 750))
    }

    @Test func throttlingAndServerErrorsBackOff() {
        #expect(Policy.decide(status: 429, attempt: 0, hasCachedBytes: false) == .retry(switchClient: false, delayMs: 250))
        #expect(Policy.decide(status: 500, attempt: 1, hasCachedBytes: false) == .retry(switchClient: true, delayMs: 500))
        #expect(Policy.decide(status: 502, attempt: 2, hasCachedBytes: false) == .retry(switchClient: true, delayMs: 750))
        #expect(Policy.decide(status: 504, attempt: 0, hasCachedBytes: true) == .retry(switchClient: false, delayMs: 250))
    }

    @Test func fourAttemptsAtMostAndOtherStatusesFail() {
        #expect(Policy.maxAttempts == 4)
        for status in Policy.retryableStatuses {
            #expect(Policy.decide(status: status, attempt: 3, hasCachedBytes: false) == .fail)
        }
        for status in [400, 405, 416, 501, 302] {
            #expect(Policy.decide(status: status, attempt: 0, hasCachedBytes: false) == .fail)
        }
        // A GET that keeps answering 403 resolves four times: same client, then two others, then gives up.
        var switches: [Bool] = []
        var attempt = 0
        while case .retry(let switchClient, _) = Policy.decide(status: 403, attempt: attempt, hasCachedBytes: false) {
            switches.append(switchClient)
            attempt += 1
        }
        #expect(switches == [false, true, true])
        #expect(attempt == 3)
    }
}

/// R11: `findMatchFanOut` (the play-time matcher) returns exactly what `findMatch` returns, whatever order the
/// concurrent searches answer in.
@Suite("TrackMatcher fan-out")
struct TrackMatcherFanOutTests {
    struct Failure: Error {}

    /// Scripted searches: per query (and shelf) a delay and the results, or a failure; every call is logged.
    struct ScriptedSearch: YouTubeMusicSearching {
        let songs: [String: (delayMs: UInt64, results: [YouTubeSearchResult]?)]
        var videos: [String: [YouTubeSearchResult]] = [:]
        var videoDelayMs: UInt64 = 0
        let log = Box<[String]>([])

        func searchSongs(_ query: String, limit: Int) async throws -> [YouTubeSearchResult] {
            log.mutate { $0.append("songs:\(query)") }
            let entry = songs[query] ?? (0, [])
            if entry.delayMs > 0 { try await Task.sleep(nanoseconds: entry.delayMs * 1_000_000) }
            guard let results = entry.results else { throw Failure() }
            return results
        }

        func searchVideos(_ query: String, limit: Int) async throws -> [YouTubeSearchResult] {
            log.mutate { $0.append("videos:\(query)") }
            if videoDelayMs > 0 { try await Task.sleep(nanoseconds: videoDelayMs * 1_000_000) }
            return videos[query] ?? []
        }
    }

    static let song = MatchableTrack(title: "Northern Lights", artist: "Nova, Guest", album: "First Light",
                                     durationMs: 183_000)
    // "Northern Lights Nova", "Northern Lights Nova First Light", "Northern Lights".
    static let queries = TrackMatcher.buildQueries(song)

    static func hit(_ id: String, seconds: Int?, album: String? = "First Light") -> YouTubeSearchResult {
        YouTubeSearchResult(videoId: id, title: "Northern Lights", artist: "Nova", album: album, durationSeconds: seconds)
    }

    func both(_ search: ScriptedSearch) async -> (sequential: Result<TrackMatch?, MusicSearchUnavailableError>,
                                                  fanOut: Result<TrackMatch?, MusicSearchUnavailableError>) {
        func run(_ body: () async throws -> TrackMatch?) async -> Result<TrackMatch?, MusicSearchUnavailableError> {
            do { return .success(try await body()) } catch let error as MusicSearchUnavailableError {
                return .failure(error)
            } catch {
                return .failure(MusicSearchUnavailableError(underlying: "unexpected \(error)"))
            }
        }
        let matcher = TrackMatcher(search: search)
        let sequential = await run { try await matcher.findMatch(Self.song) }
        let fanOut = await run { try await matcher.findMatchFanOut(Self.song) }
        return (sequential, fanOut)
    }

    @Test func theRecordedSearchIsAcceptedOnTheFirstQuery() async throws {
        guard case .results(let recorded) = InnerTubeParsing.searchResults(try Fixtures.json("innertube-search"),
                                                                           limit: 10, isVideo: false) else {
            Issue.record("expected results")
            return
        }
        let search = ScriptedSearch(songs: [Self.queries[0]: (0, recorded)])
        let (sequential, fanOut) = await both(search)
        #expect(try sequential.get()?.videoId == "abcdefghijk")
        #expect(try fanOut.get() == sequential.get())
        // Accepted at once: the fan-out searched only once.
        #expect(search.log.value.filter { $0 == "songs:\(Self.queries[0])" }.count == 2)
        #expect(search.log.value.count == 2)
    }

    @Test func aLaterAnswerNeverBeatsAnEarlierAccept() async throws {
        // Query 1 is close (0.85), query 2 is accepted (1.0) but answers last; query 3 would also be perfect.
        let search = ScriptedSearch(songs: [
            Self.queries[0]: (0, [Self.hit("closeAAAAAA", seconds: 188)]),
            Self.queries[1]: (120, [Self.hit("secondBBBBB", seconds: 183)]),
            Self.queries[2]: (0, [Self.hit("thirdCCCCCC", seconds: 183)]),
        ])
        let (sequential, fanOut) = await both(search)
        #expect(try sequential.get()?.videoId == "secondBBBBB")
        #expect(try fanOut.get() == sequential.get())
    }

    @Test func theVideoShelfDecidesWhenNoSongIsAccepted() async throws {
        var search = ScriptedSearch(songs: [
            Self.queries[0]: (30, [Self.hit("closeAAAAAA", seconds: 188)]),
            Self.queries[1]: (0, []),
            Self.queries[2]: (10, [Self.hit("noAlbumDDDD", seconds: nil, album: nil)]),
        ])
        search.videos = [Self.queries[0]: [Self.hit("videoEEEEEE", seconds: 183, album: nil)]]
        let (sequential, fanOut) = await both(search)
        #expect(try sequential.get()?.videoId == "videoEEEEEE")
        #expect(try fanOut.get() == sequential.get())
        // Nothing acceptable at all: nil from both.
        let none = ScriptedSearch(songs: [Self.queries[0]: (0, [Self.hit("farFFFFFFFF", seconds: 400)])])
        let (noneSequential, noneFanOut) = await both(none)
        #expect(try noneSequential.get() == nil)
        #expect(try noneFanOut.get() == nil)
    }

    @Test func failuresCountOnlyWhereFindMatchWouldHaveSearched() async throws {
        // A failed search with nothing acceptable: both report the search as unavailable.
        let failing = ScriptedSearch(songs: [Self.queries[0]: (0, []), Self.queries[1]: (0, nil), Self.queries[2]: (0, [])])
        let (sequential, fanOut) = await both(failing)
        #expect(throws: MusicSearchUnavailableError.self) { try sequential.get() }
        #expect(throws: MusicSearchUnavailableError.self) { try fanOut.get() }
        // A failure after the accepting query doesn't count.
        let accepted = ScriptedSearch(songs: [
            Self.queries[0]: (0, []),
            Self.queries[1]: (60, [Self.hit("secondBBBBB", seconds: 183)]),
            Self.queries[2]: (0, nil),
        ])
        let (acceptedSequential, acceptedFanOut) = await both(accepted)
        #expect(try acceptedSequential.get()?.videoId == "secondBBBBB")
        #expect(try acceptedFanOut.get() == acceptedSequential.get())
    }
}

/// R8: overlapping YouTube clients, behind the remote-config flag `innertube.hedge` (off by default; iOS only).
@Suite("Stream hedging")
struct StreamHedgingTests {
    @Test func theFlagIsOffUnlessTheRemoteFileTurnsItOn() throws {
        #expect(RemoteClientConfig.builtIn.hedging == nil)
        #expect(RemoteClientConfig.parse(#"{"innertube": {}}"#)?.hedging == nil)
        #expect(RemoteClientConfig.parse(#"{"innertube": {"hedge": {}}}"#)?.hedging == nil)
        #expect(RemoteClientConfig.parse(#"{"innertube": {"hedge": {"enabled": false, "afterSeconds": 1}}}"#)?.hedging == nil)
        #expect(RemoteClientConfig.parse(#"{"innertube": {"hedge": {"enabled": "true"}}}"#)?.hedging == nil)
        // The repository's file ships it off.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let text = try String(contentsOf: url.appendingPathComponent("remote").appendingPathComponent("config.json"),
                              encoding: .utf8)
        #expect(try #require(RemoteClientConfig.parse(text)).hedging == nil)
    }

    @Test func enabledUsesDefaultsAndClampsNumbers() throws {
        let on = try #require(RemoteClientConfig.parse(#"{"innertube": {"hedge": {"enabled": true}}}"#))
        #expect(on.hedging == StreamHedging(afterSeconds: 1.5, strategyTimeoutSeconds: 8))
        let custom = try #require(RemoteClientConfig.parse(
            #"{"innertube": {"hedge": {"enabled": true, "afterSeconds": 2.5, "strategyTimeoutSeconds": 6}}}"#))
        #expect(custom.hedging?.afterSeconds == 2.5)
        #expect(custom.hedging?.strategyTimeoutSeconds == 6)
        let wild = try #require(RemoteClientConfig.parse(
            #"{"innertube": {"hedge": {"enabled": true, "afterSeconds": 0.01, "strategyTimeoutSeconds": 99}}}"#))
        #expect(wild.hedging?.afterSeconds == 0.5)
        #expect(wild.hedging?.strategyTimeoutSeconds == 15)
        let text = try #require(RemoteClientConfig.parse(
            #"{"innertube": {"hedge": {"enabled": true, "afterSeconds": "soon"}}}"#))
        #expect(text.hedging?.afterSeconds == StreamHedging.defaultAfterSeconds)
        // The rest of the table is untouched by the flag.
        #expect(on.chain(signedIn: false) == RemoteClientConfig.builtIn.chain(signedIn: false))
    }

    /// VISIONOS then IOS, each after its own delay; a nil URL fails the client (LOGIN_REQUIRED).
    struct Player: YouTubePlayerFetching {
        let delays: [String: UInt64]
        let failing: Set<String>
        let log = Box<[String]>([])

        func fetchPlayer(videoId: String, profile: InnerTubeClientProfile) async throws -> YouTubePlayerResponse? {
            log.mutate { $0.append(profile.name) }
            let delay = delays[profile.name] ?? 0
            if delay > 0 { try await Task.sleep(nanoseconds: delay * 1_000_000) }
            if failing.contains(profile.name) { return YouTubePlayerResponse(status: "LOGIN_REQUIRED", reason: "bot", formats: []) }
            return YouTubePlayerResponse(status: "OK", reason: nil, formats: [
                YouTubeAudioFormat(itag: 18, mimeType: "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", bitrate: 500_000,
                                   url: "https://r1.googlevideo.com/videoplayback?itag=18&c=\(profile.name)",
                                   signatureCipher: nil, contentLength: 10, approxDurationMs: 1000, isMuxedFallback: true),
            ])
        }
        var lastFailureReason: String? { get async { nil } }
    }

    struct NoCipher: CipherResolving {
        func resolveCipheredUrl(_ signatureCipher: String) async -> String? { nil }
        func applyNTransform(_ url: String) async -> String { url }
    }

    static let chain = { @Sendable (_: Bool) async -> [YouTubeStreamStrategy] in
        YouTubeStreamStrategy.preSignedStrategies().filter { ["VISIONOS", "IOS"].contains($0.profile.name) }
    }

    func resolver(_ player: Player, hedging: StreamHedging?) -> ChainedYouTubeStreamResolver {
        ChainedYouTubeStreamResolver(player: player, cipher: NoCipher(), validator: nil, strategies: Self.chain,
                                     hedging: { hedging })
    }

    @Test func aSlowFirstClientLosesToTheNextOne() async throws {
        let player = Player(delays: ["VISIONOS": 5_000], failing: [])
        let started = ContinuousClock.now
        let stream = try await resolver(player, hedging: StreamHedging(afterSeconds: 0.5)).resolveStream(videoId: "dQw4w9WgXcQ",
                                                                                                         validate: false)
        #expect(stream?.strategyName == "IOS")
        #expect(ContinuousClock.now - started < .seconds(3), "IOS started after 0.5 s instead of waiting for VISIONOS")
        #expect(player.log.value == ["VISIONOS", "IOS"])
    }

    @Test func aFailedClientStartsTheNextAtOnce() async throws {
        let player = Player(delays: [:], failing: ["VISIONOS"])
        let resolver = resolver(player, hedging: StreamHedging(afterSeconds: 10))
        let started = ContinuousClock.now
        let stream = try await resolver.resolveStream(videoId: "dQw4w9WgXcQ", validate: false)
        #expect(stream?.strategyName == "IOS")
        #expect(ContinuousClock.now - started < .seconds(5), "no 10 s wait after a failure")
        #expect(await resolver.lastAttempts.first == "VISIONOS: LOGIN_REQUIRED — bot")
        #expect(await resolver.lastSuccessfulStrategy == "IOS")
        // Everything failing ends without waiting for the timers.
        let none = Player(delays: [:], failing: ["VISIONOS", "IOS"])
        let noneResolver = self.resolver(none, hedging: StreamHedging(afterSeconds: 10))
        let noneStarted = ContinuousClock.now
        #expect(try await noneResolver.resolveStream(videoId: "dQw4w9WgXcQ", validate: false) == nil)
        #expect(ContinuousClock.now - noneStarted < .seconds(5))
        #expect(await noneResolver.lastAttempts.count == 2)
        #expect(await noneResolver.lastSuccessfulStrategy == nil)
    }

    @Test func offMeansOneClientAfterAnother() async throws {
        // Without the flag a slow VISIONOS is waited for and IOS never asked (Android's behaviour).
        let player = Player(delays: ["VISIONOS": 600], failing: [])
        let stream = try await resolver(player, hedging: nil).resolveStream(videoId: "dQw4w9WgXcQ", validate: false)
        #expect(stream?.strategyName == "VISIONOS")
        #expect(player.log.value == ["VISIONOS"])
        // With the flag but a fast first client, nothing else is asked either.
        let fast = Player(delays: [:], failing: [])
        let hedged = try await resolver(fast, hedging: StreamHedging()).resolveStream(videoId: "dQw4w9WgXcQ", validate: false)
        #expect(hedged?.strategyName == "VISIONOS")
        #expect(fast.log.value == ["VISIONOS"])
    }
}
