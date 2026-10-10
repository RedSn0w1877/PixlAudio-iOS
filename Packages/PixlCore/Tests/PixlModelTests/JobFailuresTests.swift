import Foundation
import Testing
@testable import PixlModel

/// A failed job ends, says why in one short line and lets go (docs/handoff/2026-10-09-many-jobs-fix.md).
@Suite struct JobFailuresTests {
    // MARK: Words

    @Test func aReasonIsOneTidyLine() {
        #expect(JobFailureText.short("  The model\nserver   answered\tHTTP 404.  ") == "The model server answered HTTP 404.")
        #expect(JobFailureText.short("") == JobFailureText.generic)
        #expect(JobFailureText.short(" \n \t ") == JobFailureText.generic)
    }

    @Test func aLongReasonIsCutWithAnEllipsis() {
        let long = String(repeating: "word ", count: 80)
        let short = JobFailureText.short(long, limit: 40)
        #expect(short.count <= 40)
        #expect(short.hasSuffix("…"))
        #expect(!short.contains("\n"))
        #expect(JobFailureText.short("short", limit: 40) == "short")
    }

    @Test func noSourceAndOfflineAreSaidPlainly() {
        #expect(JobFailureText.httpStatus(404).contains("nothing to download"))
        #expect(JobFailureText.httpStatus(410).contains("HTTP 410"))
        #expect(JobFailureText.httpStatus(403).contains("refused"))
        #expect(JobFailureText.httpStatus(429).contains("busy"))
        #expect(JobFailureText.httpStatus(503).contains("Try again later"))
        #expect(JobFailureText.httpStatus(418) == "The source answered HTTP 418.")
        #expect(JobFailureText.urlError(code: -1009) == "No internet connection.")
        #expect(JobFailureText.urlError(code: -1001) == "The connection timed out.")
        #expect(JobFailureText.urlError(code: -1004) == "Couldn't reach the server.")
        #expect(JobFailureText.urlError(code: -999) == nil, "a cancel is not a failure")
        #expect(JobFailureText.urlError(code: 42) == nil)
    }

    @Test func describePrefersTheNetworkWordsThenTheMessage() {
        #expect(JobFailureText.describe("The operation couldn't be completed.", urlErrorCode: -1009) == "No internet connection.")
        #expect(JobFailureText.describe("Disk is full", urlErrorCode: nil) == "Disk is full")
        #expect(JobFailureText.describe(nil) == JobFailureText.generic)
        #expect(JobFailureText.describe("odd", urlErrorCode: -7) == "odd")
    }

    // MARK: Bounded retry

    @Test func aRetryBudgetWalksTheLadderThenGivesUp() {
        var budget = RetryBudget(maxAttempts: 4, delaysMs: [1_000, 2_000, 4_000])
        let first = budget.failed(), second = budget.failed(), third = budget.failed()
        #expect([first, second, third] == [1_000, 2_000, 4_000])
        #expect(!budget.isExhausted)
        let fourth = budget.failed()
        #expect(fourth == nil, "the fourth failure in a row fails the job")
        #expect(budget.isExhausted)
        let fifth = budget.failed()
        #expect(fifth == nil, "and it stays failed")
    }

    @Test func theLastDelayRepeatsWhenTheLadderIsShorterThanTheBudget() {
        var budget = RetryBudget(maxAttempts: 5, delaysMs: [100, 200])
        let waits = [budget.failed(), budget.failed(), budget.failed(), budget.failed()]
        #expect(waits == [100, 200, 200, 200])
        let last = budget.failed()
        #expect(last == nil)
    }

    @Test func progressStartsTheLadderOver() {
        var budget = RetryBudget(maxAttempts: 3, delaysMs: [10, 20])
        _ = budget.failed()
        _ = budget.failed()
        budget.reset()
        #expect(budget.attempts == 0)
        let again = budget.failed()
        #expect(again == 10)
    }

    @Test func theDefaultBudgetEndsAfterAboutHalfAnHour() {
        var budget = RetryBudget()
        var waited: Int64 = 0
        var tries = 0
        while let delay = budget.failed() {
            waited += delay
            tries += 1
            if tries > 50 { break }
        }
        #expect(tries == 4)
        #expect(waited == 900_000, "1 + 2 + 4 + 8 minutes, then it gives up")
    }

    @Test func aDegenerateBudgetStillEnds() {
        var budget = RetryBudget(maxAttempts: 0, delaysMs: [])
        let first = budget.failed()
        #expect(first == nil)
    }

    // MARK: Stalled transfers

    @Test func aTransferThatKeepsMovingNeverStalls() {
        var dog = StallWatchdog(limitTicks: 3)
        var anyStall = false
        for bytes in stride(from: Int64(0), to: 10_000, by: 1_000) where dog.tick(mark: bytes) { anyStall = true }
        #expect(!anyStall)
        #expect(dog.stalledTicks == 0)
    }

    @Test func aTransferThatStopsStallsAfterTheLimit() {
        var dog = StallWatchdog(limitTicks: 3)
        let ticks = [dog.tick(mark: 500), dog.tick(mark: 500), dog.tick(mark: 500), dog.tick(mark: 500)]
        #expect(ticks == [false, false, false, true], "three ticks without a new byte")
    }

    @Test func aTransferThatNeverStartsStallsToo() {
        // Offline: no byte is ever written, the mark stays 0.
        var dog = StallWatchdog(limitTicks: 6)
        var ticks = 0
        while !dog.tick(mark: 0) { ticks += 1 }
        #expect(ticks == 6)
    }

    @Test func aTrickleResetsTheCount() {
        var dog = StallWatchdog(limitTicks: 3)
        _ = dog.tick(mark: 1)
        _ = dog.tick(mark: 1)
        _ = dog.tick(mark: 1)
        let moved = dog.tick(mark: 2)
        #expect(!moved, "one new byte is progress")
        #expect(dog.stalledTicks == 0)
        dog.reset()
        let afterReset = dog.tick(mark: 2)
        #expect(!afterReset)
    }
}
