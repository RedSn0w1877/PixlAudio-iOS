// What Cloud Studio asks iOS for while PixlAudio isn't on screen, and how it behaves inside the time iOS gives it.
// Pure decisions, so they are tested without a device: the BackgroundTasks calls in the app are thin and only do what
// these types say (design §7.4; docs/handoff/2026-10-08-active-jobs-background.md).
//
// iOS gives no guarantees: BGAppRefresh is opportunistic and short (about 30 s), a BGProcessingTask runs when the system
// finds the phone idle (usually minutes, often overnight, never after a force-quit). The plan below only ever asks for
// them while there is something for them to do, and takes the request back when there is not.

import Foundation

/// What to have requested from iOS right now.
public struct CloudBackgroundPlan: Sendable, Equatable {
    /// When to ask the next BGAppRefresh for (Unix ms), or nil to have none requested.
    public var refreshNotBeforeMs: Int64?
    /// The same for the BGProcessingTask.
    public var processingNotBeforeMs: Int64?

    public init(refreshNotBeforeMs: Int64? = nil, processingNotBeforeMs: Int64? = nil) {
        self.refreshNotBeforeMs = refreshNotBeforeMs
        self.processingNotBeforeMs = processingNotBeforeMs
    }

    public static let none = CloudBackgroundPlan()
    public var isEmpty: Bool { refreshNotBeforeMs == nil && processingNotBeforeMs == nil }
}

public enum CloudBackgroundPlanner {
    /// Neither request is asked for sooner than this after the previous pass (iOS spaces them out anyway).
    public static let minimumDelayMs: Int64 = CloudTiming.refreshEarliestMs
    /// Between two checks of RunPod inside one long background pass.
    public static let processingPollMs: Int64 = 30_000

    /// A step of the job needs the phone to run (not just iOS' transfer daemon).
    static func needsPhone(_ state: CloudJobState) -> Bool {
        switch state {
        case .uploading, .uploaded, .submitted, .running, .resultsReady, .downloading: true
        case .queued, .preparing, .imported, .failed, .cancelled, .expired: false
        }
    }

    /// The requests to have in place for `jobs`. Nothing while the feature is off (no pass runs then, so a wake would
    /// do nothing) or when no job is outstanding.
    public static func plan(jobs: [CloudJobRecord], nowMs: Int64, isEnabled: Bool) -> CloudBackgroundPlan {
        guard isEnabled else { return .none }
        let pending = jobs.filter { $0.state.isPending }
        guard !pending.isEmpty else { return .none }
        var plan = CloudBackgroundPlan()
        let soonest = nowMs + minimumDelayMs
        // The short wake: only worth having when a step happens without the person (a transfer, RunPod, results).
        if pending.contains(where: { needsPhone($0.state) }) { plan.refreshNotBeforeMs = soonest }
        // The long pass: for anything outstanding, but never before the soonest retry that is only waiting out a backoff.
        let retryWaits = pending.compactMap { $0.nextAttemptAtMs }
        let everyJobWaits = retryWaits.count == pending.count
        if everyJobWaits, let nextRetry = retryWaits.min() {
            plan.processingNotBeforeMs = max(soonest, nextRetry)
        } else {
            plan.processingNotBeforeMs = soonest
        }
        return plan
    }

    /// Inside one long background pass: keep polling RunPod while a job is there (or its results are being brought
    /// in) and the window still has room for new work.
    public static func shouldKeepWaiting(jobs: [CloudJobRecord], window: BackgroundWorkWindow, nowMs: Int64) -> Bool {
        guard window.canStartTransfer(nowMs: nowMs) else { return false }
        return jobs.contains { $0.state.isAtRunPod || $0.state == .resultsReady || $0.state == .downloading }
    }
}

/// The time one background wake has: how long the pass may go on, and the last stretch in which nothing new starts
/// (a transfer or a RunPod submission begun in the final seconds is cut off half-way and wasted).
public struct BackgroundWorkWindow: Sendable, Equatable {
    public let startedAtMs: Int64
    public let budgetMs: Int64
    public let safetyMarginMs: Int64

    public init(startedAtMs: Int64, budgetMs: Int64, safetyMarginMs: Int64) {
        self.startedAtMs = startedAtMs
        self.budgetMs = max(budgetMs, 0)
        self.safetyMarginMs = max(safetyMarginMs, 0)
    }

    /// BGAppRefresh: about 30 s from iOS; the pass plans for 25 and starts nothing in the last 8.
    public static func appRefresh(startedAtMs: Int64) -> BackgroundWorkWindow {
        BackgroundWorkWindow(startedAtMs: startedAtMs, budgetMs: 25_000, safetyMarginMs: 8_000)
    }

    /// BGProcessingTask: iOS sets no number; the pass limits itself to two minutes and starts nothing in the last 15 s.
    public static func processing(startedAtMs: Int64) -> BackgroundWorkWindow {
        BackgroundWorkWindow(startedAtMs: startedAtMs, budgetMs: 120_000, safetyMarginMs: 15_000)
    }

    public func remainingMs(nowMs: Int64) -> Int64 { max(startedAtMs + budgetMs - nowMs, 0) }

    /// A new transfer, upload, download or RunPod submission may begin.
    public func canStartTransfer(nowMs: Int64) -> Bool { remainingMs(nowMs: nowMs) > safetyMarginMs }

    public func isOver(nowMs: Int64) -> Bool { remainingMs(nowMs: nowMs) == 0 }
}

/// A background task's completion may be reported to iOS exactly once, whichever of "the work finished" and "iOS said
/// time is up" comes first (a second `setTaskCompleted` is a programming error that iOS punishes).
public struct BackgroundCompletionGate: Sendable, Equatable {
    public private(set) var isCompleted = false
    /// Whether the work really finished or the time ran out first: tells iOS (`success`) and decides if the next
    /// request is asked for at once.
    public private(set) var finishedInTime: Bool?

    public init() {}

    /// True for the first call only: that caller reports the completion.
    public mutating func claim(finishedInTime: Bool) -> Bool {
        guard !isCompleted else { return false }
        isCompleted = true
        self.finishedInTime = finishedInTime
        return true
    }
}
