// Port of `data/worker/SpotifyMatchWorker.kt`: one matching pass over the PENDING tracks. WorkManager's scheduling
// (unique work, retry with backoff, continuation) is the app's job; this returns what Android's `doWork` decided.
// - Keyset paging (`spotifyId > cursor`), so tracks left PENDING by a failed search don't stall the pass.
// - A failed search (network, rate limit) leaves the track PENDING; only "searched, nothing acceptable" is UNMATCHED.
// - A batch where every search failed ends the pass with `retryLater` (something outside is down or limiting).
// - Writes go after each batch, as one `updateAutomaticMatches` call (never overriding a manual match).

import Foundation
import PixlFoundation
import PixlModel

/// What one pass did (Android's worker result + its decision to retry or continue).
public struct SpotifyMatchPassResult: Sendable, Hashable {
    public var matched = 0
    public var failed = 0
    public var errored = 0
    public var done = 0
    public var totalPending = 0
    /// The time budget ran out with tracks left: run another pass now.
    public var moreWork = false
    /// Network trouble (a fully failed batch, or errored tracks): try again after a backoff.
    public var retryLater = false

    public init() {}
}

/// `SpotifyMatchWorker.doWork`.
public struct SpotifyMatchRunner: Sendable {
    public static let batchSize = 48
    public static let concurrencyIdle = 4
    public static let concurrencyPlaying = 2
    public static let betweenBatchesMs: Int64 = 250
    /// A pass stops itself after 8 minutes (Android's margin before WorkManager's 10-minute kill).
    public static let runBudgetMs: Int64 = 8 * 60 * 1000

    public typealias Matcher = @Sendable (MatchableTrack) async throws -> TrackMatch?

    private let store: any SpotifyLibraryStore
    private let matcher: Matcher
    private let nowMs: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void

    public init(store: any SpotifyLibraryStore, matcher: @escaping Matcher,
                nowMs: @escaping @Sendable () -> Int64 = { currentTimeMillis() },
                sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) }) {
        self.store = store
        self.matcher = matcher
        self.nowMs = nowMs
        self.sleep = sleep
    }

    /// Runs one pass. `retryFailed` (a user's "Find audio") first puts UNMATCHED tracks back in the queue.
    /// `isPlaybackActive` lowers the concurrency while music plays; `shouldContinue` is Android's `!isStopped`.
    public func run(retryFailed: Bool = false, isPlaybackActive: @Sendable () async -> Bool = { false },
                    shouldContinue: @Sendable () async -> Bool = { true },
                    onProgress: (@Sendable (_ done: Int, _ total: Int) async -> Void)? = nil) async throws -> SpotifyMatchPassResult {
        if retryFailed { _ = try await store.requeueUnmatched() }
        var result = SpotifyMatchPassResult()
        let startedAt = nowMs()
        result.totalPending = try await store.countTracks(in: .pending)
        if result.totalPending == 0 { return result }

        var cursor = ""
        var stopped = false
        while true {
            if await !shouldContinue() {
                stopped = true
                break
            }
            if nowMs() - startedAt >= Self.runBudgetMs {
                result.moreWork = true
                break
            }
            let batch = try await store.pendingSongs(after: cursor, limit: Self.batchSize)
            if batch.isEmpty { break }
            cursor = batch.last!.spotifyId

            let permits = await isPlaybackActive() ? Self.concurrencyPlaying : Self.concurrencyIdle
            let outcomes = try await Self.search(batch, permits: permits, matcher: matcher)

            // One write for the batch (one transaction in the app's store), in the order of the searches.
            var updates: [SpotifyAutoMatchUpdate] = []
            for (song, outcome) in outcomes {
                switch outcome {
                case .failure:
                    result.errored += 1
                case .success(let match?):
                    updates.append(SpotifyAutoMatchUpdate(spotifyId: song.spotifyId, videoId: match.videoId,
                                                          score: match.score, state: .matched))
                    result.matched += 1
                case .success(nil):
                    updates.append(SpotifyAutoMatchUpdate(spotifyId: song.spotifyId, videoId: nil, score: nil,
                                                          state: .unmatched))
                    result.failed += 1
                }
            }
            if !updates.isEmpty { try await store.updateAutomaticMatches(updates) }
            result.done += outcomes.count
            await onProgress?(result.done, result.totalPending)

            if !outcomes.isEmpty && outcomes.allSatisfy({ if case .failure = $0.1 { return true } else { return false } }) {
                result.retryLater = true
                return result
            }
            // A short breather so identical bursts don't chain into a detectable pattern.
            try await sleep(Self.betweenBatchesMs)
        }

        if result.errored > 0 && !stopped {
            result.retryLater = true
            return result
        }
        if !stopped, !result.moreWork, try await store.countTracks(in: .pending) > 0 { result.moreWork = true }
        return result
    }

    /// Searches a batch with at most `permits` lookups in flight; results in batch order.
    static func search(_ batch: [SpotifyTrackRecord], permits: Int,
                       matcher: @escaping Matcher) async throws -> [(SpotifyTrackRecord, Result<TrackMatch?, any Error>)] {
        var results = [Result<TrackMatch?, any Error>?](repeating: nil, count: batch.count)
        try await withThrowingTaskGroup(of: (Int, Result<TrackMatch?, any Error>).self) { group in
            var next = 0
            func addNext() {
                guard next < batch.count else { return }
                let index = next
                let song = batch[index]
                next += 1
                group.addTask {
                    do {
                        return (index, .success(try await matcher(song.matchable)))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<max(1, permits) { addNext() }
            while let (index, outcome) = try await group.next() {
                results[index] = outcome
                addNext()
            }
        }
        return zip(batch, results).map { ($0, $1!) }
    }
}
