import XCTest
@testable import PixlAudio

/// The shared lane for heavy local jobs (docs/performance.md › Many jobs at once): one at a time in the order asked,
/// a cancelled waiter never runs and never blocks the others, and a lease gives its place back exactly once.
final class HeavyJobGovernorTests: XCTestCase {
    private actor Log {
        private(set) var events: [String] = []
        private var current = 0
        private(set) var peak = 0
        func enter(_ name: String) { current += 1; peak = max(peak, current); events.append("start \(name)") }
        func leave(_ name: String) { current -= 1; events.append("end \(name)") }
    }

    func testOnlyOneJobHoldsTheLaneAndTheRestRunInOrder() async throws {
        let governor = HeavyJobGovernor(limit: 1)
        let log = Log()
        let first = try await governor.acquire()
        XCTAssertTrue(governor.isBusy)
        var tasks: [Task<Void, any Error>] = []
        for name in ["b", "c", "d"] {
            tasks.append(Task {
                let lease = try await governor.acquire()
                await log.enter(name)
                await Task.yield()
                await log.leave(name)
                lease.release()
            })
            // Queued in this order: wait for each to be waiting before starting the next.
            while governor.waitingCount < tasks.count { await Task.yield() }
        }
        first.release()
        for task in tasks { try await task.value }
        let events = await log.events
        XCTAssertEqual(events, ["start b", "end b", "start c", "end c", "start d", "end d"])
        let peak = await log.peak
        XCTAssertEqual(peak, 1)
        XCTAssertFalse(governor.isBusy)
    }

    func testACancelledWaiterThrowsAndDoesNotBlockTheNext() async throws {
        let governor = HeavyJobGovernor(limit: 1)
        let holder = try await governor.acquire()
        let cancelled = Task { () -> Bool in
            do {
                _ = try await governor.acquire()
                return true
            } catch {
                return false
            }
        }
        while governor.waitingCount < 1 { await Task.yield() }
        let next = Task { try await governor.acquire() }
        while governor.waitingCount < 2 { await Task.yield() }
        cancelled.cancel()
        let ranWhileCancelled = await cancelled.value
        XCTAssertFalse(ranWhileCancelled)
        XCTAssertEqual(governor.waitingCount, 1)
        holder.release()
        let lease = try await next.value
        XCTAssertTrue(governor.isBusy)
        lease.release()
        XCTAssertFalse(governor.isBusy)
    }

    func testReleasingTwiceGivesThePlaceBackOnce() async throws {
        let governor = HeavyJobGovernor(limit: 1)
        let first = try await governor.acquire()
        let waiter = Task { try await governor.acquire() }
        while governor.waitingCount < 1 { await Task.yield() }
        first.release()
        first.release()
        let second = try await waiter.value
        XCTAssertTrue(governor.isBusy, "the second release must not free the waiter's place")
        second.release()
        XCTAssertFalse(governor.isBusy)
    }

    func testALeaseThatIsDroppedFreesTheLane() async throws {
        let governor = HeavyJobGovernor(limit: 1)
        do {
            let lease = try await governor.acquire()
            _ = lease
        }
        // `Lease.deinit` releases.
        XCTAssertFalse(governor.isBusy)
    }

    func testACancelledCallerNeverTakesAPlace() async {
        let governor = HeavyJobGovernor(limit: 1)
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await governor.acquire()
                return true
            } catch {
                return false
            }
        }
        let took = await task.value
        XCTAssertFalse(took)
        XCTAssertFalse(governor.isBusy)
    }
}
