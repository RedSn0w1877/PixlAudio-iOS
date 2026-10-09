import Foundation

/// A counting semaphore for blocking work (image decodes, colour extractions) that serves the **newest** request first
/// and lets a waiting request be cancelled.
///
/// A fling through a grid or list starts a request per cell that appears, long before the first finishes. Run all of
/// them at once and they fill every thread of the cooperative pool (ImageIO and file reads block), and in first-in
/// first-out order the cells where the fling stops are served last. Here at most `limit` run; the rest wait, the most
/// recently asked first (that is the cell on screen), `high` requests before low ones (prefetches); and a request whose
/// view has gone is cancelled while it waits, so it never runs at all.
actor LIFOGate {
    private struct Waiter {
        let id: Int
        let high: Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var running = 0
    private var waiters: [Waiter] = []
    private var nextID = 0

    init(limit: Int) { self.limit = max(1, limit) }

    /// Requests waiting for a slot (tests wait for this to know a request has queued).
    var waitingCount: Int { waiters.count }

    /// Waits for a slot. Returns false when the caller was cancelled while waiting (it holds no slot then). A caller
    /// that got a slot must call `release()`.
    func acquire(high: Bool = true) async -> Bool {
        if Task.isCancelled { return false }
        if running < limit {
            running += 1
            return true
        }
        nextID += 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters.append(Waiter(id: id, high: high, continuation: continuation))
            }
        } onCancel: {
            // Registered before this runs: the continuation is appended synchronously on this actor, and this hop
            // only gets its turn once that has returned.
            Task { await self.cancel(id) }
        }
    }

    func release() {
        // The newest high-priority waiter, else the newest waiter; the slot passes straight to it.
        let index = waiters.lastIndex(where: \.high) ?? waiters.indices.last
        guard let index else {
            running = max(0, running - 1)
            return
        }
        waiters.remove(at: index).continuation.resume(returning: true)
    }

    private func cancel(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
