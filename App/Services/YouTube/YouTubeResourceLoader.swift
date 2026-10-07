import AVFoundation
import Foundation
import PixlNet

/// The `AVAssetResourceLoaderDelegate` for `pixlstream://<videoId>` items (architecture §2; Android: the local Ktor
/// proxy `SpotifyStreamProxy`). Registered with the playback engine's `StreamingResourceLoaderRegistry`, so the
/// engine needs no YouTube code: AVPlayer asks for content information and byte ranges, the delegate answers from
/// the sparse cache and fetches the gaps with `StreamFetcher` (range requests with the matching client User-Agent,
/// re-resolving on 403). When a file becomes complete it can play from disk next time.
///
/// Callbacks arrive on the registry's serial queue; each loading request is served by its own task, cancelled
/// when AVPlayer cancels the request.
nonisolated final class YouTubeResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    /// AVFoundation request objects are not Sendable; they are documented to be answered from any thread.
    nonisolated private final class RequestBox: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
        init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
    }

    let fetcher: StreamFetcher
    /// A stream finished downloading completely (eviction, prefetch bookkeeping).
    let onComplete: @Sendable (String) -> Void
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(fetcher: StreamFetcher, onComplete: @escaping @Sendable (String) -> Void) {
        self.fetcher = fetcher
        self.onComplete = onComplete
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, let videoId = YouTubeSongIdentity.videoId(from: url) else { return false }
        PlaybackStartTimings.shared.loaderRequest(
            key: YouTubeSongIdentity.timingKey(videoId: videoId),
            contentInfo: loadingRequest.contentInformationRequest != nil,
            toEnd: loadingRequest.dataRequest?.requestsAllDataToEndOfResource ?? false)
        let box = RequestBox(loadingRequest)
        let key = ObjectIdentifier(loadingRequest)
        // Stored under the lock before the task can finish (its `finished` call waits for the lock).
        lock.lock()
        tasks[key] = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.serve(box, videoId: videoId)
            self.finished(key)
        }
        lock.unlock()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = tasks.removeValue(forKey: key)
        lock.unlock()
        task?.cancel()
        if task != nil, let url = loadingRequest.request.url, let videoId = YouTubeSongIdentity.videoId(from: url) {
            PlaybackStartTimings.shared.loaderCancelled(key: YouTubeSongIdentity.timingKey(videoId: videoId))
        }
    }

    private func finished(_ key: ObjectIdentifier) {
        lock.lock()
        tasks[key] = nil
        lock.unlock()
    }

    private func serve(_ box: RequestBox, videoId: String) async {
        let request = box.request
        do {
            let info = try await fetcher.info(videoId: videoId)
            if let contentRequest = request.contentInformationRequest {
                contentRequest.contentType = info.uniformTypeIdentifier
                contentRequest.contentLength = info.contentLength
                contentRequest.isByteRangeAccessSupported = true
            }
            if let dataRequest = request.dataRequest {
                let end = dataRequest.requestsAllDataToEndOfResource
                    ? info.contentLength
                    : min(info.contentLength, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
                var position = dataRequest.currentOffset
                var answered = false
                while position < end {
                    try Task.checkCancellation()
                    let data = try await fetcher.data(videoId: videoId, from: position, upTo: end)
                    guard !data.isEmpty else { throw StreamFetcher.Failure.badResponse("The stream ended early.") }
                    try Task.checkCancellation()
                    dataRequest.respond(with: data)
                    position += Int64(data.count)
                    if !answered {
                        answered = true
                        PlaybackStartTimings.shared.answered(key: YouTubeSongIdentity.timingKey(videoId: videoId))
                    }
                }
            }
            if Task.isCancelled { return }
            request.finishLoading()
            if await fetcher.cache.isComplete(videoId) { onComplete(videoId) }
        } catch is CancellationError {
            // AVPlayer cancelled the request (seek, item gone); nothing to answer.
        } catch {
            if !Task.isCancelled { request.finishLoading(with: error) }
        }
    }
}
