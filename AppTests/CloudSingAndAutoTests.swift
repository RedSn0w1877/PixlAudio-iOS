import Foundation
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// Sing's cloud job, the priority lane and "Prepare songs ahead" (auto) jobs through Cloud Studio's orchestrator, with
/// the same fakes as `CloudStudioTests`: RunPod is a queue the test steers (`FakeRunPod`), the clock only moves when a
/// test moves it, and nothing touches the network.
@MainActor
final class CloudSingAndAutoTests: XCTestCase {
    /// Three auto jobs sent as one burst: `rp-1`, `rp-2`, `rp-3`.
    private func autoBatchAtRunPod(_ h: CloudHarness) async throws -> [String] {
        let songs = ["a", "b", "c"].map { h.addSong("f:root/\($0).m4a") }
        return try await h.submittedBatch(songs, origin: .auto)
    }

    /// RunPod finishes the job, its lyrics come in, and the downloaded instrumental is checked and installed.
    private func finishAndImport(_ h: CloudHarness, key: String, runpodId: String) async throws {
        await h.runpod.setStatus(runpodId, RunPodJob(id: runpodId, status: "COMPLETED", result: h.finish(key)))
        h.clock.advance(16_000)
        await h.studio.pump()
        await h.studio.handle(.downloaded(jobKey: key, slot: "instrumental", stagedFile: try h.stagedInstrumental()))
    }

    // MARK: Sing's job

    func testASingTapAsksForTheInstrumentalEvenWhenItsOutputIsOff() async throws {
        let h = CloudHarness()
        h.settings.wantsInstrumental = false
        h.settings.wantsLyrics = false
        let song = h.addSong("f:root/a.m4a")
        let started = await h.studio.startSing(song: song)
        XCTAssertEqual(started, .started(1))
        let job = try XCTUnwrap(h.studio.job(forSong: song.id))
        XCTAssertEqual(job.tasks, [.instrumental])
        XCTAssertEqual(job.origin, .sing)
        XCTAssertNotNil(job.priorityAtMs)
        // The same settings with a tap on "Process in cloud" find nothing to do.
        let other = h.addSong("f:root/b.m4a")
        let manual = await h.studio.startNow(songs: [other], title: "Test")
        XCTAssertEqual(manual, .nothingToDo("Nothing to process — \(CloudSkipReason.alreadyDone.label)"))
    }

    func testSingKeepsTheLyricsTheSettingsAskFor() async throws {
        let h = CloudHarness()
        let song = h.addSong("f:root/a.m4a")
        h.host.facts[song.id] = CloudHarness.lineSyncedFacts
        let started = await h.studio.startSing(song: song)
        XCTAssertEqual(started, .started(1))
        XCTAssertEqual(h.studio.job(forSong: song.id)?.tasks, [.instrumental, .lyrics])
    }

    func testTheOriginIsKeptOnDisk() async throws {
        let store = CloudJobStore(file: nil)
        let h = CloudHarness(store: store)
        let song = h.addSong("f:root/a.m4a")
        let started = await h.studio.startSing(song: song)
        XCTAssertEqual(started, .started(1))
        await h.studio.pump()
        // The save runs behind the pass: look until the job list is on disk.
        var stored: [CloudJobRecord] = []
        for _ in 0..<100 where stored.isEmpty {
            stored = await store.load(nowMs: h.clock.ms)
            if stored.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.origin, .sing)
        XCTAssertNotNil(stored.first?.priorityAtMs)
    }

    func testSingAvailabilityNamesWhyTheCloudCannotTakeTheTap() async throws {
        let h = CloudHarness()
        let song = h.addSong("f:root/a.m4a")
        let usable = await h.studio.singAvailability(for: song)
        XCTAssertEqual(usable, .usable)

        let long = h.addSong("f:root/long.m4a", durationMs: 16 * 60_000)
        let tooLong = await h.studio.singAvailability(for: long)
        XCTAssertEqual(tooLong, .tooLong)

        h.host.instrumentals.insert(song.id)
        let alreadyThere = await h.studio.singAvailability(for: song)
        XCTAssertEqual(alreadyThere, .nothingToDo)
        h.host.instrumentals.remove(song.id)

        // Mobile data: only when the switch allows it.
        h.phone.goOffWiFi()
        let offWiFi = await h.studio.singAvailability(for: song)
        XCTAssertEqual(offWiFi, .notOnWiFi)
        h.settings.useCellular = true
        let onMobileData = await h.studio.singAvailability(for: song)
        XCTAssertEqual(onMobileData, .usable)
        h.settings.useCellular = false
        h.phone.goOnWiFi()

        h.settings.monthlyCapMicroUSD = 1
        let overCap = await h.studio.singAvailability(for: song)
        XCTAssertEqual(overCap, .overCap)
        h.settings.monthlyCapMicroUSD = CloudCost.defaultMonthlyCapMicroUSD

        h.settings.isEnabled = false
        let off = await h.studio.singAvailability(for: song)
        XCTAssertEqual(off, .off)
    }

    func testSingAvailabilityKnowsWhenTheCloudIsNotSetUp() async throws {
        let h = CloudHarness(ownKeys: false)
        let song = h.addSong("f:root/a.m4a")
        let off = await h.studio.singAvailability(for: song)
        XCTAssertEqual(off, .off)
        h.settings.isEnabled = true
        let notConfigured = await h.studio.singAvailability(for: song)
        XCTAssertEqual(notConfigured, .notConfigured)
    }

    func testTheToastNamesWhyThePhoneRendersInstead() {
        XCTAssertNil(SingCloudAvailability.usable.fallbackMessage)
        XCTAssertNil(SingCloudAvailability.alreadyPending(jobKey: "k").fallbackMessage)
        XCTAssertEqual(SingCloudAvailability.notOnWiFi.fallbackMessage,
                       "Not on Wi-Fi — removing vocals on this phone instead.")
        XCTAssertEqual(SingCloudAvailability.off.fallbackMessage,
                       "Cloud processing is off — removing vocals on this phone instead.")
        XCTAssertEqual(SingCloudAvailability.overCap.fallbackMessage,
                       "This month's cloud budget is used up — removing vocals on this phone instead.")
        XCTAssertEqual(SingCloudAvailability.notConfigured.fallbackMessage,
                       "Cloud processing isn't set up — removing vocals on this phone instead.")
        for availability in [SingCloudAvailability.tooLong, .nothingToDo, .keysMissing] {
            XCTAssertEqual(availability.fallbackMessage?.hasSuffix("vocals on this phone instead."), true)
        }
    }

    func testASingTapOnASongThatAlreadyHasAnAutoJobJoinsItAndPromotesIt() async throws {
        let h = CloudHarness()
        let song = h.addSong("f:root/a.m4a")
        let sent = await h.studio.startAuto(songs: [song], limit: 3)
        XCTAssertEqual(sent, 1)
        let autoJob = try XCTUnwrap(h.studio.job(forSong: song.id))
        XCTAssertEqual(autoJob.effectiveOrigin, .auto)

        let started = await h.studio.startSing(song: song)
        XCTAssertEqual(started, .started(1))
        XCTAssertEqual(h.studio.jobs.count, 1, "joined, not duplicated")
        let job = try XCTUnwrap(h.studio.job(autoJob.jobKey))
        XCTAssertEqual(job.origin, .sing)
        XCTAssertNotNil(job.priorityAtMs)
        let availability = await h.studio.singAvailability(for: song)
        XCTAssertEqual(availability, .alreadyPending(jobKey: autoJob.jobKey))
    }

    func testASongWhoseJobMakesOnlyLyricsIsNotJoinedForTheInstrumental() async throws {
        let h = CloudHarness()
        h.settings.wantsInstrumental = false
        let song = h.addSong("f:root/a.m4a")
        h.host.facts[song.id] = CloudHarness.lineSyncedFacts
        let manual = await h.studio.startNow(songs: [song], title: "Test")
        XCTAssertEqual(manual, .started(1))
        XCTAssertEqual(h.studio.jobs.first?.tasks, [.lyrics])
        // That job will never make the instrumental a Sing tap waits for: the phone makes it.
        let availability = await h.studio.singAvailability(for: song)
        XCTAssertEqual(availability, .nothingToDo)
        let started = await h.studio.startSing(song: song)
        XCTAssertEqual(started, .nothingToDo("Nothing to process — \(CloudSkipReason.pendingJob.label)"))
        XCTAssertEqual(h.studio.jobs.count, 1)
        XCTAssertEqual(h.studio.jobs.first?.effectiveOrigin, .manual)
    }

    // MARK: The priority lane

    func testASingJobGoesFirstAndTheJobsWaitingAtRunPodStepAsideAndFollowIt() async throws {
        let h = CloudHarness()
        let keys = try await autoBatchAtRunPod(h)
        let burst = await h.runpod.runs
        XCTAssertEqual(burst.map(\.input.isLastInBatch), [false, false, true])
        // The worker is busy with the first one.
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "IN_PROGRESS"))

        let singKey = try await h.singJobPrepared(h.addSong("f:root/sing.m4a"))
        let beforeUpload = await h.runpod.cancelled
        XCTAssertEqual(beforeUpload, [], "nothing steps aside while the Sing job is still getting ready")

        await h.studio.handle(.uploaded(jobKey: singKey))
        await h.studio.pump()
        let cancelled = await h.runpod.cancelled
        XCTAssertEqual(cancelled, ["rp-3", "rp-2"], "newest first; the job the worker has is never touched")
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.count, 6)
        XCTAssertEqual(runs.suffix(3).compactMap(\.input.jobKey), [singKey, keys[1], keys[2]],
                       "the Sing job first, then the jobs that stepped aside, in their old order")
        XCTAssertEqual(runs.suffix(3).map(\.input.isLastInBatch), [false, false, true],
                       "one burst: only its final job asks the worker to stop")
        for key in [singKey, keys[1], keys[2]] { XCTAssertEqual(h.studio.job(key)?.state, .submitted) }
        XCTAssertEqual(h.studio.job(keys[0])?.state, .running)
        // They never reached the worker, so there was nothing of theirs in the bucket to clear.
        XCTAssertFalse(h.objects.deleted.contains("out/\(keys[1])/manifest.json"))
        XCTAssertFalse(h.objects.deleted.contains("out/\(keys[2])/attempt.json"))
        for key in [keys[1], keys[2]] {
            let job = try XCTUnwrap(h.studio.job(key))
            XCTAssertNil(job.pausedBy)
            XCTAssertNil(job.pausedNeverStarted)
            XCTAssertNil(job.pauseIntentRunpodJobId)
            XCTAssertEqual(job.attempts, 0, "stepping aside is not a failure")
        }
    }

    func testAJobTheWorkerStartedBeforeTheCancelIsLeftRunning() async throws {
        let h = CloudHarness()
        let keys = try await autoBatchAtRunPod(h)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "IN_PROGRESS"))
        // The status the app last saw said waiting; right before the cancel RunPod says the worker has the third.
        await h.runpod.setStatus("rp-3", RunPodJob(id: "rp-3", status: "IN_PROGRESS"))
        let singKey = try await h.singJobPrepared(h.addSong("f:root/sing.m4a"))
        await h.studio.handle(.uploaded(jobKey: singKey))
        await h.studio.pump()
        let cancelled = await h.runpod.cancelled
        XCTAssertEqual(cancelled, ["rp-2"])
        XCTAssertEqual(h.studio.job(keys[2])?.state, .running)
        XCTAssertNil(h.studio.job(keys[2])?.pausedBy)
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.suffix(2).compactMap(\.input.jobKey), [singKey, keys[1]])
        XCTAssertEqual(runs.suffix(2).map(\.input.isLastInBatch), [false, true])
    }

    func testACancelThatAnsweredAnythingButCancelledPausesNothing() async throws {
        let h = CloudHarness()
        let keys = try await autoBatchAtRunPod(h)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "IN_PROGRESS"))
        // The worker took the third between the status and the cancel: RunPod's answer to the cancel says so.
        await h.runpod.setCancelAnswer("rp-3", RunPodJob(id: "rp-3", status: "IN_PROGRESS"))
        let singKey = try await h.singJobPrepared(h.addSong("f:root/sing.m4a"))
        await h.studio.handle(.uploaded(jobKey: singKey))
        await h.studio.pump()
        let cancelled = await h.runpod.cancelled
        XCTAssertEqual(cancelled, ["rp-3", "rp-2"])
        let third = try XCTUnwrap(h.studio.job(keys[2]))
        XCTAssertEqual(third.state, .submitted)
        XCTAssertNil(third.pausedBy)
        XCTAssertNil(third.pauseIntentRunpodJobId)
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.suffix(2).compactMap(\.input.jobKey), [singKey, keys[1]])
    }

    func testACancelWhoseAnswerIsLostIsSettledByPollingAndIsNotAFailure() async throws {
        let h = CloudHarness()
        let keys = try await autoBatchAtRunPod(h)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "IN_PROGRESS"))
        await h.runpod.loseCancelAnswer("rp-3")
        let singKey = try await h.singJobPrepared(h.addSong("f:root/sing.m4a"))
        await h.studio.handle(.uploaded(jobKey: singKey))
        await h.studio.pump()

        // The pass stops at the cancel it cannot be sure of.
        let cancelled = await h.runpod.cancelled
        XCTAssertEqual(cancelled, ["rp-3"])
        let second = try XCTUnwrap(h.studio.job(keys[1]))
        XCTAssertEqual(second.state, .submitted)
        XCTAssertNil(second.pauseIntentRunpodJobId, "never asked, so no intent")
        XCTAssertNil(second.pausedBy)
        // The Sing job is not held up by a RunPod hiccup: it was the fourth job sent, and the last of its burst.
        var runs = await h.runpod.runs
        XCTAssertGreaterThanOrEqual(runs.count, 4)
        XCTAssertEqual(runs.compactMap(\.input.jobKey)[3], singKey)
        XCTAssertEqual(runs[3].input.isLastInBatch, true)

        // Polling sees CANCELLED for the job whose answer was lost: that is the pause, not a failure (no attempt counted,
        // no backoff), and the job follows the Sing job. Whether the worker ever started it is not known, so the bucket
        // is cleared of any earlier attempt before it is sent again.
        h.clock.advance(3_000)
        await h.studio.pump()
        await h.studio.pump()
        let third = try XCTUnwrap(h.studio.job(keys[2]))
        XCTAssertEqual(third.state, .submitted)
        XCTAssertEqual(third.runpodJobId, "rp-5")
        XCTAssertEqual(third.attempts, 0)
        XCTAssertNil(third.lastError)
        XCTAssertNil(third.pausedBy)
        XCTAssertNil(third.pauseIntentRunpodJobId)
        runs = await h.runpod.runs
        XCTAssertEqual(runs.count, 5)
        XCTAssertEqual(runs.compactMap(\.input.jobKey)[4], keys[2])
        XCTAssertEqual(runs[4].input.isLastInBatch, true)
        XCTAssertTrue(h.objects.deleted.contains("out/\(keys[2])/manifest.json"))
        XCTAssertTrue(h.objects.deleted.contains("out/\(keys[2])/attempt.json"))
    }

    func testACancelThatFailsLeavesTheJobWhereItWas() async throws {
        let h = CloudHarness()
        let keys = try await autoBatchAtRunPod(h)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "IN_PROGRESS"))
        await h.runpod.failCancel("rp-3")
        let singKey = try await h.singJobPrepared(h.addSong("f:root/sing.m4a"))
        await h.studio.handle(.uploaded(jobKey: singKey))
        await h.studio.pump()
        let third = try XCTUnwrap(h.studio.job(keys[2]))
        XCTAssertEqual(third.state, .submitted)
        XCTAssertEqual(third.pauseIntentRunpodJobId, "rp-3", "kept: the cancel may have gone through")
        XCTAssertEqual(third.attempts, 0)
        let second = try XCTUnwrap(h.studio.job(keys[1]))
        XCTAssertEqual(second.state, .submitted)
        XCTAssertNil(second.pausedBy)
        XCTAssertEqual(h.studio.job(singKey)?.state, .submitted)
    }

    func testAStatusThatAlreadySaysCancelledCompletesThePauseWithoutAnotherCancel() async throws {
        let h = CloudHarness()
        let keys = try await autoBatchAtRunPod(h)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "IN_PROGRESS"))
        // An earlier pass cancelled the third and died before it could say so.
        await h.runpod.setStatus("rp-3", RunPodJob(id: "rp-3", status: "CANCELLED"))
        let singKey = try await h.singJobPrepared(h.addSong("f:root/sing.m4a"))
        await h.studio.handle(.uploaded(jobKey: singKey))
        await h.studio.pump()
        let cancelled = await h.runpod.cancelled
        XCTAssertEqual(cancelled, ["rp-2"], "the third was already gone from the queue")
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.suffix(3).compactMap(\.input.jobKey), [singKey, keys[1], keys[2]])
        XCTAssertEqual(runs.suffix(3).map(\.input.isLastInBatch), [false, false, true])
    }

    func testWhenTheCapStopsTheResendTheSingJobIsTheLastAndTheOthersFollowLater() async throws {
        let h = CloudHarness()
        let keys = try await autoBatchAtRunPod(h)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "IN_PROGRESS"))
        let first = try XCTUnwrap(h.studio.job(keys[0]))
        let estimate = CloudCost.estimatedSeconds(first.plan, quality: first.quality) * h.settings.pricePerSecondMicroUSD
        let singKey = try await h.singJobPrepared(h.addSong("f:root/sing.m4a"))
        // The cap shrinks while the Sing job uploads: room for the running job and the Sing job, not for a third at the
        // same time.
        h.settings.monthlyCapMicroUSD = 2 * estimate + estimate / 2
        await h.studio.handle(.uploaded(jobKey: singKey))
        await h.studio.pump()
        var runs = await h.runpod.runs
        XCTAssertEqual(runs.count, 4, "only the Sing job went out")
        XCTAssertEqual(runs.compactMap(\.input.jobKey).last, singKey)
        XCTAssertEqual(runs.last?.input.isLastInBatch, true, "the final job of the burst that did go out")
        XCTAssertEqual(h.studio.notice, .capReached)
        for key in [keys[1], keys[2]] {
            let job = try XCTUnwrap(h.studio.job(key))
            XCTAssertEqual(job.state, .uploaded)
            XCTAssertEqual(job.pausedBy, singKey)
        }

        // Room again: they go out as a burst of their own, with one last.
        h.settings.monthlyCapMicroUSD = 10 * estimate
        await h.studio.pump()
        runs = await h.runpod.runs
        XCTAssertEqual(runs.count, 6)
        XCTAssertEqual(runs.suffix(2).compactMap(\.input.jobKey), [keys[1], keys[2]])
        XCTAssertEqual(runs.suffix(2).map(\.input.isLastInBatch), [false, true])
        XCTAssertNil(h.studio.job(keys[1])?.pausedBy)
    }

    func testAJobThatFinishedBeforeTheCancelLandedIsTakenNotSentAgain() async throws {
        let h = CloudHarness()
        let keys = try await autoBatchAtRunPod(h)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "IN_PROGRESS"))
        // The second finished a moment before the cancel reached RunPod: its result is already in the bucket.
        h.store(manifest: h.finish(keys[1]))
        let singKey = try await h.singJobPrepared(h.addSong("f:root/sing.m4a"))
        await h.studio.handle(.uploaded(jobKey: singKey))
        await h.studio.pump()
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.suffix(2).compactMap(\.input.jobKey), [singKey, keys[2]])
        XCTAssertEqual(runs.suffix(2).map(\.input.isLastInBatch), [false, true])
        XCTAssertEqual(runs.compactMap(\.input.jobKey).filter { $0 == keys[1] }.count, 1, "never sent a second time")
        let second = try XCTUnwrap(h.studio.job(keys[1]))
        XCTAssertTrue([CloudJobState.resultsReady, .downloading].contains(second.state), "\(second.state)")
        XCTAssertTrue(h.host.savedLyrics.contains { $0.songId == "f:root/b.m4a" })
    }

    func testAnotherSingJobIsNeverPausedForASingJob() async throws {
        let h = CloudHarness()
        _ = try await autoBatchAtRunPod(h)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "IN_PROGRESS"))
        let firstSing = try await h.singJobPrepared(h.addSong("f:root/sing1.m4a"))
        await h.studio.handle(.uploaded(jobKey: firstSing))
        await h.studio.pump()
        let firstRunpodId = try XCTUnwrap(h.studio.job(firstSing)?.runpodJobId)
        // A second tap while the first Sing job waits at RunPod.
        let secondSing = try await h.singJobPrepared(h.addSong("f:root/sing2.m4a"))
        await h.studio.handle(.uploaded(jobKey: secondSing))
        await h.studio.pump()
        let cancelled = await h.runpod.cancelled
        XCTAssertFalse(cancelled.contains(firstRunpodId), "a Sing job is never paused")
        XCTAssertEqual(h.studio.job(secondSing)?.state, .submitted)
        XCTAssertEqual(h.studio.job(firstSing)?.state, .submitted)
    }

    func testOneSongSentByHandStepsAheadOfAManualBatch() async throws {
        let h = CloudHarness()
        let batch = ["a", "b", "c"].map { h.addSong("f:root/\($0).m4a") }
        let keys = try await h.submittedBatch(batch)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "IN_PROGRESS"))
        let single = h.addSong("f:root/single.m4a")
        let started = await h.studio.startNow(songs: [single], title: "Test")
        XCTAssertEqual(started, .started(1))
        await h.studio.pump()
        await h.studio.settle()
        let singleKey = try XCTUnwrap(h.studio.job(forSong: single.id)?.jobKey)
        await h.studio.handle(.uploaded(jobKey: singleKey))
        await h.studio.pump()
        let cancelled = await h.runpod.cancelled
        XCTAssertEqual(cancelled, ["rp-3", "rp-2"])
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.suffix(3).compactMap(\.input.jobKey), [singleKey, keys[1], keys[2]])
        XCTAssertEqual(runs.suffix(3).map(\.input.isLastInBatch), [false, false, true])
    }

    func testAPausedJobWhoseSingJobIsGoneIsSentAgain() async throws {
        var cancelled = CloudHarness.storedRecord(1, song: "f:root/s.m4a", state: .cancelled, origin: .sing)
        cancelled.priorityAtMs = CloudHarness.clockStartMs - 60_000
        var paused = CloudHarness.storedRecord(2, song: "f:root/a.m4a", state: .uploaded, origin: .auto, batch: "bulk")
        paused.submittedAtMs = CloudHarness.clockStartMs - 5_000
        paused.pausedBy = cancelled.jobKey
        paused.pausedAtMs = CloudHarness.clockStartMs - 4_000
        paused.pausedNeverStarted = true
        let store = CloudJobStore(file: nil)
        await store.save([cancelled, paused])
        let h = CloudHarness(store: store)
        h.addSong("f:root/a.m4a")
        await h.studio.pump()
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.compactMap(\.input.jobKey), [paused.jobKey])
        XCTAssertEqual(runs.first?.input.isLastInBatch, true)
        let job = try XCTUnwrap(h.studio.job(paused.jobKey))
        XCTAssertEqual(job.state, .submitted)
        XCTAssertNil(job.pausedBy)
        XCTAssertFalse(h.objects.deleted.contains("out/\(paused.jobKey)/manifest.json"), "it never started")
    }

    func testCancellingTheSingJobReleasesTheJobsThatSteppedAsideForIt() async throws {
        var sing = CloudHarness.storedRecord(1, song: "f:root/s.m4a", state: .uploading, origin: .sing)
        sing.priorityAtMs = CloudHarness.clockStartMs
        var paused = CloudHarness.storedRecord(2, song: "f:root/a.m4a", state: .uploaded, origin: .auto, batch: "bulk")
        paused.submittedAtMs = CloudHarness.clockStartMs - 5_000
        paused.pausedBy = sing.jobKey
        paused.pausedAtMs = CloudHarness.clockStartMs
        let store = CloudJobStore(file: nil)
        await store.save([sing, paused])
        let h = CloudHarness(store: store)
        h.addSong("f:root/s.m4a")
        h.addSong("f:root/a.m4a")
        await h.studio.loadForDisplay()
        XCTAssertEqual(h.studio.job(paused.jobKey)?.pausedBy, sing.jobKey)
        await h.studio.cancel(sing.jobKey)
        let job = try XCTUnwrap(h.studio.job(paused.jobKey))
        XCTAssertNil(job.pausedBy, "no longer waiting for a song that is gone")
        XCTAssertEqual(job.pausedNeverStarted, false, "what the earlier run did is not known: the bucket is read first")
    }

    func testNewAutoJobsWaitWhileASingJobIsGettingReadyButNotForever() async throws {
        var sing = CloudHarness.storedRecord(1, song: "f:root/s.m4a", state: .uploading, origin: .sing)
        sing.priorityAtMs = CloudHarness.clockStartMs
        let auto = CloudHarness.storedRecord(2, song: "f:root/a.m4a", state: .uploaded, origin: .auto, batch: "auto")
        let store = CloudJobStore(file: nil)
        await store.save([sing, auto])
        let h = CloudHarness(store: store)
        h.addSong("f:root/s.m4a")
        h.addSong("f:root/a.m4a")
        await h.studio.pump()
        var runs = await h.runpod.runs
        XCTAssertTrue(runs.isEmpty, "a new auto job must not slip ahead of the Sing job it would only have to be cancelled for")
        h.clock.advance(CloudTiming.priorityHoldMaxMs + 1)
        await h.studio.pump()
        runs = await h.runpod.runs
        XCTAssertEqual(runs.compactMap(\.input.jobKey), [auto.jobKey], "a Sing job that never gets uploaded cannot freeze the queue")
    }

    func testAnUnplannedRunPodCancelStillCountsAsAFailure() async throws {
        let h = CloudHarness()
        let key = try await h.submittedJob()
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "CANCELLED"))
        h.clock.advance(16_000)
        await h.studio.pump()
        let job = try XCTUnwrap(h.studio.job(key))
        XCTAssertEqual(job.state, .uploaded)
        XCTAssertEqual(job.attempts, 1)
        XCTAssertNotNil(job.lastError)
    }

    func testASingTapOnASongOfAnAutoBatchThatIsStillUploadingSendsItAtOnce() async throws {
        let h = CloudHarness()
        let songs = ["a", "b", "c"].map { h.addSong("f:root/\($0).m4a") }
        let sent = await h.studio.startAuto(songs: songs, limit: 3)
        XCTAssertEqual(sent, 3)
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.studio.jobs.map(\.state), [.uploading, .uploading, .uploading])
        let started = await h.studio.startSing(song: songs[0])
        XCTAssertEqual(started, .started(1))
        let key = try XCTUnwrap(h.studio.job(forSong: songs[0].id)?.jobKey)
        await h.studio.handle(.uploaded(jobKey: key))
        await h.studio.pump()
        // The batch gate holds a batch for the songs prepared with it; a song somebody is waiting for does not wait.
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.compactMap(\.input.jobKey), [key])
        XCTAssertEqual(runs.first?.input.isLastInBatch, true)
        XCTAssertEqual(h.studio.job(key)?.state, .submitted)
    }

    // MARK: Settings

    func testPrepareAheadSettingsDefaultClampAndSurviveALaunch() throws {
        let suite = "cloud-auto-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CloudSettings(defaults: defaults, secrets: CloudMemorySecrets())
        XCTAssertFalse(settings.autoPrepareEnabled, "off until the person turns it on")
        XCTAssertEqual(settings.autoPrepareBudgetMicroUSD, 1_000_000)
        XCTAssertEqual(settings.autoPrepareDailyCap, 12)

        settings.autoPrepareEnabled = true
        settings.autoPrepareBudgetMicroUSD = 9_000_000
        XCTAssertEqual(settings.autoPrepareBudgetMicroUSD, settings.effectiveMonthlyCapMicroUSD, "never above the monthly cap")
        settings.autoPrepareBudgetMicroUSD = -5
        XCTAssertEqual(settings.autoPrepareBudgetMicroUSD, 0)
        settings.autoPrepareBudgetMicroUSD = 750_000
        settings.autoPrepareDailyCap = 99
        XCTAssertEqual(settings.autoPrepareDailyCap, 30)
        settings.autoPrepareDailyCap = 0
        XCTAssertEqual(settings.autoPrepareDailyCap, 1)
        settings.autoPrepareDailyCap = 7
        // A budget above a lowered cap counts as the cap where the guards read it.
        settings.monthlyCapMicroUSD = 500_000
        XCTAssertEqual(settings.effectiveAutoBudgetMicroUSD, 500_000)
        settings.monthlyCapMicroUSD = CloudCost.defaultMonthlyCapMicroUSD
        settings.updateAutoLedger(monthStartMs: 10, dayStartMs: 20) { $0.reserve(5) }

        let again = CloudSettings(defaults: defaults, secrets: CloudMemorySecrets())
        XCTAssertTrue(again.autoPrepareEnabled)
        XCTAssertEqual(again.autoPrepareBudgetMicroUSD, 750_000)
        XCTAssertEqual(again.autoPrepareDailyCap, 7)
        XCTAssertEqual(again.autoLedger, CloudAutoLedger(monthStartMs: 10, spentMicroUSD: 5, dayStartMs: 20, dayCount: 1))
        for key in ["cloud_studio_auto_enabled", "cloud_studio_auto_budget_micro_usd", "cloud_studio_auto_daily_cap",
                    "cloud_studio_auto_ledger"] {
            XCTAssertTrue(CloudSettings.Keys.all.contains(key), "\(key) must be one of the keys backups never carry")
        }
    }

    func testTheQueueSaysWhenAJobSteppedAsideAndWhenItWasPickedAhead() {
        var job = CloudHarness.storedRecord(1, song: "f:root/a.m4a", state: .uploaded, origin: .auto)
        job.pausedBy = "someone"
        XCTAssertEqual(CloudJobRowText.status(job, progress: nil), "Paused for a song you're singing")
        XCTAssertEqual(CloudJobRowText.detail(job), "Picked ahead of time because you may sing it soon.")
        job.pausedBy = nil
        XCTAssertEqual(CloudJobRowText.status(job, progress: nil), "Uploaded")
        // A song somebody asked for, or one that is done, carries no such line.
        job.origin = .sing
        XCTAssertNil(CloudJobRowText.detail(job))
        job.origin = .auto
        job.state = .imported
        XCTAssertNil(CloudJobRowText.detail(job))
    }

    // MARK: Preparing and uploading come first too

    func testTheSingJobIsDecodedAtFullSpeedAndUploadedFirstWhileAutoWorkYields() async throws {
        let h = CloudHarness()
        h.settings.useCellular = true
        let auto = h.addSong("f:root/auto.m4a")
        let sentAuto = await h.studio.startAuto(songs: [auto], limit: 1)
        XCTAssertEqual(sentAuto, 1)
        let batch = ["m1", "m2"].map { h.addSong("f:root/\($0).m4a") }
        await h.studio.send(await h.studio.preview(songs: batch, title: "Two"))
        let singKey = try await h.singJobPrepared(h.addSong("f:root/sing.m4a"))
        await h.studio.pump()
        await h.studio.settle()

        let autoKey = try XCTUnwrap(h.studio.job(forSong: auto.id)?.jobKey)
        let batchKeys = batch.compactMap { h.studio.job(forSong: $0.id)?.jobKey }
        XCTAssertEqual(batchKeys.count, 2)
        let paced = h.preparer.pacedByJob
        XCTAssertEqual(paced[singKey], false, "somebody is waiting for it: no duty cycle")
        XCTAssertEqual(paced[autoKey], true)
        for key in batchKeys { XCTAssertEqual(paced[key], true) }

        let priorities = h.transfers.priorities
        XCTAssertEqual(priorities[singKey], 1.0)
        XCTAssertEqual(priorities[autoKey], 0.3)
        for key in batchKeys { XCTAssertEqual(priorities[key], 0.5) }

        // Songs prepared ahead never use mobile data, whatever the switch says.
        XCTAssertEqual(h.transfers.uploadAllowedCellular[autoKey], false)
        XCTAssertEqual(h.transfers.uploadAllowedCellular[singKey], true)
        for key in batchKeys { XCTAssertEqual(h.transfers.uploadAllowedCellular[key], true) }
    }

    // MARK: Prepared ahead: quiet, patient, and inside its own budget

    func testSongsPreparedAheadAskForNoPermissionAndAnnounceNothing() async throws {
        let notifier = FakeCloudNotifier()
        let h = CloudHarness(notifier: notifier)
        let a = h.addSong("f:root/a.m4a")
        let sent = await h.studio.startAuto(songs: [a], limit: 1)
        XCTAssertEqual(sent, 1)
        await h.studio.pump()
        await h.studio.settle()
        let key = try XCTUnwrap(h.studio.job(forSong: a.id)?.jobKey)
        await h.studio.handle(.uploaded(jobKey: key))
        await h.studio.pump()
        try await finishAndImport(h, key: key, runpodId: "rp-1")
        XCTAssertEqual(h.studio.job(key)?.state, .imported)
        XCTAssertEqual(notifier.permissionRequests, 0)

        // The same flow for a song somebody asked for is announced (and asks for the permission once).
        let b = h.addSong("f:root/b.m4a")
        let started = await h.studio.startNow(songs: [b], title: "Test")
        XCTAssertEqual(started, .started(1))
        await h.studio.pump()
        await h.studio.settle()
        let manualKey = try XCTUnwrap(h.studio.job(forSong: b.id)?.jobKey)
        await h.studio.handle(.uploaded(jobKey: manualKey))
        await h.studio.pump()
        try await finishAndImport(h, key: manualKey, runpodId: "rp-2")
        await h.waitUntil { notifier.outcomes.count == 1 && notifier.permissionRequests == 1 }
        XCTAssertEqual(notifier.permissionRequests, 1)
        XCTAssertEqual(notifier.outcomes.count, 1, "only the song somebody asked for is announced")
    }

    func testAnAutoBatchIsOneBurstWithOneLast() async throws {
        let h = CloudHarness()
        let songs = ["a", "b", "c"].map { h.addSong("f:root/\($0).m4a") }
        let sent = await h.studio.startAuto(songs: songs, limit: 3)
        XCTAssertEqual(sent, 3)
        XCTAssertEqual(h.studio.jobs.map(\.origin), [.auto, .auto, .auto])
        await h.studio.pump()
        await h.studio.settle()
        for key in h.studio.jobs.map(\.jobKey) { await h.studio.handle(.uploaded(jobKey: key)) }
        await h.studio.pump()
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.map(\.input.isLastInBatch), [false, false, true])
    }

    func testAutoPrepareOnlyAsksForTheInstrumentalNotForLyricsAlone() async throws {
        let h = CloudHarness()
        let hasOne = h.addSong("f:root/has.m4a")
        let lacks = h.addSong("f:root/lacks.m4a")
        h.host.instrumentals.insert(hasOne.id)
        let sent = await h.studio.startAuto(songs: [hasOne, lacks], limit: 3)
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(h.studio.jobs.map(\.songId), [lacks.id])
        XCTAssertTrue(h.studio.jobs[0].tasks.contains(.instrumental))
    }

    func testAnAutoJobWaitsForAPhoneThatIsReadyInsteadOfFailing() async throws {
        let h = CloudHarness()
        h.phone.goOffWiFi()
        let a = h.addSong("f:root/a.m4a")
        let sent = await h.studio.startAuto(songs: [a], limit: 1)
        XCTAssertEqual(sent, 1)
        await h.studio.pump()
        await h.studio.settle()
        let key = try XCTUnwrap(h.studio.job(forSong: a.id)?.jobKey)
        XCTAssertEqual(h.studio.job(key)?.state, .queued, "nothing starts off Wi-Fi")
        XCTAssertTrue(h.preparer.prepared.isEmpty)
        XCTAssertEqual(h.studio.job(key)?.attempts, 0)
        XCTAssertNil(h.studio.job(key)?.lastError)

        h.phone.goOnWiFi()
        h.studio.wakeAutoJobs()
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.preparer.prepared, [key])
        XCTAssertEqual(h.studio.job(key)?.state, .uploading)
    }

    func testAnAutoJobWhosePhoneStopsBeingReadyHalfWayIsDeferredNotFailed() async throws {
        let h = CloudHarness()
        let a = h.addSong("f:root/a.m4a")
        let sent = await h.studio.startAuto(songs: [a], limit: 1)
        XCTAssertEqual(sent, 1)
        // The audio comes down, and the phone leaves Wi-Fi while it does.
        h.host.whileAudioComesDown = { h.phone.goOffWiFi() }
        await h.studio.pump()
        await h.studio.settle()
        let key = try XCTUnwrap(h.studio.job(forSong: a.id)?.jobKey)
        let job = try XCTUnwrap(h.studio.job(key))
        XCTAssertEqual(job.state, .queued)
        XCTAssertEqual(job.attempts, 0, "not a failure")
        XCTAssertNil(job.lastError)
        XCTAssertEqual(job.nextAttemptAtMs, h.clock.ms + CloudTiming.autoDeferMs)
        XCTAssertTrue(h.preparer.prepared.isEmpty)

        h.host.whileAudioComesDown = nil
        h.phone.goOnWiFi()
        h.studio.wakeAutoJobs()
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.preparer.prepared, [key])
    }

    func testAnAutoResultWaitsForWiFiToComeDown() async throws {
        let h = CloudHarness()
        h.settings.useCellular = true
        let a = h.addSong("f:root/a.m4a")
        let sent = await h.studio.startAuto(songs: [a], limit: 1)
        XCTAssertEqual(sent, 1)
        await h.studio.pump()
        await h.studio.settle()
        let key = try XCTUnwrap(h.studio.job(forSong: a.id)?.jobKey)
        await h.studio.handle(.uploaded(jobKey: key))
        await h.studio.pump()
        h.phone.goOffWiFi()
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "COMPLETED", result: h.finish(key)))
        h.clock.advance(16_000)
        await h.studio.pump()
        XCTAssertEqual(h.studio.job(key)?.state, .resultsReady, "the result stays at RunPod's side until Wi-Fi is back")
        XCTAssertTrue(h.transfers.downloads.isEmpty)
        h.phone.goOnWiFi()
        h.studio.wakeAutoJobs()
        await h.studio.pump()
        XCTAssertEqual(h.studio.job(key)?.state, .downloading)
        XCTAssertEqual(h.transfers.downloadAllowedCellular[key], false)
    }

    func testTheAutoLedgerReservesAtSendSettlesWithTheRealCostAndSurvivesClearingFinished() async throws {
        let h = CloudHarness()
        let a = h.addSong("f:root/a.m4a")
        let sent = await h.studio.startAuto(songs: [a], limit: 1)
        XCTAssertEqual(sent, 1)
        await h.studio.pump()
        await h.studio.settle()
        let key = try XCTUnwrap(h.studio.job(forSong: a.id)?.jobKey)
        XCTAssertEqual(h.studio.autoLedger.spentMicroUSD, 0, "nothing is reserved before RunPod has the job")

        await h.studio.handle(.uploaded(jobKey: key))
        await h.studio.pump()
        let record = try XCTUnwrap(h.studio.job(key))
        let estimate = CloudCost.estimatedSeconds(record.plan, quality: record.quality) * h.settings.effectivePricePerSecondMicroUSD
        XCTAssertEqual(record.autoReservedMicroUSD, estimate)
        XCTAssertEqual(h.studio.autoLedger.spentMicroUSD, estimate)
        XCTAssertEqual(h.studio.autoLedger.dayCount, 1)

        // The result lands: the real cost (cold start + run) replaces the estimate.
        try await finishAndImport(h, key: key, runpodId: "rp-1")
        XCTAssertEqual(h.studio.job(key)?.state, .imported)
        let actual: Int64 = (18_000 + 20_000) * 192 / 1000
        XCTAssertEqual(h.studio.autoLedger.spentMicroUSD, actual)
        XCTAssertEqual(h.studio.autoLedger.dayCount, 1)
        XCTAssertNil(h.studio.job(key)?.autoReservedMicroUSD)

        // Clearing the list cannot make room: the ledger is not the list.
        h.studio.clearAllFinished()
        XCTAssertTrue(h.studio.jobs.isEmpty)
        XCTAssertEqual(h.studio.autoLedger.spentMicroUSD, actual)

        // Today's count and the month's budget both stop a new batch.
        let b = h.addSong("f:root/b.m4a")
        h.settings.autoPrepareDailyCap = 1
        let dayFull = await h.studio.startAuto(songs: [b], limit: 1)
        XCTAssertEqual(dayFull, 0, "one song today is the cap")
        h.settings.autoPrepareDailyCap = 12
        h.settings.autoPrepareBudgetMicroUSD = actual
        let monthFull = await h.studio.startAuto(songs: [b], limit: 1)
        XCTAssertEqual(monthFull, 0, "the month's auto budget is used")
        h.settings.autoPrepareBudgetMicroUSD = CloudAutoBudget.defaultMonthlyMicroUSD
        let roomAgain = await h.studio.startAuto(songs: [b], limit: 1)
        XCTAssertEqual(roomAgain, 1)
    }

    func testAnAutoJobCancelledBeforeRunPodStartedItGivesItsReservationBack() async throws {
        let h = CloudHarness()
        let a = h.addSong("f:root/a.m4a")
        let sent = await h.studio.startAuto(songs: [a], limit: 1)
        XCTAssertEqual(sent, 1)
        await h.studio.pump()
        await h.studio.settle()
        let key = try XCTUnwrap(h.studio.job(forSong: a.id)?.jobKey)
        await h.studio.handle(.uploaded(jobKey: key))
        await h.studio.pump()
        XCTAssertGreaterThan(h.studio.autoLedger.spentMicroUSD, 0)
        await h.studio.cancelAutoJobs()
        XCTAssertEqual(h.studio.job(key)?.state, .cancelled)
        XCTAssertEqual(h.studio.autoLedger.spentMicroUSD, 0, "the money was never spent")
        XCTAssertEqual(h.studio.autoLedger.dayCount, 1, "but it still counts for today")
        let cancelled = await h.runpod.cancelled
        XCTAssertEqual(cancelled, ["rp-1"])
    }
}
