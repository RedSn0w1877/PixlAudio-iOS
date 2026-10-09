import XCTest
@testable import PixlAudio

/// The decode and extraction scheduler (docs/performance.md): the newest request first, high before low, a cancelled
/// request never runs, and no more than `limit` at once.
final class LIFOGateTests: XCTestCase {
    private actor Order {
        private(set) var items: [String] = []
        func append(_ item: String) { items.append(item) }
    }

    private actor Peak {
        private var current = 0
        private(set) var maximum = 0
        func enter() { current += 1; maximum = max(maximum, current) }
        func leave() { current -= 1 }
    }

    func testTheNewestWaiterGoesFirstAndHighBeforeLow() async {
        let gate = LIFOGate(limit: 1)
        let holder = await gate.acquire()
        XCTAssertTrue(holder)
        let order = Order()
        var tasks: [Task<Void, Never>] = []
        for (name, high) in [("a", true), ("b", true), ("low", false), ("c", true)] {
            tasks.append(Task {
                if await gate.acquire(high: high) {
                    await order.append(name)
                    await gate.release()
                }
            })
            // Queued in this order: wait for each to be waiting before starting the next.
            while await gate.waitingCount < tasks.count { await Task.yield() }
        }
        await gate.release()
        for task in tasks { await task.value }
        let items = await order.items
        XCTAssertEqual(items, ["c", "b", "a", "low"])
    }

    func testACancelledWaiterNeverRunsAndFreesNoSlotItNeverHad() async {
        let gate = LIFOGate(limit: 1)
        let holder = await gate.acquire()
        XCTAssertTrue(holder)
        let waiter = Task { await gate.acquire() }
        while await gate.waitingCount < 1 { await Task.yield() }
        waiter.cancel()
        let got = await waiter.value
        XCTAssertFalse(got, "a cancelled request gets no slot")
        let waiting = await gate.waitingCount
        XCTAssertEqual(waiting, 0)
        await gate.release()
        let again = await gate.acquire()
        XCTAssertTrue(again, "the slot the holder gave back is free")
    }

    func testNeverMoreThanTheLimitAtOnce() async {
        let gate = LIFOGate(limit: 3)
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 {
                group.addTask {
                    guard await gate.acquire() else { return }
                    await peak.enter()
                    try? await Task.sleep(for: .milliseconds(5))
                    await peak.leave()
                    await gate.release()
                }
            }
        }
        let maximum = await peak.maximum
        XCTAssertLessThanOrEqual(maximum, 3)
        XCTAssertGreaterThan(maximum, 1, "the slots are used")
    }
}
