import Foundation
import Testing
@testable import PixlNet

@Suite struct CloudBackgroundPlannerTests {
    private let now: Int64 = 1_000_000_000
    private let minute: Int64 = 60_000

    private func record(_ n: Int, _ state: CloudJobState, retryAt: Int64? = nil) -> CloudJobRecord {
        var r = CloudJobRecord(jobKey: "job\(n)", songId: "s\(n)", title: "Song \(n)", artist: "A", batchId: "b",
                               tasks: [.instrumental], lyricsMode: nil, quality: .standard, createdAtMs: 0)
        r.state = state
        r.nextAttemptAtMs = retryAt
        return r
    }

    @Test func nothingIsRequestedWhenNothingIsOutstanding() {
        #expect(CloudBackgroundPlanner.plan(jobs: [], nowMs: now, isEnabled: true).isEmpty)
        let finished = [record(1, .imported), record(2, .failed), record(3, .cancelled), record(4, .expired)]
        #expect(CloudBackgroundPlanner.plan(jobs: finished, nowMs: now, isEnabled: true).isEmpty)
    }

    @Test func nothingIsRequestedWhileTheFeatureIsOff() {
        #expect(CloudBackgroundPlanner.plan(jobs: [record(1, .running)], nowMs: now, isEnabled: false).isEmpty)
    }

    @Test func aJobAtRunPodAsksForBothFifteenMinutesOut() {
        let plan = CloudBackgroundPlanner.plan(jobs: [record(1, .running)], nowMs: now, isEnabled: true)
        #expect(plan.refreshNotBeforeMs == now + 15 * minute)
        #expect(plan.processingNotBeforeMs == now + 15 * minute)
    }

    @Test func aJobStillToBePreparedWantsOnlyTheLongPass() {
        let plan = CloudBackgroundPlanner.plan(jobs: [record(1, .queued), record(2, .preparing)], nowMs: now, isEnabled: true)
        #expect(plan.refreshNotBeforeMs == nil)
        #expect(plan.processingNotBeforeMs == now + 15 * minute)
    }

    @Test func aLongBackoffPostponesTheLongPassButNotTheShortWake() {
        let retry = now + 60 * minute
        let jobs = [record(1, .queued, retryAt: retry), record(2, .uploading, retryAt: retry + minute)]
        let plan = CloudBackgroundPlanner.plan(jobs: jobs, nowMs: now, isEnabled: true)
        #expect(plan.processingNotBeforeMs == retry)
        // An upload waiting out a retry still counts as a step that needs the phone.
        #expect(plan.refreshNotBeforeMs == now + 15 * minute)
    }

    @Test func aBackoffThatIsOverDoesNotPushTheRequestIntoThePast() {
        let plan = CloudBackgroundPlanner.plan(jobs: [record(1, .queued, retryAt: now - minute)], nowMs: now, isEnabled: true)
        #expect(plan.processingNotBeforeMs == now + 15 * minute)
    }

    @Test func onePromptJobKeepsTheLongPassSooner() {
        let jobs = [record(1, .queued, retryAt: now + 120 * minute), record(2, .downloading)]
        let plan = CloudBackgroundPlanner.plan(jobs: jobs, nowMs: now, isEnabled: true)
        #expect(plan.processingNotBeforeMs == now + 15 * minute)
    }

    // MARK: Window

    @Test func theRefreshWindowStartsNothingInItsLastSeconds() {
        let window = BackgroundWorkWindow.appRefresh(startedAtMs: now)
        #expect(window.canStartTransfer(nowMs: now))
        #expect(window.canStartTransfer(nowMs: now + 16_999))
        #expect(!window.canStartTransfer(nowMs: now + 17_000))
        #expect(!window.canStartTransfer(nowMs: now + 24_000))
        #expect(!window.isOver(nowMs: now + 24_000))
        #expect(window.isOver(nowMs: now + 25_000))
        #expect(window.remainingMs(nowMs: now + 99_000) == 0)
    }

    @Test func theProcessingWindowIsLongerWithABiggerMargin() {
        let window = BackgroundWorkWindow.processing(startedAtMs: now)
        #expect(window.canStartTransfer(nowMs: now + 104_999))
        #expect(!window.canStartTransfer(nowMs: now + 105_000))
        #expect(window.budgetMs > BackgroundWorkWindow.appRefresh(startedAtMs: now).budgetMs)
    }

    @Test func aNegativeBudgetOrMarginIsTreatedAsZero() {
        let window = BackgroundWorkWindow(startedAtMs: now, budgetMs: -5, safetyMarginMs: -1)
        #expect(window.budgetMs == 0 && window.safetyMarginMs == 0)
        #expect(window.isOver(nowMs: now))
    }

    @Test func theLongPassKeepsWaitingOnlyWhileJobsAreAtRunPodAndTimeIsLeft() {
        let window = BackgroundWorkWindow.processing(startedAtMs: now)
        let atRunPod = [record(1, .submitted)]
        #expect(CloudBackgroundPlanner.shouldKeepWaiting(jobs: atRunPod, window: window, nowMs: now + 30_000))
        #expect(CloudBackgroundPlanner.shouldKeepWaiting(jobs: [record(1, .resultsReady)], window: window, nowMs: now))
        #expect(CloudBackgroundPlanner.shouldKeepWaiting(jobs: [record(1, .downloading)], window: window, nowMs: now))
        #expect(!CloudBackgroundPlanner.shouldKeepWaiting(jobs: atRunPod, window: window, nowMs: now + 110_000),
                "inside the safety margin nothing new starts")
        #expect(!CloudBackgroundPlanner.shouldKeepWaiting(jobs: [record(1, .uploading)], window: window, nowMs: now),
                "an upload is iOS' own transfer; waiting for it here helps nothing")
        #expect(!CloudBackgroundPlanner.shouldKeepWaiting(jobs: [], window: window, nowMs: now))
    }

    // MARK: Completion

    @Test func aBackgroundTaskIsCompletedExactlyOnce() {
        var gate = BackgroundCompletionGate()
        #expect(!gate.isCompleted)
        let expiry = gate.claim(finishedInTime: false)
        let afterwards = gate.claim(finishedInTime: true)
        #expect(expiry, "the expiry handler gets there first")
        #expect(!afterwards, "the work finishing afterwards must not complete it again")
        #expect(gate.finishedInTime == false)
        #expect(gate.isCompleted)
    }
}
