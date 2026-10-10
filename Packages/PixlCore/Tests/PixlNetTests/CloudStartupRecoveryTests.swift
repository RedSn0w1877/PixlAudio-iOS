import Foundation
import Testing
@testable import PixlNet

@Suite struct CloudStartupRecoveryTests {
    private func record(_ n: Int, _ state: CloudJobState, batch: String = "b1") -> CloudJobRecord {
        var r = CloudJobRecord(jobKey: "job\(n)", songId: "s\(n)", title: "Song \(n)", artist: "Artist", batchId: batch,
                               tasks: [.instrumental], lyricsMode: nil, quality: .standard, createdAtMs: Int64(n) * 1_000)
        r.state = state
        return r
    }

    @Test func aJobLeftPreparingByADeadProcessGoesBackToTheQueue() {
        var jobs = [record(1, .preparing), record(2, .queued), record(3, .uploading), record(4, .failed)]
        jobs[0].runpodJobId = "stale"
        let changed = CloudStartupRecovery.recover(&jobs, nowMs: 9_000)
        #expect(changed == 1)
        #expect(jobs[0].state == .queued)
        #expect(jobs[0].runpodJobId == nil)
        #expect(jobs[0].updatedAtMs == 9_000)
        #expect(jobs[1...].map(\.state) == [.queued, .uploading, .failed], "everything else survives a launch")
    }

    @Test func recoveringTwiceChangesNothingMore() {
        var jobs = [record(1, .preparing)]
        #expect(CloudStartupRecovery.recover(&jobs, nowMs: 1) == 1)
        #expect(CloudStartupRecovery.recover(&jobs, nowMs: 2) == 0)
    }

    @Test func clearFinishedTakesEveryFinishedJobAndNeverAPendingOne() {
        let jobs = [record(1, .imported), record(2, .failed), record(3, .cancelled), record(4, .expired),
                    record(5, .running), record(6, .queued), record(7, .uploading)]
        #expect(CloudJobClearing.clearable(jobs).map(\.jobKey) == ["job1", "job2", "job3", "job4"])
        #expect(CloudJobClearing.cancellable(jobs).map(\.jobKey) == ["job5", "job6", "job7"])
    }

    @Test func aBatchRowRetriesWhatNeedsTheUserNotWhatTheyCancelled() {
        let jobs = [record(1, .imported), record(2, .failed), record(3, .cancelled), record(4, .expired)]
        #expect(CloudJobClearing.retryable(jobs).map(\.jobKey) == ["job2", "job4"])
    }

    @Test func failureStopsRetryingAfterTheAutomaticAttempts() {
        var r = record(1, .preparing)
        var waits = 0
        // A retryable failure waits on the ladder; the last allowed attempt ends as Failed (Retry is then the person's).
        while r.state != .failed && waits < 20 {
            r.recordFailure("no connection", code: nil, retryable: true, nowMs: 1_000)
            if r.state != .failed { waits += 1 }
        }
        #expect(r.state == .failed)
        #expect(waits == CloudTiming.maxAutomaticAttempts - 1)
        #expect(r.nextAttemptAtMs == nil)
        #expect(r.lastError == "no connection")
    }
}
