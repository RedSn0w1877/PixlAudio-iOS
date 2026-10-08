// Cloud Studio's pure rules (design §1, §2.5, §5, §7.3–§7.5): object keys, the job state machine, the retry ladder,
// presigned-URL lifetimes, the batch submission gate, song selection, the cost estimate and the monthly cap, the
// import checks and retention. The app's orchestrator (`CloudStudio`) only sequences I/O around these.

import Foundation

// MARK: - Keys

/// Object keys in the bucket and the job key format.
public enum CloudKeys {
    /// `in/<jobKey>.<ext>`: the uploaded song.
    public static func input(jobKey: String, ext: String) -> String { "in/\(jobKey).\(ext)" }
    /// `out/<jobKey>/`: everything the worker writes for a job.
    public static func outputPrefix(jobKey: String) -> String { "out/\(jobKey)/" }
    public static func output(jobKey: String, slot: String, ext: String) -> String { "out/\(jobKey)/\(slot).\(ext)" }
    public static func manifest(jobKey: String) -> String { "out/\(jobKey)/manifest.json" }
    public static func attempt(jobKey: String) -> String { "out/\(jobKey)/attempt.json" }
    public static func lyrics(jobKey: String) -> String { "out/\(jobKey)/lyrics.json" }
    /// The connection test's 1-byte object.
    public static func probe(id: String) -> String { "probe/\(id)" }

    /// The worker's jobKey rule: 36 characters of `0-9 a-f -` (a lower-case UUID).
    public static func isValidJobKey(_ key: String) -> Bool {
        key.utf8.count == 36 && key.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || $0 == 0x2D }
    }

    /// A new job key from a UUID string (any case).
    public static func jobKey(uuid: String) -> String { uuid.lowercased() }

    /// The jobKey of an `out/<jobKey>/…` key or `out/<jobKey>/` prefix, if valid.
    public static func jobKey(fromOutputKey key: String) -> String? {
        guard key.hasPrefix("out/") else { return nil }
        let candidate = String(key.dropFirst(4).prefix { $0 != "/" })
        return isValidJobKey(candidate) ? candidate : nil
    }

    /// Input formats the worker accepts (`PIXL_ALLOWED_FORMATS`), by extension.
    public static let inputExtensions: Set<String> = ["m4a", "mp3", "flac", "wav", "ogg", "opus", "webm"]

    /// The Content-Type of an uploaded or downloaded file.
    public static func contentType(ext: String) -> String {
        switch ext.lowercased() {
        case "m4a", "mp4": "audio/mp4"
        case "flac": "audio/flac"
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }
}

// MARK: - Limits and timing

/// Caps the app enforces before anything is sent (the worker enforces its own as well).
public enum CloudLimits {
    /// `PIXL_MAX_AUDIO_S` 900.
    public static let maxDurationMs: Int64 = 900_000
    /// `PIXL_BEST_MAX_AUDIO_S` 480: `best` quality only up to 8 minutes.
    public static let bestQualityMaxDurationMs: Int64 = 480_000
    /// `PIXL_MAX_INPUT_MB` 60 (the worker's streamed byte cap).
    public static let maxInputBytes: Int64 = 60 * 1_048_576
    public static let maxSongsPerBatch = 200
    /// Streamed songs are fetched 2 at a time with jitter, at most 50 per batch (§7.3).
    public static let maxStreamedPerBatch = 50
    public static let streamedFetchConcurrency = 2
    /// `PIXL_MAX_LYRICS_LINES` / `_CHARS`.
    public static let maxLyricsLines = 500
    public static let maxLyricsChars = 20_000
    /// Output AAC bitrate (decision 4: AAC 256k).
    public static let outputKbps = 256
}

/// Lifetimes and intervals (milliseconds unless named otherwise).
public enum CloudTiming {
    /// `policy.ttl`: 3 days in RunPod's queue, a hard kill.
    public static let ttlMs: Int64 = 3 * 86_400_000
    /// `policy.executionTimeout`: 900 s.
    public static let executionTimeoutMs: Int64 = 900_000
    /// The upload PUT the phone presigns for itself: 24 h.
    public static let uploadPresignSeconds = 86_400
    /// The worker's URLs, signed at submission: `ttl + executionTimeout + 1 h` (≈ 76 h; R2's maximum is 7 d).
    public static var workerPresignSeconds: Int { Int((ttlMs + executionTimeoutMs) / 1000) + 3_600 }
    /// An input older than this is uploaded again instead of being submitted (upload age + ttl < the 7-day `in/`
    /// lifecycle).
    public static let maxInputAgeAtSubmitMs: Int64 = 3 * 86_400_000
    /// A batch is submitted when all its uploads are done, or this long after the first one finished.
    public static let batchGateMs: Int64 = 120_000
    /// `/status` for running jobs at most this often in the foreground.
    public static let statusPollIntervalMs: Int64 = 15_000
    /// RunPod keeps a finished job's `/status` for 30 minutes.
    public static let statusRetentionMs: Int64 = 30 * 60_000
    /// Retry ladder after a failure: 1 → 5 → 15 → 60 minutes, then every hour.
    public static let backoffLadderMs: [Int64] = [60_000, 300_000, 900_000, 3_600_000]
    /// Automatic retries before a job waits for the person's Retry.
    public static let maxAutomaticAttempts = 4
    /// BGAppRefresh is asked for no sooner than this while jobs are in flight.
    public static let refreshEarliestMs: Int64 = 15 * 60_000
    /// Jobs queued this long while the endpoint shows no workers at all suggest a paused endpoint.
    public static let pausedEndpointAfterMs: Int64 = 30 * 60_000

    /// The wait before attempt `attempts + 1` (attempts already made ≥ 1).
    public static func backoffMs(afterAttempts attempts: Int) -> Int64 {
        backoffLadderMs[min(max(attempts - 1, 0), backoffLadderMs.count - 1)]
    }
}

// MARK: - State machine

/// A job's state (§7.3): queued → preparing → uploading → uploaded → submitted ("Waiting for a GPU") → running →
/// resultsReady → downloading → imported, with the side branches failed, cancelled and expired.
public enum CloudJobState: String, Sendable, Hashable, Codable, CaseIterable {
    case queued
    case preparing
    case uploading
    case uploaded
    case submitted
    case running
    case resultsReady
    case downloading
    case imported
    case failed
    case cancelled
    case expired

    /// Nothing more happens without the person (Retry or remove).
    public var isFinished: Bool { self == .imported || self == .failed || self == .cancelled || self == .expired }
    /// RunPod holds the job: `/status` or R2 tell what became of it.
    public var isAtRunPod: Bool { self == .submitted || self == .running }
    /// Counts as "pending" for the automatic studio and the song sheet.
    public var isPending: Bool { !isFinished }
    /// The phone still has work to do before RunPod sees the job.
    public var isBeforeSubmit: Bool { self == .queued || self == .preparing || self == .uploading || self == .uploaded }

    /// Plain words for the queue screen.
    public var label: String {
        switch self {
        case .queued: "Waiting"
        case .preparing: "Preparing the audio"
        case .uploading: "Uploading"
        case .uploaded: "Uploaded"
        case .submitted: "Waiting for a GPU"
        case .running: "Processing"
        case .resultsReady: "Results ready"
        case .downloading: "Downloading results"
        case .imported: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .expired: "Expired"
        }
    }
}

/// What can happen to a job.
public enum CloudJobEvent: Sendable, Hashable {
    case prepareStarted
    case prepared
    case uploadStarted
    case uploadFinished
    case submitted
    case started
    case resultsReady
    case downloadStarted
    case imported
    case failed
    case cancelled
    case expired
    /// Back to the start (Retry, a lost job resubmitted, a missing input).
    case requeue
    /// The input is in R2 but the job must be sent again (lost at RunPod, or a FLAC redo).
    case resubmit
}

public enum CloudJobMachine {
    /// The next state, or nil when the event doesn't apply in `state` (the orchestrator then ignores it).
    public static func next(_ state: CloudJobState, on event: CloudJobEvent) -> CloudJobState? {
        switch (state, event) {
        case (.queued, .prepareStarted): .preparing
        case (.preparing, .prepared): .uploading
        case (.uploading, .uploadStarted): .uploading
        case (.preparing, .uploadStarted): .uploading
        case (.uploading, .uploadFinished): .uploaded
        case (.uploaded, .submitted): .submitted
        case (.submitted, .started): .running
        case (.running, .started): .running
        case (.submitted, .resultsReady), (.running, .resultsReady), (.uploaded, .resultsReady): .resultsReady
        case (.resultsReady, .downloadStarted): .downloading
        case (.downloading, .downloadStarted): .downloading
        case (.resultsReady, .imported), (.downloading, .imported): .imported
        case (.downloading, .resultsReady): .resultsReady
        case (.submitted, .expired), (.running, .expired), (.uploaded, .expired): .expired
        case (.imported, _): nil
        case (_, .cancelled) where !state.isFinished: .cancelled
        case (_, .failed) where !state.isFinished: .failed
        case (.failed, .requeue), (.cancelled, .requeue), (.expired, .requeue), (.uploaded, .requeue),
             (.submitted, .requeue), (.running, .requeue), (.uploading, .requeue), (.preparing, .requeue):
            .queued
        case (.submitted, .resubmit), (.running, .resubmit), (.expired, .resubmit), (.failed, .resubmit),
             (.resultsReady, .resubmit), (.downloading, .resubmit):
            .uploaded
        default: nil
        }
    }
}

// MARK: - Selection

/// What the library knows about a song's lyrics.
public enum CloudLyricsState: Sendable, Hashable {
    case none
    /// Plain text, or line timing only (alignment adds word timing).
    case textOrLineSynced
    /// Word timing from a catalog or an earlier run: nothing to add.
    case wordSynced
    /// The person synced it themselves.
    case userSynced
}

/// One song's facts for selection (gathered by the app off the main actor).
public struct CloudSongFacts: Sendable, Hashable {
    public var songId: String
    public var durationMs: Int64
    public var hasInstrumental: Bool
    public var lyrics: CloudLyricsState
    /// A local file, a music-library item or a stream that can be downloaded.
    public var hasAudioSource: Bool
    public var isStreamed: Bool
    public var hasPendingJob: Bool

    public init(songId: String, durationMs: Int64, hasInstrumental: Bool, lyrics: CloudLyricsState,
                hasAudioSource: Bool, isStreamed: Bool, hasPendingJob: Bool) {
        self.songId = songId
        self.durationMs = durationMs
        self.hasInstrumental = hasInstrumental
        self.lyrics = lyrics
        self.hasAudioSource = hasAudioSource
        self.isStreamed = isStreamed
        self.hasPendingJob = hasPendingJob
    }
}

/// The person's choices (Settings › Cloud processing › Outputs, or the confirm sheet).
public struct CloudSelectionOptions: Sendable, Hashable {
    public var instrumental: Bool
    public var lyrics: Bool
    /// "Write lyrics when none are found (AI transcription)".
    public var transcribeWhenMissing: Bool
    /// Re-time lyrics the person synced themselves.
    public var replaceUserSynced: Bool

    public init(instrumental: Bool = true, lyrics: Bool = true, transcribeWhenMissing: Bool = true,
                replaceUserSynced: Bool = false) {
        self.instrumental = instrumental
        self.lyrics = lyrics
        self.transcribeWhenMissing = transcribeWhenMissing
        self.replaceUserSynced = replaceUserSynced
    }
}

/// Why a song wasn't sent.
public enum CloudSkipReason: String, Sendable, Hashable, CaseIterable, Error {
    case alreadyDone
    case pendingJob
    case noAudio
    case tooLong
    case userSynced
    case batchFull
    case tooManyStreamed

    public var label: String {
        switch self {
        case .alreadyDone: "Already has an instrumental and word-timed lyrics"
        case .pendingJob: "Already waiting in the cloud queue"
        case .noAudio: "No audio this iPhone can fetch"
        case .tooLong: "Longer than 15 minutes"
        case .userSynced: "You synced these lyrics yourself"
        case .batchFull: "More than 200 songs in one batch"
        case .tooManyStreamed: "More than 50 streamed songs in one batch"
        }
    }
}

/// What one song needs.
public struct CloudSongPlan: Sendable, Hashable {
    public var songId: String
    public var tasks: [CloudTask]
    /// `align` when the song has lyrics, `transcribe` when it has none.
    public var lyricsMode: CloudLyricsMode?
    public var isStreamed: Bool
    public var durationMs: Int64

    public init(songId: String, tasks: [CloudTask], lyricsMode: CloudLyricsMode?, isStreamed: Bool, durationMs: Int64) {
        self.songId = songId
        self.tasks = tasks
        self.lyricsMode = lyricsMode
        self.isStreamed = isStreamed
        self.durationMs = durationMs
    }
}

/// The outcome of selecting a batch.
public struct CloudSelection: Sendable, Hashable {
    public var plans: [CloudSongPlan]
    public var skipped: [(songId: String, reason: CloudSkipReason)]

    public init(plans: [CloudSongPlan], skipped: [(songId: String, reason: CloudSkipReason)]) {
        self.plans = plans
        self.skipped = skipped
    }

    public static func == (lhs: CloudSelection, rhs: CloudSelection) -> Bool {
        lhs.plans == rhs.plans && lhs.skipped.map(\.songId) == rhs.skipped.map(\.songId)
            && lhs.skipped.map(\.reason) == rhs.skipped.map(\.reason)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(plans)
        for item in skipped {
            hasher.combine(item.songId)
            hasher.combine(item.reason)
        }
    }

    /// Skips grouped by reason, most common first (the confirm sheet's summary).
    public var skipCounts: [(reason: CloudSkipReason, count: Int)] {
        var counts: [CloudSkipReason: Int] = [:]
        for item in skipped { counts[item.reason, default: 0] += 1 }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count == $1.count ? $0.reason.rawValue < $1.reason.rawValue : $0.count > $1.count }
    }
}

public enum CloudSelector {
    /// One song's plan, or why it is skipped. One job per song covers every missing task.
    public static func plan(_ facts: CloudSongFacts, options: CloudSelectionOptions) -> Result<CloudSongPlan, CloudSkipReason> {
        if facts.hasPendingJob { return .failure(.pendingJob) }
        if facts.durationMs > CloudLimits.maxDurationMs { return .failure(.tooLong) }
        var tasks: [CloudTask] = []
        if options.instrumental && !facts.hasInstrumental { tasks.append(.instrumental) }
        var mode: CloudLyricsMode?
        var userSyncedSkip = false
        if options.lyrics {
            switch facts.lyrics {
            case .none:
                if options.transcribeWhenMissing { mode = .transcribe }
            case .textOrLineSynced:
                mode = .align
            case .wordSynced:
                break
            case .userSynced:
                if options.replaceUserSynced { mode = .align } else { userSyncedSkip = true }
            }
        }
        if mode != nil { tasks.append(.lyrics) }
        guard !tasks.isEmpty else { return .failure(userSyncedSkip ? .userSynced : .alreadyDone) }
        guard facts.hasAudioSource else { return .failure(.noAudio) }
        return .success(CloudSongPlan(songId: facts.songId, tasks: tasks, lyricsMode: mode, isStreamed: facts.isStreamed,
                                      durationMs: facts.durationMs))
    }

    /// A batch in the given order, with the 200-song and 50-streamed caps.
    public static func select(_ songs: [CloudSongFacts], options: CloudSelectionOptions) -> CloudSelection {
        var plans: [CloudSongPlan] = []
        var skipped: [(songId: String, reason: CloudSkipReason)] = []
        var streamed = 0
        var seen = Set<String>()
        for facts in songs where seen.insert(facts.songId).inserted {
            switch plan(facts, options: options) {
            case .failure(let reason):
                skipped.append((facts.songId, reason))
            case .success(let plan):
                if plans.count >= CloudLimits.maxSongsPerBatch {
                    skipped.append((facts.songId, .batchFull))
                } else if plan.isStreamed && streamed >= CloudLimits.maxStreamedPerBatch {
                    skipped.append((facts.songId, .tooManyStreamed))
                } else {
                    if plan.isStreamed { streamed += 1 }
                    plans.append(plan)
                }
            }
        }
        return CloudSelection(plans: plans, skipped: skipped)
    }

    /// `synced: true` only when the lyrics' own timeline matches the audio: their reference duration within ±2 s of
    /// the audio's (a YouTube match with an intro or a radio edit would shift every line). No reference = trust them.
    public static func syncedHint(hasLineTimes: Bool, lyricsReferenceDurationMs: Int64?, audioDurationMs: Int64) -> Bool {
        guard hasLineTimes else { return false }
        guard let reference = lyricsReferenceDurationMs, reference > 0, audioDurationMs > 0 else { return true }
        return abs(reference - audioDurationMs) <= 2_000
    }

    /// `best` falls back to `standard` above 8 minutes.
    public static func quality(_ wanted: CloudSeparationQuality, durationMs: Int64) -> CloudSeparationQuality {
        wanted == .best && durationMs > CloudLimits.bestQualityMaxDurationMs ? .standard : wanted
    }
}

// MARK: - Batch gate

public enum CloudBatchGate {
    /// Submit a batch's uploaded jobs when every upload is done, or 2 minutes after the first one finished.
    public static func shouldSubmit(uploadsPending: Int, uploadsDone: Int, firstUploadDoneAtMs: Int64?, nowMs: Int64) -> Bool {
        guard uploadsDone > 0 else { return false }
        if uploadsPending == 0 { return true }
        guard let first = firstUploadDoneAtMs else { return false }
        return nowMs - first >= CloudTiming.batchGateMs
    }
}

// MARK: - Cost

/// Estimates and actual costs in micro-dollars (µ$; $1 = 1,000,000 µ$). RunPod Flex prices (§6).
public enum CloudCost {
    /// AMPERE_24 (L4 / A5000 / 3090): $0.000192/s — the Settings default.
    public static let defaultPricePerSecondMicroUSD: Int64 = 192
    /// AMPERE_16 (A4000 / A4500 / RTX 4000 Ada): $0.000161/s.
    public static let ampere16PricePerSecondMicroUSD: Int64 = 161
    /// ADA_24 (4090): $1.10/h.
    public static let ada24PricePerSecondMicroUSD: Int64 = 306
    /// The default app cap: $3 a month.
    public static let defaultMonthlyCapMicroUSD: Int64 = 3_000_000

    /// Billed GPU seconds per warm song (§6): instrumental + aligned lyrics.
    public static let warmSecondsStandard: Int64 = 20
    public static let extraSecondsTranscribe: Int64 = 10
    public static let extraSecondsBest: Int64 = 12
    public static let extraSecondsStems: Int64 = 5
    /// One cold start per batch: model load plus the 10 s idle timeout.
    public static let coldStartSeconds: Int64 = 35

    /// The per-second price for a GPU name from a manifest (`worker.gpu`), else `fallback`.
    public static func pricePerSecondMicroUSD(gpu: String?, fallback: Int64 = defaultPricePerSecondMicroUSD) -> Int64 {
        guard let gpu = gpu?.uppercased(), !gpu.isEmpty else { return fallback }
        if gpu.contains("4090") { return ada24PricePerSecondMicroUSD }
        if gpu.contains("A4000") || gpu.contains("A4500") || gpu.contains("RTX 4000") || gpu.contains("RTX 2000") {
            return ampere16PricePerSecondMicroUSD
        }
        if gpu.contains("L4") || gpu.contains("A5000") || gpu.contains("3090") { return defaultPricePerSecondMicroUSD }
        return fallback
    }

    /// Estimated GPU seconds for one song's plan (scaled by length: the figures are for a 4-minute song).
    public static func estimatedSeconds(_ plan: CloudSongPlan, quality: CloudSeparationQuality) -> Int64 {
        var seconds = warmSecondsStandard
        if plan.lyricsMode == .transcribe { seconds += extraSecondsTranscribe }
        if plan.tasks.contains(.stems4) { seconds += extraSecondsStems }
        if CloudSelector.quality(quality, durationMs: plan.durationMs) == .best { seconds += extraSecondsBest }
        let scale = max(Double(plan.durationMs) / 240_000, 0.25)
        return Int64((Double(seconds) * scale).rounded(.up))
    }

    /// A batch's estimate: one cold start plus every song warm.
    public static func estimateMicroUSD(_ plans: [CloudSongPlan], quality: CloudSeparationQuality,
                                        pricePerSecondMicroUSD: Int64) -> Int64 {
        guard !plans.isEmpty else { return 0 }
        let seconds = coldStartSeconds + plans.reduce(0) { $0 + estimatedSeconds($1, quality: quality) }
        return seconds * max(pricePerSecondMicroUSD, 0)
    }

    /// What a finished job cost: its billed time (total + its share of a cold start) at its GPU's price.
    public static func actualMicroUSD(timings: CloudTimings?, gpu: String?, fallbackPricePerSecondMicroUSD: Int64) -> Int64 {
        guard let timings else { return 0 }
        let ms = max(timings.totalMs ?? 0, 0) + max(timings.coldStartMs ?? 0, 0)
        let price = pricePerSecondMicroUSD(gpu: gpu, fallback: fallbackPricePerSecondMicroUSD)
        return (ms * price + 999) / 1000
    }

    /// "$0.39", "<$0.01".
    public static func format(microUSD: Int64) -> String {
        if microUSD > 0 && microUSD < 10_000 { return "<$0.01" }
        let cents = (microUSD + 5_000) / 10_000
        let tail = cents % 100
        return "$\(cents / 100).\(tail < 10 ? "0" : "")\(tail)"
    }
}

/// The monthly cap (§5, app guards): after it, submissions stop.
public enum CloudBudget {
    /// Cost recorded by jobs completed since `monthStartMs`.
    public static func spentMicroUSD(_ records: [CloudJobRecord], monthStartMs: Int64) -> Int64 {
        records.reduce(0) { sum, record in
            guard let done = record.completedAtMs, done >= monthStartMs else { return sum }
            return sum + max(record.costMicroUSD ?? 0, 0)
        }
    }

    public static func remainingMicroUSD(capMicroUSD: Int64, spentMicroUSD: Int64) -> Int64 {
        max(capMicroUSD - spentMicroUSD, 0)
    }

    /// A batch may go out when its estimate fits what is left this month.
    public static func allows(estimateMicroUSD: Int64, capMicroUSD: Int64, spentMicroUSD: Int64) -> Bool {
        estimateMicroUSD <= remainingMicroUSD(capMicroUSD: capMicroUSD, spentMicroUSD: spentMicroUSD)
    }

    /// Start of the UTC month containing `nowMs` (the app passes its local month start instead when it has one).
    public static func utcMonthStartMs(_ nowMs: Int64) -> Int64 {
        let date = S3Signer.amzDate(nowMs / 1000)
        guard let year = Int64(date.prefix(4)), let month = Int64(date.dropFirst(4).prefix(2)) else { return 0 }
        // days_from_civil for the 1st of the month.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return (era * 146_097 + doe - 719_468) * 86_400_000
    }
}

// MARK: - Import checks

public enum CloudImportCheck {
    /// One AAC frame of slack (priming / remainder).
    public static let sampleToleranceFrames: Int64 = 1024
    /// The worker's decode rate.
    public static let workerSampleRate: Int64 = 44_100

    /// The downloaded file is the one the manifest describes.
    public static func matches(expectedBytes: Int64, expectedSHA256: String, actualBytes: Int64, actualSHA256: String) -> Bool {
        expectedBytes == actualBytes && expectedSHA256.lowercased() == actualSHA256.lowercased()
    }

    /// The result's length equals the phone's own decode of the source within ±1 AAC frame (R13), comparing at the
    /// worker's 44.1 kHz.
    public static func samplesMatch(sourceFrames: Int64, sourceSampleRate: Double, resultFrames: Int64,
                                    resultSampleRate: Double) -> Bool {
        guard sourceFrames > 0, resultFrames > 0, sourceSampleRate > 0, resultSampleRate > 0 else { return false }
        let source = Double(sourceFrames) * Double(workerSampleRate) / sourceSampleRate
        let result = Double(resultFrames) * Double(workerSampleRate) / resultSampleRate
        return abs(source - result) <= Double(sampleToleranceFrames) + 1
    }
}

// MARK: - Retention and lost jobs

public enum CloudRetention {
    /// Job history is kept 30 days after import, then pruned.
    public static let keepImportedMs: Int64 = 30 * 86_400_000
    /// Failed / cancelled / expired records go after 30 days too.
    public static let keepFinishedMs: Int64 = 30 * 86_400_000
    /// R2 lifecycle backstops (owner step D8).
    public static let inputLifecycleDays = 7
    public static let outputLifecycleDays = 30

    public static func shouldPrune(_ record: CloudJobRecord, nowMs: Int64) -> Bool {
        switch record.state {
        case .imported: return nowMs - (record.importedAtMs ?? record.createdAtMs) > keepImportedMs
        case .failed, .cancelled, .expired: return nowMs - (record.updatedAtMs ?? record.createdAtMs) > keepFinishedMs
        default: return false
        }
    }

    /// A submitted job whose ttl (plus its execution time) has passed without a manifest in R2 is lost.
    public static func isPastTTL(submittedAtMs: Int64, nowMs: Int64) -> Bool {
        nowMs - submittedAtMs > CloudTiming.ttlMs + CloudTiming.executionTimeoutMs
    }

    /// The uploaded input is too old to submit (upload again first).
    public static func inputTooOldToSubmit(uploadedAtMs: Int64?, nowMs: Int64) -> Bool {
        guard let uploadedAtMs else { return true }
        return nowMs - uploadedAtMs > CloudTiming.maxInputAgeAtSubmitMs
    }

    /// The upload's own presigned PUT has expired (re-sign and start again).
    public static func uploadURLExpired(expiresAtMs: Int64?, nowMs: Int64) -> Bool {
        guard let expiresAtMs else { return true }
        return nowMs >= expiresAtMs
    }
}

/// Paused-endpoint detection (§7.4, risk R5).
public enum CloudEndpointWatch {
    /// Jobs have waited more than 30 minutes while the endpoint shows no idle and no running workers: RunPod paused
    /// it, or no GPU is free in its pools.
    public static func looksPaused(oldestWaitingSinceMs: Int64?, nowMs: Int64, health: RunPodHealth) -> Bool {
        guard let since = oldestWaitingSinceMs, nowMs - since > CloudTiming.pausedEndpointAfterMs else { return false }
        return health.idleWorkers == 0 && health.runningWorkers == 0 && health.initializingWorkers == 0
    }

    public static let pausedMessage = "RunPod paused this endpoint, or no GPU is free right now. Run the keepalive workflow on GitHub, or wait and try again later."
}
