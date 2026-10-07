// RunPod Serverless job API for the Cloud Studio endpoint (design §1, §5, §7.1): `/run`, `/status`, `/cancel`,
// `/health`, and `/runsync` for the selftest only. The phone holds a Restricted key (Read/Write on this one endpoint)
// and calls nothing else: it never creates or changes endpoints and never reads billing.
//
// Behaviour:
// - A 429 sets a Retry-After gate: every call before it ends fails fast with `.rateLimited` (SpotifyConnectClient's
//   pattern).
// - Reads (`/status`, `/health`) retry a 5xx or a dropped connection twice with backoff. `/run` is never retried here:
//   a lost response may still have queued the job, so the orchestrator decides (the worker's guard makes a duplicate
//   harmless).
// - `/run` calls are at least 100 ms apart (§5, app guards).
// - A `/status` 404 is `.jobNotFound` ("expired or never existed"; results then come from R2), a 404 anywhere else is
//   `.endpointNotFound`.

import Foundation
import PixlFoundation
import PixlModel

/// RunPod's job states.
public enum RunPodJobStatus: String, Sendable, CaseIterable {
    case inQueue = "IN_QUEUE"
    case inProgress = "IN_PROGRESS"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
    case timedOut = "TIMED_OUT"

    /// The job will not change any more.
    public var isFinal: Bool { self == .completed || self == .failed || self == .cancelled || self == .timedOut }
}

/// The worker's `progress_update` text, `stage:pct` (e.g. `separate:40`).
public struct CloudProgress: Sendable, Hashable {
    public var stage: String
    public var percent: Int?

    public init(stage: String, percent: Int?) {
        self.stage = stage
        self.percent = percent
    }

    /// Parses `stage:pct` (or a bare stage name).
    public static func parse(_ text: String) -> CloudProgress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64, !trimmed.hasPrefix("{") else { return nil }
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let stage = String(parts[0])
        guard !stage.isEmpty, stage.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        let percent = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)).map { min(max($0, 0), 100) } : nil
        return CloudProgress(stage: stage, percent: percent)
    }

    /// A short label for the queue screen.
    public var label: String {
        switch stage {
        case "fetch", "download": "Fetching the song"
        case "probe", "decode": "Reading the audio"
        case "separate": "Separating vocals"
        case "stems4", "stems": "Splitting stems"
        case "lyrics", "align": "Timing the lyrics"
        case "transcribe": "Writing the lyrics"
        case "encode": "Encoding"
        case "upload": "Uploading results"
        case "guard": "Starting"
        default: stage.capitalized
        }
    }
}

/// A job as `/run`, `/status`, `/runsync` and `/cancel` describe it.
public struct RunPodJob: Sendable, Hashable {
    public var id: String
    public var status: String
    /// The manifest, when the output is one (`pixl.cloudstudio.result`).
    public var result: CloudJobResult?
    /// A text output: the progress string while running.
    public var outputText: String?
    /// The raw output JSON when it is an object that isn't a manifest (the selftest's).
    public var outputJSON: JSONValue?
    /// RunPod's `error` (the handler returns `"<CODE>: <message>"`).
    public var error: String?
    public var delayTimeMs: Int64?
    public var executionTimeMs: Int64?

    public init(id: String, status: String, result: CloudJobResult? = nil, outputText: String? = nil,
                outputJSON: JSONValue? = nil, error: String? = nil, delayTimeMs: Int64? = nil,
                executionTimeMs: Int64? = nil) {
        self.id = id
        self.status = status
        self.result = result
        self.outputText = outputText
        self.outputJSON = outputJSON
        self.error = error
        self.delayTimeMs = delayTimeMs
        self.executionTimeMs = executionTimeMs
    }

    public var typedStatus: RunPodJobStatus? { RunPodJobStatus(rawValue: status) }

    /// Progress while running.
    public var progress: CloudProgress? { outputText.flatMap(CloudProgress.parse) }

    /// The worker error code in a failed job's `error` (`"POISONED: …"`), else the manifest's.
    public var errorCode: CloudErrorCode? {
        if let code = result?.errorCode { return code }
        guard let error else { return nil }
        let head = error.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
        return head.flatMap(CloudErrorCode.init(rawValue:))
    }

    /// Parses a RunPod job response body.
    public static func parse(_ body: Data) -> RunPodJob? {
        guard let json = try? JSONParser().parse(utf8: [UInt8](body)), let object = json.objectValue,
              let id = object["id"]?.stringValue, !id.isEmpty else { return nil }
        var job = RunPodJob(id: id, status: object["status"]?.stringValue ?? "")
        job.delayTimeMs = object["delayTime"]?.int64Value
        job.executionTimeMs = object["executionTime"]?.int64Value
        if let error = object["error"] {
            job.error = error.stringValue ?? (error.isNull ? nil : JSONWriter.write(error))
        }
        switch object["output"] {
        case .string(let text)?:
            job.outputText = text
        case .object(let output)?:
            let value = JSONValue.object(output)
            if output["schema"]?.stringValue == CloudSchema.result,
               let result = try? CloudJSON.decode(CloudJobResult.self, from: Data(JSONWriter.write(value).utf8)) {
                job.result = result
            } else if let error = output["error"]?.stringValue, job.error == nil {
                job.error = error
                job.outputJSON = value
            } else {
                job.outputJSON = value
            }
        default:
            break
        }
        return job
    }
}

/// `/health`: queue and worker counts.
public struct RunPodHealth: Sendable, Hashable {
    public var inQueue: Int
    public var inProgress: Int
    public var completed: Int
    public var failed: Int
    public var idleWorkers: Int
    public var runningWorkers: Int
    public var initializingWorkers: Int
    public var unhealthyWorkers: Int

    public init(inQueue: Int = 0, inProgress: Int = 0, completed: Int = 0, failed: Int = 0, idleWorkers: Int = 0,
                runningWorkers: Int = 0, initializingWorkers: Int = 0, unhealthyWorkers: Int = 0) {
        self.inQueue = inQueue
        self.inProgress = inProgress
        self.completed = completed
        self.failed = failed
        self.idleWorkers = idleWorkers
        self.runningWorkers = runningWorkers
        self.initializingWorkers = initializingWorkers
        self.unhealthyWorkers = unhealthyWorkers
    }

    public static func parse(_ body: Data) -> RunPodHealth? {
        guard let json = try? JSONParser().parse(utf8: [UInt8](body)), json.objectValue != nil else { return nil }
        func int(_ group: String, _ key: String) -> Int { Int(json[group]?[key]?.int64Value ?? 0) }
        return RunPodHealth(inQueue: int("jobs", "inQueue"), inProgress: int("jobs", "inProgress"),
                            completed: int("jobs", "completed"), failed: int("jobs", "failed"),
                            idleWorkers: int("workers", "idle") + int("workers", "ready"),
                            runningWorkers: int("workers", "running"),
                            initializingWorkers: int("workers", "initializing"),
                            unhealthyWorkers: int("workers", "unhealthy"))
    }
}

/// A RunPod request failed.
public enum RunPodError: Error, Sendable, Hashable, CustomStringConvertible {
    /// 401/403: the key is wrong, disabled, or not allowed on this endpoint.
    case unauthorized(status: Int)
    /// 404 on the endpoint: the Endpoint ID is wrong (or the endpoint was deleted).
    case endpointNotFound
    /// 404 on `/status/<id>`: the job's 30-minute retention (or its ttl) passed, or it never existed.
    case jobNotFound
    /// 429; calls fail fast until the gate ends.
    case rateLimited(retryAfterMs: Int64)
    case server(status: Int)
    case http(status: Int)
    case network(String)
    case badResponse(String)
    /// The Endpoint ID or key is missing or malformed.
    case notConfigured

    public var description: String {
        switch self {
        case .unauthorized(let status): "RunPod refused the key (HTTP \(status))"
        case .endpointNotFound: "Endpoint not found — check the Endpoint ID"
        case .jobNotFound: "Job not found (expired)"
        case .rateLimited(let ms): "Rate limited for \(ms / 1000) s"
        case .server(let status): "RunPod server error (HTTP \(status))"
        case .http(let status): "RunPod answered HTTP \(status)"
        case .network(let message): "Network error: \(message)"
        case .badResponse(let message): "Unexpected RunPod answer: \(message)"
        case .notConfigured: "RunPod isn't set up"
        }
    }
}

/// What the orchestrator needs from RunPod. `RunPodJobsClient` is the real one; app tests use fakes.
public protocol RunPodJobsAPI: Sendable {
    func run(_ request: CloudJobRequest) async throws -> RunPodJob
    func status(jobId: String) async throws -> RunPodJob
    func cancel(jobId: String) async throws
    func health() async throws -> RunPodHealth
    /// `/runsync` with `op: "selftest"` (about one cold start, ~1¢).
    func selftest(build: String) async throws -> RunPodJob
}

public actor RunPodJobsClient: RunPodJobsAPI {
    public static let baseURL = "https://api.runpod.ai/v2"
    /// §5: one `/run` per 100 ms or slower.
    public static let minimumRunIntervalMs: Int64 = 100
    /// Backoff before the 2nd and 3rd try of a read.
    public static let readRetryDelaysMs: [Int64] = [1_000, 3_000]

    private let http: any HTTPClient
    private let endpointId: String
    private let apiKey: String
    private let nowMs: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private var notBeforeMs: Int64 = 0
    private var lastRunAtMs: Int64?

    public init(http: any HTTPClient, endpointId: String, apiKey: String,
                nowMs: @escaping @Sendable () -> Int64 = { currentTimeMillis() },
                sleep: @escaping @Sendable (Int64) async throws -> Void = {
                    try await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000)
                }) {
        self.http = http
        self.endpointId = endpointId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.nowMs = nowMs
        self.sleep = sleep
    }

    /// RunPod endpoint ids are short lower-case alphanumerics; anything else can't be put in a URL path.
    public static func isValidEndpointId(_ id: String) -> Bool { isSafeIdentifier(id, maxLength: 64) }

    static func isSafeIdentifier(_ id: String, maxLength: Int) -> Bool {
        !id.isEmpty && id.utf8.count <= maxLength
            && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
    }

    /// How long the Retry-After gate still holds (0 = open).
    public var retryAfterRemainingMs: Int64 { max(notBeforeMs - nowMs(), 0) }

    // MARK: API

    public func run(_ request: CloudJobRequest) async throws -> RunPodJob {
        if let last = lastRunAtMs {
            let wait = Self.minimumRunIntervalMs - (nowMs() - last)
            if wait > 0 { try await sleep(wait) }
        }
        let body = try CloudJSON.encode(request)
        lastRunAtMs = nowMs()
        let response = try await send(.post, path: "run", body: body, retries: false)
        guard let job = RunPodJob.parse(response.body) else { throw RunPodError.badResponse("no job id") }
        return job
    }

    public func status(jobId: String) async throws -> RunPodJob {
        guard Self.isSafeIdentifier(jobId, maxLength: 128) else { throw RunPodError.jobNotFound }
        let response = try await send(.get, path: "status/\(jobId)", retries: true, notFound: .jobNotFound)
        guard let job = RunPodJob.parse(response.body) else { throw RunPodError.badResponse("unreadable job status") }
        return job
    }

    public func cancel(jobId: String) async throws {
        guard Self.isSafeIdentifier(jobId, maxLength: 128) else { throw RunPodError.jobNotFound }
        _ = try await send(.post, path: "cancel/\(jobId)", retries: true, notFound: .jobNotFound)
    }

    public func health() async throws -> RunPodHealth {
        let response = try await send(.get, path: "health", retries: true)
        guard let health = RunPodHealth.parse(response.body) else { throw RunPodError.badResponse("unreadable health") }
        return health
    }

    public func selftest(build: String) async throws -> RunPodJob {
        let body = try CloudJSON.encode(CloudOpRequest(op: .selftest, build: build))
        let response = try await send(.post, path: "runsync", body: body, retries: false, timeout: 150)
        guard let job = RunPodJob.parse(response.body) else { throw RunPodError.badResponse("no selftest answer") }
        return job
    }

    // MARK: Transport

    private func send(_ method: HTTPMethod, path: String, body: Data? = nil, retries: Bool,
                      notFound: RunPodError = .endpointNotFound, timeout: Double = 30) async throws -> HTTPResponse {
        guard Self.isValidEndpointId(endpointId), !apiKey.isEmpty else { throw RunPodError.notConfigured }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let wait = notBeforeMs - nowMs()
            if wait > 0 { throw RunPodError.rateLimited(retryAfterMs: wait) }
            var request = HTTPRequest(method: method, url: "\(Self.baseURL)/\(endpointId)/\(path)", body: body,
                                      timeout: timeout)
            request.setHeader("Authorization", "Bearer \(apiKey)")
            request.setHeader("Accept", "application/json")
            if body != nil { request.setHeader("Content-Type", "application/json") }
            let failure: RunPodError
            do {
                let response = try await http.send(request)
                switch response.statusCode {
                case 200...299: return response
                case 401, 403: throw RunPodError.unauthorized(status: response.statusCode)
                case 404: throw notFound
                case 429:
                    let ms = Self.retryAfterMs(response.header("Retry-After"))
                    notBeforeMs = nowMs() + ms
                    throw RunPodError.rateLimited(retryAfterMs: ms)
                case 500...599: failure = .server(status: response.statusCode)
                default: throw RunPodError.http(status: response.statusCode)
                }
            } catch let error as RunPodError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                failure = .network(CloudRedaction.redact(String(describing: error)))
            }
            guard retries, attempt < Self.readRetryDelaysMs.count else { throw failure }
            try await sleep(Self.readRetryDelaysMs[attempt])
            attempt += 1
        }
    }

    /// `Retry-After` in seconds (default 5 s, capped at 10 min).
    static func retryAfterMs(_ header: String?) -> Int64 {
        guard let header, let seconds = Double(header.trimmingCharacters(in: .whitespaces)), seconds.isFinite,
              seconds >= 0 else { return 5_000 }
        return min(Int64(seconds * 1000), 600_000)
    }
}
