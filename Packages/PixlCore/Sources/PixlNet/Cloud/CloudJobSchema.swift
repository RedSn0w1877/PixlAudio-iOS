// Cloud Studio job schema v1 (design: docs/handoff/2026-10-07-plans/cloud-studio-design.md §2.3). These are the
// phone's copies of `cloud/runpod-worker/schema/v1/*.schema.json`: the `/run` body the phone sends, the result
// manifest the worker returns (and writes to R2 as `manifest.json`), and `lyrics.json`.
//
// Versioning (§2.3): `v` is an integer major version; new optional fields don't bump it and both sides ignore unknown
// fields. Everything the worker may leave out on an error path is optional here, so a short error manifest still
// decodes. Enum-like fields stay `String` on the wire (an unknown value from a newer worker must not fail the whole
// manifest); typed views sit next to them.

import Foundation

/// Schema names and the version this app speaks.
public enum CloudSchema {
    public static let version = 1
    /// Versions this app can send and read (selftest reports the worker's own list).
    public static let supportedVersions: [Int] = [1]
    public static let job = "pixl.cloudstudio.job"
    public static let result = "pixl.cloudstudio.result"
    public static let lyrics = "pixl.cloudstudio.lyrics"
    /// `client.app`.
    public static let clientApp = "pixlaudio-ios"
}

/// `input.op`.
public enum CloudOp: String, Sendable, CaseIterable {
    case process
    case selftest
    case bench
}

/// `input.tasks` entries.
public enum CloudTask: String, Sendable, CaseIterable, Codable {
    case instrumental
    case vocals
    case stems4
    case lyrics

    /// The `output.put` keys a task needs (`stems4` needs drums, bass and other).
    public var outputSlots: [String] {
        switch self {
        case .instrumental: ["instrumental"]
        case .vocals: ["vocals"]
        case .stems4: ["drums", "bass", "other"]
        case .lyrics: ["lyrics"]
        }
    }
}

/// `input.storage`.
public enum CloudStorageMode: String, Sendable, CaseIterable {
    case presigned
    case volume
}

/// `input.separation.quality`: `standard` = overlap 2, `best` = overlap 4 (songs ≤ 8 min).
public enum CloudSeparationQuality: String, Sendable, CaseIterable, Codable {
    case standard
    case best
}

/// `input.lyrics.mode`.
public enum CloudLyricsMode: String, Sendable, CaseIterable, Codable {
    /// Needs `lines`.
    case align
    /// Ignores `lines`.
    case transcribe
    /// Aligns when there are lines, transcribes otherwise.
    case auto
}

/// `input.output.codec`.
public enum CloudOutputCodec: String, Sendable, CaseIterable, Codable {
    case aac
    case flac

    /// The file extension of an audio output in this codec.
    public var fileExtension: String { self == .aac ? "m4a" : "flac" }
}

// MARK: - Input (the /run body)

/// The whole `/run` body: `{"input": …, "policy": …}`.
public struct CloudJobRequest: Codable, Sendable, Hashable {
    public var input: CloudJobInput
    public var policy: CloudJobPolicy?

    public init(input: CloudJobInput, policy: CloudJobPolicy?) {
        self.input = input
        self.policy = policy
    }
}

/// RunPod's per-request execution policy (milliseconds). `ttl` covers queue time and is a hard kill.
public struct CloudJobPolicy: Codable, Sendable, Hashable {
    public var ttl: Int64
    public var executionTimeout: Int64

    public init(ttl: Int64, executionTimeout: Int64) {
        self.ttl = ttl
        self.executionTimeout = executionTimeout
    }
}

/// `input` for `op: "process"` (and the shared head of the other ops).
public struct CloudJobInput: Codable, Sendable, Hashable {
    public var schema: String
    public var v: Int
    public var op: String
    public var jobKey: String?
    public var client: CloudClientInfo?
    public var storage: String?
    public var audio: CloudAudioInput?
    public var tasks: [String]?
    public var separation: CloudSeparation?
    public var lyrics: CloudLyricsRequest?
    public var output: CloudOutputRequest?
    /// Optional (an old app may omit it); without it the worker just processes the job.
    public var `guard`: CloudJobGuard?

    public init(schema: String = CloudSchema.job, v: Int = CloudSchema.version, op: String = CloudOp.process.rawValue,
                jobKey: String? = nil, client: CloudClientInfo? = nil, storage: String? = nil,
                audio: CloudAudioInput? = nil, tasks: [String]? = nil, separation: CloudSeparation? = nil,
                lyrics: CloudLyricsRequest? = nil, output: CloudOutputRequest? = nil, guard: CloudJobGuard? = nil) {
        self.schema = schema
        self.v = v
        self.op = op
        self.jobKey = jobKey
        self.client = client
        self.storage = storage
        self.audio = audio
        self.tasks = tasks
        self.separation = separation
        self.lyrics = lyrics
        self.output = output
        self.guard = `guard`
    }

    /// The typed tasks (unknown entries dropped).
    public var typedTasks: [CloudTask] { (tasks ?? []).compactMap(CloudTask.init(rawValue:)) }
}

/// `input.client`.
public struct CloudClientInfo: Codable, Sendable, Hashable {
    public var app: String
    public var build: String

    public init(app: String = CloudSchema.clientApp, build: String) {
        self.app = app
        self.build = build
    }
}

/// `input.audio`. Presigned mode carries `get`/`delete`; the volume fallback carries `key` instead.
public struct CloudAudioInput: Codable, Sendable, Hashable {
    public var get: String?
    public var delete: String?
    /// Volume fallback only: `in/<jobKey>.<ext>`.
    public var key: String?
    public var ext: String
    public var bytes: Int64
    /// Lower-case hex.
    public var sha256: String
    public var durationMs: Int64

    public init(get: String? = nil, delete: String? = nil, key: String? = nil, ext: String, bytes: Int64,
                sha256: String, durationMs: Int64) {
        self.get = get
        self.delete = delete
        self.key = key
        self.ext = ext
        self.bytes = bytes
        self.sha256 = sha256
        self.durationMs = durationMs
    }
}

/// `input.separation`.
public struct CloudSeparation: Codable, Sendable, Hashable {
    public var quality: String

    public init(quality: CloudSeparationQuality) { self.quality = quality.rawValue }
}

/// `input.lyrics`.
public struct CloudLyricsRequest: Codable, Sendable, Hashable {
    public var mode: String
    /// Optional ISO 639-1 hint (`NLLanguageRecognizer`).
    public var language: String?
    /// `false` = plain lyrics without line times (the worker takes windows from VAD).
    public var synced: Bool
    public var lines: [CloudLyricsInputLine]?

    public init(mode: CloudLyricsMode, language: String?, synced: Bool, lines: [CloudLyricsInputLine]?) {
        self.mode = mode.rawValue
        self.language = language
        self.synced = synced
        self.lines = lines
    }
}

/// One known lyric line sent for alignment.
public struct CloudLyricsInputLine: Codable, Sendable, Hashable {
    public var startMs: Int64?
    public var endMs: Int64?
    public var text: String

    public init(startMs: Int64?, endMs: Int64?, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

/// `input.output`: codec and one presigned PUT per output slot (`instrumental`, `vocals`, `drums`, `bass`, `other`,
/// `lyrics`, `manifest`).
public struct CloudOutputRequest: Codable, Sendable, Hashable {
    public var codec: String
    public var kbps: Int?
    public var put: [String: String]

    public init(codec: CloudOutputCodec, kbps: Int?, put: [String: String]) {
        self.codec = codec.rawValue
        self.kbps = kbps
        self.put = put
    }
}

/// `input.guard`: the duplicate / poison checks the worker runs before downloading anything.
public struct CloudJobGuard: Codable, Sendable, Hashable {
    public var manifestGet: String
    public var attemptGet: String
    public var attemptPut: String

    public init(manifestGet: String, attemptGet: String, attemptPut: String) {
        self.manifestGet = manifestGet
        self.attemptGet = attemptGet
        self.attemptPut = attemptPut
    }
}

/// `op: "selftest"` / `"bench"`: no audio, no URLs.
public struct CloudOpRequest: Codable, Sendable, Hashable {
    public var input: CloudJobInput

    public init(op: CloudOp, build: String) {
        input = CloudJobInput(op: op.rawValue, client: CloudClientInfo(build: build))
    }
}

// MARK: - Result (job output = manifest.json)

/// `status`.
public enum CloudResultStatus: String, Sendable, CaseIterable {
    case ok
    /// The instrumental arrived but lyrics failed (reason in `warnings`).
    case partial
    case error
}

/// The worker's error codes (§2.3).
public enum CloudErrorCode: String, Sendable, CaseIterable {
    case badSchema = "BAD_SCHEMA"
    case unsupportedVersion = "UNSUPPORTED_VERSION"
    case badOp = "BAD_OP"
    case badURL = "BAD_URL"
    case inputTooLarge = "INPUT_TOO_LARGE"
    case inputMismatch = "INPUT_MISMATCH"
    case tooLong = "TOO_LONG"
    case unsupportedFormat = "UNSUPPORTED_FORMAT"
    case decodeFailed = "DECODE_FAILED"
    case gpuOOM = "GPU_OOM"
    case deadline = "DEADLINE"
    case uploadFailed = "UPLOAD_FAILED"
    case `internal` = "INTERNAL"
    /// The guard refused a third delivery of the same RunPod job.
    case poisoned = "POISONED"
    /// The input GET answered 404: upload again rather than retrying blindly.
    case inputMissing = "INPUT_MISSING"

    /// Whether the phone should try the same job again later (with the backoff ladder) rather than give up.
    public var isRetryable: Bool {
        switch self {
        case .gpuOOM, .deadline, .uploadFailed, .internal, .inputMissing, .badURL: true
        case .badSchema, .unsupportedVersion, .badOp, .inputTooLarge, .inputMismatch, .tooLong, .unsupportedFormat,
             .decodeFailed, .poisoned: false
        }
    }

    /// The input has to be uploaded again before a retry.
    public var needsReupload: Bool { self == .inputMissing || self == .inputMismatch }

    /// Plain words for the queue screen (the code stays visible next to it).
    public var message: String {
        switch self {
        case .badSchema, .unsupportedVersion, .badOp: "The cloud worker doesn't understand this app version."
        case .badURL: "The upload links were refused or had expired."
        case .inputTooLarge: "This song's file is too big for the cloud worker."
        case .inputMismatch: "The uploaded file didn't arrive intact."
        case .tooLong: "This song is longer than 15 minutes."
        case .unsupportedFormat: "The cloud worker can't read this audio format."
        case .decodeFailed: "The cloud worker couldn't decode this song."
        case .gpuOOM: "The GPU ran out of memory."
        case .deadline: "The job ran out of time."
        case .uploadFailed: "The worker couldn't upload the results."
        case .internal: "The cloud worker hit an internal error."
        case .poisoned: "This song crashed the worker twice, so it was stopped."
        case .inputMissing: "The uploaded song was gone; it will be uploaded again."
        }
    }
}

/// The result manifest (`pixl.cloudstudio.result` v1): identical to the RunPod job output and to `manifest.json`.
public struct CloudJobResult: Codable, Sendable, Hashable {
    public var schema: String
    public var v: Int
    public var jobKey: String
    public var status: String
    public var error: CloudResultError?
    public var warnings: [String]?
    public var worker: CloudWorkerInfo?
    public var models: CloudModelsInfo?
    public var input: CloudInputInfo?
    public var outputs: [String: CloudOutputFile]?
    public var lyrics: CloudLyricsSummary?
    public var timings: CloudTimings?

    public init(schema: String = CloudSchema.result, v: Int = CloudSchema.version, jobKey: String, status: CloudResultStatus,
                error: CloudResultError? = nil, warnings: [String]? = nil, worker: CloudWorkerInfo? = nil,
                models: CloudModelsInfo? = nil, input: CloudInputInfo? = nil, outputs: [String: CloudOutputFile]? = nil,
                lyrics: CloudLyricsSummary? = nil, timings: CloudTimings? = nil) {
        self.schema = schema
        self.v = v
        self.jobKey = jobKey
        self.status = status.rawValue
        self.error = error
        self.warnings = warnings
        self.worker = worker
        self.models = models
        self.input = input
        self.outputs = outputs
        self.lyrics = lyrics
        self.timings = timings
    }

    /// The typed status (an unknown status reads as `error`).
    public var typedStatus: CloudResultStatus { CloudResultStatus(rawValue: status) ?? .error }
    /// The typed error code, when the worker sent a known one.
    public var errorCode: CloudErrorCode? { error.flatMap { CloudErrorCode(rawValue: $0.code) } }
    /// `ok` or `partial`: something is there to import.
    public var hasResults: Bool { typedStatus != .error }
    /// The worker flagged this result as returned by the duplicate guard.
    public var isDuplicate: Bool { (warnings ?? []).contains("duplicate") }
}

/// `error` of an error manifest.
public struct CloudResultError: Codable, Sendable, Hashable {
    public var code: String
    public var message: String?

    public init(code: String, message: String?) {
        self.code = code
        self.message = message
    }
}

/// `worker`.
public struct CloudWorkerInfo: Codable, Sendable, Hashable {
    public var version: String?
    public var gitSha: String?
    public var gpu: String?
    public var vramGB: Double?
    public var cuda: String?

    public init(version: String?, gitSha: String?, gpu: String?, vramGB: Double?, cuda: String?) {
        self.version = version
        self.gitSha = gitSha
        self.gpu = gpu
        self.vramGB = vramGB
        self.cuda = cuda
    }
}

/// `models` (null entries were not used by this job).
public struct CloudModelsInfo: Codable, Sendable, Hashable {
    public var separator: String?
    public var stems4: String?
    public var aligner: String?
    public var asr: String?

    public init(separator: String?, stems4: String?, aligner: String?, asr: String?) {
        self.separator = separator
        self.stems4 = stems4
        self.aligner = aligner
        self.asr = asr
    }
}

/// `input` of the manifest: what the worker decoded.
public struct CloudInputInfo: Codable, Sendable, Hashable {
    public var codec: String?
    public var sampleRate: Int?
    public var channels: Int?
    public var decodedSamples: Int64?
    public var durationMs: Int64?

    public init(codec: String?, sampleRate: Int?, channels: Int?, decodedSamples: Int64?, durationMs: Int64?) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.decodedSamples = decodedSamples
        self.durationMs = durationMs
    }
}

/// One output file in R2.
public struct CloudOutputFile: Codable, Sendable, Hashable {
    /// `out/<jobKey>/<slot>.<ext>`.
    public var key: String
    public var bytes: Int64
    public var sha256: String
    public var codec: String?
    public var kbps: Int?
    /// Decoded sample frames per channel (44.1 kHz), for the priming check.
    public var samples: Int64?

    public init(key: String, bytes: Int64, sha256: String, codec: String?, kbps: Int?, samples: Int64?) {
        self.key = key
        self.bytes = bytes
        self.sha256 = sha256
        self.codec = codec
        self.kbps = kbps
        self.samples = samples
    }
}

/// `lyrics` of the manifest: where `lyrics.json` is and what it holds.
public struct CloudLyricsSummary: Codable, Sendable, Hashable {
    public var key: String
    /// `aligned` or `transcribed` (machine-written text).
    public var mode: String?
    public var language: String?
    public var lines: Int?
    public var wordTimedLines: Int?
    public var words: Int?
    /// The global shift the worker's offset check applied to the line times (§2.4 stage 6), when > 1 s.
    public var lyricsOffsetMs: Int64?

    public init(key: String, mode: String?, language: String?, lines: Int?, wordTimedLines: Int?, words: Int?,
                lyricsOffsetMs: Int64? = nil) {
        self.key = key
        self.mode = mode
        self.language = language
        self.lines = lines
        self.wordTimedLines = wordTimedLines
        self.words = words
        self.lyricsOffsetMs = lyricsOffsetMs
    }
}

/// `timings` (milliseconds). `coldStartMs` is non-zero only on the first job of a worker process.
public struct CloudTimings: Codable, Sendable, Hashable {
    public var coldStartMs: Int64?
    public var downloadMs: Int64?
    public var decodeMs: Int64?
    public var separateMs: Int64?
    public var stemsMs: Int64?
    public var lyricsMs: Int64?
    public var encodeMs: Int64?
    public var uploadMs: Int64?
    public var totalMs: Int64?

    public init(coldStartMs: Int64? = nil, downloadMs: Int64? = nil, decodeMs: Int64? = nil, separateMs: Int64? = nil,
                stemsMs: Int64? = nil, lyricsMs: Int64? = nil, encodeMs: Int64? = nil, uploadMs: Int64? = nil,
                totalMs: Int64? = nil) {
        self.coldStartMs = coldStartMs
        self.downloadMs = downloadMs
        self.decodeMs = decodeMs
        self.separateMs = separateMs
        self.stemsMs = stemsMs
        self.lyricsMs = lyricsMs
        self.encodeMs = encodeMs
        self.uploadMs = uploadMs
        self.totalMs = totalMs
    }
}

// MARK: - lyrics.json

/// `pixl.cloudstudio.lyrics` v1.
public struct CloudLyricsDocument: Codable, Sendable, Hashable {
    public var schema: String
    public var v: Int
    /// `aligned` or `transcribed`.
    public var mode: String
    public var language: String?
    public var lines: [CloudLyricsLine]

    public init(schema: String = CloudSchema.lyrics, v: Int = CloudSchema.version, mode: String, language: String?,
                lines: [CloudLyricsLine]) {
        self.schema = schema
        self.v = v
        self.mode = mode
        self.language = language
        self.lines = lines
    }

    /// Machine-written text (shown as "AI-written lyrics").
    public var isTranscribed: Bool { mode == "transcribed" }
}

/// One line: the original text unchanged, with word timing (`timing: "word"`) or only line timing (`"line"`).
public struct CloudLyricsLine: Codable, Sendable, Hashable {
    public var i: Int?
    public var startMs: Int64
    public var endMs: Int64
    public var text: String
    public var timing: String?
    public var words: [CloudLyricsWord]?

    public init(i: Int?, startMs: Int64, endMs: Int64, text: String, timing: String?, words: [CloudLyricsWord]?) {
        self.i = i
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.timing = timing
        self.words = words
    }

    public var isWordTimed: Bool { timing != "line" && !(words ?? []).isEmpty }
}

/// One aligned word: its time and its UTF-16 range `[c0, c1)` in the original line text.
public struct CloudLyricsWord: Codable, Sendable, Hashable {
    public var startMs: Int64
    public var endMs: Int64
    public var text: String
    public var conf: Double?
    public var c0: Int
    public var c1: Int

    public init(startMs: Int64, endMs: Int64, text: String, conf: Double?, c0: Int, c1: Int) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.conf = conf
        self.c0 = c0
        self.c1 = c1
    }
}

// MARK: - Coding

/// JSON encoding and decoding for the schema types (stable key order, so request bodies are reproducible).
public enum CloudJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
