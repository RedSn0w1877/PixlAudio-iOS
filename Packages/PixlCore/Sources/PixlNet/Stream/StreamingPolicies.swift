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

/// R3: how far ahead the app prepares upcoming streamed songs while music plays (owner decision 2026-10-07: the next
/// 1 song on cellular, the next 2 on Wi-Fi, 512 KB each, none in Low Data Mode, only while playing). Preparing means
/// matching a Spotify song to its video, resolving the stream URL and caching the first 512 KiB.
public enum StreamPrefetchPolicy {
    /// The network the phone is on (the app maps `NWPath` to this).
    public enum Network: Sendable, Hashable {
        case wifi, wired, cellular, other, offline
        /// No path reported yet.
        case unknown
    }

    public struct Conditions: Sendable, Hashable {
        public var network: Network
        /// Low Data Mode.
        public var isConstrained: Bool
        /// A metered path (cellular, or a Wi-Fi personal hotspot).
        public var isExpensive: Bool

        public init(network: Network, isConstrained: Bool = false, isExpensive: Bool = false) {
            self.network = network
            self.isConstrained = isConstrained
            self.isExpensive = isExpensive
        }

        public static let unknown = Conditions(network: .unknown)
    }

    /// The most songs prepared ahead.
    public static let maxDepth = 2
    /// Head bytes cached early for each prepared song.
    public static let headBytes: Int64 = 512 << 10
    /// The next song's first MiB is cached this long before the current one ends (the gapless hand-over's bytes).
    public static let topUpBytes: Int64 = 1 << 20
    public static let topUpLeadMs: Int64 = 30_000
    /// Matching and resolution start this long after playback starts or the queue changes (Android's 1.5 s settle).
    public static let prepareDelayMs: Int64 = 1_500
    /// Head bytes are fetched once the current song has played this far.
    public static let headStartPositionMs: Int64 = 3_000

    /// How many upcoming songs to prepare early: none while paused, offline or in Low Data Mode; two on Wi-Fi or
    /// Ethernet (unless the path is metered, e.g. a personal hotspot); one on cellular and anything else.
    public static func depth(_ conditions: Conditions, isPlaying: Bool) -> Int {
        guard isPlaying, !conditions.isConstrained else { return 0 }
        switch conditions.network {
        case .offline: return 0
        case .wifi, .wired: return conditions.isExpensive ? 1 : maxDepth
        case .cellular, .other, .unknown: return 1
        }
    }

    /// The queue indices to prepare, in skip order: the entries after `current` (wrapping to the start under
    /// repeat-all), at most `depth`, never the current one.
    public static func upcomingIndices(current: Int, count: Int, wraps: Bool, depth: Int) -> [Int] {
        guard count > 0, current >= 0, current < count, depth > 0 else { return [] }
        var indices: [Int] = []
        for step in 1...depth {
            var index = current + step
            if index >= count {
                guard wraps else { break }
                index %= count
            }
            if index == current || indices.contains(index) { break }
            indices.append(index)
        }
        return indices
    }
}
