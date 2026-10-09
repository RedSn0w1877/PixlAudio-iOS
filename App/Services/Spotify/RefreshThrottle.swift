import Foundation
import Synchronization

/// Lets an action through at most once per `interval` (the matcher reports progress after every 48-track batch; the
/// dashboard's counters refresh on that at most every couple of seconds, not 100 times for a big account).
nonisolated final class RefreshThrottle: Sendable {
    private let last = Mutex<ContinuousClock.Instant?>(nil)
    private let interval: Duration

    init(interval: Duration = .seconds(2)) { self.interval = interval }

    /// True when the action may run now (and starts the next interval).
    func allows(now: ContinuousClock.Instant = ContinuousClock.now) -> Bool {
        last.withLock { last in
            if let previous = last, now - previous < interval { return false }
            last = now
            return true
        }
    }
}
