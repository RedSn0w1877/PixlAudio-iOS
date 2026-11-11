import Foundation
import PixlModel
import PixlNet

/// The YouTube side of playback (architecture §2): a videoId becomes a playable URL plus the User-Agent it must be
/// fetched with. Order, from PixlNet's iOS policy and the remote client table:
/// 1. **VISIONOS** first — no PoToken policy (audio never truncated), no JS player (direct URLs), no cookie, a fresh
///    visitorData on every request;
/// 2. the other pre-signed clients (IOS: muxed itag 18 only without a streaming PoToken);
/// 3. the deciphered clients (TVHTML5, WEB when signed in, WEB_REMIX with a BotGuard PoToken when signed in) — the
///    signature and `n` functions run in JavaScriptCore, base.js cached per player version;
/// 4. **Piped** instances.
/// Formats are AAC only (`mp4a`, itags 141/140/139, then the muxed 18) — what AVPlayer plays progressively.
/// Resolved URLs are cached until googlevideo's `expire`; the streaming loader invalidates them on a 403.
actor InnerTubeService {
    let client: InnerTubeClient
    let cipher: SignatureCipherSolver
    let evaluator: JavaScriptCoreEvaluator
    let piped: PipedStreamResolver
    let spotiFLAC: SpotiFLACClient
    let remote: RemoteClientConfigStore
    private let resolver: ChainedYouTubeStreamResolver
    private let validator: StreamUrlValidator
    private let account: YouTubeAccount
    private var cache: [String: (stream: ResolvedStream, expiresAt: Date)] = [:]
    private var inFlight: [String: Task<ResolvedStream?, Never>] = [:]

    /// What the last resolution tried, in order (diagnostics).
    private(set) var lastAttempts: [String] = []
    private(set) var lastSuccessfulStrategy: String?

    static let pipedStrategyName = "Piped"
    static let spotiFLACStrategyName = "SpotiFLAC"

    /// - Parameters:
    ///   - innerTubeHTTP: InnerTube transport (no cookie jar; device-code Bearer for TVHTML5).
    ///   - plainHTTP: base.js, probes, SpotiFLAC and Piped (no cookie jar).
    init(innerTubeHTTP: any HTTPClient, plainHTTP: any HTTPClient, account: YouTubeAccount, remote: RemoteClientConfigStore) {
        self.account = account
        self.remote = remote
        let client = InnerTubeClient(http: innerTubeHTTP, session: account)
        self.client = client
        let evaluator = JavaScriptCoreEvaluator()
        self.evaluator = evaluator
        let cipher = SignatureCipherSolver(http: BaseJsCachingHTTPClient(inner: plainHTTP), evaluator: evaluator)
        self.cipher = cipher
        piped = PipedStreamResolver(http: plainHTTP, aacOnly: true)
        spotiFLAC = SpotiFLACClient(http: plainHTTP)
        let validator = StreamUrlValidator(http: plainHTTP)
        self.validator = validator
        resolver = ChainedYouTubeStreamResolver(
            player: client, cipher: cipher, validator: validator, policy: .iOS,
            isSignedIn: { await account.hasCookie },
            maxBitrateKbps: { StreamingAudioQuality.maxBitrateKbps() },
            strategies: { signedIn in await remote.current().chain(signedIn: signedIn) },
            // Streaming speed R8: overlapping clients only when remote/config.json turns `innertube.hedge` on.
            hedging: { await remote.current().hedging })
    }

    // MARK: Resolution

    /// A playable stream. Cached until the URL expires unless `excluding` names strategies that just failed
    /// (a 403 from googlevideo) or `validate` asks for a probed URL (diagnostics, downloads).
    func resolve(videoId: String, excluding: Set<String> = [], validate: Bool = false) async -> ResolvedStream? {
        guard CloudStreamSecurity.validateYouTubeVideoId(videoId) else { return nil }
        if excluding.isEmpty, !validate, let cached = cache[videoId], cached.expiresAt > Date() { return cached.stream }
        if excluding.isEmpty, !validate, let running = inFlight[videoId] { return await running.value }
        let task = Task { await self.resolveFresh(videoId: videoId, excluding: excluding, validate: validate) }
        if excluding.isEmpty, !validate { inFlight[videoId] = task }
        let stream = await task.value
        if excluding.isEmpty, !validate { inFlight[videoId] = nil }
        return stream
    }

    private func resolveFresh(videoId: String, excluding: Set<String>, validate: Bool) async -> ResolvedStream? {
        let started = ContinuousClock.now
        // Streaming speed R4: never wait for the remote client table; a due refresh runs in the background and the
        // resolution uses the current table (the saved file, or the built-in one).
        await remote.refreshInBackground()
        let configMs = PlaybackStartTimings.ms(from: started, to: .now)
        var stream: ResolvedStream?
        var attempts: [String] = []
        var successful: String?

        // 0. SpotiFLAC primary lossless chain (`tracks.monochrome.st` → Tidal HiFi instances → Deezer ISRC enrichment).
        //    Automatically falls back to YouTube (`InnerTube` → `Piped`) if the track is not found or fails validation.
        if !excluding.contains(Self.spotiFLACStrategyName),
           let query = SpotiFLACTrackRegistry.shared.query(forVideoId: videoId) {
            if let flac = await spotiFLAC.resolve(query) {
                let urlString = flac.url.absoluteString
                var playable = true
                if validate {
                    let probe = await validator.probe(url: urlString, userAgent: flac.userAgent, sendRange: true)
                    playable = probe.ok
                    if !playable {
                        await spotiFLAC.invalidate(query)
                        attempts.append("SpotiFLAC (\(flac.provider.rawValue)): \(probe.describe())")
                    }
                }
                if playable {
                    stream = ResolvedStream(
                        url: urlString,
                        userAgent: flac.userAgent,
                        strategyName: Self.spotiFLACStrategyName,
                        mimeType: "audio/flac"
                    )
                    successful = Self.spotiFLACStrategyName
                    attempts.append("SpotiFLAC (\(flac.provider.rawValue)): lossless FLAC (\(flac.trackId))")
                }
            } else {
                attempts.append("SpotiFLAC: no lossless match")
            }
        }

        // 1. Automatic fallback to YouTube (`InnerTube` → `Piped`) when SpotiFLAC misses or was excluded.
        if stream == nil, !SpotiFLACTrackRegistry.isSyntheticVideoId(videoId) {
            stream = (try? await resolver.resolveStream(videoId: videoId, validate: validate,
                                                        excludedStrategies: excluding)) ?? nil
            attempts.append(contentsOf: await resolver.lastAttempts)
            successful = await resolver.lastSuccessfulStrategy
            if stream == nil, !excluding.contains(Self.pipedStrategyName) {
                let fromPiped = await piped.resolve(videoId: videoId)
                let detail = await piped.lastDetail
                if let fromPiped {
                    stream = ResolvedStream(url: fromPiped.url, userAgent: fromPiped.userAgent,
                                            strategyName: Self.pipedStrategyName)
                    successful = Self.pipedStrategyName
                    attempts.append("Piped: \(detail ?? "resolved")")
                } else {
                    attempts.append("Piped: \(detail ?? "no instance answered")")
                }
            }
        }
        lastAttempts = attempts
        lastSuccessfulStrategy = stream == nil ? nil : successful
        if let stream { cache[videoId] = (stream, Self.expiry(of: stream.url)) }
        if !validate {
            PlaybackStartTimings.shared.resolved(
                key: YouTubeSongIdentity.timingKey(videoId: videoId),
                Self.timing(stream: stream, strategy: successful, attempts: attempts,
                            ms: PlaybackStartTimings.ms(from: started, to: .now), configMs: configMs))
        }
        return stream
    }

    /// The start-timings view of a resolution: the winner's detail (itag, bitrate, `n`), or every attempt.
    static func timing(stream: ResolvedStream?, strategy: String?, attempts: [String], ms: Int,
                       configMs: Int) -> PlaybackStartTimings.Resolve {
        guard let stream else {
            return PlaybackStartTimings.Resolve(ms: ms, configMs: configMs, strategy: nil,
                                                detail: attempts.joined(separator: "; "), hasN: nil)
        }
        var detail = attempts.last ?? ""
        if let separator = detail.range(of: ": ") { detail = String(detail[separator.upperBound...]) }
        return PlaybackStartTimings.Resolve(ms: ms, configMs: configMs, strategy: strategy, detail: detail,
                                            hasN: URLCoding.androidQueryParameter(stream.url, "n") != nil)
    }

    /// Drops the cached URL (googlevideo or SpotiFLAC answered 403/410: expired, or bound to another client).
    func invalidate(videoId: String) async {
        cache[videoId] = nil
        if let query = SpotiFLACTrackRegistry.shared.query(forVideoId: videoId) {
            await spotiFLAC.invalidate(query)
        }
    }

    /// Drops every cached URL (the sign-in state changed, so other clients may now be used).
    func invalidateAll() {
        cache.removeAll()
    }

    /// googlevideo's `expire` (Unix seconds) minus two minutes; four hours when absent.
    static func expiry(of url: String) -> Date {
        if let text = URLCoding.androidQueryParameter(url, "expire"), let seconds = Double(text) {
            return Date(timeIntervalSince1970: seconds - 120)
        }
        return Date().addingTimeInterval(4 * 3600)
    }

    /// Hosts the streaming layer may fetch audio from: googlevideo, SpotiFLAC lossless hosts, and trusted Piped hosts.
    func allowedHosts() async -> Set<String> {
        CloudStreamSecurity.allowedHostSuffixes(pipedTrustedHosts: await piped.trustedHosts)
            .union(SpotiFLACClient.trustedAudioHostSuffixes)
    }

    /// A fresh, validated resolution with its attempts (the playback test).
    func diagnosticsOutcome(videoId: String) async -> StreamResolutionOutcome {
        let stream = await resolve(videoId: videoId, validate: true)
        return StreamResolutionOutcome(stream: stream, attempts: lastAttempts, successfulStrategy: lastSuccessfulStrategy)
    }

    // MARK: Search and diagnostics

    func searchMusic(_ query: String, limit: Int) async throws -> [YouTubeSearchResult] {
        try await client.searchMusic(query, limit: limit)
    }

    func lastClientFailure() async -> String? {
        await client.lastFailureReason
    }

    /// The cipher's step-by-step report (iframe API, player id, base.js, patterns, a test run of `n`).
    func cipherReport() async -> String {
        await cipher.diagnose()
    }

    func remoteSource() async -> String {
        await remote.source
    }

    /// Whether the remote table turns on overlapping clients (streaming speed R8), for the deep probe.
    func hedgingDescription() async -> String {
        guard let hedging = await remote.current().hedging else { return "off" }
        return "on (next client after \(hedging.afterSeconds) s, \(hedging.strategyTimeoutSeconds) s per client)"
    }
}

/// Settings › Playback › Streaming audio quality (Android `AudioQuality.maxBitrateKbps`): the cap the stream
/// resolvers pick under (the highest AAC stream at or below it; above every stream, the lowest), read whenever a
/// stream is resolved. Changing it drops the cached URLs (`InnerTubeService.invalidateAll`).
nonisolated enum StreamingAudioQuality {
    static func maxBitrateKbps(_ defaults: UserDefaults = .standard) -> Int? {
        switch defaults.string(forKey: PreferenceKeys.audioQuality) ?? "ULTRASOUND" {
        case "LOW": 96
        case "STANDARD": 160
        case "HIGH": 256
        default: nil
        }
    }
}

/// The YouTube video id behind a library song: `yt:<id>` songs and anything whose item URL is `pixlstream://<id>`
/// (Spotify songs matched by stage 12 use the same URL).
nonisolated enum YouTubeSongIdentity {
    static let scheme = "pixlstream"

    static func videoId(for song: Song) -> String? {
        if song.contentUriString.hasPrefix("\(scheme)://") {
            let id = String(song.contentUriString.dropFirst("\(scheme)://".count).prefix { $0 != "/" && $0 != "?" })
            return CloudStreamSecurity.validateYouTubeVideoId(id) ? id : nil
        }
        if song.id.hasPrefix("yt:") {
            let id = String(song.id.dropFirst(3))
            return CloudStreamSecurity.validateYouTubeVideoId(id) ? id : nil
        }
        return nil
    }

    /// The id of a `pixlstream://<id>` URL, read from the URL text (video ids are case-sensitive; hosts are not).
    static func videoId(from url: URL) -> String? {
        let text = url.absoluteString
        let prefix = "\(scheme)://"
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        let id = String(text.dropFirst(prefix.count).prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        return CloudStreamSecurity.validateYouTubeVideoId(id) ? id : nil
    }

    static func streamURL(videoId: String) -> URL? { URL(string: "\(scheme)://\(videoId)") }

    /// The `PlaybackStartTimings` key of a streamed video: the item URL's text (`pixlstream://<videoId>`).
    static func timingKey(videoId: String) -> String { "\(scheme)://\(videoId)" }
}
