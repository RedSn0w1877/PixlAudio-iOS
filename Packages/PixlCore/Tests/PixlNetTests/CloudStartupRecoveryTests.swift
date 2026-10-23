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

    @Test func storedJobsStopAskingTheCloudForLyrics() {
        // Stored before 2026-10-23, when the cloud still timed lyrics.
        func legacy(_ n: Int, _ state: CloudJobState, tasks: [CloudTask] = [.instrumental, .lyrics]) -> CloudJobRecord {
            var r = record(n, state)
            r.tasks = tasks
            r.lyricsMode = .align
            return r
        }
        var jobs = [legacy(1, .queued), legacy(2, .uploaded), legacy(3, .uploading, tasks: [.lyrics]),
                    legacy(4, .submitted), legacy(5, .running, tasks: [.lyrics]), legacy(6, .imported),
                    record(7, .queued)]
        let result = CloudStartupRecovery.retireCloudLyrics(&jobs, nowMs: 5_000)
        // Not sent yet: the instrumental goes alone; a lyrics-only job is handed back to be cancelled.
        #expect(result.changed == 2)
        #expect(result.lyricsOnly == ["job3"])
        #expect(jobs[0].tasks == [.instrumental] && jobs[0].lyricsMode == nil && jobs[0].updatedAtMs == 5_000)
        #expect(jobs[1].tasks == [.instrumental] && jobs[1].state == .uploaded)
        #expect(jobs[2].tasks == [.lyrics], "left for the caller to cancel")
        // RunPod already has these, or they are done: they finish as they are.
        #expect(jobs[3].tasks == [.instrumental, .lyrics] && jobs[4].tasks == [.lyrics])
        #expect(jobs[5].tasks == [.instrumental, .lyrics])
        #expect(jobs[6].tasks == [.instrumental])
        // A second launch finds nothing more to change.
        let again = CloudStartupRecovery.retireCloudLyrics(&jobs, nowMs: 6_000)
        #expect(again.changed == 0 && again.lyricsOnly == ["job3"])
    }

    @Test func droppingTheLyricsTaskKeepsTheInstrumental() {
        var both = record(1, .uploaded)
        both.tasks = [.instrumental, .lyrics]
        both.lyricsMode = .transcribe
        let dropped = both.dropLyricsTask(nowMs: 7)
        #expect(dropped && both.tasks == [.instrumental] && both.lyricsMode == nil)
        var lyricsOnly = record(2, .queued)
        lyricsOnly.tasks = [.lyrics]
        let kept = lyricsOnly.dropLyricsTask(nowMs: 7)
        #expect(!kept && lyricsOnly.tasks == [.lyrics], "nothing would be left to ask for")
        var plain = record(3, .queued)
        let unchanged = plain.dropLyricsTask(nowMs: 7)
        #expect(unchanged && plain.updatedAtMs == nil)
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
