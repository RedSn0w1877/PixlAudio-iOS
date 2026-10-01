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

/// Resolves and pre-loads the next YouTube song before the current one ends (architecture §2: "prefetch 30 s before
/// track end"). On every queue / track change the next entry's stream is resolved at once (one InnerTube request);
/// its first megabyte is fetched into the cache 30 s before the end, so the gapless hand-over (prepared 4.5 s
/// ahead) finds content information and the first bytes on disk. One sleeping task, no ticking timer: it wakes
/// at the computed moment and re-checks (seeks and pauses move the moment).
@MainActor
final class YouTubePrefetcher {
    static let leadMs: Int64 = 30_000

    private let engine: DualDeckEngine
    private let service: InnerTubeService
    private let fetcher: StreamFetcher
    private var task: Task<Void, Never>?
    private var planned: (current: String?, next: String)?

    init(engine: DualDeckEngine, service: InnerTubeService, fetcher: StreamFetcher) {
        self.engine = engine
        self.service = service
        self.fetcher = fetcher
    }

    /// The current item or the queue changed.
    func upcomingChanged() {
        let queue = engine.queue
        guard let index = queue.nextIndexForAutoAdvance, let next = queue.entry(at: index)?.song,
              let videoId = YouTubeSongIdentity.videoId(for: next), DownloadFiles.existingFile(videoId: videoId) == nil else {
            task?.cancel()
            task = nil
            planned = nil
            return
        }
        let current = queue.current?.song.id
        if let planned, planned.current == current, planned.next == videoId, task != nil { return }
        planned = (current, videoId)
        task?.cancel()
        let service = self.service, fetcher = self.fetcher
        task = Task { [weak self] in
            _ = await service.resolve(videoId: videoId)
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = self.engine.currentDurationMs() - self.engine.currentPositionMs()
                if remaining <= Self.leadMs { break }
                try? await Task.sleep(for: .milliseconds(max(remaining - Self.leadMs, 5_000)))
            }
            guard !Task.isCancelled else { return }
            await fetcher.prefetch(videoId: videoId)
        }
    }
}
