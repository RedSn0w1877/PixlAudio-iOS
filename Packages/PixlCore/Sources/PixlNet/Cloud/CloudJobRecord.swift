// One Cloud Studio job as the phone remembers it (design §7.1 `CloudJobRecord`): identity, request, state, retries,
// telemetry and results. A plain Codable value, so the state rules are tested here and the app stores the list as one
// JSON file (`CloudJobStore`).

import Foundation

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

    public var id: String { jobKey }

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
        case .submitted: submittedAtMs = nowMs
        case .imported: importedAtMs = nowMs
        case .requeue:
            runpodJobId = nil
            progressStage = nil
            progressPercent = nil
            nextAttemptAtMs = nil
        case .resubmit:
            runpodJobId = nil
            progressStage = nil
            progressPercent = nil
        default: break
        }
        return true
    }

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

    /// The job as a selection plan (cost estimates): its tasks at its prepared, else library, length.
    public var plan: CloudSongPlan {
        CloudSongPlan(songId: songId, tasks: tasks, lyricsMode: lyricsMode, isStreamed: isStreamed,
                      durationMs: durationMs ?? songDurationMs ?? CloudCost.referenceSongMs)
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
