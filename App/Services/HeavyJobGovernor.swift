import Foundation
import PixlModel
import Synchronization

/// The shared lane for jobs that hold a lot of memory or every CPU core while they run: the model install's compile
/// (a ~900 MB package), lyric alignment (a Core ML model and the decoded song) and stem separation (a 44.1 kHz stereo
/// decode and its spectrogram). Run together on a phone they are what the system ends an app for, so they take turns:
/// at most `limit` hold a lease, the rest wait in the order they asked and say so ("Waiting" in Active jobs).
///
/// A lease is taken for the compute part of a job only, never while the job waits on something that needs a lease to
/// finish (the model download and install): that is how two jobs would deadlock each other.
///
/// Not an actor: `release` is synchronous so a `defer` can call it, and the state is a few integers under a `Mutex`.
nonisolated final class HeavyJobGovernor: Sendable {
    /// One at a time: the install's compile alone can use more memory than the jobs it would overlap with.
    static let shared = HeavyJobGovernor(limit: 1)

    /// Handed to the holder; `release()` (idempotent) gives the place to the next in line.
    nonisolated final class Lease: Sendable {
        private let ticket: Int
        private let owner: HeavyJobGovernor
        private let released = Mutex(false)

        fileprivate init(ticket: Int, owner: HeavyJobGovernor) {
            self.ticket = ticket
            self.owner = owner
        }

        func release() {
            let first = released.withLock { value -> Bool in
                if value { return false }
                value = true
                return true
            }
            if first { owner.release(ticket) }
        }

        deinit { release() }
    }

    private nonisolated struct State {
        var lane: HeavyLane
        var nextTicket = 0
        var continuations: [Int: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state: Mutex<State>

    init(limit: Int) {
        state = Mutex(State(lane: HeavyLane(limit: limit)))
    }

    /// A caller asking now would have to wait (so it can say so before it does).
    var isBusy: Bool { state.withLock { $0.lane.isBusy } }

    var waitingCount: Int { state.withLock { $0.lane.waiting.count } }

    /// Waits for a place. Throws `CancellationError` when the caller is cancelled while it waits (it holds nothing then).
    func acquire() async throws -> Lease {
        try Task.checkCancellation()
        let ticket = state.withLock { state -> Int in
            state.nextTicket += 1
            return state.nextTicket
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Decided under the lock so a cancel cannot slip between "not cancelled" and "queued".
                let outcome: Result<Bool, CancellationError> = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if state.lane.request(ticket) { return .success(true) }
                    state.continuations[ticket] = continuation
                    return .success(false)
                }
                switch outcome {
                case .failure(let error): continuation.resume(throwing: error)
                case .success(true): continuation.resume()
                case .success(false): break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard state.lane.cancel(ticket) else { return nil }
                return state.continuations.removeValue(forKey: ticket)
            }
            waiter?.resume(throwing: CancellationError())
        }
        return Lease(ticket: ticket, owner: self)
    }

    fileprivate func release(_ ticket: Int) {
        let next = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard let granted = state.lane.release(ticket) else { return nil }
            return state.continuations.removeValue(forKey: granted)
        }
        next?.resume()
    }
}
