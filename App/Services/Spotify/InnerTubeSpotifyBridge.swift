import Foundation
import PixlModel
import PixlNet

/// Stage 11's YouTube layer behind Spotify (integration of stages 11 + 12): the matcher searches through the app's
/// InnerTube session (signed in when the user is, cookies only to clients that accept them), matched videos play
/// through the `pixlstream://` loader — or a downloaded / fully cached file — and the playback test reports the same
/// chain the player uses (remote client table, JavaScriptCore cipher, Piped).
nonisolated final class InnerTubeSpotifyBridge: SpotifyYouTubeBridge {
    let service: InnerTubeService
    var search: any YouTubeMusicSearching { service.client }

    init(service: InnerTubeService) {
        self.service = service
    }

    func lastSearchFailure() async -> String? {
        await service.lastClientFailure()
    }

    func playableURL(videoId: String, base: any PlayableURLResolving) async -> URL? {
        // `base` contains stage 11's StreamingPlayableURLResolver: download → complete cache file → pixlstream://.
        if let url = await base.playableURL(for: SpotifyPlayableURLResolver.youTubeSong(videoId: videoId)) { return url }
        guard let stream = await service.resolve(videoId: videoId) else { return nil }
        return URL(string: stream.url)
    }

    func resolveForDiagnostics(videoId: String) async -> SpotifyStreamResolution {
        let outcome = await service.diagnosticsOutcome(videoId: videoId)
        return SpotifyStreamResolution(url: outcome.stream?.url, userAgent: outcome.stream?.userAgent,
                                       strategy: outcome.successfulStrategy, attempts: outcome.attempts)
    }
}
