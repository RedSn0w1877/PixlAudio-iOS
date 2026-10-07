import Foundation
import Testing
@testable import PixlNet

/// Streaming speed (2026-10-07, iOS first): the pure rules behind the app's streaming loader — GET sizes (R2).
@Suite("Stream chunk policy")
struct StreamChunkPolicyTests {
    @Test func fetchesGrowFrom128KiBTo2MiB() {
        #expect(StreamChunkPolicy.startFetchBytes == 131_072)
        #expect(StreamChunkPolicy.maxFetchBytes == 2_097_152)
        var size = StreamChunkPolicy.startFetchBytes
        var sizes = [size]
        for _ in 0..<4 {
            size = StreamChunkPolicy.nextFetchSize(after: size)
            sizes.append(size)
        }
        #expect(sizes == [131_072, 524_288, 2_097_152, 2_097_152, 2_097_152])
        // Never below the start size, never above the cap (yt-dlp asks for 10 MiB ranges).
        #expect(StreamChunkPolicy.nextFetchSize(after: 1) == 524_288)
        #expect(StreamChunkPolicy.nextFetchSize(after: 50 << 20) == 2_097_152)
    }

    @Test func theFirstRequestReadsAheadOfAVFoundationsTwoBytes() {
        // Nothing cached and the size unknown: the 2-byte request becomes bytes=0-131071.
        let first = StreamChunkPolicy.requestRange(for: 0..<2, readAhead: StreamChunkPolicy.startFetchBytes,
                                                   nextCachedStart: nil, contentLength: nil)
        #expect(first == 0..<131_072)
        #expect(ContentRange.requestHeader(first) == "bytes=0-131071")
        // Never past the end of a short file, never into bytes already on disk.
        #expect(StreamChunkPolicy.requestRange(for: 0..<2, readAhead: 131_072, nextCachedStart: nil,
                                               contentLength: 50_000) == 0..<50_000)
        #expect(StreamChunkPolicy.requestRange(for: 0..<2, readAhead: 131_072, nextCachedStart: 4_096,
                                               contentLength: nil) == 0..<4_096)
        // Without read-ahead (or when the cached span starts inside the range) the range is asked for as is.
        #expect(StreamChunkPolicy.requestRange(for: 10..<20, readAhead: 0, nextCachedStart: nil,
                                               contentLength: 100) == 10..<20)
        #expect(StreamChunkPolicy.requestRange(for: 10..<20, readAhead: 1_000, nextCachedStart: 15,
                                               contentLength: nil) == 10..<20)
        // A cached span that starts before the range is no limit.
        #expect(StreamChunkPolicy.requestRange(for: 10..<20, readAhead: 1_000, nextCachedStart: 5,
                                               contentLength: nil) == 10..<1_010)
    }

    @Test func aFetchStopsAtItsSizeTheEndOrCachedBytes() {
        #expect(StreamChunkPolicy.fetchEnd(offset: 0, end: 10_000_000, fetchSize: 131_072, nextCachedStart: nil) == 131_072)
        #expect(StreamChunkPolicy.fetchEnd(offset: 100, end: 300, fetchSize: 131_072, nextCachedStart: nil) == 300)
        #expect(StreamChunkPolicy.fetchEnd(offset: 100, end: 10_000, fetchSize: 131_072, nextCachedStart: 400) == 400)
        // A cached span at or before the offset is ignored; at least one byte is always fetched.
        #expect(StreamChunkPolicy.fetchEnd(offset: 100, end: 10_000, fetchSize: 1_000, nextCachedStart: 100) == 1_100)
        #expect(StreamChunkPolicy.fetchEnd(offset: 100, end: 100, fetchSize: 1_000, nextCachedStart: nil) == 101)
    }
}

/// R3: what the prefetcher prepares ahead (owner decision: next 1 on cellular, next 2 on Wi-Fi, 512 KB each, none in
/// Low Data Mode, only while playing).
@Suite("Stream prefetch policy")
struct StreamPrefetchPolicyTests {
    typealias Policy = StreamPrefetchPolicy

    @Test func depthFollowsTheNetwork() {
        #expect(Policy.depth(.init(network: .wifi), isPlaying: true) == 2)
        #expect(Policy.depth(.init(network: .wired), isPlaying: true) == 2)
        #expect(Policy.depth(.init(network: .cellular, isExpensive: true), isPlaying: true) == 1)
        #expect(Policy.depth(.init(network: .cellular), isPlaying: true) == 1)
        // A personal hotspot is Wi-Fi but metered: treated like cellular.
        #expect(Policy.depth(.init(network: .wifi, isExpensive: true), isPlaying: true) == 1)
        #expect(Policy.depth(.init(network: .other), isPlaying: true) == 1)
        #expect(Policy.depth(.unknown, isPlaying: true) == 1)
        #expect(Policy.depth(.init(network: .offline), isPlaying: true) == 0)
    }

    @Test func nothingInLowDataModeOrWhilePaused() {
        #expect(Policy.depth(.init(network: .wifi, isConstrained: true), isPlaying: true) == 0)
        #expect(Policy.depth(.init(network: .cellular, isConstrained: true, isExpensive: true), isPlaying: true) == 0)
        #expect(Policy.depth(.init(network: .wifi), isPlaying: false) == 0)
        #expect(Policy.depth(.init(network: .cellular), isPlaying: false) == 0)
    }

    @Test func sizesAndTimings() {
        #expect(Policy.headBytes == 524_288)
        #expect(Policy.topUpBytes == 1_048_576)
        #expect(Policy.topUpLeadMs == 30_000)
        #expect(Policy.prepareDelayMs == 1_500)
        #expect(Policy.headStartPositionMs == 3_000)
        #expect(Policy.maxDepth == 2)
    }

    @Test func upcomingSongsInSkipOrder() {
        #expect(Policy.upcomingIndices(current: 0, count: 5, wraps: false, depth: 2) == [1, 2])
        #expect(Policy.upcomingIndices(current: 3, count: 5, wraps: false, depth: 2) == [4])
        #expect(Policy.upcomingIndices(current: 4, count: 5, wraps: false, depth: 2) == [])
        // Repeat-all wraps to the start.
        #expect(Policy.upcomingIndices(current: 4, count: 5, wraps: true, depth: 2) == [0, 1])
        #expect(Policy.upcomingIndices(current: 3, count: 5, wraps: true, depth: 2) == [4, 0])
        // Never the current song, never twice.
        #expect(Policy.upcomingIndices(current: 0, count: 1, wraps: true, depth: 2) == [])
        #expect(Policy.upcomingIndices(current: 1, count: 2, wraps: true, depth: 2) == [0])
        #expect(Policy.upcomingIndices(current: 0, count: 5, wraps: false, depth: 0) == [])
        #expect(Policy.upcomingIndices(current: 7, count: 5, wraps: false, depth: 2) == [])
    }
}
