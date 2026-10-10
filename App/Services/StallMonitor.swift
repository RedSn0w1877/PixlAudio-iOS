import Foundation
import PixlModel

/// Fails a transfer that stopped moving. A background `URLSession` download waits for connectivity without a deadline
/// (up to seven days), so with the phone offline, or a source that never answers, it never reports an error by itself
/// and its job would sit at "downloading" for ever. The owner of the transfers arms an id when one starts, tells the
/// monitor how much has arrived (`note`), and gets `onStall(id)` once when `limitTicks` intervals in a row saw no
/// progress; it then cancels the transfer and fails the job with a reason (docs/handoff/2026-10-09-many-jobs-fix.md).
///
/// One timer for all ids, alive only while something is armed (no timers ticking while idle). The rule itself is
/// PixlModel's `StallWatchdog`. A suspended app does not tick, so a download that carries on in the system's background
/// session is not failed for the time the app was away.
@MainActor
final class StallMonitor<ID: Hashable & Sendable> {
    private var dogs: [ID: StallWatchdog] = [:]
    private var marks: [ID: Int64] = [:]
    private var loop: Task<Void, Never>?
    private let interval: Duration
    private let limitTicks: Int

    /// Called once for each id that stalled; the id has been disarmed already.
    var onStall: (ID) -> Void = { _ in }

    /// 15 s ticks and 6 of them: a transfer must show no new byte for about 1½ to 2 minutes to be failed.
    init(interval: Duration = .seconds(15), limitTicks: Int = 6) {
        self.interval = interval
        self.limitTicks = limitTicks
    }

    var armedCount: Int { dogs.count }

    func isArmed(_ id: ID) -> Bool { dogs[id] != nil }

    /// A transfer started (or was found running after a launch).
    func arm(_ id: ID) {
        dogs[id] = StallWatchdog(limitTicks: limitTicks)
        marks[id] = 0
        startLoopIfNeeded()
    }

    /// How much has arrived so far; anything that changes while data moves will do.
    func note(_ id: ID, mark: Int64) {
        guard dogs[id] != nil, marks[id] != mark else { return }
        marks[id] = mark
    }

    /// The transfer ended one way or another.
    func disarm(_ id: ID) {
        dogs[id] = nil
        marks[id] = nil
        if dogs.isEmpty { stopLoop() }
    }

    func disarmAll() {
        dogs.removeAll()
        marks.removeAll()
        stopLoop()
    }

    /// One interval: every armed id that made no progress for `limitTicks` intervals is reported. The timer calls this;
    /// tests call it directly.
    func check() {
        var stalled: [ID] = []
        for id in Array(dogs.keys) {
            guard var dog = dogs[id] else { continue }
            if dog.tick(mark: marks[id] ?? 0) {
                stalled.append(id)
            } else {
                dogs[id] = dog
            }
        }
        for id in stalled {
            disarm(id)
            onStall(id)
        }
    }

    private func startLoopIfNeeded() {
        guard loop == nil else { return }
        let interval = self.interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.check()
            }
        }
    }

    private func stopLoop() {
        loop?.cancel()
        loop = nil
    }
}
