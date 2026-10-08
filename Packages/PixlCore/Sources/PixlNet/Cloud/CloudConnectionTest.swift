// "Test connection" in Settings › Cloud processing (design §7.2): RunPod's `/health` and a tiny probe object in the
// bucket (PUT, HEAD, DELETE under `probe/`), each reported on its own in plain English, plus the optional selftest.
// Nothing here runs a GPU except `selftest` (about one cold start, ~1¢).

import Foundation
import PixlFoundation

/// One check's outcome.
public struct CloudCheck: Sendable, Hashable {
    public var ok: Bool
    /// One sentence the person can act on.
    public var message: String
    /// Extra facts on success (queue and worker counts, the worker's GPU), else nil.
    public var detail: String?

    public init(ok: Bool, message: String, detail: String? = nil) {
        self.ok = ok
        self.message = message
        self.detail = detail
    }
}

/// Both checks of one "Test connection".
public struct CloudConnectionReport: Sendable, Hashable {
    public var runpod: CloudCheck
    public var storage: CloudCheck

    public init(runpod: CloudCheck, storage: CloudCheck) {
        self.runpod = runpod
        self.storage = storage
    }

    public var allOK: Bool { runpod.ok && storage.ok }
}

public enum CloudConnectionTest {
    /// `GET /health`: 200 → the endpoint answers (with its queue and worker counts); 401/403 → the key; 404 → the
    /// Endpoint ID.
    public static func checkRunPod(_ api: (any RunPodJobsAPI)?) async -> CloudCheck {
        guard let api else {
            return CloudCheck(ok: false, message: "Fill in the Endpoint ID and the RunPod key first.")
        }
        do {
            let health = try await api.health()
            return CloudCheck(ok: true, message: "RunPod works: the endpoint answered and accepted the key.",
                              detail: healthSummary(health))
        } catch let error as RunPodError {
            return CloudCheck(ok: false, message: message(for: error))
        } catch is CancellationError {
            return CloudCheck(ok: false, message: "The test was stopped.")
        } catch {
            return CloudCheck(ok: false, message: "Couldn't reach RunPod. Check your connection and try again.")
        }
    }

    /// "1 song waiting · 1 worker running".
    public static func healthSummary(_ health: RunPodHealth) -> String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        let waiting = count(health.inQueue, "song waiting", "songs waiting")
        let workers = health.runningWorkers + health.initializingWorkers
        let running = workers == 0 && health.idleWorkers == 0 ? "no worker awake (normal when idle)"
            : count(workers, "worker running", "workers running") + (health.idleWorkers > 0 ? ", \(health.idleWorkers) idle" : "")
        var text = "\(waiting) · \(running)"
        if health.unhealthyWorkers > 0 { text += " · \(count(health.unhealthyWorkers, "unhealthy worker", "unhealthy workers"))" }
        return text
    }

    public static func message(for error: RunPodError) -> String {
        switch error {
        case .unauthorized:
            "RunPod refused the key. Use the Restricted key with Read/Write on this endpoint, and check it isn't disabled."
        case .endpointNotFound:
            "RunPod doesn't know this Endpoint ID. Copy it again from Serverless › pixl-cloud-studio."
        case .jobNotFound:
            "RunPod no longer has that job."
        case .rateLimited:
            "RunPod asked to slow down. Try again in a minute."
        case .server(let status):
            "RunPod had a problem on its side (HTTP \(status)). Try again later."
        case .http(let status):
            "RunPod answered with an unexpected error (HTTP \(status))."
        case .network:
            "Couldn't reach RunPod. Check your connection and try again."
        case .badResponse:
            "RunPod answered something this app doesn't understand."
        case .notConfigured:
            "Fill in the Endpoint ID and the RunPod key first."
        }
    }

    /// PUT a 1-byte object at `probe/<probeId>`, HEAD it, DELETE it. Each step's failure says which permission or
    /// field is wrong.
    public static func checkStorage(_ store: (any CloudObjectStoring)?, probeId: String) async -> CloudCheck {
        guard let store else {
            return CloudCheck(ok: false, message: "Fill in the R2 endpoint, bucket, access key ID and secret first.")
        }
        let key = CloudKeys.probe(id: probeId)
        do {
            try await store.put(key: key, data: Data([0x31]), contentType: "application/octet-stream")
        } catch {
            return CloudCheck(ok: false, message: storageMessage(error, step: "write a test file"))
        }
        do {
            guard try await store.head(key: key) != nil else {
                return CloudCheck(ok: false, message: "Storage took the test file but couldn't find it again. Check the bucket name.")
            }
        } catch {
            try? await store.delete(key: key)
            return CloudCheck(ok: false, message: storageMessage(error, step: "read the test file back"))
        }
        do {
            try await store.delete(key: key)
        } catch {
            return CloudCheck(ok: false, message: storageMessage(error, step: "delete the test file")
                + " The token needs Object Read & Write, which includes deleting.")
        }
        return CloudCheck(ok: true, message: "Storage works: a test file was written, found and deleted.")
    }

    static func storageMessage(_ error: any Error, step: String) -> String {
        switch error as? CloudStorageError {
        case .unauthorized?:
            "Storage refused the key when trying to \(step). Check the access key ID and secret, and that the token has Object Read & Write on this bucket."
        case .bucketNotFound?:
            "Storage says this bucket doesn't exist. Check the bucket name and the account ID in the endpoint."
        case .http(let status)?:
            "Storage answered HTTP \(status) when trying to \(step)."
        case .network?:
            "Couldn't reach storage. Check the R2 endpoint (or account ID) and your connection."
        case .badResponse?:
            "Storage answered something this app doesn't understand."
        case .notConfigured?:
            "Fill in the R2 endpoint, bucket, access key ID and secret first."
        case nil:
            error is CancellationError ? "The test was stopped." : "Couldn't \(step): \(CloudRedaction.redact(String(describing: error)))"
        }
    }

    /// `op: "selftest"` through `/runsync`: the worker's version and GPU (one cold start, about 1¢).
    public static func selftest(_ api: (any RunPodJobsAPI)?, build: String) async -> CloudCheck {
        guard let api else { return CloudCheck(ok: false, message: "Fill in the Endpoint ID and the RunPod key first.") }
        do {
            let job = try await api.selftest(build: build)
            if job.typedStatus == .completed, let selftest = job.selftest {
                guard selftest.isOK else {
                    let reason = selftest.error.map { "\($0.code): \($0.message ?? "")" } ?? "status \(selftest.status)"
                    return CloudCheck(ok: false, message: "The worker started but reported a problem (\(CloudRedaction.redact(reason))).")
                }
                guard selftest.agreedVersion != nil else {
                    return CloudCheck(ok: false, message: "The worker doesn't speak this app's job format (v\(CloudSchema.version)). Update the worker or the app.")
                }
                let missing = (selftest.models ?? [:]).filter { !$0.value.isAvailable }.map(\.key).sorted()
                guard missing.isEmpty else {
                    return CloudCheck(ok: false, message: "The worker is missing models: \(missing.joined(separator: ", ")).")
                }
                let version = selftest.worker?.version ?? "?"
                let gpu = selftest.worker?.gpu ?? "unknown GPU"
                return CloudCheck(ok: true, message: "The worker answered.", detail: "Worker \(version) on \(gpu)")
            }
            if job.typedStatus == .completed, let output = job.outputJSON {
                let version = output["worker"]?["version"]?.stringValue ?? "?"
                let gpu = output["worker"]?["gpu"]?.stringValue ?? "unknown GPU"
                let supported = output["supported"]?.arrayValue?.compactMap { $0.int64Value.map(Int.init) } ?? []
                guard supported.isEmpty || supported.contains(CloudSchema.version) else {
                    return CloudCheck(ok: false, message: "The worker doesn't speak this app's job format (v\(CloudSchema.version)). Update the worker or the app.")
                }
                return CloudCheck(ok: true, message: "The worker answered.", detail: "Worker \(version) on \(gpu)")
            }
            if job.typedStatus == .inQueue || job.typedStatus == .inProgress {
                return CloudCheck(ok: false, message: "The worker is still starting (a cold start can take a few minutes). Try again shortly.")
            }
            return CloudCheck(ok: false, message: "The selftest failed: \(CloudRedaction.redact(job.error ?? job.status)).")
        } catch let error as RunPodError {
            return CloudCheck(ok: false, message: message(for: error))
        } catch {
            return CloudCheck(ok: false, message: "Couldn't reach RunPod. Check your connection and try again.")
        }
    }
}
