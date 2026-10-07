// Streaming speed (2026-10-07; iOS first, Android later): the pure rules behind the app's streaming loader, kept
// here so they are unit-tested on every platform. The app's `StreamFetcher`, `YouTubeResourceLoader` and
// `YouTubePrefetcher` apply them.

import Foundation

/// R2: how many bytes each ranged GET asks for. AVFoundation's first loading request wants the content information
/// and bytes 0–1; the GET that answers it reads `startFetchBytes` ahead, so the next request's first bytes come from
/// disk. Within one loading request the network fetches then grow 128 KiB → 512 KiB → 2 MiB (capped), so the first
/// audio reaches the player after a small download instead of a whole megabyte, and a cancelled request loses less.
public enum StreamChunkPolicy {
    /// The first GET of a stream (and of every loading request's first network fetch).
    public static let startFetchBytes: Int64 = 128 << 10
    /// The largest single GET (googlevideo throttles very large single ranges; yt-dlp asks for 10 MiB).
    public static let maxFetchBytes: Int64 = 2 << 20
    public static let growthFactor: Int64 = 4

    /// The next network fetch size within one loading request: 128 KiB → 512 KiB → 2 MiB → 2 MiB ….
    public static func nextFetchSize(after size: Int64) -> Int64 {
        min(max(size, startFetchBytes) * growthFactor, maxFetchBytes)
    }

    /// The bytes a GET asks for: at least `range`, read ahead to `range.lowerBound + readAhead`, but never into bytes
    /// already cached (`nextCachedStart`: where the next cached span begins) or past the file's end.
    public static func requestRange(for range: Range<Int64>, readAhead: Int64, nextCachedStart: Int64?,
                                    contentLength: Int64?) -> Range<Int64> {
        var upper = range.lowerBound + max(readAhead, 0)
        if let nextCachedStart, nextCachedStart > range.lowerBound { upper = min(upper, nextCachedStart) }
        if let contentLength, contentLength > 0 { upper = min(upper, contentLength) }
        return range.lowerBound..<max(range.upperBound, upper)
    }

    /// Where one network fetch from `offset` stops: after `fetchSize` bytes, at `end`, or where cached bytes resume
    /// (always at least one byte).
    public static func fetchEnd(offset: Int64, end: Int64, fetchSize: Int64, nextCachedStart: Int64?) -> Int64 {
        var stop = min(offset + max(fetchSize, 1), end)
        if let nextCachedStart, nextCachedStart > offset { stop = min(stop, nextCachedStart) }
        return max(stop, offset + 1)
    }
}
