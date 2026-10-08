import Foundation
import Testing
import PixlModel
@testable import PixlNet

@Suite struct CloudQueuePolicyTests {
    static let key = "6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10"

    // MARK: Keys

    @Test func objectKeysFollowTheDesign() {
        #expect(CloudKeys.input(jobKey: Self.key, ext: "m4a") == "in/\(Self.key).m4a")
        #expect(CloudKeys.manifest(jobKey: Self.key) == "out/\(Self.key)/manifest.json")
        #expect(CloudKeys.attempt(jobKey: Self.key) == "out/\(Self.key)/attempt.json")
        #expect(CloudKeys.output(jobKey: Self.key, slot: "instrumental", ext: "m4a") == "out/\(Self.key)/instrumental.m4a")
        #expect(CloudKeys.jobKey(fromOutputKey: "out/\(Self.key)/lyrics.json") == Self.key)
        #expect(CloudKeys.jobKey(fromOutputKey: "out/not-a-key/x") == nil)
        #expect(CloudKeys.isValidJobKey(Self.key))
        #expect(!CloudKeys.isValidJobKey(Self.key.uppercased()))
        #expect(!CloudKeys.isValidJobKey("../" + Self.key.dropFirst(3)))
        #expect(CloudKeys.jobKey(uuid: "6F1C2A9E-3B7D-4C11-9A0E-2D5F8B7C4E10") == Self.key)
        #expect(CloudKeys.contentType(ext: "flac") == "audio/flac")
    }

    // MARK: State machine

    @Test func happyPathWalksEveryState() {
        var state = CloudJobState.queued
        let path: [(CloudJobEvent, CloudJobState)] = [
            (.prepareStarted, .preparing), (.prepared, .uploading), (.uploadFinished, .uploaded), (.submitted, .submitted),
            (.started, .running), (.started, .running), (.resultsReady, .resultsReady), (.downloadStarted, .downloading),
            (.imported, .imported),
        ]
        for (event, expected) in path {
            state = CloudJobMachine.next(state, on: event) ?? state
            #expect(state == expected, "after \(event)")
        }
        #expect(state.isFinished)
    }

    @Test func invalidEventsAreIgnored() {
        #expect(CloudJobMachine.next(.queued, on: .submitted) == nil)
        #expect(CloudJobMachine.next(.imported, on: .failed) == nil)
        #expect(CloudJobMachine.next(.imported, on: .cancelled) == nil)
        #expect(CloudJobMachine.next(.cancelled, on: .resultsReady) == nil)
        #expect(CloudJobMachine.next(.failed, on: .failed) == nil)
    }

    @Test func sideBranches() {
        #expect(CloudJobMachine.next(.running, on: .cancelled) == .cancelled)
        #expect(CloudJobMachine.next(.uploading, on: .failed) == .failed)
        #expect(CloudJobMachine.next(.submitted, on: .expired) == .expired)
        #expect(CloudJobMachine.next(.failed, on: .requeue) == .queued)
        // A FLAC redo after the AAC result didn't line up starts over from the upload.
        #expect(CloudJobMachine.next(.downloading, on: .requeue) == .queued)
        #expect(CloudJobMachine.next(.resultsReady, on: .requeue) == .queued)
        #expect(CloudJobMachine.next(.expired, on: .resubmit) == .uploaded)
        #expect(CloudJobMachine.next(.running, on: .resubmit) == .uploaded)
        #expect(CloudJobMachine.next(.uploaded, on: .resultsReady) == .resultsReady) // found in R2 after a lost response
        #expect(CloudJobState.submitted.isAtRunPod && CloudJobState.running.isAtRunPod)
        #expect(CloudJobState.uploaded.isBeforeSubmit)
        #expect(CloudJobState.submitted.label == "Waiting for a GPU")
    }

    @Test func backoffLadder() {
        #expect(CloudTiming.backoffMs(afterAttempts: 1) == 60_000)
        #expect(CloudTiming.backoffMs(afterAttempts: 2) == 300_000)
        #expect(CloudTiming.backoffMs(afterAttempts: 3) == 900_000)
        #expect(CloudTiming.backoffMs(afterAttempts: 4) == 3_600_000)
        #expect(CloudTiming.backoffMs(afterAttempts: 9) == 3_600_000)
    }

    // MARK: Selection

    static func facts(_ id: String, duration: Int64 = 240_000, instrumental: Bool = false,
                      lyrics: CloudLyricsState = .textOrLineSynced, audio: Bool = true, streamed: Bool = false,
                      pending: Bool = false) -> CloudSongFacts {
        CloudSongFacts(songId: id, durationMs: duration, hasInstrumental: instrumental, lyrics: lyrics,
                       hasAudioSource: audio, isStreamed: streamed, hasPendingJob: pending)
    }

    @Test func oneJobCoversEveryMissingTask() throws {
        let plan = try CloudSelector.plan(Self.facts("a"), options: CloudSelectionOptions()).get()
        #expect(plan.tasks == [.instrumental, .lyrics])
        #expect(plan.lyricsMode == .align)
        let none = try CloudSelector.plan(Self.facts("b", lyrics: .none), options: CloudSelectionOptions()).get()
        #expect(none.lyricsMode == .transcribe)
        let instrumentalOnly = try CloudSelector.plan(Self.facts("c", lyrics: .wordSynced), options: CloudSelectionOptions()).get()
        #expect(instrumentalOnly.tasks == [.instrumental])
        #expect(instrumentalOnly.lyricsMode == nil)
    }

    @Test func skipReasons() {
        let options = CloudSelectionOptions()
        func reason(_ facts: CloudSongFacts, _ options: CloudSelectionOptions = CloudSelectionOptions()) -> CloudSkipReason? {
            if case .failure(let reason) = CloudSelector.plan(facts, options: options) { return reason }
            return nil
        }
        #expect(reason(Self.facts("a", instrumental: true, lyrics: .wordSynced)) == .alreadyDone)
        #expect(reason(Self.facts("a", pending: true)) == .pendingJob)
        #expect(reason(Self.facts("a", duration: 900_001)) == .tooLong)
        #expect(reason(Self.facts("a", duration: 900_000)) == nil)
        #expect(reason(Self.facts("a", audio: false)) == .noAudio)
        #expect(reason(Self.facts("a", instrumental: true, lyrics: .userSynced)) == .userSynced)
        #expect(reason(Self.facts("a", instrumental: true, lyrics: .userSynced),
                       CloudSelectionOptions(replaceUserSynced: true)) == nil)
        #expect(reason(Self.facts("a", instrumental: true, lyrics: .none),
                       CloudSelectionOptions(transcribeWhenMissing: false)) == .alreadyDone)
        _ = options
    }

    @Test func batchCaps() {
        var songs = (0..<210).map { Self.facts("s\($0)") }
        songs.insert(Self.facts("s0"), at: 5) // duplicates count once
        let selection = CloudSelector.select(songs, options: CloudSelectionOptions())
        #expect(selection.plans.count == 200)
        #expect(selection.skipped.filter { $0.reason == .batchFull }.count == 10)
        let streamed = CloudSelector.select((0..<60).map { Self.facts("y\($0)", streamed: true) }, options: CloudSelectionOptions())
        #expect(streamed.plans.count == 50)
        #expect(streamed.skipCounts.first?.reason == .tooManyStreamed)
        #expect(streamed.skipCounts.first?.count == 10)
    }

    @Test func workerCapsStopSongsTheEndpointWouldRefuse() {
        // No selftest yet, or the endpoint at its defaults (= the app's own limits): nothing extra is refused.
        #expect(CloudLimits.workerRefusal(bytes: 150 * 1_048_576, durationMs: 899_000, caps: nil) == nil)
        let defaults = CloudWorkerCaps(maxInputMB: 160, maxAudioS: 900, hostsConfigured: 1)
        #expect(CloudLimits.workerRefusal(bytes: 160 * 1_048_576, durationMs: 900_000, caps: defaults) == nil)
        // An endpoint set stricter than the app.
        let strict = CloudWorkerCaps(maxInputMB: 60, maxAudioS: 600)
        let tooBig = CloudLimits.workerRefusal(bytes: 61 * 1_048_576, durationMs: 200_000, caps: strict)
        #expect(tooBig?.contains("61 MB") == true && tooBig?.contains("60 MB") == true)
        #expect(tooBig?.contains("PIXL_MAX_INPUT_MB") == true)
        let tooLong = CloudLimits.workerRefusal(bytes: 1_048_576, durationMs: 600_001, caps: strict)
        #expect(tooLong?.contains("10-minute") == true)
        let short = CloudLimits.workerRefusal(bytes: 1, durationMs: 90_001, caps: CloudWorkerCaps(maxAudioS: 90))
        #expect(short?.contains("90-second") == true)
        // Caps the worker didn't report are not limits.
        #expect(CloudLimits.workerRefusal(bytes: 500 * 1_048_576, durationMs: 1, caps: CloudWorkerCaps()) == nil)
    }

    @Test func syncedOnlyWhenTheDurationsAgree() {
        #expect(CloudSelector.syncedHint(hasLineTimes: true, lyricsReferenceDurationMs: 241_500, audioDurationMs: 240_000))
        #expect(!CloudSelector.syncedHint(hasLineTimes: true, lyricsReferenceDurationMs: 245_000, audioDurationMs: 240_000))
        #expect(CloudSelector.syncedHint(hasLineTimes: true, lyricsReferenceDurationMs: nil, audioDurationMs: 240_000))
        #expect(!CloudSelector.syncedHint(hasLineTimes: false, lyricsReferenceDurationMs: 240_000, audioDurationMs: 240_000))
    }

    @Test func bestQualityOnlyUpToEightMinutes() {
        #expect(CloudSelector.quality(.best, durationMs: 480_000) == .best)
        #expect(CloudSelector.quality(.best, durationMs: 480_001) == .standard)
        #expect(CloudSelector.quality(.standard, durationMs: 100) == .standard)
    }

    @Test func batchGate() {
        #expect(!CloudBatchGate.shouldSubmit(uploadsPending: 3, uploadsDone: 0, firstUploadDoneAtMs: nil, nowMs: 0))
        #expect(CloudBatchGate.shouldSubmit(uploadsPending: 0, uploadsDone: 3, firstUploadDoneAtMs: 0, nowMs: 1))
        #expect(!CloudBatchGate.shouldSubmit(uploadsPending: 2, uploadsDone: 1, firstUploadDoneAtMs: 1_000, nowMs: 120_999))
        #expect(CloudBatchGate.shouldSubmit(uploadsPending: 2, uploadsDone: 1, firstUploadDoneAtMs: 1_000, nowMs: 121_000))
    }

    /// Runs a submit pass through `CloudSubmitBurst` the way `CloudStudio.submitReadyBatches` does: nil in `items` is
    /// a job that turned out not to be sendable (skipped, unsigned); the pass stops early at `stopAt` (the cap).
    static func sends(_ items: [String?], stopAt: Int? = nil) -> [(String, Bool)] {
        var burst = CloudSubmitBurst<String>()
        var sent: [(String, Bool)] = []
        for (index, item) in items.enumerated() {
            if index == stopAt { break }
            guard let item else { continue }
            if let previous = burst.ready(item) { sent.append((previous, false)) }
        }
        if let last = burst.end() { sent.append((last, true)) }
        return sent
    }

    @Test func submitBurstMarksOnlyItsLastJob() {
        let three = Self.sends(["a", "b", "c"])
        #expect(three.map { $0.0 } == ["a", "b", "c"])
        #expect(three.map { $0.1 } == [false, false, true])
        // A single song is a burst of one.
        let one = Self.sends(["a"])
        #expect(one.map { $0.0 } == ["a"] && one.map { $0.1 } == [true])
        #expect(Self.sends([]).isEmpty)
        #expect(Self.sends([nil, nil]).isEmpty)
    }

    @Test func submitBurstsLastIsTheLastJobThatActuallyGoesOut() {
        // The final job can't be sent (its URLs didn't sign): the one before it is the last.
        let skippedEnd = Self.sends(["a", "b", nil])
        #expect(skippedEnd.map { $0.0 } == ["a", "b"] && skippedEnd.map { $0.1 } == [false, true])
        // A job skipped in the middle changes nothing.
        let skippedMiddle = Self.sends(["a", nil, "c"])
        #expect(skippedMiddle.map { $0.0 } == ["a", "c"] && skippedMiddle.map { $0.1 } == [false, true])
        // The monthly cap stops the pass at the third job: the second, already held, goes out as the last.
        let capped = Self.sends(["a", "b", "c", "d"], stopAt: 2)
        #expect(capped.map { $0.0 } == ["a", "b"] && capped.map { $0.1 } == [false, true])
    }

    @Test func submitBurstHoldsOneJobAtATime() {
        var burst = CloudSubmitBurst<Int>()
        #expect(burst.holding == nil)
        let first = burst.ready(1)
        #expect(first == nil && burst.holding == 1)
        let second = burst.ready(2)
        #expect(second == 1 && burst.holding == 2)
        let last = burst.end()
        #expect(last == 2 && burst.holding == nil)
        let again = burst.end()
        #expect(again == nil)
    }

    // MARK: Cost

    @Test func gpuPrices() {
        #expect(CloudCost.pricePerSecondMicroUSD(gpu: "NVIDIA L4") == 192)
        #expect(CloudCost.pricePerSecondMicroUSD(gpu: "NVIDIA RTX A4000") == 161)
        #expect(CloudCost.pricePerSecondMicroUSD(gpu: "NVIDIA RTX 4000 Ada Generation") == 161)
        #expect(CloudCost.pricePerSecondMicroUSD(gpu: "NVIDIA GeForce RTX 4090") == 306)
        #expect(CloudCost.pricePerSecondMicroUSD(gpu: nil, fallback: 200) == 200)
        #expect(CloudCost.pricePerSecondMicroUSD(gpu: "Mystery", fallback: 175) == 175)
    }

    @Test func estimatesMatchTheDesignTable() {
        let plan = CloudSongPlan(songId: "a", tasks: [.instrumental, .lyrics], lyricsMode: .align, isStreamed: false,
                                 durationMs: 240_000)
        // One song on its own: cold (35 s) + warm (20 s) = 55 s × $0.000192 ≈ $0.0106 (design: 45–55 s, $0.009–0.011).
        #expect(CloudCost.estimateMicroUSD([plan], quality: .standard, pricePerSecondMicroUSD: 192) == 10_560)
        // 100 songs in one burst: 35 + 2000 s ≈ $0.39 on 24 GB (design: ~2,035 s, $0.39).
        let hundred = Array(repeating: plan, count: 100)
        #expect(CloudCost.estimateMicroUSD(hundred, quality: .standard, pricePerSecondMicroUSD: 192) == 390_720)
        #expect(CloudCost.format(microUSD: 390_720) == "$0.39")
        #expect(CloudCost.estimateMicroUSD([], quality: .standard, pricePerSecondMicroUSD: 192) == 0)
        let transcribeBest = CloudSongPlan(songId: "b", tasks: [.lyrics], lyricsMode: .transcribe, isStreamed: false,
                                           durationMs: 240_000)
        #expect(CloudCost.estimatedSeconds(transcribeBest, quality: .best) == 42)
        let long = CloudSongPlan(songId: "c", tasks: [.instrumental], lyricsMode: nil, isStreamed: false, durationMs: 600_000)
        #expect(CloudCost.estimatedSeconds(long, quality: .best) == 50) // 10 min: best falls back, scaled 2.5×
    }

    @Test func actualCostFromTimings() {
        let timings = CloudTimings(coldStartMs: 18_400, totalMs: 19_400)
        #expect(CloudCost.actualMicroUSD(timings: timings, gpu: "NVIDIA L4", fallbackPricePerSecondMicroUSD: 1) == 7_258)
        #expect(CloudCost.actualMicroUSD(timings: nil, gpu: "NVIDIA L4", fallbackPricePerSecondMicroUSD: 192) == 0)
    }

    @Test func formatting() {
        #expect(CloudCost.format(microUSD: 0) == "$0.00")
        #expect(CloudCost.format(microUSD: 4_000) == "<$0.01")
        #expect(CloudCost.format(microUSD: 3_000_000) == "$3.00")
        #expect(CloudCost.format(microUSD: 1_055_000) == "$1.06")
    }

    @Test func monthlyCap() {
        var a = CloudJobRecord(jobKey: Self.key, songId: "a", title: "", artist: "", batchId: "b", tasks: [.instrumental],
                               lyricsMode: nil, quality: .standard, createdAtMs: 0)
        a.completedAtMs = 2_000
        a.costMicroUSD = 1_000_000
        var old = a
        old.completedAtMs = 500
        old.costMicroUSD = 9_000_000
        let spent = CloudBudget.spentMicroUSD([a, old], monthStartMs: 1_000)
        #expect(spent == 1_000_000)
        #expect(CloudBudget.remainingMicroUSD(capMicroUSD: 3_000_000, spentMicroUSD: spent) == 2_000_000)
        #expect(CloudBudget.allows(estimateMicroUSD: 2_000_000, capMicroUSD: 3_000_000, spentMicroUSD: spent))
        #expect(!CloudBudget.allows(estimateMicroUSD: 2_000_001, capMicroUSD: 3_000_000, spentMicroUSD: spent))
        #expect(CloudBudget.remainingMicroUSD(capMicroUSD: 3_000_000, spentMicroUSD: 4_000_000) == 0)
        // 2026-10-07T12:00Z → 2026-10-01T00:00Z.
        #expect(CloudBudget.utcMonthStartMs(1_791_374_400_000) == 1_790_812_800_000)
        #expect(CloudBudget.utcMonthStartMs(951_782_400_000) == 949_363_200_000) // 2000-02-29 → 2000-02-01
    }

    // MARK: Import, retention, endpoint

    @Test func importChecks() {
        #expect(CloudImportCheck.matches(expectedBytes: 10, expectedSHA256: "AB", actualBytes: 10, actualSHA256: "ab"))
        #expect(!CloudImportCheck.matches(expectedBytes: 10, expectedSHA256: "ab", actualBytes: 11, actualSHA256: "ab"))
        #expect(CloudImportCheck.samplesMatch(sourceFrames: 10_628_100, sourceSampleRate: 44_100,
                                              resultFrames: 10_628_100 + 1024, resultSampleRate: 44_100))
        #expect(!CloudImportCheck.samplesMatch(sourceFrames: 10_628_100, sourceSampleRate: 44_100,
                                               resultFrames: 10_628_100 + 2112, resultSampleRate: 44_100))
        // A 48 kHz source against the worker's 44.1 kHz output.
        #expect(CloudImportCheck.samplesMatch(sourceFrames: 11_568_000, sourceSampleRate: 48_000,
                                              resultFrames: 10_628_100, resultSampleRate: 44_100))
        #expect(!CloudImportCheck.samplesMatch(sourceFrames: 0, sourceSampleRate: 44_100, resultFrames: 1, resultSampleRate: 44_100))
        // A manifest naming another input belongs to an earlier attempt; one that names none (older worker) is taken.
        let sha = String(repeating: "a", count: 64)
        let named = CloudJobResult(jobKey: Self.key, status: .ok,
                                   input: CloudInputInfo(codec: "flac", sampleRate: 44_100, channels: 2, decodedSamples: 1,
                                                         durationMs: 1, sha256: sha))
        #expect(CloudImportCheck.manifestDescribesUpload(named, uploadedSHA256: sha.uppercased()))
        #expect(!CloudImportCheck.manifestDescribesUpload(named, uploadedSHA256: String(repeating: "b", count: 64)))
        #expect(CloudImportCheck.manifestDescribesUpload(named, uploadedSHA256: nil))
        #expect(CloudImportCheck.manifestDescribesUpload(CloudJobResult(jobKey: Self.key, status: .error), uploadedSHA256: sha))
    }

    @Test func retention() {
        var record = CloudJobRecord(jobKey: Self.key, songId: "a", title: "", artist: "", batchId: "b", tasks: [.instrumental],
                                    lyricsMode: nil, quality: .standard, createdAtMs: 0)
        #expect(!CloudRetention.shouldPrune(record, nowMs: 100 * 86_400_000))
        record.state = .imported
        record.importedAtMs = 0
        #expect(!CloudRetention.shouldPrune(record, nowMs: 30 * 86_400_000))
        #expect(CloudRetention.shouldPrune(record, nowMs: 30 * 86_400_000 + 1))
        #expect(!CloudRetention.isPastTTL(submittedAtMs: 0, nowMs: CloudTiming.ttlMs + CloudTiming.executionTimeoutMs))
        #expect(CloudRetention.isPastTTL(submittedAtMs: 0, nowMs: CloudTiming.ttlMs + CloudTiming.executionTimeoutMs + 1))
        #expect(CloudRetention.inputTooOldToSubmit(uploadedAtMs: 0, nowMs: 3 * 86_400_000 + 1))
        #expect(!CloudRetention.inputTooOldToSubmit(uploadedAtMs: 0, nowMs: 3 * 86_400_000))
        #expect(CloudRetention.inputTooOldToSubmit(uploadedAtMs: nil, nowMs: 0))
        #expect(CloudRetention.uploadURLExpired(expiresAtMs: 10, nowMs: 10))
        #expect(!CloudRetention.uploadURLExpired(expiresAtMs: 11, nowMs: 10))
        // Upload age (≤ 3 d) + ttl (3 d) stays under the 7-day in/ lifecycle.
        #expect(CloudTiming.maxInputAgeAtSubmitMs + CloudTiming.ttlMs < Int64(CloudRetention.inputLifecycleDays) * 86_400_000)
    }

    @Test func pausedEndpoint() {
        let empty = RunPodHealth(inQueue: 4)
        #expect(!CloudEndpointWatch.looksPaused(oldestWaitingSinceMs: 0, nowMs: 30 * 60_000, health: empty))
        #expect(CloudEndpointWatch.looksPaused(oldestWaitingSinceMs: 0, nowMs: 30 * 60_000 + 1, health: empty))
        #expect(!CloudEndpointWatch.looksPaused(oldestWaitingSinceMs: 0, nowMs: 60 * 60_000,
                                                health: RunPodHealth(inQueue: 4, runningWorkers: 1)))
        #expect(!CloudEndpointWatch.looksPaused(oldestWaitingSinceMs: nil, nowMs: 60 * 60_000, health: empty))
    }
}

@Suite struct CloudJobRecordTests {
    static func record() -> CloudJobRecord {
        CloudJobRecord(jobKey: CloudQueuePolicyTests.key, songId: "f:1/a.m4a", title: "Song", artist: "Artist",
                       batchId: "batch", tasks: [.instrumental, .lyrics], lyricsMode: .align, quality: .standard,
                       createdAtMs: 1_000)
    }

    @Test func eventsStampTimes() {
        var r = Self.record()
        let applied1 = r.apply(.prepareStarted, nowMs: 2)
        #expect(applied1)
        let applied2 = r.apply(.prepared, nowMs: 3)
        #expect(applied2)
        let applied3 = r.apply(.uploadFinished, nowMs: 4)
        #expect(applied3)
        #expect(r.uploadedAtMs == 4)
        let applied4 = r.apply(.imported, nowMs: 5)
        #expect(!applied4)
        #expect(r.state == .uploaded)
        let applied5 = r.apply(.submitted, nowMs: 6)
        #expect(applied5)
        #expect(r.submittedAtMs == 6)
        r.runpodJobId = "job"
        let applied6 = r.apply(.resubmit, nowMs: 7)
        #expect(applied6)
        #expect(r.runpodJobId == nil)
        #expect(r.state == .uploaded)
        r.inputExt = "flac"
        #expect(r.inputKey == "in/\(CloudQueuePolicyTests.key).flac")
    }

    @Test func failuresClimbTheLadderThenStop() {
        var r = Self.record()
        r.recordFailure("net", code: nil, retryable: true, nowMs: 0)
        #expect(r.state == .queued)
        #expect(r.nextAttemptAtMs == 60_000)
        #expect(!r.isDue(nowMs: 59_999))
        #expect(r.isDue(nowMs: 60_000))
        r.recordFailure("net", code: nil, retryable: true, nowMs: 0)
        r.recordFailure("net", code: nil, retryable: true, nowMs: 0)
        #expect(r.nextAttemptAtMs == 900_000)
        r.recordFailure("net", code: nil, retryable: true, nowMs: 0)
        #expect(r.state == .failed)
        var hard = Self.record()
        hard.recordFailure("too long", code: "TOO_LONG", retryable: false, nowMs: 0)
        #expect(hard.state == .failed)
        #expect(hard.lastErrorCode == "TOO_LONG")
    }

    @Test func resultsAndCost() throws {
        var r = Self.record()
        let result = try CloudJSON.decode(CloudJobResult.self, from: CloudFixtures.data("job.result.ok"))
        r.takeResult(result, fallbackPricePerSecondMicroUSD: 192, nowMs: 50)
        #expect(r.costMicroUSD == 7_258)
        #expect(r.gpu == "NVIDIA L4")
        #expect(r.lyricsKey == "out/\(CloudQueuePolicyTests.key)/lyrics.json")
        #expect(!r.lyricsTranscribed)
        #expect(r.completedAtMs == 50)
        #expect(!r.isFullyImported)
        r.importedInstrumental = true
        r.importedLyrics = true
        #expect(r.isFullyImported)
        // The guard's duplicate answer doesn't add cost.
        var duplicate = result
        duplicate.warnings = ["duplicate"]
        r.takeResult(duplicate, fallbackPricePerSecondMicroUSD: 192, nowMs: 60)
        #expect(r.costMicroUSD == 7_258)
        #expect(r.warnings.isEmpty)
    }

    @Test func codableRoundTrip() throws {
        var r = Self.record()
        r.state = .running
        r.progressStage = "separate"
        r.outputs = ["instrumental": CloudOutputFile(key: "k", bytes: 1, sha256: "a", codec: "aac", kbps: 256, samples: 9)]
        let data = try JSONEncoder().encode([r])
        #expect(try JSONDecoder().decode([CloudJobRecord].self, from: data) == [r])
    }
}

/// The month's committed spend and the confirm sheet's batch figures (design §5 app guards, §7.3).
@Suite struct CloudBudgetTests {
    static func record(_ key: String, state: CloudJobState, durationMs: Int64 = 240_000) -> CloudJobRecord {
        var r = CloudJobRecord(jobKey: key, songId: "s-\(key)", title: "T", artist: "A", batchId: "b",
                               tasks: [.instrumental, .lyrics], lyricsMode: .align, quality: .standard, createdAtMs: 0)
        r.state = state
        r.durationMs = durationMs
        return r
    }

    @Test func committedCountsJobsStillAtRunPod() {
        var done = Self.record("a", state: .imported)
        done.completedAtMs = 2_000
        done.costMicroUSD = 5_000
        var running = Self.record("b", state: .running)
        running.submittedAtMs = 1_500
        let waiting = Self.record("c", state: .submitted)
        let queued = Self.record("d", state: .queued)
        // A redo after an earlier result counts again; one that already finished this run doesn't.
        var redo = Self.record("e", state: .submitted)
        redo.completedAtMs = 1_000
        redo.submittedAtMs = 3_000
        var finishedRun = Self.record("f", state: .running)
        finishedRun.completedAtMs = 4_000
        finishedRun.submittedAtMs = 3_000
        let records = [done, running, waiting, queued, redo, finishedRun]
        // 20 s warm each at 192 µ$/s for a 4-minute song: running, waiting and the redo.
        #expect(CloudBudget.committedMicroUSD(records, monthStartMs: 0, pricePerSecondMicroUSD: 192)
            == 5_000 + 3 * 20 * 192)
        #expect(running.isRunningAtRunPod && waiting.isRunningAtRunPod && redo.isRunningAtRunPod)
        #expect(!finishedRun.isRunningAtRunPod && !queued.isRunningAtRunPod)
    }

    @Test func planUsesThePreparedThenTheLibraryLength() {
        var r = Self.record("a", state: .queued)
        r.durationMs = nil
        #expect(r.plan.durationMs == CloudCost.referenceSongMs)
        r.songDurationMs = 300_000
        #expect(r.plan.durationMs == 300_000)
        r.durationMs = 301_000
        #expect(r.plan.durationMs == 301_000)
        #expect(r.plan.tasks == [.instrumental, .lyrics])
    }

    @Test func redoAddsItsRunToTheCost() throws {
        var r = Self.record("a", state: .running)
        let result = try CloudJSON.decode(CloudJobResult.self, from: CloudFixtures.worker("job.result.ok"))
        r.takeResult(result, fallbackPricePerSecondMicroUSD: 192, nowMs: 10)
        #expect(r.costMicroUSD == 7_258)
        r.takeResult(result, fallbackPricePerSecondMicroUSD: 192, nowMs: 20)
        #expect(r.costMicroUSD == 14_516)
    }

    @Test func batchEstimateForTheConfirmSheet() {
        let plans = [CloudSongPlan(songId: "a", tasks: [.instrumental, .lyrics], lyricsMode: .align, isStreamed: false,
                                   durationMs: 240_000),
                     CloudSongPlan(songId: "b", tasks: [.instrumental], lyricsMode: nil, isStreamed: true,
                                   durationMs: 120_000)]
        let estimate = CloudBatchEstimate.make(plans: plans, uploadBytes: ["a": 8_000_000], quality: .standard,
                                               pricePerSecondMicroUSD: 192, committedMicroUSD: 2_990_000,
                                               capMicroUSD: 3_000_000)
        #expect(estimate.songs == 2 && estimate.streamedSongs == 1)
        #expect(estimate.minutes == 6)
        // "b" as FLAC: 120 s × 176,400 B/s × 0.6.
        #expect(estimate.uploadBytes == 8_000_000 + 12_700_800)
        #expect(estimate.uploadMB == 20)
        // One cold start (35 s) + 20 s + 10 s.
        #expect(estimate.costMicroUSD == (35 + 20 + 10) * 192)
        #expect(estimate.remainingMicroUSD == 10_000)
        #expect(!estimate.fitsCap)
        #expect(CloudUploadEstimate.bytes(durationMs: 240_000, passthroughBitsPerSecond: 256_000) == 7_680_000)
    }
}
