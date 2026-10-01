import Foundation
import Observation
import PixlModel
import PixlNet

/// Offline downloads of streamed songs (Android `AudioCacheManager.requestDownload` / `SongDownloadWorker` +
/// `OfflineDownloadCard`'s states). A song whose stream is already fully cached is copied at once; otherwise a
/// background `URLSession` download task fetches the resolved audio with the client's User-Agent (it keeps running
/// while the app is suspended). If googlevideo refuses the single transfer, the download falls back to the
/// streaming loader's ranged fetch in the foreground. Files land in `Application Support/Downloads/<videoId>.m4a`,
/// which the resolver plays first.
@MainActor
@Observable
final class DownloadManager {
    nonisolated enum State: Equatable, Sendable {
        case downloading(percent: Int?)
        case downloaded
        case failed(String)
    }

    static let sessionIdentifier = "io.github.redsn0w1877.pixlaudio.downloads"

    /// By video id.
    private(set) var states: [String: State] = [:]

    @ObservationIgnored private let service: InnerTubeService?
    @ObservationIgnored private let fetcher: StreamFetcher?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private let delegate = DownloadDelegate()
    @ObservationIgnored private var fallbackTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var started = false
    /// The song-row badges (kind only, no percentage): rows re-render when a download starts, ends or fails,
    /// never on progress ticks.
    @ObservationIgnored let badges = DownloadBadges()

    /// `service`/`fetcher` nil = UI tests (no network; states set by the demo).
    init(service: InnerTubeService?, fetcher: StreamFetcher?) {
        self.service = service
        self.fetcher = fetcher
    }

    /// Launch: downloaded files and transfers still running from a previous launch.
    func start() {
        guard !started, service != nil else { return }
        started = true
        for id in DownloadFiles.downloadedIds() { setState(id, .downloaded) }
        delegate.owner = self
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session
        Task {
            for task in await session.allTasks where task.state == .running || task.state == .suspended {
                if let id = task.taskDescription, states[id] != .downloaded { setState(id, .downloading(percent: nil)) }
            }
        }
    }

    func state(for song: Song) -> State? {
        YouTubeSongIdentity.videoId(for: song).flatMap { states[$0] }
    }

    /// Sets a state directly (UI-test demo data).
    func setDemoState(_ state: State?, videoId: String) { setState(videoId, state) }

    /// Every state change goes through here, so the row badges follow.
    private func setState(_ videoId: String, _ state: State?) {
        states[videoId] = state
        badges.update(videoId, state)
    }

    // MARK: Actions

    /// Android `requestDownload`.
    func download(_ song: Song) {
        guard let videoId = YouTubeSongIdentity.videoId(for: song) else { return }
        switch states[videoId] {
        case .downloaded, .downloading: return
        default: break
        }
        setState(videoId, .downloading(percent: nil))
        guard let service, let fetcher else { return }
        Task {
            let destination = DownloadFiles.fileURL(videoId: videoId)
            if await fetcher.cache.copyComplete(videoId, to: destination) {
                setState(videoId, .downloaded)
                return
            }
            guard let stream = await service.resolve(videoId: videoId, validate: true), let url = URL(string: stream.url),
                  CloudStreamSecurity.isSafeRemoteStreamURL(stream.url, allowedHostSuffixes: await service.allowedHosts()),
                  let session else {
                setState(videoId, .failed("No YouTube client could provide this song's audio."))
                return
            }
            var request = URLRequest(url: url)
            request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            let task = session.downloadTask(with: request)
            task.taskDescription = videoId
            task.resume()
        }
    }

    /// Downloads every streamed song in `songs`; returns how many were queued.
    @discardableResult
    func downloadAll(_ songs: [Song]) -> Int {
        var count = 0
        for song in songs {
            guard let id = YouTubeSongIdentity.videoId(for: song), states[id] != .downloaded else { continue }
            download(song)
            count += 1
        }
        return count
    }

    /// Android `removeDownload`.
    func remove(_ song: Song) {
        guard let videoId = YouTubeSongIdentity.videoId(for: song) else { return }
        fallbackTasks[videoId]?.cancel()
        fallbackTasks[videoId] = nil
        session?.getAllTasks { tasks in
            for task in tasks where task.taskDescription == videoId { task.cancel() }
        }
        try? FileManager.default.removeItem(at: DownloadFiles.fileURL(videoId: videoId))
        setState(videoId, nil)
    }

    // MARK: Delegate events

    fileprivate func progress(_ videoId: String, written: Int64, expected: Int64) {
        guard expected > 0 else { return }
        let percent = Int(min(100, max(0, written * 100 / expected)))
        if states[videoId] != .downloading(percent: percent) { setState(videoId, .downloading(percent: percent)) }
    }

    fileprivate func finished(_ videoId: String, failure: String?, retryInForeground: Bool) {
        if failure == nil {
            setState(videoId, .downloaded)
            return
        }
        guard retryInForeground, let fetcher else {
            setState(videoId, .failed(failure ?? "Download failed"))
            return
        }
        // googlevideo refused the single transfer: ranged fetch through the streaming cache, then copy.
        fallbackTasks[videoId] = Task { [weak self] in
            guard let manager = self else { return }
            do {
                try await fetcher.fillCache(videoId: videoId) { written, total in
                    await manager.progress(videoId, written: written, expected: total)
                }
                let copied = await fetcher.cache.copyComplete(videoId, to: DownloadFiles.fileURL(videoId: videoId))
                manager.setState(videoId, copied ? .downloaded : .failed("Couldn't save the song."))
            } catch is CancellationError {
            } catch {
                manager.setState(videoId, .failed(error.localizedDescription))
            }
            manager.fallbackTasks[videoId] = nil
        }
    }

    /// Background-session callbacks (any thread). The file must be moved before `didFinishDownloadingTo` returns.
    nonisolated final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        weak var owner: DownloadManager?
        private let lock = NSLock()
        private var failures: [Int: (reason: String, retry: Bool)] = [:]

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let videoId = downloadTask.taskDescription else { return }
            let http = downloadTask.response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let type = http?.value(forHTTPHeaderField: "Content-Type")
            if status != 200 && status != 206 {
                record(downloadTask.taskIdentifier, "The audio server answered HTTP \(status).", retry: true)
                return
            }
            if !CloudStreamSecurity.isSupportedAudioContentType(type) {
                record(downloadTask.taskIdentifier, "The server sent \(type ?? "?"), not audio.", retry: true)
                return
            }
            let destination = DownloadFiles.fileURL(videoId: videoId)
            let fm = FileManager.default
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            do {
                try fm.moveItem(at: location, to: destination)
            } catch {
                record(downloadTask.taskIdentifier, "Couldn't save the song.", retry: false)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard let videoId = downloadTask.taskDescription else { return }
            Task { @MainActor [weak owner] in
                owner?.progress(videoId, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            guard let videoId = task.taskDescription else { return }
            lock.lock()
            let recorded = failures.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            let cancelled = (error as? URLError)?.code == .cancelled
            if cancelled { return }
            let failure: String? = recorded?.reason ?? error?.localizedDescription
            let retry = recorded?.retry ?? (error != nil)
            Task { @MainActor [weak owner] in
                owner?.finished(videoId, failure: failure, retryInForeground: retry)
            }
        }

        private func record(_ id: Int, _ reason: String, retry: Bool) {
            lock.lock()
            failures[id] = (reason, retry)
            lock.unlock()
        }
    }
}

/// The song-row offline badge (Android `EnhancedSongListItem.SongAvailabilityBadge` fed by `SongCacheStateCache`):
/// downloading, downloaded or failed, per video id. Kept apart from `DownloadManager.states` so the percentage
/// ticks of a running download never invalidate the song lists.
@MainActor
@Observable
final class DownloadBadges {
    nonisolated enum Kind: Sendable, Equatable {
        case downloading, downloaded, failed
    }

    private(set) var kinds: [String: Kind] = [:]

    func update(_ videoId: String, _ state: DownloadManager.State?) {
        let kind: Kind? = switch state {
        case .downloading: .downloading
        case .downloaded: .downloaded
        case .failed: .failed
        case nil: nil
        }
        if kinds[videoId] != kind { kinds[videoId] = kind }
    }

    /// Local files have no badge (they already play offline).
    func kind(for song: Song) -> Kind? {
        guard !kinds.isEmpty, let videoId = YouTubeSongIdentity.videoId(for: song) else { return nil }
        return kinds[videoId]
    }
}
