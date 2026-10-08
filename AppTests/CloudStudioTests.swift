import Foundation
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// Cloud Studio's orchestrator with fakes for everything outside it (design §7.6): the background session, the
/// preparer, RunPod, the bucket, the clock and the app. Nothing touches the network, the Keychain or `Stems/`.
@MainActor
final class CloudStudioTests: XCTestCase {
    // MARK: Happy path

    func testOneSongFromSendToImportAndCleanup() async throws {
        let h = CloudHarness()
        let song = h.addSong("f:root/a.m4a")
        h.host.facts[song.id] = CloudHarness.lineSyncedFacts

        let preview = await h.studio.preview(songs: [song], title: "Test")
        XCTAssertEqual(preview.plans.map(\.tasks), [[.instrumental, .lyrics]])
        XCTAssertTrue(preview.estimate.fitsCap)
        await h.studio.send(preview)
        await h.studio.pump()
        await h.studio.settle()

        // Prepared and handed to the background session as a presigned PUT.
        let key = try XCTUnwrap(h.studio.jobs.first?.jobKey)
        XCTAssertEqual(h.studio.job(key)?.state, .uploading)
        XCTAssertEqual(h.transfers.uploads.count, 1)
        XCTAssertTrue(h.transfers.uploads[0].url.contains("/in/\(key).flac?m=PUT"))
        XCTAssertEqual(h.preparer.prepared, [key])
        XCTAssertEqual(h.preparer.forcedDecode, [false], "a local AAC file may go up as it is")
        let noRunYet = await h.runpod.runs.count
        XCTAssertEqual(noRunYet, 0, "nothing goes to RunPod before the upload is done")

        // Upload done: the batch (of one) goes out with every URL the worker needs.
        await h.studio.handle(.uploaded(jobKey: key))
        await h.studio.pump()
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.count, 1)
        let input = try XCTUnwrap(runs.first?.input)
        XCTAssertEqual(input.jobKey, key)
        XCTAssertEqual(input.audio?.ext, "flac")
        XCTAssertEqual(input.audio?.sha256, CloudHarness.uploadSHA)
        XCTAssertEqual(input.lyrics?.mode, "align")
        XCTAssertEqual(input.lyrics?.lines?.first?.text, "hello world")
        XCTAssertEqual(input.guard?.attemptPut.contains("/out/\(key)/attempt.json"), true)
        XCTAssertEqual(runs.first?.policy, CloudJobPolicy(ttl: CloudTiming.ttlMs, executionTimeout: CloudTiming.executionTimeoutMs))
        // A single song is a burst of one: the worker stops itself after it instead of idling, billed.
        XCTAssertEqual(input.policy, CloudJobInputPolicy(lastInBatch: true))
        XCTAssertEqual(h.studio.job(key)?.state, .submitted)
        XCTAssertEqual(h.studio.job(key)?.runpodJobId, "rp-1")

        // RunPod finishes: lyrics import at once, the instrumental downloads in the background.
        let result = h.finish(key)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "COMPLETED", result: result))
        h.clock.advance(16_000)
        await h.studio.pump()
        XCTAssertEqual(h.host.savedLyrics.map { $0.songId }, [song.id])
        XCTAssertEqual(h.host.savedLyrics.first?.doc.lines.first?.syllables.map(\.text), ["hello ", "world"])
        XCTAssertEqual(h.studio.job(key)?.state, .downloading)
        XCTAssertEqual(h.transfers.downloads.map { $0.slot }, ["instrumental"])

        // The download is checked and moved into Stems/; the bucket is emptied.
        await h.studio.handle(.downloaded(jobKey: key, slot: "instrumental", stagedFile: try h.stagedInstrumental()))
        let job = try XCTUnwrap(h.studio.job(key))
        XCTAssertEqual(job.state, .imported)
        XCTAssertTrue(job.importedInstrumental && job.importedLyrics)
        XCTAssertEqual(h.host.installed.map { $0.songId }, [song.id])
        XCTAssertEqual(h.host.installed.first?.flac, false)
        XCTAssertEqual(job.costMicroUSD, (18_000 + 20_000) * 192 / 1000)
        for object in ["in/\(key).flac", "out/\(key)/instrumental.m4a", "out/\(key)/lyrics.json",
                       "out/\(key)/manifest.json", "out/\(key)/attempt.json"] {
            XCTAssertTrue(h.objects.deleted.contains(object), "\(object) was not deleted")
        }
        XCTAssertEqual(h.preparer.removed, [key], "the prepared upload is deleted after import")
        XCTAssertFalse(h.studio.hasPendingJob(songId: song.id))
    }

    func testResultsAreFoundInR2AfterStatusExpired() async throws {
        let h = CloudHarness()
        let key = try await h.submittedJob()
        // /status has forgotten the job (30 min); the manifest waits in the bucket.
        await h.runpod.setMissing("rp-1")
        h.store(manifest: h.finish(key))
        h.clock.advance(60 * 60_000)
        await h.studio.pump()
        XCTAssertEqual(h.studio.job(key)?.state, .downloading)
    }

    func testAnEarlierAttemptsManifestIsNotTaken() async throws {
        let h = CloudHarness()
        let key = try await h.submittedJob()
        await h.runpod.setMissing("rp-1")
        // The bucket still holds a manifest from an attempt with another input (the song was prepared again).
        var stale = h.finish(key)
        stale.input = CloudInputInfo(codec: "flac", sampleRate: 44_100, channels: 2,
                                     decodedSamples: CloudTestValues.sourceFrames, durationMs: 240_000,
                                     sha256: String(repeating: "0", count: 64))
        h.store(manifest: stale)
        h.clock.advance(60 * 60_000)
        await h.studio.pump()
        // The bucket shows the worker has the job, but another input's results are not imported.
        XCTAssertEqual(h.studio.job(key)?.state.isAtRunPod, true, "\(String(describing: h.studio.job(key)?.state))")
        XCTAssertTrue(h.host.savedLyrics.isEmpty)
        // This upload's manifest arrives: it is taken.
        var fresh = h.finish(key)
        fresh.input = CloudInputInfo(codec: "flac", sampleRate: 44_100, channels: 2,
                                     decodedSamples: CloudTestValues.sourceFrames, durationMs: 240_000,
                                     sha256: CloudHarness.uploadSHA)
        h.store(manifest: fresh)
        h.clock.advance(60 * 60_000)
        await h.studio.pump()
        XCTAssertEqual(h.studio.job(key)?.state, .downloading)
    }

    // MARK: Guards

    func testASongOverTheEndpointsLimitsStopsBeforeUpload() async throws {
        let h = CloudHarness()
        // The last selftest said this endpoint takes songs up to 3 minutes; the prepared song is 4.
        h.settings.workerCaps = CloudWorkerCaps(maxInputMB: 160, maxAudioS: 180, hostsConfigured: 1)
        let song = h.addSong("f:root/a.m4a")
        h.host.facts[song.id] = CloudHarness.lineSyncedFacts
        await h.studio.send(await h.studio.preview(songs: [song], title: "Test"))
        await h.studio.pump()
        await h.studio.settle()
        let key = try XCTUnwrap(h.studio.jobs.first?.jobKey)
        XCTAssertEqual(h.studio.job(key)?.state, .failed)
        XCTAssertEqual(h.studio.job(key)?.lastError?.contains("3-minute"), true)
        XCTAssertTrue(h.transfers.uploads.isEmpty, "nothing is uploaded")
        XCTAssertTrue(h.preparer.removed.contains(key), "the prepared file is deleted")
        let runs = await h.runpod.runs.count
        XCTAssertEqual(runs, 0)
    }

    func testNothingIsSentWithoutConsent() async {
        let h = CloudHarness()
        h.settings.isEnabled = false
        let song = h.addSong("f:root/a.m4a")
        let preview = await h.studio.preview(songs: [song], title: "Test")
        await h.studio.send(preview)
        await h.studio.pump()
        XCTAssertTrue(h.studio.jobs.isEmpty)
        XCTAssertEqual(h.studio.notice, .off)
        XCTAssertTrue(h.transfers.uploads.isEmpty)
    }

    func testTheMonthlyCapStopsSubmissions() async throws {
        let h = CloudHarness()
        let song = h.addSong("f:root/a.m4a")
        h.settings.monthlyCapMicroUSD = 1
        let tooBig = await h.studio.preview(songs: [song], title: "Test")
        XCTAssertFalse(tooBig.estimate.fitsCap)
        await h.studio.send(tooBig)
        XCTAssertTrue(h.studio.jobs.isEmpty, "a batch over the cap can't be sent")

        h.settings.monthlyCapMicroUSD = CloudCost.defaultMonthlyCapMicroUSD
        await h.studio.send(await h.studio.preview(songs: [song], title: "Test"))
        await h.studio.pump()
        await h.studio.settle()
        let key = try XCTUnwrap(h.studio.jobs.first?.jobKey)
        // The cap is lowered before the upload finishes: the job waits instead of going out.
        h.settings.monthlyCapMicroUSD = 1
        await h.studio.handle(.uploaded(jobKey: key))
        await h.studio.pump()
        let runs = await h.runpod.runs.count
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(h.studio.notice, .capReached)
        XCTAssertEqual(h.studio.job(key)?.state, .uploaded)
    }

    func testABatchWaitsForAllItsUploads() async throws {
        let h = CloudHarness()
        let a = h.addSong("f:root/a.m4a"), b = h.addSong("f:root/b.m4a")
        await h.studio.send(await h.studio.preview(songs: [a, b], title: "Two"))
        await h.studio.pump()
        await h.studio.settle()
        let keys = h.studio.jobs.map(\.jobKey)
        XCTAssertEqual(keys.count, 2)
        await h.studio.handle(.uploaded(jobKey: keys[0]))
        await h.studio.pump()
        var runs = await h.runpod.runs.count
        XCTAssertEqual(runs, 0, "the gate holds the first song while the second uploads")
        // Two minutes after the first upload the gate opens anyway.
        h.clock.advance(CloudTiming.batchGateMs + 1)
        await h.studio.pump()
        runs = await h.runpod.runs.count
        XCTAssertEqual(runs, 1)
    }

    // MARK: Idle workers (last_in_batch)

    /// Three songs sent, prepared and handed to the background session; their uploads not yet finished.
    private func threeUploadingJobs(_ h: CloudHarness) async -> [String] {
        let songs = ["a", "b", "c"].map { h.addSong("f:root/\($0).m4a") }
        await h.studio.send(await h.studio.preview(songs: songs, title: "Three"))
        await h.studio.pump()
        await h.studio.settle()
        return h.studio.jobs.map(\.jobKey)
    }

    func testOnlyTheLastJobOfABurstAsksTheWorkerToStop() async throws {
        let h = CloudHarness()
        let keys = await threeUploadingJobs(h)
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(h.studio.jobs.map(\.state), [.uploading, .uploading, .uploading])
        for key in keys { await h.studio.handle(.uploaded(jobKey: key)) }
        await h.studio.pump()
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.compactMap(\.input.jobKey), keys, "one burst, in queue order")
        // The worker stays warm between the songs and stops itself after the last one.
        XCTAssertEqual(runs.map(\.input.policy), [nil, nil, CloudJobInputPolicy(lastInBatch: true)])
        XCTAssertEqual(h.studio.jobs.map(\.state), [.submitted, .submitted, .submitted])
    }

    func testAJobSentLaterIsTheLastOfItsOwnBurst() async throws {
        let h = CloudHarness()
        let a = h.addSong("f:root/a.m4a"), b = h.addSong("f:root/b.m4a")
        await h.studio.send(await h.studio.preview(songs: [a, b], title: "Two"))
        await h.studio.pump()
        await h.studio.settle()
        let keys = h.studio.jobs.map(\.jobKey)
        await h.studio.handle(.uploaded(jobKey: keys[0]))
        h.clock.advance(CloudTiming.batchGateMs + 1)
        await h.studio.pump()
        // The gate let the first song go alone; the second follows when its upload is done.
        await h.studio.handle(.uploaded(jobKey: keys[1]))
        await h.studio.pump()
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.compactMap(\.input.jobKey), keys)
        XCTAssertEqual(runs.map(\.input.isLastInBatch), [true, true])
    }

    func testTheCapEndsABurstWithTheLastJobThatWentOut() async throws {
        let h = CloudHarness()
        let keys = await threeUploadingJobs(h)
        XCTAssertEqual(keys.count, 3)
        // Room for two songs this month: the third waits, and the second is the burst's last.
        let record = try XCTUnwrap(h.studio.job(keys[0]))
        let estimate = CloudCost.estimatedSeconds(record.plan, quality: record.quality) * h.settings.pricePerSecondMicroUSD
        h.settings.monthlyCapMicroUSD = 2 * estimate
        for key in keys { await h.studio.handle(.uploaded(jobKey: key)) }
        await h.studio.pump()
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.compactMap(\.input.jobKey), Array(keys.prefix(2)))
        XCTAssertEqual(runs.map(\.input.isLastInBatch), [false, true])
        XCTAssertEqual(h.studio.notice, .capReached)
        XCTAssertEqual(h.studio.job(keys[2])?.state, .uploaded)
    }

    // MARK: Worker errors

    func testInputMissingUploadsAgain() async throws {
        let h = CloudHarness()
        let key = try await h.submittedJob()
        let error = CloudJobResult(jobKey: key, status: .error, error: CloudResultError(code: "INPUT_MISSING", message: "404"))
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "FAILED", result: error, error: "INPUT_MISSING: 404"))
        h.clock.advance(16_000)
        await h.studio.pump()
        let job = try XCTUnwrap(h.studio.job(key))
        XCTAssertEqual(job.state, .queued)
        XCTAssertEqual(job.lastErrorCode, "INPUT_MISSING")
        XCTAssertEqual(job.attempts, 1)
        // After the first rung of the ladder it is prepared and uploaded again.
        h.clock.advance(CloudTiming.backoffLadderMs[0] + 1)
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.preparer.prepared, [key, key])
        XCTAssertEqual(h.studio.job(key)?.state, .uploading)
    }

    func testARetryableWorkerErrorGoesOutAgainWithoutRereadingTheOldManifest() async throws {
        let h = CloudHarness()
        let key = try await h.submittedJob()
        // The worker ran out of GPU memory: its error manifest stays in the bucket (the worker never clears it).
        h.store(manifest: CloudJobResult(jobKey: key, status: .error,
                                         error: CloudResultError(code: "GPU_OOM", message: "CUDA out of memory")))
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "FAILED", error: "GPU_OOM: CUDA out of memory"))
        h.clock.advance(16_000)
        await h.studio.pump()
        XCTAssertEqual(h.studio.job(key)?.state, .uploaded, "sent again from the upload already in the bucket")
        XCTAssertEqual(h.studio.job(key)?.attempts, 1)
        // After the first rung it goes out again, and the earlier run's manifest and marker are cleared first.
        h.clock.advance(CloudTiming.backoffLadderMs[0] + 1)
        await h.studio.pump()
        var runs = await h.runpod.runs.count
        XCTAssertEqual(runs, 2)
        XCTAssertTrue(h.objects.deleted.contains("out/\(key)/manifest.json"))
        XCTAssertTrue(h.objects.deleted.contains("out/\(key)/attempt.json"))
        // The next listings find no old error to take: the job waits for its new run instead of being sent again.
        for _ in 0..<2 {
            h.clock.advance(16_000)
            await h.studio.pump()
        }
        XCTAssertEqual(h.studio.job(key)?.state, .submitted)
        XCTAssertEqual(h.studio.job(key)?.runpodJobId, "rp-2")
        XCTAssertEqual(h.studio.job(key)?.attempts, 1)
        runs = await h.runpod.runs.count
        XCTAssertEqual(runs, 2)
    }

    func testTransferEventsAfterARelaunchKeepTheStoredJobs() async throws {
        // A job an earlier launch saved, its upload still with the system's transfer daemon.
        let key = CloudHarness.key(7)
        var record = CloudJobRecord(jobKey: key, songId: "f:root/a.m4a", title: "A", artist: "B", batchId: "b",
                                    tasks: [.instrumental], lyricsMode: nil, quality: .standard, createdAtMs: 1_000)
        record.state = .uploading
        record.inputExt = "flac"
        record.sha256 = CloudHarness.uploadSHA
        record.bytes = 1_024
        record.durationMs = 240_000
        record.decodedFrames = CloudHarness.sourceFrames
        record.sampleRate = 44_100
        let store = CloudJobStore(file: nil)
        await store.save([record])
        let h = CloudHarness(store: store)
        h.addSong("f:root/a.m4a")
        // iOS relaunches the app for the transfer session: the upload's event arrives before any pass has run.
        await h.studio.handle(.uploaded(jobKey: key))
        XCTAssertEqual(h.studio.job(key)?.state, .uploaded, "the event found its stored job")
        await h.studio.pump()
        XCTAssertEqual(h.studio.job(key)?.state, .submitted)
        let stored = await store.load(nowMs: h.clock.ms)
        XCTAssertEqual(stored.map(\.jobKey), [key], "the stored list was never replaced by an empty one")
    }

    func testAPoisonedJobStopsAndEmptiesTheBucket() async throws {
        let h = CloudHarness()
        let key = try await h.submittedJob()
        h.store(manifest: CloudJobResult(jobKey: key, status: .error,
                                         error: CloudResultError(code: "POISONED", message: "third delivery")))
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "FAILED", error: "POISONED: third delivery"))
        h.clock.advance(16_000)
        await h.studio.pump()
        await Task.yield()
        let job = try XCTUnwrap(h.studio.job(key))
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.lastErrorCode, "POISONED")
        await h.waitUntil { h.objects.deleted.contains("in/\(key).flac") }
        XCTAssertTrue(h.objects.deleted.contains("in/\(key).flac"))
        // Retry starts it over from the upload.
        h.studio.retry(key)
        XCTAssertEqual(h.studio.job(key)?.state, .queued)
        XCTAssertEqual(h.studio.job(key)?.attempts, 0)
    }

    func testALostJobIsSentOnceMoreThenExpires() async throws {
        let h = CloudHarness()
        let key = try await h.submittedJob()
        // /status forgets it and no manifest ever appears: once its ttl has passed, it is lost.
        await h.runpod.setMissing("rp-1")
        h.clock.advance(CloudTiming.ttlMs + CloudTiming.executionTimeoutMs + 1)
        await h.studio.pump()
        XCTAssertEqual(h.studio.job(key)?.resubmits, 1)
        XCTAssertEqual(h.studio.job(key)?.state, .uploaded)
        // The input is older than 3 days by now, so it is prepared and uploaded again before it goes out once more.
        await h.studio.pump()
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.studio.job(key)?.state, .uploading)
        await h.studio.handle(.uploaded(jobKey: key))
        await h.studio.pump()
        let runs = await h.runpod.runs.count
        XCTAssertEqual(runs, 2)
        XCTAssertEqual(h.studio.job(key)?.runpodJobId, "rp-2")
        // Lost a second time: expired, and the bucket is emptied.
        await h.runpod.setMissing("rp-2")
        h.clock.advance(CloudTiming.ttlMs + CloudTiming.executionTimeoutMs + 1)
        await h.studio.pump()
        XCTAssertEqual(h.studio.job(key)?.state, .expired)
        XCTAssertTrue(h.objects.deleted.contains("in/\(key).flac"))
    }

    // MARK: Import checks

    func testADamagedDownloadIsFetchedAgain() async throws {
        let h = CloudHarness()
        let key = try await h.submittedJob()
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "COMPLETED", result: h.finish(key)))
        h.clock.advance(16_000)
        await h.studio.pump()
        await h.studio.handle(.downloaded(jobKey: key, slot: "instrumental",
                                          stagedFile: try h.stagedInstrumental(Data("not the result".utf8))))
        let job = try XCTUnwrap(h.studio.job(key))
        XCTAssertEqual(job.state, .resultsReady)
        XCTAssertEqual(job.attempts, 1)
        XCTAssertTrue(h.host.installed.isEmpty)
        h.clock.advance(CloudTiming.backoffLadderMs[0] + 1)
        await h.studio.pump()
        XCTAssertEqual(h.transfers.downloads.count, 2)
    }

    func testAnInstrumentalThatDoesntLineUpIsRedoneAsFlac() async throws {
        let h = CloudHarness()
        let key = try await h.submittedJob()
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "COMPLETED", result: h.finish(key)))
        h.clock.advance(16_000)
        await h.studio.pump()
        // This phone decodes the AAC 3,000 frames longer than the source (priming not honoured).
        h.inspector.decodedFrames = CloudHarness.sourceFrames + 3_000
        await h.studio.handle(.downloaded(jobKey: key, slot: "instrumental", stagedFile: try h.stagedInstrumental()))
        let job = try XCTUnwrap(h.studio.job(key))
        // Back to the start (a pass may already be preparing it again).
        XCTAssertTrue([.queued, .preparing, .uploading].contains(job.state), "\(job.state)")
        XCTAssertEqual(job.outputCodec, .flac)
        XCTAssertTrue(job.flacRedone)
        XCTAssertEqual(job.tasks, [.instrumental], "the lyrics were already imported")
        XCTAssertTrue(h.host.installed.isEmpty)
        await h.waitUntil { h.objects.deleted.contains("out/\(key)/instrumental.m4a") }
        XCTAssertTrue(h.objects.deleted.contains("out/\(key)/instrumental.m4a"), "the AAC result is removed")
    }

    func testAChangedYouTubeMatchIsNotImported() async throws {
        let h = CloudHarness()
        let song = h.addSong("sp:4uLU6hMCjMI75M1A2tKUQC", contentUri: "spotify://4uLU6hMCjMI75M1A2tKUQC")
        h.host.identity[song.id] = "dQw4w9WgXcQ"
        let key = try await h.submittedJob(song: song)
        XCTAssertEqual(h.studio.job(key)?.videoId, "dQw4w9WgXcQ")
        XCTAssertEqual(h.preparer.forcedDecode, [true], "a streamed song's download always goes up as FLAC")
        h.host.identity[song.id] = "9bZkp7q19f0"
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "COMPLETED", result: h.finish(key)))
        h.clock.advance(16_000)
        await h.studio.pump()
        XCTAssertEqual(h.studio.job(key)?.state, .failed)
        XCTAssertTrue(h.host.savedLyrics.isEmpty)
    }

    // MARK: Person's actions

    func testCancelStopsEverything() async throws {
        let h = CloudHarness()
        let key = try await h.submittedJob()
        await h.studio.cancel(key)
        XCTAssertEqual(h.studio.job(key)?.state, .cancelled)
        XCTAssertEqual(h.transfers.cancelled, [key])
        let cancelled = await h.runpod.cancelled
        XCTAssertEqual(cancelled, ["rp-1"])
        XCTAssertTrue(h.objects.deleted.contains("in/\(key).flac"))
    }

    func testSongsWithEverythingAreSkipped() async {
        let h = CloudHarness()
        let done = h.addSong("f:root/done.m4a")
        h.host.instrumentals.insert(done.id)
        h.host.facts[done.id] = CloudLyricsFacts(state: .wordSynced, lines: nil, hasLineTimes: true,
                                                 referenceDurationMs: nil, language: nil)
        let long = h.addSong("f:root/long.m4a", durationMs: 16 * 60_000)
        let preview = await h.studio.preview(songs: [done, long], title: "Test")
        XCTAssertTrue(preview.isEmpty)
        XCTAssertEqual(Set(preview.skipped.map(\.reason)), [.alreadyDone, .tooLong])
    }

    // MARK: Storage and backups

    func testJobStoreKeepsJobsAcrossLaunches() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var record = CloudJobRecord(jobKey: CloudHarness.key(1), songId: "f:a", title: "A", artist: "B", batchId: "b",
                                    tasks: [.instrumental], lyricsMode: nil, quality: .standard, createdAtMs: 1_000)
        record.state = .submitted
        record.runpodJobId = "rp-9"
        var old = CloudJobRecord(jobKey: CloudHarness.key(2), songId: "f:b", title: "B", artist: "C", batchId: "b",
                                 tasks: [.instrumental], lyricsMode: nil, quality: .standard, createdAtMs: 1_000)
        old.state = .imported
        old.importedAtMs = 1_000
        await CloudJobStore(file: file).save([record, old])
        let loaded = await CloudJobStore(file: file).load(nowMs: 1_000 + CloudRetention.keepImportedMs + 1)
        XCTAssertEqual(loaded, [record], "imported jobs older than 30 days are pruned")
    }

    func testCloudKeysNeverReachABackup() throws {
        let suite = "cloud-backup-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CloudSettings(defaults: defaults, secrets: CloudMemorySecrets())
        settings.isEnabled = true
        settings.endpointId = "abc123xyz"
        settings.r2Endpoint = "0123456789abcdef0123456789abcdef"
        settings.bucket = "pixl-cloud-studio"
        settings.monthlyCapMicroUSD = 5_000_000
        let exported = SettingsBackup.exportValues(defaults: defaults, keychain: { account in
            CloudKeychain.accounts.contains(account) ? "SECRET" : nil
        })
        let keys = Set(exported.map(\.key))
        for key in CloudSettings.Keys.all + CloudKeychain.accounts {
            XCTAssertFalse(keys.contains(key), "\(key) would be exported")
            XCTAssertFalse(SettingsBackup.isKeychainKey(key), "\(key) looks like an exported key")
        }
    }

    func testWorkerCapsAreKeptUntilTheEndpointChanges() throws {
        let suite = "cloud-caps-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CloudSettings(defaults: defaults, secrets: CloudMemorySecrets())
        XCTAssertNil(settings.workerCaps, "unknown until a selftest ran")
        settings.endpointId = "abc123xyz"
        let caps = CloudWorkerCaps(maxInputMB: 120, maxAudioS: 600, bestMaxAudioS: 480, hostsConfigured: 1)
        settings.workerCaps = caps
        XCTAssertEqual(CloudSettings(defaults: defaults, secrets: CloudMemorySecrets()).workerCaps, caps,
                       "kept across launches")
        settings.endpointId = "abc123xyz"
        XCTAssertEqual(settings.workerCaps, caps, "the same endpoint keeps them")
        settings.endpointId = "other999"
        XCTAssertNil(settings.workerCaps, "another endpoint's limits are unknown")
        XCTAssertNil(CloudSettings(defaults: defaults, secrets: CloudMemorySecrets()).workerCaps)
    }

    func testCloudSettingsDefaults() throws {
        let suite = "cloud-settings-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CloudSettings(defaults: defaults, secrets: CloudMemorySecrets())
        XCTAssertFalse(settings.isEnabled, "off until the person switches it on")
        XCTAssertEqual(settings.bucket, "pixl-cloud-studio")
        XCTAssertFalse(settings.useCellular)
        XCTAssertEqual(settings.monthlyCapMicroUSD, 3_000_000)
        XCTAssertEqual(settings.pricePerSecondMicroUSD, 192)
        XCTAssertEqual(settings.quality, .standard)
        XCTAssertTrue(settings.wantsInstrumental && settings.wantsLyrics && settings.transcribeWhenMissing)
    }

    func testLyricsFactsFromStoredLyrics() {
        let none = LiveCloudStudioHost.facts(lyrics: nil, userSynced: false)
        XCTAssertEqual(none.state, .none)
        let lines = Lyrics(plain: nil, synced: [SyncedLine(time: 1_000, line: "a"), SyncedLine(time: 2_000, line: "b")],
                           areFromRemote: false)
        let synced = LiveCloudStudioHost.facts(lyrics: lines, userSynced: false)
        XCTAssertEqual(synced.state, .textOrLineSynced)
        XCTAssertTrue(synced.hasLineTimes)
        XCTAssertEqual(synced.lines?.count, 2)
        XCTAssertEqual(LiveCloudStudioHost.facts(lyrics: lines, userSynced: true).state, .userSynced)
    }

    func testSampleCheckComparesAtTheWorkersRate() {
        var record = CloudJobRecord(jobKey: CloudHarness.key(1), songId: "f:a", title: "A", artist: "B", batchId: "b",
                                    tasks: [.instrumental], lyricsMode: nil, quality: .standard, createdAtMs: 0)
        record.decodedFrames = 441_000
        record.sampleRate = 44_100
        let output = CloudOutputFile(key: "k", bytes: 1, sha256: "a", codec: "aac", kbps: 256, sampleRate: 44_100,
                                     samples: 441_000)
        XCTAssertTrue(CloudStudio.samplesLineUp(record, output: output, decodedFrames: 441_500))
        XCTAssertFalse(CloudStudio.samplesLineUp(record, output: output, decodedFrames: 443_000))
        var shifted = output
        shifted.samples = 445_000
        XCTAssertFalse(CloudStudio.samplesLineUp(record, output: shifted, decodedFrames: 441_000))
    }
}

// MARK: - Harness

/// Values the fakes share (nonisolated: the fakes run off the main actor).
nonisolated enum CloudTestValues {
    static let uploadSHA = String(repeating: "ab", count: 32)
    static let sourceFrames: Int64 = 10_584_000
    static let lineSyncedFacts = CloudLyricsFacts(
        state: .textOrLineSynced, lines: [CloudLyricsInputLine(startMs: 1_000, endMs: 2_000, text: "hello world")],
        hasLineTimes: true, referenceDurationMs: nil, language: "en")
    static func key(_ n: Int) -> String { String(format: "6f1c2a9e-3b7d-4c11-9a0e-%012ld", n) }
}

@MainActor
final class CloudHarness {
    static let uploadSHA = CloudTestValues.uploadSHA
    static let sourceFrames = CloudTestValues.sourceFrames
    static let lineSyncedFacts = CloudTestValues.lineSyncedFacts
    static func key(_ n: Int) -> String { CloudTestValues.key(n) }

    let clock: CloudTestClock
    let host: FakeCloudHost
    let transfers: FakeCloudTransfers
    let preparer: FakeCloudPreparer
    let inspector: FakeCloudInspector
    let runpod: FakeRunPod
    let objects: FakeCloudObjects
    let settings: CloudSettings
    let studio: CloudStudio
    private let directory: URL
    private var nextKey = 100
    let instrumental = Data(repeating: 7, count: 4_096)

    /// `store`: a job list an earlier launch left (a relaunch); empty by default.
    init(store: CloudJobStore = CloudJobStore(file: nil)) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CloudHarness-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clock = CloudTestClock(), host = FakeCloudHost(), transfers = FakeCloudTransfers()
        let preparer = FakeCloudPreparer(directory: directory), inspector = FakeCloudInspector()
        let runpod = FakeRunPod(), objects = FakeCloudObjects()
        inspector.decodedFrames = CloudTestValues.sourceFrames
        let suite = "cloud-harness-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let settings = CloudSettings(defaults: defaults, secrets: CloudMemorySecrets(
            CloudSecrets(runpodKey: "rpa_TEST", accessKeyId: "AKID", secretAccessKey: "SECRET")))
        settings.isEnabled = true
        settings.endpointId = "abc123xyz"
        settings.r2Endpoint = "0123456789abcdef0123456789abcdef"
        var counter = 0
        let dependencies = CloudStudio.Dependencies(
            store: store, host: host, makeTransfers: { transfers }, preparer: preparer,
            inspector: inspector, makeRunPod: { _ in runpod }, makeObjects: { _ in objects },
            nowMs: { clock.ms }, monthStartMs: { _ in 0 },
            newJobKey: {
                counter += 1
                return CloudTestValues.key(counter)
            },
            build: "1.0 (test)", removeStaged: { _ in }, background: nil)
        self.directory = directory
        self.clock = clock
        self.host = host
        self.transfers = transfers
        self.preparer = preparer
        self.inspector = inspector
        self.runpod = runpod
        self.objects = objects
        self.settings = settings
        studio = CloudStudio(settings: settings, dependencies: dependencies)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func addSong(_ id: String, durationMs: Int64 = 240_000, contentUri: String? = nil) -> Song {
        let song = Song(id: id, title: "Song \(id)", artist: "Artist", artistId: 1, album: "Album", albumId: 1,
                        path: contentUri == nil ? "\(id).m4a" : "", contentUriString: contentUri ?? "file:///music/\(id).m4a",
                        albumArtUriString: nil, duration: durationMs, mimeType: nil, bitrate: nil, sampleRate: nil)
        host.songs[id] = song
        return song
    }

    /// One song sent, uploaded and submitted (RunPod job `rp-1`).
    func submittedJob(song: Song? = nil) async throws -> String {
        let song = song ?? addSong("f:root/a.m4a")
        if host.facts[song.id] == nil { host.facts[song.id] = Self.lineSyncedFacts }
        await studio.send(await studio.preview(songs: [song], title: "Test"))
        await studio.pump()
        await studio.settle()
        let key = try XCTUnwrap(studio.jobs.last?.jobKey)
        await studio.handle(.uploaded(jobKey: key))
        await studio.pump()
        XCTAssertEqual(studio.job(key)?.state, .submitted)
        return key
    }

    /// The worker's ok manifest for `key` (and its lyrics.json put in the bucket).
    func finish(_ key: String) -> CloudJobResult {
        let cloudLyrics = CloudLyricsDocument(mode: "aligned", language: "en", lines: [
            CloudLyricsLine(i: 0, startMs: 1_000, endMs: 2_000, text: "hello world", timing: "word",
                            words: [CloudLyricsWord(startMs: 1_000, endMs: 1_400, text: "hello", conf: nil, c0: 0, c1: 5),
                                    CloudLyricsWord(startMs: 1_500, endMs: 2_000, text: "world", conf: nil, c0: 6, c1: 11)]),
        ])
        let lyricsData = (try? CloudJSON.encode(cloudLyrics)) ?? Data()
        objects.set("out/\(key)/lyrics.json", lyricsData)
        return CloudJobResult(
            jobKey: key, status: .ok,
            worker: CloudWorkerInfo(version: "1.0.0", gitSha: "abc", gpu: "NVIDIA L4", vramGB: 24, cuda: "12.8"),
            outputs: ["instrumental": CloudOutputFile(key: "out/\(key)/instrumental.m4a", bytes: Int64(instrumental.count),
                                                      sha256: CloudPlatform.sha256Hex(instrumental), codec: "aac", kbps: 256,
                                                      sampleRate: 44_100, samples: Self.sourceFrames)],
            lyrics: CloudLyricsSummary(key: "out/\(key)/lyrics.json", bytes: Int64(lyricsData.count),
                                       sha256: CloudPlatform.sha256Hex(lyricsData), mode: "aligned", language: "en",
                                       lines: 1, wordTimedLines: 1, words: 2, offsetMs: 0),
            timings: CloudTimings(coldStartMs: 18_000, totalMs: 20_000))
    }

    func store(manifest: CloudJobResult) {
        objects.set(CloudKeys.manifest(jobKey: manifest.jobKey), (try? CloudJSON.encode(manifest)) ?? Data())
    }

    /// A downloaded result in a temporary file (the instrumental's bytes unless given).
    func stagedInstrumental(_ data: Data? = nil) throws -> URL {
        nextKey += 1
        let url = directory.appendingPathComponent("staged-\(nextKey).m4a")
        try (data ?? instrumental).write(to: url)
        return url
    }

    /// Lets detached cleanup tasks run.
    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

nonisolated final class CloudTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Int64 = 1_790_000_000_000
    var ms: Int64 { lock.withLock { now } }
    func advance(_ by: Int64) { lock.withLock { now += by } }
}

@MainActor
final class FakeCloudHost: CloudStudioHost {
    var songs: [String: Song] = [:]
    var current: Song?
    var facts: [String: CloudLyricsFacts] = [:]
    var instrumentals: Set<String> = []
    var identity: [String: String] = [:]
    var installed: [(songId: String, flac: Bool)] = []
    var savedLyrics: [(songId: String, doc: LyricsDoc)] = []
    var saveOutcome: CloudLyricsSaveOutcome = .saved

    func song(id: String) -> Song? { songs[id] }
    var currentSong: Song? { current }
    var librarySongs: [Song] { Array(songs.values).sorted { $0.id < $1.id } }
    func audioSource(for song: Song) async throws -> URL { URL(fileURLWithPath: "/music/\(song.id)") }
    func streamIdentity(for song: Song) async -> String? { identity[song.id] }
    func lyricsFacts(for song: Song) async -> CloudLyricsFacts { facts[song.id] ?? .none }
    func hasInstrumental(songId: String) async -> Bool { instrumentals.contains(songId) }

    func installInstrumental(from staged: URL, songId: String, flac: Bool) throws {
        installed.append((songId, flac))
        try? FileManager.default.removeItem(at: staged)
    }

    func saveLyrics(_ doc: LyricsDoc, for song: Song, replaceUserSynced: Bool) async -> CloudLyricsSaveOutcome {
        if saveOutcome == .saved { savedLyrics.append((song.id, doc)) }
        return saveOutcome
    }

    func instrumentalImported(songId: String) {}
    func lyricsImported(song: Song) {}
}

nonisolated final class FakeCloudTransfers: CloudTransferring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedUploads: [(jobKey: String, url: String)] = []
    private var storedDownloads: [(jobKey: String, slot: String)] = []
    private var storedCancelled: [String] = []
    var onEvent: (@Sendable (CloudTransferEvent) -> Void)?
    var onProgress: (@Sendable (_ jobKey: String, _ slot: String, _ fraction: Double) -> Void)?
    var allowsCellular = false

    var uploads: [(jobKey: String, url: String)] { lock.withLock { storedUploads } }
    var downloads: [(jobKey: String, slot: String)] { lock.withLock { storedDownloads } }
    var cancelled: [String] { lock.withLock { storedCancelled } }

    func upload(fileURL: URL, to url: URL, jobKey: String, contentType: String) {
        lock.withLock { storedUploads.append((jobKey, url.absoluteString)) }
    }

    func download(from url: URL, jobKey: String, slot: String) {
        lock.withLock { storedDownloads.append((jobKey, slot)) }
    }

    func cancel(jobKey: String) async { lock.withLock { storedCancelled.append(jobKey) } }
    func pendingTaskDescriptions() async -> [String] { [] }
}

nonisolated final class FakeCloudPreparer: CloudAudioPreparing, @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private var storedPrepared: [String] = []
    private var storedForced: [Bool] = []
    private var storedRemoved: [String] = []

    init(directory: URL) { self.directory = directory }

    var prepared: [String] { lock.withLock { storedPrepared } }
    /// `forceDecode` of each `prepare` call, in order.
    var forcedDecode: [Bool] { lock.withLock { storedForced } }
    var removed: [String] { lock.withLock { Array(Set(storedRemoved)).sorted() } }

    func prepare(source: URL, jobKey: String, forceDecode: Bool) async throws -> CloudPreparedAudio {
        let url = directory.appendingPathComponent("\(jobKey).flac")
        try Data(repeating: 1, count: 1_024).write(to: url)
        lock.withLock {
            storedPrepared.append(jobKey)
            storedForced.append(forceDecode)
        }
        return CloudPreparedAudio(fileURL: url, ext: "flac", bytes: 1_024, sha256: CloudTestValues.uploadSHA,
                                  durationMs: 240_000, frames: CloudTestValues.sourceFrames, sampleRate: 44_100,
                                  passthrough: false)
    }

    func removeUpload(jobKey: String) { lock.withLock { storedRemoved.append(jobKey) } }

    func uploadFile(jobKey: String, ext: String) -> URL? {
        let url = directory.appendingPathComponent("\(jobKey).\(ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

nonisolated final class FakeCloudInspector: CloudFileInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedFrames: Int64 = 0
    /// What this phone "decodes" from a downloaded result.
    var decodedFrames: Int64 {
        get { lock.withLock { storedFrames } }
        set { lock.withLock { storedFrames = newValue } }
    }

    func digest(_ url: URL) throws -> (sha256: String, bytes: Int64) { try CloudPlatform.fileDigest(url) }
    func frames(_ url: URL) async throws -> Int64 { decodedFrames }
    func sha256Hex(_ data: Data) -> String { CloudPlatform.sha256Hex(data) }
}

actor FakeRunPod: RunPodJobsAPI {
    private(set) var runs: [CloudJobRequest] = []
    private(set) var cancelled: [String] = []
    private var statuses: [String: RunPodJob] = [:]
    private var missing: Set<String> = []

    func setStatus(_ id: String, _ job: RunPodJob) {
        statuses[id] = job
        missing.remove(id)
    }

    func setMissing(_ id: String) {
        statuses[id] = nil
        missing.insert(id)
    }

    func run(_ request: CloudJobRequest) async throws -> RunPodJob {
        runs.append(request)
        let id = "rp-\(runs.count)"
        statuses[id] = RunPodJob(id: id, status: "IN_QUEUE")
        return RunPodJob(id: id, status: "IN_QUEUE")
    }

    func status(jobId: String) async throws -> RunPodJob {
        if missing.contains(jobId) { throw RunPodError.jobNotFound }
        guard let job = statuses[jobId] else { throw RunPodError.jobNotFound }
        return job
    }

    func cancel(jobId: String) async throws { cancelled.append(jobId) }
    func health() async throws -> RunPodHealth { RunPodHealth(idleWorkers: 1) }
    func selftest(build: String) async throws -> RunPodJob { RunPodJob(id: "s", status: "COMPLETED") }
}

nonisolated final class FakeCloudObjects: CloudObjectStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedObjects: [String: Data] = [:]
    private var storedDeleted: [String] = []

    var deleted: [String] { lock.withLock { storedDeleted } }

    func set(_ key: String, _ data: Data) { lock.withLock { storedObjects[key] = data } }

    func presignedURL(_ method: HTTPMethod, key: String, expiresSeconds: Int) -> String? {
        "https://r2.test/pixl-cloud-studio/\(key)?m=\(method.rawValue)&X-Amz-Expires=\(expiresSeconds)&X-Amz-Signature=t"
    }

    func head(key: String) async throws -> Int64? { lock.withLock { storedObjects[key].map { Int64($0.count) } } }
    func get(key: String) async throws -> Data? { lock.withLock { storedObjects[key] } }
    func put(key: String, data: Data, contentType: String) async throws { set(key, data) }

    func delete(key: String) async throws {
        lock.withLock {
            storedObjects[key] = nil
            storedDeleted.append(key)
        }
    }

    func list(prefix: String, delimiter: String?) async throws -> S3ListResult {
        let keys = lock.withLock { Array(storedObjects.keys) }.filter { $0.hasPrefix(prefix) }
        var prefixes = Set<String>()
        for key in keys {
            let rest = key.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") { prefixes.insert(prefix + String(rest[..<slash]) + "/") }
        }
        return S3ListResult(objects: [], commonPrefixes: prefixes.sorted(), isTruncated: false, nextContinuationToken: nil)
    }
}
