import Foundation
import PixlModel
import PixlNet

/// Where YouTube songs play from (stage 11's `PlayableURLResolving`, wrapping the default resolver): a downloaded
/// file first, then a fully cached stream (both local files — no network, and seeking is instant), else the
/// `pixlstream://<videoId>` URL the streaming resource loader serves. Every other song goes to `base`.
nonisolated struct StreamingPlayableURLResolver: PlayableURLResolving {
    let base: any PlayableURLResolving
    let cache: StreamCache

    func playableURL(for song: Song) async -> URL? {
        guard let videoId = YouTubeSongIdentity.videoId(for: song) else { return await base.playableURL(for: song) }
        if let downloaded = DownloadFiles.existingFile(videoId: videoId) { return downloaded }
        if let cached = await cache.completeFileURL(videoId) { return cached }
        return YouTubeSongIdentity.streamURL(videoId: videoId)
    }
}

/// Downloaded songs: `Application Support/Downloads/<videoId>.m4a` (the folder Settings › Offline storage measures).
nonisolated enum DownloadFiles {
    static var directory: URL {
        OfflineStorageUsage.downloadsDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }

    static func fileURL(videoId: String) -> URL { directory.appendingPathComponent("\(videoId).m4a") }

    static func existingFile(videoId: String) -> URL? {
        let url = fileURL(videoId: videoId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Video ids with a downloaded file.
    static func downloadedIds() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(files.filter { $0.hasSuffix(".m4a") }.map { String($0.dropLast(4)) }
            .filter(CloudStreamSecurity.validateYouTubeVideoId))
    }
}

/// Prepares upcoming streamed songs while music plays (streaming speed R3; owner decisions 2026-10-07, PixlNet's
/// `StreamPrefetchPolicy`). Android oct3 resolves the next Spotify track's URL 1.5 s after playback starts, only
/// while playing; this goes further (iOS first, Android later):
/// 1. 1.5 s after playback (re)starts or the queue changes, the next songs in skip order — 2 on Wi-Fi, 1 on cellular,
///    none in Low Data Mode — go through the engine's full resolver, so Spotify songs are matched on the spot, and
///    their stream URLs are resolved.
/// 2. Once the current song has played 3 s, their first 512 KiB are cached (never on a Low Data Mode path).
/// 3. 30 s before the end, the next song's first MiB is cached, as before, for the gapless hand-over.
/// One task, re-planned when the queue, the current song or the play state changes; pausing cancels it (nothing
/// runs while paused). Matching, resolution and downloads run off the main actor (`@concurrent`); the main actor
/// only reads positions while the task sleeps towards the next step (no ticking timer).
@MainActor
final class YouTubePrefetcher {
    private struct Plan: Equatable {
        var current: Int
        /// Queue entry ids, in skip order (up to `StreamPrefetchPolicy.maxDepth`).
        var early: [Int]
        var topUp: Int?
    }

    private let engine: DualDeckEngine
    private let service: InnerTubeService
    private let fetcher: StreamFetcher
    private let network: NetworkConditionsMonitor
    private var task: Task<Void, Never>?
    private var planned: Plan?

    init(engine: DualDeckEngine, service: InnerTubeService, fetcher: StreamFetcher, network: NetworkConditionsMonitor) {
        self.engine = engine
        self.service = service
        self.fetcher = fetcher
        self.network = network
    }

    /// The current item or the queue changed.
    func upcomingChanged() {
        replan()
    }

    /// Playback started or paused (Android prepares only while the player is playing).
    func playingChanged(_ playing: Bool) {
        replan()
    }

    private func replan() {
        let queue = engine.queue
        guard engine.playWhenReady, let current = queue.current, let currentIndex = queue.currentIndex else {
            cancel()
            return
        }
        network.startIfNeeded()
        let early = StreamPrefetchPolicy.upcomingIndices(current: currentIndex, count: queue.count,
                                                         wraps: queue.repeatMode == .all,
                                                         depth: StreamPrefetchPolicy.maxDepth)
            .compactMap { queue.entry(at: $0) }
            .filter { Self.needsPreparation($0.song) }
        var topUp: QueueEntry?
        if let next = queue.nextIndexForAutoAdvance, next != currentIndex, let entry = queue.entry(at: next),
           Self.needsPreparation(entry.song) {
            topUp = entry
        }
        let plan = Plan(current: current.id, early: early.map(\.id), topUp: topUp?.id)
        if plan == planned, task != nil { return }
        task?.cancel()
        planned = plan
        guard !early.isEmpty || topUp != nil else {
            task = nil
            return
        }
        // The outermost resolver (Spotify → YouTube → files), read now: AppEnvironment installs it after this object.
        let resolver = engine.factory.resolver
        let service = self.service, fetcher = self.fetcher, network = self.network
        let earlySongs = early.map(\.song), topUpSong = topUp?.song
        task = Task { [weak self] in
            // 1. Settle, then match and resolve the next songs (how many depends on the network now).
            try? await Task.sleep(for: .milliseconds(StreamPrefetchPolicy.prepareDelayMs))
            guard !Task.isCancelled else { return }
            let depth = StreamPrefetchPolicy.depth(network.conditions, isPlaying: self?.engine.playWhenReady == true)
            var prepared: [(songId: String, videoId: String)] = []
            for song in earlySongs.prefix(depth) {
                guard !Task.isCancelled else { return }
                if let videoId = await Self.prepare(song, resolver: resolver, service: service) {
                    prepared.append((song.id, videoId))
                }
            }
            // 2. Their head bytes once the current song has played a few seconds.
            if !prepared.isEmpty {
                while !Task.isCancelled, let position = self?.engine.currentPositionMs(),
                      position < StreamPrefetchPolicy.headStartPositionMs {
                    try? await Task.sleep(for: .milliseconds(max(StreamPrefetchPolicy.headStartPositionMs - position, 250)))
                }
                for item in prepared {
                    guard !Task.isCancelled else { return }
                    await fetcher.prefetch(videoId: item.videoId, bytes: StreamPrefetchPolicy.headBytes,
                                           allowsConstrained: false)
                }
            }
            // 3. The next song's first MiB shortly before the hand-over.
            guard let topUpSong else { return }
            while !Task.isCancelled {
                guard let engine = self?.engine else { return }
                let remaining = engine.currentDurationMs() - engine.currentPositionMs()
                if remaining <= StreamPrefetchPolicy.topUpLeadMs { break }
                try? await Task.sleep(for: .milliseconds(max(remaining - StreamPrefetchPolicy.topUpLeadMs, 5_000)))
            }
            guard !Task.isCancelled else { return }
            var videoId = prepared.first { $0.songId == topUpSong.id }?.videoId
            if videoId == nil { videoId = await Self.prepare(topUpSong, resolver: resolver, service: service) }
            guard let videoId, !Task.isCancelled else { return }
            await fetcher.prefetch(videoId: videoId, bytes: StreamPrefetchPolicy.topUpBytes)
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        planned = nil
    }

    /// Streamed songs only: YouTube songs without a downloaded file, and Spotify songs (matched on the way).
    private static func needsPreparation(_ song: Song) -> Bool {
        if let videoId = YouTubeSongIdentity.videoId(for: song) { return DownloadFiles.existingFile(videoId: videoId) == nil }
        return SpotifyPlayableURLResolver.spotifyId(of: song) != nil
    }

    /// Matches (Spotify) and resolves one song off the main actor; its video id when it streams (nil for a local,
    /// downloaded or fully cached file, or when nothing matched).
    @concurrent
    nonisolated private static func prepare(_ song: Song, resolver: any PlayableURLResolving,
                                            service: InnerTubeService) async -> String? {
        guard let url = await resolver.playableURL(for: song), let videoId = YouTubeSongIdentity.videoId(from: url) else {
            return nil
        }
        _ = await service.resolve(videoId: videoId)
        return videoId
    }
}
