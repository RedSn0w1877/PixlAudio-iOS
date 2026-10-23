// One Cloud Studio job as the phone remembers it (design §7.1 `CloudJobRecord`): identity, request, state, retries,
// telemetry and results. A plain Codable value, so the state rules are tested here and the app stores the list as one
// JSON file (`CloudJobStore`).

import Foundation

/// Who started a job. `manual` is "Process in cloud" (a record without an origin is a manual one), `sing` is a tap on
/// Sing, `auto` is "Prepare songs ahead in the cloud" (the one thing that sends songs without a tap).
public enum CloudJobOrigin: String, Codable, Sendable {
    case manual, sing, auto
}

public struct CloudJobRecord: Codable, Sendable, Hashable, Identifiable {
    // Identity
    public var jobKey: String
    public var songId: String
    /// The YouTube video the audio came from (streamed and Spotify songs); re-checked on import.
    public var videoId: String?
    /// The itag and byte length of a streamed source, when known.
    public var itag: Int?
    public var contentLength: Int64?
    public var title: String
    public var artist: String
    /// The library's length of the song (cost estimates before the audio is prepared).
    public var songDurationMs: Int64?
    /// Songs sent together (the submission gate works per batch).
    public var batchId: String
    public var isStreamed: Bool
    /// The only stream on offer was low quality (itag 139 / 18): shown on the confirm sheet and the row.
    public var lowQualitySource: Bool

    // Request
    public var tasks: [CloudTask]
    public var lyricsMode: CloudLyricsMode?
    public var language: String?
    public var quality: CloudSeparationQuality
    public var outputCodec: CloudOutputCodec
    public var replaceUserSynced: Bool

    // State
    public var state: CloudJobState
    public var runpodJobId: String?
    public var inputExt: String?
    public var sha256: String?
    public var bytes: Int64?
    public var durationMs: Int64?
    /// The phone's own decoded sample frames of the uploaded audio, and their rate (the import's priming check).
    public var decodedFrames: Int64?
    public var sampleRate: Double?
    /// When the upload's own presigned PUT expires.
    public var uploadURLExpiresAtMs: Int64?
    /// Worker progress while running (`stage`, percent).
    public var progressStage: String?
    public var progressPercent: Int?

    // Retries
    public var attempts: Int
    public var nextAttemptAtMs: Int64?
    public var lastError: String?
    public var lastErrorCode: String?
    /// A job lost at RunPod is resubmitted once with the same key.
    public var resubmits: Int
    /// A sample-count mismatch is redone once with FLAC output.
    public var flacRedone: Bool

    // Telemetry
    public var timings: CloudTimings?
    public var gpu: String?
    public var coldStartMs: Int64?
    public var costMicroUSD: Int64?
    public var warnings: [String]

    // Results
    public var resultStatus: String?
    public var outputs: [String: CloudOutputFile]?
    public var lyricsKey: String?
    /// The manifest's `lyrics` entry (size and SHA-256 of `lyrics.json`, its mode and counts).
    public var lyricsFile: CloudLyricsSummary?
    public var lyricsTranscribed: Bool
    public var importedInstrumental: Bool
    public var importedLyrics: Bool

    // Timestamps (Unix ms)
    public var createdAtMs: Int64
    public var updatedAtMs: Int64?
    public var uploadedAtMs: Int64?
    public var submittedAtMs: Int64?
    public var completedAtMs: Int64?
    public var importedAtMs: Int64?
    /// Last `/status` call, for the 15 s polling floor.
    public var lastPolledAtMs: Int64?

    // Origin and the priority lane. Every field here is optional on purpose: the job list is one Codable file, and a
    // field that older stored records lack would make the whole list unreadable (`CloudJobStore.load` then starts
    // empty). A record without them decodes as a plain manual job.
    /// Who started the job (nil = manual).
    public var origin: CloudJobOrigin?
    /// When the job was given priority (a Sing tap, or an auto job a Sing tap joined).
    public var priorityAtMs: Int64?
    /// The priority job this one stepped aside for (its job key). Set from the moment the pause begins.
    public var pausedBy: String?
    public var pausedAtMs: Int64?
    /// The cancel reached RunPod before the worker had started the job, so nothing of it is in the bucket yet.
    public var pausedNeverStarted: Bool?
    /// RunPod job id whose `/cancel` was about to be sent: written before the call, so a lost answer is still known as
    /// ours (a CANCELLED status for it completes the pause instead of counting as a failure).
    public var pauseIntentRunpodJobId: String?
    /// The estimate this auto job reserved in the auto-prepare ledger when it first went to RunPod, until its real cost
    /// replaces it.
    public var autoReservedMicroUSD: Int64?

    // Sing's preview piece ("clip job", `CloudSingClip`): a minute of the song around the playhead, separated ahead of
    // the full job so the instrumental starts sooner. To the worker it is just a short song. Optional like the rest.
    /// Where the clip starts in the song (ms). Set only on a clip job.
    public var clipStartMs: Int64?
    /// The clip's length (ms): as asked for, then as the phone decoded it.
    public var clipDurationMs: Int64?

    public var id: String { jobKey }

    /// A preview piece of a Sing, not a whole song: its result is played for a while and thrown away, never kept as the
    /// song's instrumental, and it has no row of its own in the queue or Active jobs.
    public var isClip: Bool { clipStartMs != nil }

    /// The clip's place in the song (nil for a whole-song job).
    public var clipRange: CloudClipRange? {
        guard let start = clipStartMs, let length = clipDurationMs, length > 0 else { return nil }
        return CloudClipRange(startMs: start, endMs: start + length)
    }

    public init(jobKey: String, songId: String, title: String, artist: String, batchId: String, tasks: [CloudTask],
                lyricsMode: CloudLyricsMode?, quality: CloudSeparationQuality, createdAtMs: Int64,
                isStreamed: Bool = false, videoId: String? = nil, language: String? = nil,
                outputCodec: CloudOutputCodec = .aac, replaceUserSynced: Bool = false) {
        self.jobKey = jobKey
        self.songId = songId
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.batchId = batchId
        self.isStreamed = isStreamed
        lowQualitySource = false
        self.tasks = tasks
        self.lyricsMode = lyricsMode
        self.language = language
        self.quality = quality
        self.outputCodec = outputCodec
        self.replaceUserSynced = replaceUserSynced
        state = .queued
        attempts = 0
        resubmits = 0
        flacRedone = false
        warnings = []
        lyricsTranscribed = false
        importedInstrumental = false
        importedLyrics = false
        self.createdAtMs = createdAtMs
    }

    /// `in/<jobKey>.<ext>` once prepared.
    public var inputKey: String? { inputExt.map { CloudKeys.input(jobKey: jobKey, ext: $0) } }

    /// Applies an event through the state machine; returns false (and changes nothing) when it doesn't apply.
    @discardableResult
    public mutating func apply(_ event: CloudJobEvent, nowMs: Int64) -> Bool {
        guard let next = CloudJobMachine.next(state, on: event) else { return false }
        state = next
        updatedAtMs = nowMs
        switch event {
        case .uploadFinished: uploadedAtMs = nowMs
        case .submitted:
            submittedAtMs = nowMs
            // Sent again after stepping aside: the pause is over.
            clearPause()
        case .imported: importedAtMs = nowMs
        case .requeue:
            runpodJobId = nil
            progressStage = nil
            progressPercent = nil
            nextAttemptAtMs = nil
            clearPause()
        case .resubmit:
            runpodJobId = nil
            progressStage = nil
            progressPercent = nil
            clearPause()
        case .pause:
            // The fields that say why are set by `completePause`.
            runpodJobId = nil
            progressStage = nil
            progressPercent = nil
        default: break
        }
        return true
    }

    // MARK: Origin and the priority lane

    /// The origin, a record without one being a manual job.
    public var effectiveOrigin: CloudJobOrigin { origin ?? .manual }

    /// Stepped aside for a priority job: uploaded again, waiting to be sent after it.
    public var isPaused: Bool { state == .uploaded && pausedBy != nil }

    /// The cancel for this job was started and its outcome isn't known yet.
    public var hasPauseIntent: Bool { pauseIntentRunpodJobId != nil }

    /// Gives the job priority: a Sing tap (a job already waiting for the song is joined, not duplicated).
    public mutating func promote(nowMs: Int64) {
        origin = .sing
        priorityAtMs = nowMs
        updatedAtMs = nowMs
    }

    /// About to cancel this job at RunPod so `priorityJobKey` goes first. Written (and saved) before the cancel.
    public mutating func beginPause(runpodJobId: String, by priorityJobKey: String, nowMs: Int64) {
        pauseIntentRunpodJobId = runpodJobId
        pausedBy = priorityJobKey
        pausedAtMs = nowMs
        updatedAtMs = nowMs
    }

    /// The job was cancelled at RunPod: back to `uploaded` (its upload stays), held until the priority job has gone
    /// out. `neverStarted` nil = not known yet.
    @discardableResult
    public mutating func completePause(by priorityJobKey: String, neverStarted: Bool?, nowMs: Int64) -> Bool {
        guard apply(.pause, nowMs: nowMs) else { return false }
        pausedBy = priorityJobKey
        pausedAtMs = pausedAtMs ?? nowMs
        pausedNeverStarted = neverStarted
        pauseIntentRunpodJobId = nil
        return true
    }

    /// The pause did not happen (the job had started, or the priority job went away): the job carries on as it was.
    public mutating func abortPause() {
        pauseIntentRunpodJobId = nil
        if state != .uploaded { clearPause() }
    }

    /// The hold ends (the priority job is gone): the job is sent with the next batch. What is known about whether it
    /// ever started stays, so the send can skip clearing a bucket that holds nothing of it; what is not known counts as
    /// "may have started", so the send still looks in the bucket for its result first.
    public mutating func release() {
        pausedBy = nil
        pausedAtMs = nil
        pausedNeverStarted = pausedNeverStarted ?? false
    }

    /// Forgets every trace of a pause.
    public mutating func clearPause() {
        pausedBy = nil
        pausedAtMs = nil
        pausedNeverStarted = nil
        pauseIntentRunpodJobId = nil
    }

    /// The job was paused (and not sent since): its earlier run may or may not have left objects in the bucket.
    public var wasPaused: Bool { pausedBy != nil || pausedNeverStarted != nil }

    /// Records a failure: retryable ones wait on the backoff ladder (up to `maxAutomaticAttempts`), others stop.
    public mutating func recordFailure(_ message: String, code: String?, retryable: Bool, nowMs: Int64) {
        attempts += 1
        lastError = message
        lastErrorCode = code
        if retryable && attempts < CloudTiming.maxAutomaticAttempts {
            nextAttemptAtMs = nowMs + CloudTiming.backoffMs(afterAttempts: attempts)
        } else {
            nextAttemptAtMs = nil
            apply(.failed, nowMs: nowMs)
        }
        updatedAtMs = nowMs
    }

    /// A retry is due (no wait pending, or the wait is over).
    public func isDue(nowMs: Int64) -> Bool { (nextAttemptAtMs ?? 0) <= nowMs }

    /// Takes a finished manifest's results and telemetry.
    public mutating func takeResult(_ result: CloudJobResult, fallbackPricePerSecondMicroUSD: Int64, nowMs: Int64) {
        resultStatus = result.status
        outputs = result.outputs
        lyricsKey = result.lyrics?.key
        lyricsFile = result.lyrics
        lyricsTranscribed = result.lyrics?.mode == "transcribed"
        warnings = (result.warnings ?? []).filter { $0 != "duplicate" }
        timings = result.timings
        gpu = result.worker?.gpu
        coldStartMs = result.timings?.coldStartMs
        // A duplicate answer cost a few hundred ms; the first delivery's cost was already recorded. A redo (a FLAC
        // redo, a re-upload) adds its own run to what the job already cost.
        if !result.isDuplicate {
            costMicroUSD = (costMicroUSD ?? 0) + CloudCost.actualMicroUSD(timings: result.timings, gpu: result.worker?.gpu,
                                                                          fallbackPricePerSecondMicroUSD: fallbackPricePerSecondMicroUSD)
        } else if costMicroUSD == nil {
            costMicroUSD = 0
        }
        completedAtMs = nowMs
        updatedAtMs = nowMs
        progressStage = nil
        progressPercent = nil
    }

    /// The job as a selection plan (cost estimates): its tasks at its prepared, else asked-for (a clip), else library,
    /// length.
    public var plan: CloudSongPlan {
        CloudSongPlan(songId: songId, tasks: tasks, lyricsMode: lyricsMode, isStreamed: isStreamed,
                      durationMs: durationMs ?? clipDurationMs ?? songDurationMs ?? CloudCost.referenceSongMs)
    }

    /// RunPod holds this job now and hasn't finished the run (a redo after an earlier result counts again).
    public var isRunningAtRunPod: Bool {
        guard state.isAtRunPod else { return false }
        guard let completed = completedAtMs else { return true }
        return (submittedAtMs ?? 0) > completed
    }

    /// Every result this job asked for has been imported.
    public var isFullyImported: Bool {
        (!tasks.contains(.instrumental) || importedInstrumental || outputs?["instrumental"] == nil)
            && (!tasks.contains(.lyrics) || importedLyrics || lyricsKey == nil)
    }
}
