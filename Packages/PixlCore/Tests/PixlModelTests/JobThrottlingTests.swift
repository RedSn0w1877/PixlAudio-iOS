import Testing
@testable import PixlModel

@Suite struct JobThrottlingTests {
    @Test func theFirstChangeRunsAtOnce() {
        let coalescer = UpdateCoalescer(minIntervalMs: 250)
        #expect(coalescer.delayMs(nowMs: 1_000) == 0)
    }

    @Test func aChangeInsideTheIntervalWaitsForTheRest() {
        var coalescer = UpdateCoalescer(minIntervalMs: 250)
        coalescer.ran(nowMs: 1_000)
        #expect(coalescer.delayMs(nowMs: 1_040) == 210)
        #expect(coalescer.delayMs(nowMs: 1_250) == 0)
        #expect(coalescer.delayMs(nowMs: 9_000) == 0)
    }

    @Test func aBurstOfProgressRunsAtMostFourTimesASecond() {
        var coalescer = UpdateCoalescer(minIntervalMs: 250)
        var runs = 0
        var now: Int64 = 0
        // A change every 5 ms for two seconds, each handled after its delay the way the aggregator does.
        var pendingUntil: Int64?
        while now < 2_000 {
            if let due = pendingUntil, now >= due {
                coalescer.ran(nowMs: now)
                runs += 1
                pendingUntil = nil
            }
            if pendingUntil == nil {
                let delay = coalescer.delayMs(nowMs: now)
                if delay == 0 {
                    coalescer.ran(nowMs: now)
                    runs += 1
                } else {
                    pendingUntil = now + delay
                }
            }
            now += 5
        }
        #expect(runs <= 9)
        #expect(runs >= 7)
    }

    @Test func aClockGoingBackwardsNeverStallsLongerThanOneInterval() {
        var coalescer = UpdateCoalescer(minIntervalMs: 250)
        coalescer.ran(nowMs: 10_000)
        #expect(coalescer.delayMs(nowMs: 4_000) == 250)
    }

    @Test func theLaneRunsOneAtATimeInTheOrderAsked() {
        var lane = HeavyLane(limit: 1)
        let first = lane.request(1)
        let second = lane.request(2)
        let third = lane.request(3)
        #expect(first)
        #expect(!second)
        #expect(!third)
        #expect(lane.isBusy)
        #expect(lane.waiting == [2, 3])
        let afterFirst = lane.release(1)
        #expect(afterFirst == 2)
        #expect(lane.running == [2])
        let afterSecond = lane.release(2)
        #expect(afterSecond == 3)
        let afterThird = lane.release(3)
        #expect(afterThird == nil)
        #expect(!lane.isBusy)
    }

    @Test func aWiderLaneStillNeverExceedsItsLimit() {
        var lane = HeavyLane(limit: 2)
        let first = lane.request(1)
        let second = lane.request(2)
        let third = lane.request(3)
        #expect(first)
        #expect(second)
        #expect(!third)
        #expect(lane.running.count == 2)
        let next = lane.release(2)
        #expect(next == 3)
        #expect(lane.running.count == 2)
    }

    @Test func aCancelledWaiterNeverRuns() {
        var lane = HeavyLane(limit: 1)
        let first = lane.request(1)
        let second = lane.request(2)
        let third = lane.request(3)
        #expect(first)
        #expect(!second)
        #expect(!third)
        let removed = lane.cancel(2)
        let removedAgain = lane.cancel(2)
        #expect(removed)
        #expect(!removedAgain, "already gone")
        let next = lane.release(1)
        #expect(next == 3)
    }

    @Test func releasingATicketThatIsNotRunningChangesNothing() {
        var lane = HeavyLane(limit: 1)
        let first = lane.request(1)
        let second = lane.request(2)
        #expect(first)
        #expect(!second)
        let next = lane.release(2)
        #expect(next == nil)
        #expect(lane.running == [1])
        #expect(lane.waiting == [2])
    }

    @Test func askingTwiceWithTheSameTicketDoesNotDoubleBook() {
        var lane = HeavyLane(limit: 1)
        let first = lane.request(1)
        let again = lane.request(1)
        #expect(first)
        #expect(again)
        #expect(lane.running == [1])
    }
}
