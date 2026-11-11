import Foundation
import PixlModel
import PixlNet

/// The audio a Spatial audio library job uploads (cloud audio spec 6.2 step 3, 6.4), and the stream it came from.
///
/// Sing's jobs take `TaisServices.audioSource`, which downloads a streamed song permanently first (it counts in Settings ›
/// Offline storage and gets its "downloaded" badge): right for a tap on Sing, wrong for a render asked for because a song
/// merely played or was picked by the background queue. So a library job takes, in this order:
/// 1. the song's download, when the person already downloaded it;
/// 2. the stream cache's complete file (`Library/Caches/YouTube/streams`, which Offline storage can free);
/// 3. the stream cache filled first (`StreamFetcher.fillCache`): the song comes down once, into the cache.
///
/// `library.source` names the stream (spec 6.2 step 3): the itag and codec the cache recorded for the video, when it
/// recorded them (a download whose stream was never cached has neither, and the block then has no `source`).
nonisolated enum CloudAudioSource {
    nonisolated struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The audio of `videoId` for a library job. Runs off the caller's actor: filling the cache is a long run of reads.
    @concurrent
    static func fetch(videoId: String, cache: StreamCache?, fetcher: StreamFetcher?) async throws -> CloudLibraryAudioSource {
        guard CloudLibrary.isValidVideoId(videoId) else { throw Failure(message: "This song has no YouTube video to render.") }
        if let file = DownloadFiles.existingFile(videoId: videoId) {
            return await source(file, videoId: videoId, cache: cache)
        }
        guard let cache, let fetcher else { throw Failure(message: "Streaming isn't available, so the song can't be sent.") }
        if let file = await cache.completeFileURL(videoId) {
            return await source(file, videoId: videoId, cache: cache)
        }
        try await fetcher.fillCache(videoId: videoId)
        try Task.checkCancellation()
        guard let file = await cache.completeFileURL(videoId) else {
            throw Failure(message: "The song didn't come down whole; it will be tried again.")
        }
        return await source(file, videoId: videoId, cache: cache)
    }

    private static func source(_ file: URL, videoId: String, cache: StreamCache?) async -> CloudLibraryAudioSource {
        let meta = await cache?.meta(videoId)
        let itag = CloudLibrarySourceFormat.itag(meta?.itag)
        return CloudLibraryAudioSource(url: file, itag: itag,
                                       codec: CloudLibrarySourceFormat.codec(itag: itag, contentType: meta?.contentType))
    }
}
