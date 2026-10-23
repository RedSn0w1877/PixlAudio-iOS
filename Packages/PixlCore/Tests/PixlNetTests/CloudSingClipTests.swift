import Foundation
import Testing
@testable import PixlNet

/// Sing's preview piece (the clip job, Sing step 4): its range, the record fields older lists lack, the offset mapping,
/// its place in the priority lane and in a burst, and the lists it stays out of. (The orchestrator's use of them is
/// tested in AppTests/CloudSingAndAutoTests.)
@Suite struct CloudSingClipTests {
    private let now: Int64 = 1_790_000_000_000

    private func record(_ key: String, song: String = "s1", batch: String = "b1", state: CloudJobState = .queued,
                        clip: CloudClipRange? = nil, origin: CloudJobOrigin? = .sing) -> CloudJobRecord {
        var r = CloudJobRecord(jobKey: key, songId: song, title: "Song", artist: "A", batchId: batch,
                               tasks: [.instrumental], lyricsMode: nil, quality: .standard, createdAtMs: now)
        r.state = state
        r.origin = origin
        r.clipStartMs = clip?.startMs
        r.clipDurationMs = clip?.durationMs
        if state == .submitted || state == .running { r.runpodJobId = "rp-\(key)" }
        if state == .uploaded { r.uploadedAtMs = now - 1_000 }
        return r
    }

    // MARK: The range

    @Test func theClipIsThreeSecondsBeforeToAMinuteAfterThePlayhead() {
        #expect(CloudSingClip.range(playheadMs: 90_000, songDurationMs: 240_000)
                == CloudClipRange(startMs: 87_000, endMs: 150_000))
        let range = CloudSingClip.range(playheadMs: 90_000, songDurationMs: 240_000)
        #expect(range?.durationMs == 63_000)
    }

    @Test func theClipIsClampedToTheSong() {
        // Just started: it can't begin before the song.
        #expect(CloudSingClip.range(playheadMs: 1_000, songDurationMs: 240_000)
                == CloudClipRange(startMs: 0, endMs: 61_000))
        #expect(CloudSingClip.range(playheadMs: -500, songDurationMs: 240_000)
                == CloudClipRange(startMs: 0, endMs: 60_000))
        // Near the end: it stops with the song.
        #expect(CloudSingClip.range(playheadMs: 200_000, songDurationMs: 240_000)
                == CloudClipRange(startMs: 197_000, endMs: 240_000))
    }

    @Test func aShortSongOrAPlayheadNearTheEndGetsNoClip() {
        #expect(CloudSingClip.range(playheadMs: 10_000, songDurationMs: 74_999) == nil, "under 75 s: the whole song only")
        #expect(CloudSingClip.range(playheadMs: 10_000, songDurationMs: 75_000) != nil)
        #expect(CloudSingClip.range(playheadMs: 220_001, songDurationMs: 240_000) == nil, "within 20 s of the end")
        #expect(CloudSingClip.range(playheadMs: 220_000, songDurationMs: 240_000) != nil)
        #expect(CloudSingClip.range(playheadMs: 300_000, songDurationMs: 240_000) == nil, "past the end")
        #expect(CloudSingClip.range(playheadMs: 0, songDurationMs: 0) == nil)
    }

    @Test func theOffsetMapsSongTimeToClipTimeOnlyInsideTheClip() {
        let clip = CloudClipRange(startMs: 87_000, endMs: 150_000)
        #expect(clip.clipTimeMs(forSongMs: 87_000) == 0)
        #expect(clip.clipTimeMs(forSongMs: 100_500) == 13_500)
        #expect(clip.clipTimeMs(forSongMs: 149_999) == 62_999)
        #expect(clip.clipTimeMs(forSongMs: 150_000) == nil, "the end is not part of it")
        #expect(clip.clipTimeMs(forSongMs: 86_999) == nil)
        #expect(clip.songTimeMs(forClipMs: 13_500) == 100_500)
        #expect(clip.contains(87_000) && !clip.contains(150_000))
    }

    @Test func theCutAndThePlacementUseTheSameFrame() {
        #expect(CloudSingClip.frame(ms: 87_000) == 3_836_700)
        #expect(CloudSingClip.frame(ms: 1) == 44, "whole frames, rounded down")
        #expect(CloudSingClip.frame(ms: 1_000, sampleRate: 48_000) == 48_000)
        #expect(CloudSingClip.frame(ms: -5) == 0)
    }

    // MARK: The record

    @Test func aRecordWithoutTheClipFieldsStillDecodesAsAWholeSong() throws {
        let plain = record("job1", clip: nil, origin: nil)
        let data = try JSONEncoder().encode([plain])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"clipStartMs\"") && !text.contains("\"clipDurationMs\""))
        let decoded = try JSONDecoder().decode([CloudJobRecord].self, from: data)
        #expect(decoded == [plain])
        #expect(!decoded[0].isClip && decoded[0].clipRange == nil)
    }

    @Test func aClipRecordKeepsItsPlaceInTheSong() throws {
        let clip = record("clip1", clip: CloudClipRange(startMs: 87_000, endMs: 150_000))
        let again = try JSONDecoder().decode([CloudJobRecord].self, from: try JSONEncoder().encode([clip]))
        #expect(again == [clip])
        #expect(again[0].isClip)
        #expect(again[0].clipRange == CloudClipRange(startMs: 87_000, endMs: 150_000))
        // Its cost is the clip's length, not the song's.
        var withSong = clip
        withSong.songDurationMs = 240_000
        #expect(withSong.plan.durationMs == 63_000)
    }

    // MARK: Joining and the burst

    @Test func aSingTapThatJoinsAJobStillGetsAClipUntilTheWorkerHasIt() {
        for state in [CloudJobState.queued, .preparing, .uploading, .uploaded, .submitted] {
            let full = record("full", state: state)
            #expect(CloudSingClip.mayAddClip(to: full, jobs: [full]), "\(state)")
        }
        for state in [CloudJobState.running, .resultsReady, .downloading, .imported, .failed] {
            let full = record("full", state: state)
            #expect(!CloudSingClip.mayAddClip(to: full, jobs: [full]), "\(state)")
        }
        let full = record("full", state: .uploading)
        let clip = record("clip", state: .preparing, clip: CloudClipRange(startMs: 0, endMs: 60_000))
        #expect(!CloudSingClip.mayAddClip(to: full, jobs: [full, clip]), "one clip on its way is enough")
        var lyricsOnly = record("full", state: .queued)
        lyricsOnly.tasks = [.lyrics]
        #expect(!CloudSingClip.mayAddClip(to: lyricsOnly, jobs: [lyricsOnly]))
        #expect(!CloudSingClip.mayAddClip(to: clip, jobs: [clip]), "a clip is not a whole job")
    }

    @Test func aClipIsNotTheBurstsLastWhileItsWholeJobIsRightBehindIt() {
        let clip = record("clip", state: .uploaded, clip: CloudClipRange(startMs: 0, endMs: 60_000))
        for state in [CloudJobState.queued, .preparing, .uploading] {
            let full = record("full", state: state)
            #expect(CloudSingClip.fullJobFollows(clip, jobs: [clip, full], nowMs: now), "\(state)")
        }
        for state in [CloudJobState.uploaded, .submitted, .running, .imported, .failed, .cancelled] {
            let full = record("full", state: state)
            #expect(!CloudSingClip.fullJobFollows(clip, jobs: [clip, full], nowMs: now), "\(state)")
        }
        var waiting = record("full", state: .uploading)
        waiting.nextAttemptAtMs = now + 60_000
        #expect(!CloudSingClip.fullJobFollows(clip, jobs: [clip, waiting], nowMs: now), "a retry is not right behind")
        #expect(!CloudSingClip.fullJobFollows(clip, jobs: [clip], nowMs: now), "no whole job, nothing follows")
        let otherBatch = record("full", batch: "b2", state: .uploading)
        #expect(!CloudSingClip.fullJobFollows(clip, jobs: [clip, otherBatch], nowMs: now))
        let full = record("full", state: .uploading)
        #expect(!CloudSingClip.fullJobFollows(full, jobs: [clip, full], nowMs: now), "only a clip asks")
    }

    @Test func theClipGoesFirstThenItsWholeJobInOneBurst() {
        // The whole job was added before the clip (a Sing tap that joined it): the clip still goes first.
        let full = record("full", state: .uploaded)
        let clip = record("clip", state: .uploaded, clip: CloudClipRange(startMs: 0, endMs: 60_000))
        var other = record("other", song: "s2", batch: "b2", state: .uploaded, origin: .auto)
        other.submittedAtMs = now - 10_000
        let jobs = [full, other, clip]
        #expect(CloudPriorityLane.submitOrder(ready: ["full", "other", "clip"], jobs: jobs) == ["clip", "full", "other"])
        let keys = CloudPriorityLane.priorityJobKeys(jobs)
        #expect(CloudPriorityLane.ordered(jobs, priorityKeys: keys).map(\.jobKey) == ["clip", "full", "other"])
        #expect(CloudPriorityLane.readyPriorityJob(jobs, priorityKeys: keys, nowMs: now)?.jobKey == "clip")
    }

    @Test func theSongsOwnWaitingWholeJobStepsAsideForItsClip() {
        let full = record("full", state: .submitted)
        let clip = record("clip", state: .uploaded, clip: CloudClipRange(startMs: 0, endMs: 60_000))
        let auto = record("auto", song: "s2", batch: "b2", state: .submitted, origin: .auto)
        let otherSing = record("sing2", song: "s3", batch: "b3", state: .submitted)
        let running = record("run", song: "s4", batch: "b4", state: .running, origin: .auto)
        let jobs = [full, clip, auto, otherSing, running]
        let keys = CloudPriorityLane.priorityJobKeys(jobs)
        #expect(Set(CloudPriorityLane.pausable(jobs, priorityKeys: keys, for: clip).map(\.jobKey)) == ["full", "auto"],
                "another song's Sing job and a running job never step aside")
        // For a whole job, nothing changes.
        #expect(CloudPriorityLane.pausable(jobs, priorityKeys: keys, for: full).map(\.jobKey) == ["auto"])
    }

    // MARK: The lists it stays out of

    @Test func aClipHasNoRowOfItsOwnAndIsNeverAnnounced() {
        let full = record("full", state: .uploading)
        let clip = record("clip", state: .running, clip: CloudClipRange(startMs: 0, endMs: 60_000))
        let rows = CloudActiveJobMapper.rows([clip, full], transfer: [:])
        #expect(rows.count == 1)
        #expect(rows.first?.subtitle?.hasPrefix("Song · Uploading") == true, "the song's own job is the row")
        #expect(CloudActiveJobMapper.activeSummary([clip, full]).count == 1)
        #expect(CloudActiveJobMapper.activeSummary([clip]).count == 0)

        // The clip still running doesn't hold back the song's announcement, and a lone clip announces nothing.
        var done = record("full", state: .imported)
        done.importedInstrumental = true
        #expect(CloudBatchNotifier.incompleteBatchIds([clip, done]).isEmpty)
        let outcomes = CloudBatchNotifier.completions(previouslyIncomplete: ["b1"], jobs: [clip, done], alreadyNotified: [])
        #expect(outcomes.count == 1 && outcomes.first?.total == 1)
        let loneClip = record("c", batch: "b9", state: .imported, clip: CloudClipRange(startMs: 0, endMs: 60_000))
        #expect(CloudBatchNotifier.completions(previouslyIncomplete: ["b9"], jobs: [loneClip], alreadyNotified: []).isEmpty)
    }

    @Test func aClipIsNeverRetriedAndOneLeftByAnEarlierLaunchIsStopped() {
        let failedClip = record("clip", state: .failed, clip: CloudClipRange(startMs: 0, endMs: 60_000))
        let failedSong = record("full", state: .failed)
        #expect(CloudJobClearing.retryable([failedClip, failedSong]).map(\.jobKey) == ["full"])
        let pendingClip = record("c2", state: .submitted, clip: CloudClipRange(startMs: 0, endMs: 60_000))
        let doneClip = record("c3", state: .imported, clip: CloudClipRange(startMs: 0, endMs: 60_000))
        #expect(CloudStartupRecovery.staleClips([pendingClip, doneClip, failedSong]) == ["c2"])
    }
}
