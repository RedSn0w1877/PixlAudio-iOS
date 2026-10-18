import AVFoundation
import Foundation
import PixlModel
import PixlNet

/// What Spotify needs from the YouTube layer (stage 11): a YouTube Music search for the matcher, the URL the player
/// opens for a matched video, and a stream resolution the playback test can report on. Spotify's Web API gives
/// metadata only, so every Spotify song plays through this seam.
///
/// `PixlNetYouTubeBridge` works on its own (anonymous InnerTube search with a fresh visitorData, the pre-signed
/// client chain); stage 11 swaps in its signed-in session and streaming loader by passing its own bridge (or its
/// search client / resolver) to `SpotifyService` — the Spotify code doesn't change.
nonisolated protocol SpotifyYouTubeBridge: Sendable {
    /// YouTube Music search used by `TrackMatcher`.
    var search: any YouTubeMusicSearching { get }
    /// Why the last search failed (diagnostics), when known.
    func lastSearchFailure() async -> String?
    /// The URL the player opens for `videoId`. `base` is the app's resolver (stage 11 maps `yt:` songs to its
    /// streaming scheme there).
    func playableURL(videoId: String, base: any PlayableURLResolving) async -> URL?
    /// Resolves a stream for the playback test: the URL (validated with a 2-byte ranged GET) and what each client did.
    func resolveForDiagnostics(videoId: String) async -> SpotifyStreamResolution
}

/// The playback test's view of a stream resolution.
nonisolated struct SpotifyStreamResolution: Sendable, Equatable {
    var url: String?
    var userAgent: String?
    var strategy: String?
    var attempts: [String]
}

/// No base.js available (stage 11 owns the JavaScriptCore cipher): ciphered clients fail, pre-signed URLs pass
/// through untransformed. VISIONOS, which leads the chain, needs neither.
nonisolated struct PassThroughCipher: CipherResolving {
    func resolveCipheredUrl(_ signatureCipher: String) async -> String? { nil }
    func applyNTransform(_ url: String) async -> String { url }
}

/// The self-contained bridge on PixlNet: InnerTube search and the pre-signed client chain, anonymous (no cookie is
/// ever sent — the native clients answer 400 to one), with a fresh visitorData per process.
nonisolated final class PixlNetYouTubeBridge: SpotifyYouTubeBridge {
    let client: InnerTubeClient
    private let resolver: ChainedYouTubeStreamResolver
    var search: any YouTubeMusicSearching { client }

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        let session = AnonymousYouTubeSession(visitorData: VisitorDataProvider(http: http))
        client = InnerTubeClient(http: http, session: session)
        resolver = ChainedYouTubeStreamResolver(player: client, cipher: PassThroughCipher(),
                                                validator: StreamUrlValidator(http: http),
                                                maxBitrateKbps: { StreamingAudioQuality.maxBitrateKbps() })
    }

    func lastSearchFailure() async -> String? { await client.lastFailureReason }

    func playableURL(videoId: String, base: any PlayableURLResolving) async -> URL? {
        // Stage 11's route: a `yt:` song on its streaming scheme (architecture §2: `pixlstream://<videoId>`).
        let song = SpotifyPlayableURLResolver.youTubeSong(videoId: videoId)
        if let url = await base.playableURL(for: song) {
            let streamable = await MainActor.run { StreamingResourceLoaderRegistry.shared.handles(url) }
            if streamable || url.scheme == "https" || url.isFileURL { return url }
        }
        // Without the streaming loader: a direct googlevideo URL from the pre-signed chain (not re-validated: the
        // validation request would spend the URL).
        guard let stream = try? await resolver.resolveStream(videoId: videoId, validate: false) else { return nil }
        return URL(string: stream.url)
    }

    func resolveForDiagnostics(videoId: String) async -> SpotifyStreamResolution {
        let stream = try? await resolver.resolveStream(videoId: videoId, validate: true)
        return SpotifyStreamResolution(url: stream?.url, userAgent: stream?.userAgent,
                                       strategy: await resolver.lastSuccessfulStrategy, attempts: await resolver.lastAttempts)
    }
}

/// Plays Spotify songs (`spotify://<id>`, Android `SpotifyStreamProxy`): looks up the track's matched video —
/// matching it on the spot when the background matcher hasn't got to it yet (25 s cap, never over a manual choice;
/// the searches fan out, R11) — and hands the video to the YouTube bridge. Every other song goes to `base` unchanged.
nonisolated struct SpotifyPlayableURLResolver: PlayableURLResolving {
    static let onDemandMatchTimeoutSeconds: Double = 25

    let base: any PlayableURLResolving
    let bridge: any SpotifyYouTubeBridge
    let persistence: PersistenceActor

    static func spotifyId(of song: Song) -> String? {
        if let id = song.spotifyId, !id.isEmpty { return id }
        let uri = song.contentUriString
        guard uri.hasPrefix("spotify://") else { return nil }
        // Spotify ids are case-sensitive base62: cut the string by hand, never through URL host parsing.
        let id = String(uri.dropFirst("spotify://".count).prefix { $0 != "/" })
        return id.isEmpty ? nil : id
    }

    /// The synthetic `yt:` song a matched video plays as.
    static func youTubeSong(videoId: String) -> Song {
        Song(id: "yt:\(videoId)", title: "", artist: "", artistId: 0, album: "", albumId: 0, path: "",
             contentUriString: "pixlstream://\(videoId)", albumArtUriString: nil, duration: 0, mimeType: nil, bitrate: nil,
             sampleRate: nil)
    }

    func playableURL(for song: Song) async -> URL? {
        guard let spotifyId = Self.spotifyId(of: song) else { return await base.playableURL(for: song) }
        guard let videoId = await videoId(for: spotifyId), CloudStreamSecurity.validateYouTubeVideoId(videoId) else { return nil }
        return await bridge.playableURL(videoId: videoId, base: base)
    }

    /// Another video for the song after the player could not load `failedURL`: that video is set aside for half an
    /// hour, the next-best search candidate replaces it (once found, for good), and the player retries with it.
    /// Nil when the failure was not a matched video, or no other acceptable candidate exists.
    func recoverPlayableURL(for song: Song, afterFailedURL failedURL: URL) async -> URL? {
        guard let spotifyId = Self.spotifyId(of: song),
              let failedVideoId = YouTubeSongIdentity.videoId(from: failedURL) else {
            return await base.recoverPlayableURL(for: song, afterFailedURL: failedURL)
        }
        let coordinator = SpotifyMatchCoordinator.shared
        await coordinator.exclude(videoId: failedVideoId, for: spotifyId)
        guard let videoId = await videoId(for: spotifyId), videoId != failedVideoId,
              CloudStreamSecurity.validateYouTubeVideoId(videoId) else { return nil }
        return await bridge.playableURL(videoId: videoId, base: base)
    }

    func videoId(for spotifyId: String) async -> String? {
        let coordinator = SpotifyMatchCoordinator.shared
        let excluded = await coordinator.excludedIds(for: spotifyId)
        if let stored = try? await persistence.matchedVideoId(spotifyId: spotifyId), !excluded.contains(stored) { return stored }
        return await coordinator.match(spotifyId: spotifyId) { await rematch(spotifyId: spotifyId, excluding: excluded) }
    }

    private func rematch(spotifyId: String, excluding excluded: Set<String>) async -> SpotifyMatchCoordinator.Outcome {
        guard let record = try? await persistence.spotifySong(spotifyId: spotifyId) else { return .failed }
        if record.matchState == .manual { return .failed }
        let matcher = TrackMatcher(search: bridge.search)
        let track = record.matchable
        // Streaming speed R11: on the play-time path the searches after the first run at once (same result as the
        // background matcher's sequential `findMatch`, sooner).
        let found: TrackMatch??
        do {
            found = try await withTimeout(seconds: Self.onDemandMatchTimeoutSeconds, {
                try await matcher.findMatchFanOut(track, excludingVideoIds: excluded)
            })
        } catch {
            return .failed
        }
        // A timeout or a failed search is not "no match": only a finished search that found nothing is remembered.
        guard let found else { return .failed }
        guard let match = found else { return .none }
        if excluded.isEmpty {
            try? await persistence.updateAutomaticMatch(spotifyId: spotifyId, videoId: match.videoId, score: match.score, state: .matched)
            return .found((try? await persistence.matchedVideoId(spotifyId: spotifyId)) ?? match.videoId)
        }
        try? await persistence.replaceAutomaticMatch(spotifyId: spotifyId, videoId: match.videoId, score: match.score)
        return .found(match.videoId)
    }
}

/// Play-time matching bookkeeping shared by the engine and the prefetcher (Android `SpotifyStreamProxy` match locks
/// and `noMatchUntil`): one search per song at a time, a finished search that found nothing is not repeated for ten
/// minutes, and a video the player could not load is set aside for half an hour (memory only: YouTube's blocks
/// change, so the video gets another chance after that and after a relaunch).
actor SpotifyMatchCoordinator {
    nonisolated enum Outcome: Sendable {
        case found(String)
        /// The search finished without an acceptable candidate.
        case none
        /// Timeout, network trouble or an unknown song: try again next time.
        case failed
    }

    static let shared = SpotifyMatchCoordinator()
    static let exclusionTTL: Duration = .seconds(30 * 60)
    static let noMatchTTL: Duration = .seconds(10 * 60)
    private static let maxEntries = 400

    private var excluded: [String: [String: ContinuousClock.Instant]] = [:]
    private var noMatchUntil: [String: ContinuousClock.Instant] = [:]
    private var inFlight: [String: Task<Outcome, Never>] = [:]

    func exclude(videoId: String, for spotifyId: String) {
        if excluded.count > Self.maxEntries { excluded = excluded.filter { !$0.value.values.allSatisfy { $0 <= ContinuousClock.now } } }
        excluded[spotifyId, default: [:]][videoId] = ContinuousClock.now.advanced(by: Self.exclusionTTL)
        noMatchUntil[spotifyId] = nil
    }

    func excludedIds(for spotifyId: String) -> Set<String> {
        guard var entries = excluded[spotifyId] else { return [] }
        let now = ContinuousClock.now
        entries = entries.filter { $0.value > now }
        excluded[spotifyId] = entries.isEmpty ? nil : entries
        return Set(entries.keys)
    }

    func match(spotifyId: String, work: @escaping @Sendable () async -> Outcome) async -> String? {
        if let until = noMatchUntil[spotifyId] {
            if ContinuousClock.now < until { return nil }
            noMatchUntil[spotifyId] = nil
        }
        let task: Task<Outcome, Never>
        if let running = inFlight[spotifyId] {
            task = running
        } else {
            task = Task { await work() }
            inFlight[spotifyId] = task
        }
        let outcome = await task.value
        inFlight[spotifyId] = nil
        switch outcome {
        case .found(let id):
            return id
        case .none:
            if noMatchUntil.count > Self.maxEntries { noMatchUntil = noMatchUntil.filter { $0.value > ContinuousClock.now } }
            noMatchUntil[spotifyId] = ContinuousClock.now.advanced(by: Self.noMatchTTL)
            return nil
        case .failed:
            return nil
        }
    }
}
