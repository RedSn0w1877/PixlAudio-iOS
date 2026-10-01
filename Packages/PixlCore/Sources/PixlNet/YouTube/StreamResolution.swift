// Port of `YouTubeStreamResolver.kt` (pre-signed and deciphered strategies, the chained resolver) and
// `StreamUrlValidator.kt`. A videoId becomes a playable URL plus the User-Agent it must be fetched with. The chain
// tries VISIONOS first (one request, no PoToken, no base.js), then the other pre-signed clients, then the clients
// that need base.js. On iOS the format choice is AAC-only by default (`AudioFormatPolicy.iOS`).

import Foundation

/// The `player` call a strategy makes (`InnerTubeClient` conforms).
public protocol YouTubePlayerFetching: Sendable {
    func fetchPlayer(videoId: String, profile: InnerTubeClientProfile) async throws -> YouTubePlayerResponse?
    var lastFailureReason: String? { get async }
}

extension InnerTubeClient: YouTubePlayerFetching {}

/// Signature/`n` deciphering (`SignatureCipherSolver` conforms).
public protocol CipherResolving: Sendable {
    func resolveCipheredUrl(_ signatureCipher: String) async -> String?
    func applyNTransform(_ url: String) async -> String
}

extension SignatureCipherSolver: CipherResolving {}

/// Which formats a resolver may pick.
public enum AudioFormatPolicy: Sendable, Hashable {
    /// Android's `pickBestAudio` (any audio, Opus included).
    case android
    /// AAC only (141/140/139), then itag 18 — what AVPlayer can play progressively.
    case iOS

    public func pick(_ formats: [YouTubeAudioFormat], maxBitrateKbps: Int?) -> YouTubeAudioFormat? {
        switch self {
        case .android: return AudioFormatSelection.pickBestAudio(formats, maxBitrateKbps: maxBitrateKbps)
        case .iOS: return AudioFormatSelection.pickBestIOSAudio(formats, maxBitrateKbps: maxBitrateKbps)
        }
    }
}

/// One resolution strategy.
public struct YouTubeStreamStrategy: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Clients that return pre-signed URLs (the `n` parameter is still transformed).
        case preSigned
        /// Clients whose signature must be deciphered with base.js.
        case ciphered
    }

    public var kind: Kind
    public var profile: InnerTubeClientProfile

    public init(kind: Kind, profile: InnerTubeClientProfile) {
        self.kind = kind
        self.profile = profile
    }

    /// The log/diagnostics name: the profile name, plus " (deciphered)" for ciphered strategies.
    public var name: String { kind == .preSigned ? profile.name : "\(profile.name) (deciphered)" }

    /// The User-Agent the resolved URL must be fetched with.
    public var userAgent: String { profile.userAgent }

    /// One attempt: the URL (or nil) and the diagnostics detail.
    public func resolve(videoId: String, player: any YouTubePlayerFetching, cipher: any CipherResolving,
                        policy: AudioFormatPolicy = .iOS, maxBitrateKbps: Int? = nil) async throws -> (url: String?, detail: String) {
        guard let response = try await player.fetchPlayer(videoId: videoId, profile: profile) else {
            return (nil, await player.lastFailureReason ?? "no response")
        }
        if !response.isPlayable { return (nil, response.statusDetail) }
        let eligible = AudioFormatSelection.eligibleFormats(response, profile: profile)
        switch kind {
        case .preSigned:
            guard let best = policy.pick(eligible.filter { $0.url != nil }, maxBitrateKbps: maxBitrateKbps), let url = best.url else {
                return (nil, "OK but \(response.formats.count) usable formats")
            }
            let transformed = await cipher.applyNTransform(url)
            let detail = "itag \(best.itag), \(best.bitrate / 1000) kbps" + (transformed != url ? ", n descifrado" : ", n sin cambiar")
            return (transformed, detail)
        case .ciphered:
            guard let format = policy.pick(eligible, maxBitrateKbps: maxBitrateKbps) else { return (nil, "OK but no audio formats") }
            if let url = format.url {
                let transformed = await cipher.applyNTransform(url)
                return (SignatureCipher.withStreamingPoToken(transformed, response.streamingPoToken), "itag \(format.itag), plain URL")
            }
            guard let signatureCipher = format.signatureCipher else {
                return (nil, "itag \(format.itag) had neither URL nor cipher")
            }
            let resolved = await cipher.resolveCipheredUrl(signatureCipher)
            return (SignatureCipher.withStreamingPoToken(resolved, response.streamingPoToken),
                    resolved == nil ? "could not run base.js" : "itag \(format.itag), deciphered")
        }
    }

    /// The pre-signed strategies in `PLAYER_PROFILES` order (VISIONOS first).
    public static func preSignedStrategies(_ profiles: [InnerTubeClientProfile] = InnerTubeContexts.playerProfiles) -> [YouTubeStreamStrategy] {
        profiles.filter(\.expectsPreSignedUrls).map { YouTubeStreamStrategy(kind: .preSigned, profile: $0) }
    }

    /// `currentStrategies()`: pre-signed first in both cases (none accepts cookies, so signing in changes nothing for
    /// them), then TVHTML5, WEB (signed in only) and WEB_REMIX deciphered.
    public static func chain(signedIn: Bool, profiles: [InnerTubeClientProfile] = InnerTubeContexts.playerProfiles) -> [YouTubeStreamStrategy] {
        var strategies = preSignedStrategies(profiles)
        strategies.append(YouTubeStreamStrategy(kind: .ciphered, profile: InnerTubeContexts.tvHTML5))
        if signedIn { strategies.append(YouTubeStreamStrategy(kind: .ciphered, profile: InnerTubeContexts.web)) }
        strategies.append(YouTubeStreamStrategy(kind: .ciphered, profile: InnerTubeContexts.webRemix))
        return strategies
    }
}

/// The result of probing a stream URL (`StreamUrlValidator.Probe`).
public struct StreamProbe: Sendable, Hashable {
    public var ok: Bool
    public var httpStatus: Int?
    public var contentType: String?
    public var error: String?

    public init(ok: Bool, httpStatus: Int? = nil, contentType: String? = nil, error: String? = nil) {
        self.ok = ok
        self.httpStatus = httpStatus
        self.contentType = contentType
        self.error = error
    }

    /// Short summary for the diagnostics report.
    public func describe() -> String {
        if ok { return "playable (\(contentType ?? "unknown type"))" }
        if let error { return error }
        if let httpStatus { return "HTTP \(httpStatus)" }
        return "unreachable"
    }

    /// Classifies a response: 206 (with Range) or 200, and a media-looking (or missing) Content-Type — an HTML 200
    /// is an error page in disguise.
    public static func classify(statusCode: Int, contentType: String?) -> StreamProbe {
        guard statusCode == 206 || statusCode == 200 else {
            return StreamProbe(ok: false, httpStatus: statusCode, contentType: contentType)
        }
        let looksLikeMedia = contentType == nil || contentType!.hasPrefix("audio/") || contentType!.hasPrefix("video/")
            || contentType!.contains("octet-stream")
        return StreamProbe(ok: looksLikeMedia, httpStatus: statusCode, contentType: contentType,
                           error: looksLikeMedia ? nil : "server returned \(contentType!), not audio")
    }
}

/// Checks that a stream URL really plays (`StreamUrlValidator`).
public protocol StreamProbing: Sendable {
    func probe(url: String, userAgent: String, sendRange: Bool) async -> StreamProbe
}

/// `StreamUrlValidator`: a 2-byte ranged GET with exactly the headers the real download will send.
public struct StreamUrlValidator: StreamProbing {
    public let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    /// The probe request.
    public static func probeRequest(url: String, userAgent: String = InnerTubeContexts.androidVR.userAgent, sendRange: Bool = true) -> HTTPRequest {
        var request = HTTPRequest(url: url)
        if sendRange { request.setHeader("Range", "bytes=0-1") }
        for header in InnerTubeContexts.streamHeaders(userAgent: userAgent) { request.setHeader(header.name, header.value) }
        return request
    }

    public func probe(url: String, userAgent: String = InnerTubeContexts.androidVR.userAgent, sendRange: Bool = true) async -> StreamProbe {
        do {
            let response = try await http.send(Self.probeRequest(url: url, userAgent: userAgent, sendRange: sendRange))
            return StreamProbe.classify(statusCode: response.statusCode, contentType: response.header("Content-Type"))
        } catch let error as HTTPTransportError {
            return StreamProbe(ok: false, error: NetText.trim("\(error.kind): \(error.message)"))
        } catch {
            return StreamProbe(ok: false, error: String(describing: error))
        }
    }
}

/// `ChainedYouTubeStreamResolver`: tries the strategies in order and returns the first that works.
public actor ChainedYouTubeStreamResolver {
    public static let strategyTimeoutSeconds: Double = 15

    private let player: any YouTubePlayerFetching
    private let cipher: any CipherResolving
    private let validator: (any StreamProbing)?
    private let policy: AudioFormatPolicy
    private let isSignedIn: @Sendable () async -> Bool
    private let maxBitrateKbps: @Sendable () async -> Int?
    /// The strategies for a signed-in state (iOS passes the remote client config's chain; default: the built-in one).
    private let strategies: @Sendable (Bool) async -> [YouTubeStreamStrategy]

    /// The strategy that last succeeded (diagnostics).
    public private(set) var lastSuccessfulStrategy: String?
    /// What each client did in the last attempt, in order.
    public private(set) var lastAttempts: [String] = []

    public init(player: any YouTubePlayerFetching, cipher: any CipherResolving, validator: (any StreamProbing)?,
                policy: AudioFormatPolicy = .iOS,
                isSignedIn: @escaping @Sendable () async -> Bool = { false },
                maxBitrateKbps: @escaping @Sendable () async -> Int? = { nil },
                strategies: @escaping @Sendable (Bool) async -> [YouTubeStreamStrategy] = { YouTubeStreamStrategy.chain(signedIn: $0) }) {
        self.player = player
        self.cipher = cipher
        self.validator = validator
        self.policy = policy
        self.isSignedIn = isSignedIn
        self.maxBitrateKbps = maxBitrateKbps
        self.strategies = strategies
    }

    /// `lastDetail`.
    public var lastDetail: String? { lastAttempts.isEmpty ? nil : lastAttempts.joined(separator: "\n") }

    /// `resolveStream(videoId, validate, excludedStrategies)`. With `validate = false` no probe request is made (the
    /// streaming layer validates the real response and retries another client).
    public func resolveStream(videoId: String, validate: Bool = true, excludedStrategies: Set<String> = []) async throws -> ResolvedStream? {
        var attempts: [String] = []
        let cap = await maxBitrateKbps()
        let signedIn = await isSignedIn()
        for strategy in await strategies(signedIn) where !excludedStrategies.contains(strategy.name) {
            let player = self.player, cipher = self.cipher, policy = self.policy
            let outcome: (url: String?, detail: String)?
            do {
                outcome = try await withTimeout(seconds: Self.strategyTimeoutSeconds) {
                    try await strategy.resolve(videoId: videoId, player: player, cipher: cipher, policy: policy, maxBitrateKbps: cap)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcome = nil
            }
            guard let url = outcome?.url, !NetText.isBlank(url) else {
                attempts.append("\(strategy.name): \(outcome?.detail ?? "no URL")")
                continue
            }
            let detail = outcome?.detail ?? "url"
            if !validate || validator == nil {
                attempts.append("\(strategy.name): \(detail) (sin validar)")
                lastAttempts = attempts
                lastSuccessfulStrategy = strategy.name
                return ResolvedStream(url: url, userAgent: strategy.userAgent, strategyName: strategy.name)
            }
            let probe = await validator!.probe(url: url, userAgent: strategy.userAgent, sendRange: true)
            if probe.ok {
                attempts.append("\(strategy.name): \(probe.describe())")
                lastAttempts = attempts
                lastSuccessfulStrategy = strategy.name
                return ResolvedStream(url: url, userAgent: strategy.userAgent, strategyName: strategy.name)
            }
            attempts.append("\(strategy.name): got URL but \(probe.describe())")
        }
        lastAttempts = attempts
        lastSuccessfulStrategy = nil
        return nil
    }
}

/// Runs `operation`, returning nil when it does not finish within `seconds` (Kotlin `withTimeoutOrNull`).
public func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { return nil }
        return first
    }
}
