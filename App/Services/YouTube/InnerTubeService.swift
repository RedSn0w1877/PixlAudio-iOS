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
/// Separately, `resolveOpus` finds the Opus stream that `OpusStreams.swift` repackages ahead of time; it reads the
/// `player` responses the AAC resolution just fetched (`PlayerResponseMemo`) instead of asking YouTube again.
actor InnerTubeService {
    let client: InnerTubeClient
    let cipher: SignatureCipherSolver
    let evaluator: JavaScriptCoreEvaluator
    let piped: PipedStreamResolver
    let spotiFLAC: SpotiFLACClient
    let remote: RemoteClientConfigStore
    private let resolver: ChainedYouTubeStreamResolver
    private let opusResolver: ChainedYouTubeStreamResolver
    private let responses: PlayerResponseMemo
    private let validator: StreamUrlValidator
    private let plainHTTP: any HTTPClient
    private let account: YouTubeAccount
    private var cache: [String: (stream: ResolvedStream, expiresAt: Date)] = [:]
    private var inFlight: [String: Task<ResolvedStream?, Never>] = [:]
    private var opusStatusProvider: (@Sendable (String) async -> String?)?

    /// What the last resolution tried, in order (diagnostics).
    private(set) var lastAttempts: [String] = []
    private(set) var lastSuccessfulStrategy: String?
    /// What the last Opus resolution tried.
    private(set) var lastOpusAttempts: [String] = []

    static let pipedStrategyName = "Piped"
    static let spotiFLACStrategyName = "SpotiFLAC"

    /// - Parameters:
    ///   - innerTubeHTTP: InnerTube transport (no cookie jar; device-code Bearer for TVHTML5).
    ///   - plainHTTP: base.js, probes, SpotiFLAC and Piped (no cookie jar).
    init(innerTubeHTTP: any HTTPClient, plainHTTP: any HTTPClient, account: YouTubeAccount, remote: RemoteClientConfigStore) {
        self.account = account
        self.remote = remote
        self.plainHTTP = plainHTTP
        let client = InnerTubeClient(http: innerTubeHTTP, session: account)
        self.client = client
        let evaluator = JavaScriptCoreEvaluator()
        self.evaluator = evaluator
        let cipher = SignatureCipherSolver(http: BaseJsCachingHTTPClient(inner: plainHTTP), evaluator: evaluator)
        self.cipher = cipher
        piped = PipedStreamResolver(http: plainHTTP, aacOnly: true)
        let responses = PlayerResponseMemo(inner: client)
        self.responses = responses
        spotiFLAC = SpotiFLACClient(http: plainHTTP)
        let validator = StreamUrlValidator(http: plainHTTP)
        self.validator = validator
        resolver = ChainedYouTubeStreamResolver(
            player: responses.live, cipher: cipher, validator: validator, policy: .iOS,
            isSignedIn: { await account.hasCookie },
            maxBitrateKbps: { StreamingAudioQuality.maxBitrateKbps() },
            strategies: { signedIn in await remote.current().chain(signedIn: signedIn) },
            // Streaming speed R8: overlapping clients only when remote/config.json turns `innertube.hedge` on.
            hedging: { await remote.current().hedging })
        // The Opus upgrade: the same clients one after another, in the background, no probe.
        opusResolver = ChainedYouTubeStreamResolver(
            player: responses.remembered, cipher: cipher, validator: nil, policy: .opusUpgrade,
            isSignedIn: { await account.hasCookie },
            maxBitrateKbps: { StreamingAudioQuality.maxBitrateKbps() },
            strategies: { signedIn in await remote.current().chain(signedIn: signedIn) })
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

        // A synthetic id (a Spotify song YouTube can't match) has no video: SpotiFLAC is its only source.
        let synthetic = SpotiFLACTrackRegistry.isSyntheticVideoId(videoId)
        let spotiFLACUsable = !excluding.contains(Self.spotiFLACStrategyName)
        // Same order as Android. Pro and Studio Pro: SpotiFLAC first, YouTube as the fallback; Pro skips a file it
        // already knows is over 48 kHz. Low/Medium/High stay on YouTube at their cap and fall back to SpotiFLAC only
        // when YouTube has nothing for the song (a synthetic id never has anything else).
        let quality = StreamingAudioQuality.current()
        let knownRate = SpotiFLACTrackRegistry.shared.facts(forVideoId: videoId)?.flacSampleRate
        let flacFirst = spotiFLACUsable && (synthetic || quality.allowsFlacFirst(sampleRate: knownRate))

        // 0. SpotiFLAC first (`tracks.monochrome.st`, then any Tidal HiFi instance).
        if flacFirst, let flac = await resolveViaSpotiFLAC(videoId: videoId, validate: validate, lastResort: synthetic,
                                                          quality: quality, attempts: &attempts) {
            stream = flac
            successful = Self.spotiFLACStrategyName
        }

        // 1. YouTube (`InnerTube` → `Piped`) when SpotiFLAC wasn't first, missed or was excluded.
        if stream == nil, !synthetic {
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

        // 2. Capped quality (or a file too big for Pro): SpotiFLAC only as the last resort.
        if stream == nil, spotiFLACUsable, !flacFirst,
           let flac = await resolveViaSpotiFLAC(videoId: videoId, validate: validate, lastResort: true,
                                                quality: quality, attempts: &attempts) {
            stream = flac
            successful = Self.spotiFLACStrategyName
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

    /// SpotiFLAC's stream for the song registered under `videoId`, or nil. `lastResort`: YouTube has nothing, so any
    /// file is taken. When `validate` (downloads, the playback test) the file's first bytes are read before it is
    /// handed out: they say what it is, and a file above the quality setting goes to YouTube before anything big is
    /// downloaded. Streams check the same bytes in `StreamFetcher.store`.
    private func resolveViaSpotiFLAC(videoId: String, validate: Bool, lastResort: Bool, quality: StreamingAudioQuality,
                                     attempts: inout [String]) async -> ResolvedStream? {
        guard let query = SpotiFLACTrackRegistry.shared.query(forVideoId: videoId) else { return nil }
        SpotiFLACTrackRegistry.shared.setLastResort(lastResort, forVideoId: videoId)
        guard let flac = await spotiFLAC.resolve(query) else {
            attempts.append("SpotiFLAC: no match")
            return nil
        }
        let urlString = flac.url.absoluteString
        if validate {
            guard let facts = await headFacts(url: urlString, userAgent: flac.userAgent) else {
                await spotiFLAC.invalidate(query)
                attempts.append("SpotiFLAC (\(flac.provider.rawValue)): the file didn't answer")
                return nil
            }
            SpotiFLACTrackRegistry.shared.record(facts, forVideoId: videoId)
            guard facts.format == .flac || facts.format == .mp4 else {
                attempts.append("SpotiFLAC (\(flac.provider.rawValue)): a \(facts.format.rawValue) file this player can't keep")
                return nil
            }
            if !lastResort, !quality.allowsFlacFirst(sampleRate: facts.flacSampleRate) {
                attempts.append("SpotiFLAC (\(flac.provider.rawValue)): \(facts.sampleRate ?? 0) Hz, above the quality setting")
                return nil
            }
        }
        let mimeType = SpotiFLACTrackRegistry.shared.facts(forVideoId: videoId)?.format.mimeType ?? flac.mimeType
        attempts.append("SpotiFLAC (\(flac.provider.rawValue)): \(mimeType == "audio/flac" ? "FLAC" : mimeType) (\(flac.trackId))")
        return ResolvedStream(url: urlString, userAgent: flac.userAgent,
                              strategyName: Self.spotiFLACStrategyName, mimeType: mimeType)
    }

    /// The first `SpotiFLACAudioFileFacts.headBytes` of a SpotiFLAC file (one ranged GET), read as facts; nil when it
    /// doesn't answer with them.
    private func headFacts(url: String, userAgent: String) async -> SpotiFLACAudioFileFacts? {
        let request = HTTPRequest(method: .get, url: url, headers: [
            HTTPHeader("User-Agent", userAgent),
            HTTPHeader("Range", "bytes=0-\(SpotiFLACAudioFileFacts.headBytes - 1)")
        ], timeout: 10)
        guard let response = try? await plainHTTP.send(request),
              response.statusCode == 206 || response.statusCode == 200,
              CloudStreamSecurity.isSupportedAudioContentType(response.header("Content-Type")) else { return nil }
        let facts = SpotiFLACParsing.audioFileFacts(response.body)
        return facts.format == .unknown ? nil : facts
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

    /// A fresh, validated resolution with its attempts (the playback test), and the song's Opus line.
    func diagnosticsOutcome(videoId: String) async -> StreamResolutionOutcome {
        let stream = await resolve(videoId: videoId, validate: true)
        var outcome = StreamResolutionOutcome(stream: stream, attempts: lastAttempts, successfulStrategy: lastSuccessfulStrategy)
        if let opusStatusProvider { outcome.opusStatus = await opusStatusProvider(videoId) }
        return outcome
    }

    // MARK: Opus (iOS: repackaged ahead of time, see OpusStreams.swift)

    /// The Opus stream to prepare for `videoId` when a client offers one better than the AAC pick (itag 251 over
    /// 140; a 256 kbps AAC stays). The AAC stream is resolved first (usually cached), so its `player` response is
    /// in the memo and choosing Opus costs no request on the usual path. `fresh` forgets that response first
    /// (googlevideo refused the Opus URL).
    func resolveOpus(videoId: String, fresh: Bool = false) async -> OpusStreamResolution? {
        guard CloudStreamSecurity.validateYouTubeVideoId(videoId) else { return nil }
        let aac = await resolve(videoId: videoId)
        if fresh { await responses.forget(videoId: videoId) }
        let stream = (try? await opusResolver.resolveStream(videoId: videoId, validate: false)) ?? nil
        lastOpusAttempts = await opusResolver.lastAttempts
        guard let stream else { return nil }
        return OpusStreamResolution(stream: stream, aacStreamURL: aac?.url)
    }

    /// The Test playback report's Opus line (set by `YouTubeServices.install`).
    func setOpusStatusProvider(_ provider: @escaping @Sendable (String) async -> String?) {
        opusStatusProvider = provider
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

/// Settings › Playback › Streaming audio quality (Android `AudioQuality`), read whenever a stream is resolved; changing
/// it drops the cached URLs (`InnerTubeService.invalidateAll`).
/// - Low / Medium / High cap YouTube at 96 / 160 / 256 kbps (the resolvers pick the highest AAC stream at or below it;
///   above every stream, the lowest). SpotiFLAC is then only the last resort, when YouTube has nothing.
/// - Pro (the default) plays SpotiFLAC's file first when it is at most 48 kHz: CD quality and most 24-bit masters.
/// - Studio Pro plays every SpotiFLAC file first, including 88.2–192 kHz masters (up to ~6 Mbps).
nonisolated enum StreamingAudioQuality: String, CaseIterable, Sendable {
    case low = "LOW", medium = "MEDIUM", high = "HIGH", pro = "PRO", studioPro = "STUDIO_PRO"

    static let `default`: StreamingAudioQuality = .pro

    /// The tier for a stored value, including the old ones (`STANDARD` is Medium, `ULTRASOUND` is Pro).
    static func from(stored value: String?) -> StreamingAudioQuality {
        switch value {
        case nil: .default
        case "STANDARD": .medium
        case "ULTRASOUND": .pro
        case let other?: StreamingAudioQuality(rawValue: other) ?? .default
        }
    }

    static func current(_ defaults: UserDefaults = .standard) -> StreamingAudioQuality {
        from(stored: defaults.string(forKey: PreferenceKeys.audioQuality))
    }

    /// The YouTube cap the stream resolvers pick under (Android `AudioQuality.maxBitrateKbps`).
    static func maxBitrateKbps(_ defaults: UserDefaults = .standard) -> Int? { current(defaults).maxBitrateKbps }

    var maxBitrateKbps: Int? {
        switch self {
        case .low: 96
        case .medium: 160
        case .high: 256
        case .pro, .studioPro: nil
        }
    }

    /// Whether SpotiFLAC's file of `sampleRate` may play before YouTube (an unknown rate counts as allowed).
    func allowsFlacFirst(sampleRate: Int?) -> Bool {
        switch self {
        case .low, .medium, .high: false
        case .pro: sampleRate.map { $0 <= 48_000 } ?? true
        case .studioPro: true
        }
    }

    /// The label for a YouTube stream on this tier: an uncapped tier plays YouTube's best, "High".
    var youTubeLabel: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high, .pro, .studioPro: "High"
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
