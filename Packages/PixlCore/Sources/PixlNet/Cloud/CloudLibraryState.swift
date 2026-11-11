// Spatial audio's library on the phone (cloud audio spec of 2026-11-10, sections 6.1, 6.2 and 6.4), as pure rules:
// where a rendition stands given its job and the phone's facts, when a failed one may be tried again, what the local
// store keeps when it is over its budget, and the money and the daily count of library jobs. The app's library
// (`SpatialCloudLibrary`) and Cloud Studio only gather the facts and do the I/O.

import Foundation
import PixlModel

// MARK: - Where a rendition stands

public enum CloudLibraryStatus {
    /// The cloud's side of spec 6.1's state for `key` (never `preview`):
    /// - `ready` while a verified render is in the local store, whatever the switches say;
    /// - from the latest library job that covers it: `queued` before the GPU (`waitingForNetwork` while that job may
    ///   not use the network there is, `capReached` while the month's cap holds it), `processing` at RunPod,
    ///   `downloading` once the render exists and is coming down, `failed` when the job failed or this render was not
    ///   made or not accepted;
    /// - else `failed` while a recent failure waits out its backoff, and `none`.
    ///
    /// `networkAllowed`: the network there is now is one this job may use (the cloud's own rule for the song that plays,
    /// a ready phone on Wi-Fi for the background queue).
    public static func status(for key: RenditionKey, isLocal: Bool, job: CloudJobRecord?, networkAllowed: Bool,
                              retry: CloudLibraryRetryBook.Entry?, nowMs: Int64) -> RenditionStatus {
        if isLocal { return .ready }
        if let job, job.state != .cancelled, let info = job.library, info.covers(key) {
            switch job.state {
            case .queued, .preparing, .uploading:
                if info.heldByCap == true { return .capReached }
                return networkAllowed ? .queued : .waitingForNetwork
            case .uploaded:
                return info.heldByCap == true ? .capReached : .queued
            case .submitted, .running:
                return .processing
            case .resultsReady, .downloading:
                if info.didFail(key.profile) { return .failed }
                if info.isImported(key.profile) { return .none }
                return networkAllowed ? .downloading : .waitingForNetwork
            case .imported:
                // Imported and no longer on the phone (removed, evicted): nothing is under way for it.
                return info.didFail(key.profile) ? .failed : .none
            case .failed, .expired:
                return .failed
            case .cancelled:
                break
            }
        }
        if let retry, !retry.isDue(nowMs: nowMs) { return .failed }
        return .none
    }

    /// The latest library job about `key` that was not cancelled (the list is oldest first).
    public static func latestJob(for key: RenditionKey, in jobs: [CloudJobRecord]) -> CloudJobRecord? {
        jobs.last { $0.library?.covers(key) == true && $0.state != .cancelled }
    }

    /// The library job on its way for `key`, if any.
    public static func pendingJob(for key: RenditionKey, in jobs: [CloudJobRecord]) -> CloudJobRecord? {
        jobs.last { $0.library?.covers(key) == true && $0.state.isPending }
    }
}

// MARK: - Trying again after a failure

/// When a failed rendition is tried again (spec 6.1: 10 minutes, 1 hour, 1 day; `RenditionRetry`). Kept per rendition,
/// each failed job counted once, so a relaunch neither forgets a failure nor counts it twice.
public struct CloudLibraryRetryBook: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable {
        public var failures: Int
        public var lastFailureAtMs: Int64

        public init(failures: Int, lastFailureAtMs: Int64) {
            self.failures = failures
            self.lastFailureAtMs = lastFailureAtMs
        }

        public func isDue(nowMs: Int64) -> Bool {
            RenditionRetry.isDue(failures: failures, lastFailureAtMs: lastFailureAtMs, nowMs: nowMs)
        }

        /// When it may be tried again.
        public var dueAtMs: Int64 { lastFailureAtMs + RenditionRetry.delayMs(afterFailures: failures) }
    }

    /// How many counted job keys are remembered (the newest).
    public static let countedLimit = 200
    /// A failure older than this (and due) is forgotten: the next attempt starts the ladder over.
    public static let forgetAfterMs: Int64 = 7 * 86_400_000

    /// `<videoId>/sp-<profile>` → its failures.
    public var entries: [String: Entry]
    /// Job keys whose failure was counted (newest last).
    public var counted: [String]

    public init(entries: [String: Entry] = [:], counted: [String] = []) {
        self.entries = entries
        self.counted = counted
    }

    public func entry(for key: RenditionKey) -> Entry? { entries[key.description] }

    /// Not waiting out a failure's backoff.
    public func mayTry(_ key: RenditionKey, nowMs: Int64) -> Bool { entry(for: key)?.isDue(nowMs: nowMs) ?? true }

    /// One more failure of `key` at `nowMs`. A job's failure counts once (`jobKey`): false, and nothing changes, when it
    /// was counted before.
    @discardableResult
    public mutating func recordFailure(_ key: RenditionKey, jobKey: String?, nowMs: Int64) -> Bool {
        if let jobKey {
            let mark = "\(jobKey)|\(key.profile.rawValue)"
            guard !counted.contains(mark) else { return false }
            counted.append(mark)
            if counted.count > Self.countedLimit { counted.removeFirst(counted.count - Self.countedLimit) }
        }
        var entry = entries[key.description] ?? Entry(failures: 0, lastFailureAtMs: nowMs)
        entry.failures += 1
        entry.lastFailureAtMs = nowMs
        entries[key.description] = entry
        return true
    }

    /// The render arrived: its failures are forgotten.
    public mutating func clear(_ key: RenditionKey) {
        entries[key.description] = nil
    }

    /// Old failures that are due go (the book stays small).
    public mutating func prune(nowMs: Int64) {
        entries = entries.filter { _, entry in !(entry.isDue(nowMs: nowMs) && nowMs - entry.lastFailureAtMs > Self.forgetAfterMs) }
    }
}

// MARK: - The local store

/// One verified render in the local store, as its index sees it.
public struct CloudAudioStoreEntry: Sendable, Hashable {
    public var key: RenditionKey
    public var bytes: Int64
    /// When it last started playing (when it was stored, until then).
    public var lastPlayedMs: Int64

    public init(key: RenditionKey, bytes: Int64, lastPlayedMs: Int64) {
        self.key = key
        self.bytes = bytes
        self.lastPlayedMs = lastPlayedMs
    }
}

/// The local store's rules (spec 6.2 "Local store", 6.1 `cloudAudio.storageMB`): a file plus a valid manifest beside it
/// is the index, and the least recently played renders go first when the store is over its budget.
public enum CloudAudioStorePolicy {
    /// A stored pair is part of the index: the manifest passes the acceptance rule (spec 3.1: `schema`, `v`, `libV`,
    /// `videoId`, `kind` and `profile` are those its path names; FLAC at the canonical key with usable facts) and the
    /// file's size is the manifest's. Its SHA-256 was checked when it was stored, before the manifest was written.
    public static func accepts(_ manifest: CloudLibraryManifest, key: RenditionKey, fileBytes: Int64?) -> Bool {
        guard case .success(let audio) = manifest.check(for: key), let fileBytes else { return false }
        return audio.bytes == fileBytes
    }

    /// The renders to delete so that the rest fit in `budgetBytes`: least recently played first, never one of
    /// `keeping` (the one just stored, the one that plays). Ties go oldest key first, so the answer is stable.
    public static func evictions(_ entries: [CloudAudioStoreEntry], budgetBytes: Int64,
                                 keeping: Set<RenditionKey> = []) -> [RenditionKey] {
        var total = entries.reduce(Int64(0)) { $0 + max($1.bytes, 0) }
        guard total > budgetBytes else { return [] }
        let order = entries.sorted { lhs, rhs in
            lhs.lastPlayedMs != rhs.lastPlayedMs ? lhs.lastPlayedMs < rhs.lastPlayedMs : lhs.key.description < rhs.key.description
        }
        var out: [RenditionKey] = []
        for entry in order where !keeping.contains(entry.key) {
            guard total > budgetBytes else { break }
            out.append(entry.key)
            total -= max(entry.bytes, 0)
        }
        return out
    }

    /// "Songs ready: N · X GB on this phone": songs with at least one render, and every render's size.
    public static func usage(_ entries: [CloudAudioStoreEntry]) -> (songs: Int, bytes: Int64) {
        (Set(entries.map(\.key.videoId)).count, entries.reduce(Int64(0)) { $0 + max($1.bytes, 0) })
    }
}

// MARK: - Money and the daily count

/// Library jobs' own money (spec 6.1 "Money"): a monthly sum kept in its own ledger (`CloudAutoLedger`'s shape: the
/// estimate is reserved when RunPod takes a job and replaced by the real cost when its result lands), under
/// `cloudAudio.monthlyCapUSD` (nil: no limit). Sing's cap and its $3 rule with built-in keys never apply here, and
/// library jobs never count against Sing's. The day's count is the background queue's (`cloudAudio.dailyAhead`).
public enum CloudLibraryBudget {
    /// The month's cap leaves room for a job of `estimateMicroUSD` next to what is already spent or reserved.
    public static func capAllows(estimateMicroUSD: Int64, spentMicroUSD: Int64, capMicroUSD: Int64?) -> Bool {
        guard let cap = capMicroUSD else { return true }
        return max(spentMicroUSD, 0) + max(estimateMicroUSD, 0) <= max(cap, 0)
    }

    /// A library job may go to RunPod now: the cap has room (the ledger plus `pendingMicroUSD`, jobs accepted in this
    /// pass and not in the ledger yet) and, for the background queue, today's count is under `dailyAhead`.
    public static func allows(estimateMicroUSD: Int64, ledger: CloudAutoLedger, pendingMicroUSD: Int64 = 0,
                              pendingAhead: Int = 0, capMicroUSD: Int64?, ahead: Bool, dailyAhead: Int) -> Bool {
        if ahead, ledger.dayCount + pendingAhead >= max(dailyAhead, 0) { return false }
        return capAllows(estimateMicroUSD: estimateMicroUSD, spentMicroUSD: ledger.spentMicroUSD + max(pendingMicroUSD, 0),
                         capMicroUSD: capMicroUSD)
    }

    /// The estimate of one library job for a song (`CloudCost.estimatedSeconds` of its plan at `pricePerSecond`).
    public static func estimateMicroUSD(durationMs: Int64, profiles: Int, quality: CloudSeparationQuality = .standard,
                                        pricePerSecondMicroUSD: Int64) -> Int64 {
        let plan = CloudSongPlan(songId: "", tasks: [.spatial], lyricsMode: nil, isStreamed: true,
                                 durationMs: durationMs > 0 ? durationMs : CloudCost.referenceSongMs, renders: profiles)
        return CloudCost.estimatedSeconds(plan, quality: quality) * max(pricePerSecondMicroUSD, 0)
    }
}

// MARK: - The background queue (spec 6.4)

public enum CloudLibraryAhead {
    /// At most this many of its jobs on their way at once (lookups included: most end in a cheap download).
    public static let maxOutstanding = 3
    /// The best songs of the ranking it looks at in one go.
    public static let candidateLimit = 24
    /// Two looks are at least this far apart (unless a setting just changed).
    public static let minGapMs: Int64 = 5 * 60_000

    /// How many songs it may hand to the cloud now: room among the outstanding jobs, in today's count (a lookup that
    /// ends in a download does not count; a job sent to RunPod does), and in the month's cap for one more job.
    public static func room(outstanding: Int, ledger: CloudAutoLedger, dailyAhead: Int, capMicroUSD: Int64?,
                            estimateMicroUSD: Int64) -> Int {
        let slots = maxOutstanding - max(outstanding, 0)
        let today = max(dailyAhead, 0) - ledger.dayCount
        guard slots > 0, today > 0 else { return 0 }
        guard CloudLibraryBudget.capAllows(estimateMicroUSD: estimateMicroUSD, spentMicroUSD: ledger.spentMicroUSD,
                                           capMicroUSD: capMicroUSD) else { return 0 }
        return min(slots, today)
    }
}
