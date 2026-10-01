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
        resolver = ChainedYouTubeStreamResolver(player: client, cipher: PassThroughCipher(), validator: StreamUrlValidator(http: http))
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
/// matching it on the spot when the background matcher hasn't got to it yet (25 s cap, never over a manual choice) —
/// and hands the video to the YouTube bridge. Every other song goes to `base` unchanged.
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

    func videoId(for spotifyId: String) async -> String? {
        if let stored = try? await persistence.matchedVideoId(spotifyId: spotifyId) { return stored }
        guard let record = try? await persistence.spotifySong(spotifyId: spotifyId), record.matchState != .manual else { return nil }
        let matcher = TrackMatcher(search: bridge.search)
        let track = record.matchable
        guard let found = try? await withTimeout(seconds: Self.onDemandMatchTimeoutSeconds, { try await matcher.findMatch(track) }),
              let match = found else { return nil }
        try? await persistence.updateAutomaticMatch(spotifyId: spotifyId, videoId: match.videoId, score: match.score, state: .matched)
        return (try? await persistence.matchedVideoId(spotifyId: spotifyId)) ?? match.videoId
    }
}
