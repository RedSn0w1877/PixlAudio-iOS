// Pure rules behind the "many jobs at once" fixes (docs/performance.md › Many jobs at once): how often a screen may
// recompute from a stream of progress changes, and which heavy job runs when only so many may at once. No clocks and
// no threads in here: the callers pass the time and do the waiting, so the rules are testable on any platform.

import Foundation

/// Spaces out the recomputations a stream of changes asks for. The first change after a quiet period is handled at
/// once; changes that arrive inside `minIntervalMs` of the last run wait for it to end (and are all served by that one
/// run, because the run re-reads the sources).
public struct UpdateCoalescer: Sendable, Equatable {
    public let minIntervalMs: Int64
    private var lastRunMs: Int64?

    public init(minIntervalMs: Int64 = 250) {
        self.minIntervalMs = max(0, minIntervalMs)
    }

    /// How long to wait before running now (0 = run at once).
    public func delayMs(nowMs: Int64) -> Int64 {
        guard let lastRunMs else { return 0 }
        let elapsed = nowMs - lastRunMs
        // A clock that went backwards must not stall the screen for longer than one interval.
        if elapsed < 0 { return minIntervalMs }
        return max(0, minIntervalMs - elapsed)
    }

    /// Records that the recomputation ran.
    public mutating func ran(nowMs: Int64) {
        lastRunMs = nowMs
    }
}

/// A counting FIFO lane: at most `limit` tickets run, the rest wait in the order they asked. Heavy local jobs (the
/// model install's compile, lyric alignment, stem separation) each hold a ticket while they hold big buffers or a model.
public struct HeavyLane: Sendable, Equatable {
    public let limit: Int
    public private(set) var running: [Int] = []
    public private(set) var waiting: [Int] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public var isBusy: Bool { running.count >= limit }

    /// True when the ticket may run now; otherwise it is queued.
    public mutating func request(_ ticket: Int) -> Bool {
        if running.contains(ticket) || waiting.contains(ticket) { return running.contains(ticket) }
        if running.count < limit {
            running.append(ticket)
            return true
        }
        waiting.append(ticket)
        return false
    }

    /// A running ticket is done: the oldest waiting one takes its place and is returned.
    @discardableResult
    public mutating func release(_ ticket: Int) -> Int? {
        guard let index = running.firstIndex(of: ticket) else { return nil }
        running.remove(at: index)
        guard running.count < limit, !waiting.isEmpty else { return nil }
        let next = waiting.removeFirst()
        running.append(next)
        return next
    }

    /// A waiting ticket gave up. Returns whether it was waiting (a running one is released instead).
    @discardableResult
    public mutating func cancel(_ ticket: Int) -> Bool {
        if let index = waiting.firstIndex(of: ticket) {
            waiting.remove(at: index)
            return true
        }
        return false
    }
}
