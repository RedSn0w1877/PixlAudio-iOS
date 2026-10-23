import Foundation
import Testing
@testable import PixlNet

/// The priority lane's pure rules: who is a priority job, who may step aside, what order a burst goes in, and what holds
/// a job back. (The orchestrator's use of them is tested in AppTests/CloudStudioTests.)
@Suite struct CloudPriorityLaneTests {
    private let now: Int64 = 1_790_000_000_000
    private let minute: Int64 = 60_000

    /// A record. By default every job is a batch of its own, so a manual one is "one song sent by hand".
    private func record(_ n: Int, _ state: CloudJobState = .queued, batch: String? = nil, origin: CloudJobOrigin? = nil,
                        submittedAtMs: Int64? = nil) -> CloudJobRecord {
        var r = CloudJobRecord(jobKey: "job\(n)", songId: "s\(n)", title: "Song \(n)", artist: "A", batchId: batch ?? "b\(n)",
                               tasks: [.instrumental], lyricsMode: nil, quality: .standard, createdAtMs: now - 100 * minute + Int64(n))
        r.state = state
        r.origin = origin
        r.submittedAtMs = submittedAtMs
        if state == .submitted || state == .running { r.runpodJobId = "rp-\(n)" }
        if state == .uploaded { r.uploadedAtMs = now - 1_000 }
        return r
    }

    private func paused(_ n: Int, by priority: String, origin: CloudJobOrigin? = .auto, at pausedAt: Int64? = nil) -> CloudJobRecord {
        var r = record(n, .uploaded, batch: "bulk", origin: origin, submittedAtMs: now - 10 * minute)
        r.pausedBy = priority
        r.pausedAtMs = pausedAt ?? now - 1_000
        return r
    }

    // MARK: The state machine

    @Test func onlyAWaitingJobCanPause() {
        #expect(CloudJobMachine.next(.submitted, on: .pause) == .uploaded)
        for state in CloudJobState.allCases where state != .submitted {
            #expect(CloudJobMachine.next(state, on: .pause) == nil, "\(state) must not pause")
        }
        #expect(CloudJobMachine.next(.running, on: .pause) == nil, "a running job is never paused")
    }

    // MARK: The record

    @Test func aPauseKeepsTheUploadAndTheFirstSendTime() {
        var r = record(1, .submitted, batch: "bulk", origin: .auto, submittedAtMs: 500)
        r.beginPause(runpodJobId: "rp-1", by: "P", nowMs: 1_000)
        #expect(r.hasPauseIntent && r.state == .submitted && !r.isPaused)
        let didPause = r.completePause(by: "P", neverStarted: nil, nowMs: 1_100)
        #expect(didPause)
        #expect(r.state == .uploaded && r.isPaused && r.wasPaused)
        #expect(r.runpodJobId == nil)
        #expect(r.submittedAtMs == 500, "so it skips the batch gate when it goes out again")
        #expect(r.pausedBy == "P" && r.pausedAtMs == 1_000 && !r.hasPauseIntent)
        #expect(r.attempts == 0 && r.lastError == nil, "a pause is not a failure")
        // The hold ends, but what is known about the earlier run stays for the send.
        r.pausedNeverStarted = true
        r.release()
        #expect(!r.isPaused && r.pausedNeverStarted == true && r.wasPaused)
        // Sent again: nothing of the pause is left.
        r.apply(.submitted, nowMs: 2_000)
        #expect(r.pausedNeverStarted == nil && !r.wasPaused && r.pausedBy == nil)
    }

    @Test func aReleasedJobWhoseEarlierRunIsNotKnownIsStillLookedUpBeforeItIsSentAgain() {
        // The pause ended by polling (a CANCELLED seen later), so nobody listed the bucket: after the hold ends the send
        // must still read the bucket for a result, not delete it.
        var r = record(1, .submitted, batch: "bulk", origin: .auto, submittedAtMs: 500)
        r.beginPause(runpodJobId: "rp-1", by: "P", nowMs: 1_000)
        r.completePause(by: "P", neverStarted: nil, nowMs: 1_100)
        #expect(r.pausedNeverStarted == nil)
        r.release()
        #expect(!r.isPaused && r.wasPaused && r.pausedNeverStarted == false)
    }

    @Test func aRunningJobDoesNotPause() {
        var r = record(1, .running, origin: .auto, submittedAtMs: 500)
        let didPause = r.completePause(by: "P", neverStarted: nil, nowMs: 1_000)
        #expect(!didPause)
        #expect(r.state == .running && r.pausedBy == nil && r.runpodJobId == "rp-1")
    }

    @Test func anAbortedPauseLeavesTheJobAsItWas() {
        var r = record(1, .submitted, origin: .auto, submittedAtMs: 500)
        r.beginPause(runpodJobId: "rp-1", by: "P", nowMs: 1_000)
        r.abortPause()
        #expect(!r.hasPauseIntent && r.pausedBy == nil && r.pausedAtMs == nil)
        #expect(r.state == .submitted && r.runpodJobId == "rp-1")
    }

    @Test func startingOverForgetsThePause() {
        var r = paused(1, by: "P")
        r.pausedNeverStarted = false
        r.apply(.requeue, nowMs: 5)
        #expect(r.state == .queued && !r.wasPaused && r.pausedAtMs == nil)
    }

    @Test func promotingAJobMakesItASingJob() {
        var r = record(1, .queued, batch: "auto", origin: .auto)
        r.promote(nowMs: 123)
        #expect(r.origin == .sing && r.priorityAtMs == 123)
        #expect(r.effectiveOrigin == .sing)
        #expect(record(2).effectiveOrigin == .manual)
    }

    @Test func recordsWithoutTheNewFieldsStillDecodeAndEncodeWithoutThem() throws {
        // The job list is one Codable file: a record written before the origin and pause fields existed must still
        // read (else the whole list is dropped), and a plain record must not write them.
        let plain = record(1, .submitted, submittedAtMs: 9)
        let data = try JSONEncoder().encode([plain])
        let text = String(decoding: data, as: UTF8.self)
        for key in ["origin", "priorityAtMs", "pausedBy", "pausedAtMs", "pausedNeverStarted", "pauseIntentRunpodJobId",
                    "autoReservedMicroUSD"] {
            #expect(!text.contains("\"\(key)\""), "\(key) was written for a plain record")
        }
        let decoded = try JSONDecoder().decode([CloudJobRecord].self, from: data)
        #expect(decoded == [plain])
        #expect(decoded[0].origin == nil && decoded[0].effectiveOrigin == .manual && !decoded[0].isPaused)

        var full = paused(2, by: "P")
        full.origin = .auto
        full.priorityAtMs = 5
        full.pausedNeverStarted = true
        full.pauseIntentRunpodJobId = "rp-2"
        full.autoReservedMicroUSD = 7_296
        let again = try JSONDecoder().decode([CloudJobRecord].self, from: try JSONEncoder().encode([full]))
        #expect(again == [full])
    }

    // MARK: Who goes first

    @Test func singJobsAndLoneManualJobsAreThePriorityJobs() {
        let jobs = [
            record(1, .preparing, origin: .sing),
            record(2, .uploaded),                                  // one song sent by hand
            record(3, .uploaded, batch: "bulk"), record(4, .uploaded, batch: "bulk"), record(5, .submitted, batch: "bulk"),
            record(6, .uploaded, origin: .auto),
            record(7, .imported, origin: .sing),                   // done: nothing to go first
        ]
        #expect(CloudPriorityLane.priorityJobKeys(jobs) == ["job1", "job2"])
        let keys = CloudPriorityLane.priorityJobKeys(jobs)
        #expect(jobs.map { CloudPriorityLane.tier(of: $0, priorityKeys: keys) } == [0, 1, 2, 2, 2, 3, 0])
    }

    @Test func preparationOrderIsByTierThenQueueOrder() {
        let jobs = [record(1, .queued, origin: .auto), record(2, .queued, batch: "bulk"), record(3, .queued, batch: "bulk"),
                    record(4, .queued, origin: .sing), record(5, .queued)]
        let keys = CloudPriorityLane.priorityJobKeys(jobs)
        #expect(CloudPriorityLane.ordered(jobs, priorityKeys: keys).map(\.jobKey) == ["job4", "job5", "job2", "job3", "job1"])
        #expect(CloudPriorityLane.transferPriority(for: jobs[3], priorityKeys: keys) == 1.0)
        #expect(CloudPriorityLane.transferPriority(for: jobs[1], priorityKeys: keys) == 0.5)
        #expect(CloudPriorityLane.transferPriority(for: jobs[0], priorityKeys: keys) == 0.3)
    }

    // MARK: Who steps aside

    @Test func onlyJobsWaitingAtRunPodStepAsideNewestFirst() {
        let jobs = [
            record(1, .running, batch: "bulk", origin: .auto, submittedAtMs: 50),
            record(2, .submitted, origin: .auto, submittedAtMs: 100),
            record(3, .submitted, origin: .auto, submittedAtMs: 200),
            record(4, .submitted, batch: "bulk", submittedAtMs: 150),     // a manual batch yields too
            record(5, .submitted, origin: .sing, submittedAtMs: 10),      // another Sing job never does
            record(6, .submitted, submittedAtMs: 20),                     // one song sent by hand never does
            record(7, .uploaded, origin: .auto, submittedAtMs: 100),
        ]
        let keys = CloudPriorityLane.priorityJobKeys(jobs)
        let candidates = CloudPriorityLane.pausable(jobs, priorityKeys: keys)
        #expect(candidates.map(\.jobKey) == ["job2", "job3", "job4"])
        #expect(CloudPriorityLane.newestFirst(candidates).map(\.jobKey) == ["job3", "job4", "job2"])
        // The same moment of submission: the later one in the queue goes first.
        let tie = [record(8, .submitted, origin: .auto, submittedAtMs: 7), record(9, .submitted, origin: .auto, submittedAtMs: 7)]
        #expect(CloudPriorityLane.newestFirst(tie).map(\.jobKey) == ["job9", "job8"])
    }

    @Test func theReadyPriorityJobIsUploadedDueAndFresh() {
        var waiting = record(1, .uploaded, origin: .sing)
        waiting.nextAttemptAtMs = now + minute
        var stale = record(2, .uploaded, origin: .sing)
        stale.uploadedAtMs = now - 4 * 86_400_000
        let fine = record(3, .uploaded, origin: .sing)
        let early = record(4, .uploading, origin: .sing)
        let pausedSing = paused(5, by: "job3", origin: .sing)
        let jobs = [waiting, stale, early, pausedSing, fine]
        let keys = CloudPriorityLane.priorityJobKeys(jobs)
        #expect(CloudPriorityLane.readyPriorityJob(jobs, priorityKeys: keys, nowMs: now)?.jobKey == "job3")
        #expect(CloudPriorityLane.readyPriorityJob([waiting, early], priorityKeys: keys, nowMs: now) == nil)
        // A manual song comes after a Sing job when both are ready.
        let manual = record(6, .uploaded)
        let both = [manual, fine]
        #expect(CloudPriorityLane.readyPriorityJob(both, priorityKeys: CloudPriorityLane.priorityJobKeys(both), nowMs: now)?.jobKey == "job3")
    }

    // MARK: What a cancel turned out to be

    @Test func theStatusTakenBeforeTheCancelDecidesWhetherToCancel() {
        func outcome(_ status: String) -> QueueCancelOutcome? {
            CloudPriorityLane.outcome(afterStatus: RunPodJob(id: "j", status: status))
        }
        #expect(outcome("IN_QUEUE") == nil, "still waiting: go on and cancel it")
        #expect(outcome("IN_PROGRESS") == .alreadyStarted(.inProgress))
        #expect(outcome("COMPLETED") == .alreadyStarted(.completed))
        #expect(outcome("FAILED") == .alreadyStarted(.failed))
        #expect(outcome("TIMED_OUT") == .alreadyStarted(.timedOut))
        #expect(outcome("CANCELLED") == .cancelledFromQueue, "an earlier cancel whose answer was lost")
        #expect(outcome("SOMETHING_NEW") == .failed)
    }

    @Test func onlyCancelledInTheAnswerCountsAsSteppedAside() {
        func outcome(_ status: String) -> QueueCancelOutcome {
            CloudPriorityLane.outcome(afterCancel: RunPodJob(id: "j", status: status))
        }
        #expect(outcome("CANCELLED") == .cancelledFromQueue)
        #expect(outcome("IN_PROGRESS") == .alreadyStarted(.inProgress))
        #expect(outcome("COMPLETED") == .alreadyStarted(.completed))
        #expect(outcome("") == .failed)
    }

    // MARK: Ending a pause

    @Test func aPauseEndsWhenItsPriorityJobIsGone() {
        let jobs = [
            record(1, .cancelled, origin: .sing),
            paused(2, by: "job1"),                       // priority job cancelled
            paused(3, by: "missing"),                    // priority job removed from the list
            record(4, .uploaded, origin: .sing),
            paused(5, by: "job4"),                       // priority job still on its way
        ]
        #expect(CloudPriorityLane.pausesToEnd(jobs) == ["job2", "job3"])
    }

    @Test func aCancelNotYetAnsweredEndsOnceThePriorityJobHasStarted() {
        func intent(_ n: Int, by priority: String) -> CloudJobRecord {
            var r = record(n, .submitted, batch: "bulk", origin: .auto, submittedAtMs: 100)
            r.beginPause(runpodJobId: "rp-\(n)", by: priority, nowMs: now)
            return r
        }
        let jobs = [
            record(1, .uploaded, origin: .sing), intent(2, by: "job1"),
            record(3, .submitted, origin: .sing, submittedAtMs: 1), intent(4, by: "job3"),   // waiting at RunPod: the pause still helps
            record(5, .running, origin: .sing, submittedAtMs: 1), intent(6, by: "job5"),     // already started: nothing to step aside for
        ]
        #expect(CloudPriorityLane.pausesToEnd(jobs) == ["job6"])
    }

    // MARK: Sending

    @Test func aBurstGoesPriorityFirstThenTheJobsThatSteppedAsideThenTheRest() {
        let jobs = [
            paused(1, by: "job4"),
            record(2, .uploaded, batch: "bulk", submittedAtMs: 5),
            paused(3, by: "job4"),
            record(4, .uploaded, origin: .sing),
            record(5, .uploaded, origin: .auto),
        ]
        let ready = jobs.map(\.jobKey)
        #expect(CloudPriorityLane.submitOrder(ready: ready, jobs: jobs) == ["job4", "job1", "job3", "job2", "job5"])
        // Without a priority job in the pass the queue order stays, paused jobs ahead of the rest.
        let noPriority = Array(jobs.filter { $0.jobKey != "job4" })
        #expect(CloudPriorityLane.submitOrder(ready: noPriority.map(\.jobKey), jobs: noPriority) == ["job1", "job3", "job2", "job5"])
        #expect(CloudPriorityLane.submitOrder(ready: ["ghost", "job2"], jobs: jobs) == ["job2"])
    }

    @Test func newAutoJobsWaitWhileAPriorityJobIsGettingReady() {
        let sing = record(1, .uploading, origin: .sing)
        let auto = record(2, .uploaded, origin: .auto)
        let manual = record(3, .uploaded, batch: "bulk")
        let bulkMate = record(4, .running, batch: "bulk", submittedAtMs: 1)   // so job3 is part of a batch, not a lone song
        var jobs = [sing, auto, manual, bulkMate]
        jobs[0].priorityAtMs = now - minute
        #expect(CloudPriorityLane.shouldHoldAutoSubmissions(jobs, nowMs: now))
        #expect(CloudPriorityLane.heldBack(ready: ["job2", "job3"], jobs: jobs, nowMs: now) == ["job2"])
        // The priority job goes in this pass: the auto job follows it instead of waiting.
        var uploaded = jobs
        uploaded[0].state = .uploaded
        #expect(CloudPriorityLane.heldBack(ready: ["job1", "job2", "job3"], jobs: uploaded, nowMs: now).isEmpty)
        // Once it has been sent nothing holds anything.
        var sent = jobs
        sent[0].state = .submitted
        #expect(!CloudPriorityLane.shouldHoldAutoSubmissions(sent, nowMs: now))
        // A priority job that never gets ready holds for five minutes only.
        jobs[0].priorityAtMs = now - CloudTiming.priorityHoldMaxMs
        #expect(!CloudPriorityLane.shouldHoldAutoSubmissions(jobs, nowMs: now))
        jobs[0].priorityAtMs = nil
        jobs[0].createdAtMs = now - minute
        #expect(CloudPriorityLane.shouldHoldAutoSubmissions(jobs, nowMs: now), "no priority time: the job's creation counts")
    }

    @Test func aJobThatSteppedAsideWaitsUntilItsPriorityJobHasGone() {
        let priority = record(1, .uploaded, origin: .sing)
        let aside = paused(2, by: "job1")
        let jobs = [priority, aside]
        // The priority job is not part of this pass (say its send is held up): its jobs wait.
        #expect(CloudPriorityLane.heldBack(ready: ["job2"], jobs: jobs, nowMs: now) == ["job2"])
        // It is part of the pass: they go right after it.
        #expect(CloudPriorityLane.heldBack(ready: ["job1", "job2"], jobs: jobs, nowMs: now).isEmpty)
        // It has been sent, or is finished or gone: they go as a burst of their own.
        var sent = jobs
        sent[0].state = .submitted
        #expect(CloudPriorityLane.heldBack(ready: ["job2"], jobs: sent, nowMs: now).isEmpty)
        var gone = jobs
        gone[0].state = .failed
        #expect(CloudPriorityLane.heldBack(ready: ["job2"], jobs: gone, nowMs: now).isEmpty)
        #expect(CloudPriorityLane.heldBack(ready: ["job2"], jobs: [aside], nowMs: now).isEmpty)
        // A hold lasts five minutes, whatever becomes of the priority job.
        let old = paused(3, by: "job1", at: now - CloudTiming.priorityHoldMaxMs)
        #expect(CloudPriorityLane.heldBack(ready: ["job3"], jobs: [priority, old], nowMs: now).isEmpty)
    }

    @Test func theLabelSaysWhySomethingIsWaiting() {
        #expect(CloudPriorityLane.pausedLabel == "Paused for a song you're singing")
        let r = paused(1, by: "job9")
        #expect(CloudActiveJobMapper.status(r, transfer: nil) == CloudPriorityLane.pausedLabel)
        var plain = r
        plain.pausedBy = nil
        #expect(CloudActiveJobMapper.status(plain, transfer: nil) == "Uploaded")
    }
}
