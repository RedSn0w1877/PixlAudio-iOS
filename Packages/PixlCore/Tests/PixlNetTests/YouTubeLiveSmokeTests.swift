import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import PixlFoundation
@testable import PixlNet

/// The only tests that touch the network: YouTube Music search, the VISIONOS-first resolution chain and a ranged
/// probe of the resolved URL against the real services. Off unless `PIXL_LIVE_YOUTUBE=1` (CI runs them in a
/// non-blocking step — YouTube breaking a client must not turn the build red, but it should be visible).
@Suite("YouTube live smoke", .enabled(if: ProcessInfo.processInfo.environment["PIXL_LIVE_YOUTUBE"] == "1"))
struct YouTubeLiveSmokeTests {
    struct NoJavaScript: JavaScriptEvaluating {
        func evaluate(_ script: String) async -> String? { nil }
    }

    /// No cookie jar: a cookie set by one InnerTube answer must never reach the native clients (HTTP 400).
    static func http() -> URLSessionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        return URLSessionHTTPClient(session: URLSession(configuration: configuration))
    }

    @Test func searchAndResolveAPlayableAACStream() async throws {
        let http = Self.http()
        let client = InnerTubeClient(http: http, session: AnonymousYouTubeSession(visitorData: VisitorDataProvider(http: http)))
        let results = try await client.searchSongs("Daft Punk Get Lucky", limit: 5)
        print("live: search → \(results.count) results; first \(results.first.map { "\($0.videoId) \($0.title)" } ?? "-")")
        let first = try #require(results.first)

        let resolver = ChainedYouTubeStreamResolver(player: client,
                                                    cipher: SignatureCipherSolver(http: http, evaluator: NoJavaScript()),
                                                    validator: StreamUrlValidator(http: http))
        let stream = try await resolver.resolveStream(videoId: first.videoId, validate: true)
        for attempt in await resolver.lastAttempts { print("live: \(attempt)") }
        let resolved = try #require(stream, "no client resolved a playable stream")
        print("live: resolved via \(resolved.strategyName ?? "?")")
        #expect(CloudStreamSecurity.isSafeRemoteStreamURL(resolved.url, allowedHostSuffixes: ["googlevideo.com"]))

        let probe = await StreamUrlValidator(http: http).probe(url: resolved.url, userAgent: resolved.userAgent, sendRange: true)
        print("live: probe \(probe.describe())")
        #expect(probe.ok)
    }

    @Test func botGuardCreateAnswers() async throws {
        let response = try await Self.http().send(PoTokenJS.createRequest())
        print("live: BotGuard Create HTTP \(response.statusCode), \(response.body.count) bytes")
        #expect(response.statusCode == 200)
        let challenge = try PoTokenJS.parseChallengeData(response.text)
        #expect(challenge.contains("\"program\":\""))
    }
}
