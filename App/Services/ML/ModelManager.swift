import CoreML
import CryptoKit
import Foundation
import Observation
import PixlFoundation

/// Downloads, verifies, compiles and stores the on-device ML models (`ModelCatalog`). Android ships them inside the
/// APK; here the first TAIS job that needs one fetches it from the `models-v1` release:
///
/// 1. a background `URLSession` download task (keeps going while the app is suspended; progress for the UI),
/// 2. size + SHA-256 check against the catalog pin (CryptoKit, streamed),
/// 3. the ustar archive extracted with PixlFoundation's `UstarExtractor` (iOS has no public tar API),
/// 4. `MLModel.compileModel(at:)`, the compiled `.mlmodelc` moved to `Application Support/Models/<id>/` (excluded
///    from iCloud backups), the archive and package deleted.
///
/// `ensureInstalled` is what jobs call: it returns the compiled model at once, or starts (or joins) the download and
/// waits. UI tests get a demo manager whose states are set directly.
@MainActor
@Observable
final class ModelManager {
    nonisolated enum State: Equatable, Sendable {
        case notInstalled
        /// `fraction` nil while the size is unknown.
        case downloading(fraction: Double?)
        /// Verifying the checksum, extracting and compiling.
        case installing
        /// `bytes` on disk.
        case installed(bytes: Int64)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .installing: true
            default: false
            }
        }
    }

    nonisolated struct ModelError: LocalizedError, Sendable, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static let sessionIdentifier = "io.github.redsn0w1877.pixlaudio.models"

    private(set) var states: [ModelDescriptor.ID: State] = [:]

    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private let delegate = ModelDownloadDelegate()
    @ObservationIgnored private var waiters: [ModelDescriptor.ID: [UUID: CheckedContinuation<URL, any Error>]] = [:]
    @ObservationIgnored private var tasks: [ModelDescriptor.ID: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var started = false

    init(isDemo: Bool) {
        self.isDemo = isDemo
        for model in ModelCatalog.all { states[model.id] = .notInstalled }
    }

    func state(_ id: ModelDescriptor.ID) -> State { states[id] ?? .notInstalled }

    /// UI-test demo data.
    func setDemoState(_ state: State, for id: ModelDescriptor.ID) { states[id] = state }

    /// Total bytes of installed models.
    var installedBytes: Int64 {
        states.values.reduce(0) { sum, state in
            if case .installed(let bytes) = state { return sum + bytes }
            return sum
        }
    }

    /// Launch (cheap): which models are installed, and transfers left running by a previous launch.
    func start() {
        guard !started, !isDemo else { return }
        started = true
        for model in ModelCatalog.all {
            if let bytes = Self.installedSize(model) { states[model.id] = .installed(bytes: bytes) }
        }
        delegate.owner = self
        let session = makeSession()
        Task {
            for task in await session.allTasks {
                guard let raw = task.taskDescription, let id = ModelDescriptor.ID(rawValue: raw),
                      let download = task as? URLSessionDownloadTask else { continue }
                if task.state == .running || task.state == .suspended {
                    tasks[id] = download
                    if case .installed = state(id) {} else { states[id] = .downloading(fraction: nil) }
                }
            }
        }
    }

    private func makeSession() -> URLSession {
        if let session { return session }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session
        return session
    }

    // MARK: Using models

    /// The compiled model, downloading and installing it first when needed (joins a running download).
    func ensureInstalled(_ id: ModelDescriptor.ID) async throws -> URL {
        let model = ModelCatalog.descriptor(id)
        if let url = Self.compiledURL(model), FileManager.default.fileExists(atPath: url.path),
           Self.installedSize(model) != nil {
            return url
        }
        if isDemo { throw ModelError(message: "On-device models aren't available in this preview.") }
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id, default: [:]][token] = continuation
                if !state(id).isBusy { download(id) }
            }
        } onCancel: {
            // Only this waiter stops; the download keeps going for next time.
            Task { @MainActor in self.dropWaiter(id, token: token) }
        }
    }

    private func dropWaiter(_ id: ModelDescriptor.ID, token: UUID) {
        waiters[id]?.removeValue(forKey: token)?.resume(throwing: CancellationError())
    }

    /// Starts a download (the "Download" button). No-op while one runs or once installed.
    func download(_ id: ModelDescriptor.ID) {
        start()
        switch state(id) {
        case .downloading, .installing, .installed: return
        default: break
        }
        guard !isDemo else { return }
        let model = ModelCatalog.descriptor(id)
        states[id] = .downloading(fraction: 0)
        let task = makeSession().downloadTask(with: model.downloadURL)
        task.taskDescription = id.rawValue
        task.countOfBytesClientExpectsToReceive = model.bytes
        tasks[id] = task
        task.resume()
    }

    /// Cancels a running download.
    func cancel(_ id: ModelDescriptor.ID) {
        tasks.removeValue(forKey: id)?.cancel()
        if state(id).isBusy { states[id] = .notInstalled }
        resume(id, with: .failure(CancellationError()))
    }

    /// Removes an installed model (it downloads again when next needed).
    func delete(_ id: ModelDescriptor.ID) {
        cancel(id)
        if let dir = Self.directory(for: ModelCatalog.descriptor(id)) { try? FileManager.default.removeItem(at: dir) }
        states[id] = .notInstalled
    }

    // MARK: Delegate callbacks

    fileprivate func progress(_ id: ModelDescriptor.ID, written: Int64, expected: Int64) {
        guard case .downloading(let old) = state(id) else { return }
        let total = expected > 0 ? expected : ModelCatalog.descriptor(id).bytes
        let fraction = min(max(Double(written) / Double(max(total, 1)), 0), 1)
        // Whole percents only: the card re-renders 100 times per download, not per packet.
        if let old, Int(old * 100) == Int(fraction * 100) { return }
        states[id] = .downloading(fraction: fraction)
    }

    fileprivate func finished(_ id: ModelDescriptor.ID, archive: URL?, failure: String?) {
        tasks[id] = nil
        guard failure == nil, let archive else {
            states[id] = .failed(failure ?? "The download failed.")
            resume(id, with: .failure(ModelError(message: failure ?? "The download failed.")))
            return
        }
        states[id] = .installing
        let model = ModelCatalog.descriptor(id)
        Task {
            do {
                let url = try await Self.install(model, archive: archive)
                states[id] = .installed(bytes: Self.installedSize(model) ?? model.bytes)
                resume(id, with: .success(url))
            } catch {
                let message = (error as? ModelError)?.message ?? "Couldn't install the model (\(error.localizedDescription))."
                states[id] = .failed(message)
                resume(id, with: .failure(ModelError(message: message)))
            }
        }
    }

    private func resume(_ id: ModelDescriptor.ID, with result: Result<URL, any Error>) {
        let pending = waiters.removeValue(forKey: id) ?? [:]
        for continuation in pending.values { continuation.resume(with: result) }
    }

    // MARK: Files

    nonisolated static var rootDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated static func directory(for model: ModelDescriptor) -> URL? {
        rootDirectory?.appendingPathComponent(model.id.rawValue, isDirectory: true)
    }

    /// `<id>/<Package>.mlmodelc`.
    nonisolated static func compiledURL(_ model: ModelDescriptor) -> URL? {
        let name = (model.package as NSString).deletingPathExtension + ".mlmodelc"
        return directory(for: model)?.appendingPathComponent(name, isDirectory: true)
    }

    /// Where a finished download waits for verification.
    nonisolated static func stagingURL(_ id: ModelDescriptor.ID) -> URL? {
        rootDirectory?.appendingPathComponent(".staging", isDirectory: true).appendingPathComponent("\(id.rawValue).tar")
    }

    /// The installed model's size, or nil when it isn't installed (or was built from another catalog pin).
    nonisolated static func installedSize(_ model: ModelDescriptor) -> Int64? {
        guard let dir = directory(for: model), let compiled = compiledURL(model),
              let pin = try? String(contentsOf: dir.appendingPathComponent("sha256.txt"), encoding: .utf8),
              pin.trimmingCharacters(in: .whitespacesAndNewlines) == model.sha256,
              FileManager.default.fileExists(atPath: compiled.path) else { return nil }
        return directorySize(compiled)
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Verify → extract → compile → move into place (off the main actor).
    nonisolated static func install(_ model: ModelDescriptor, archive: URL) async throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: archive) }
        guard let dir = directory(for: model), let compiled = compiledURL(model) else {
            throw ModelError(message: "No storage for models.")
        }
        let size = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == model.bytes else {
            throw ModelError(message: "The downloaded model has the wrong size (\(size) bytes). Try again.")
        }
        let digest = try await Task.detached(priority: .utility) { try sha256Hex(of: archive) }.value
        guard digest == model.sha256 else {
            throw ModelError(message: "The downloaded model failed its checksum. Try again.")
        }
        let work = fm.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try await Task.detached(priority: .utility) {
            try UstarExtractor.extract(archive: archive, to: work) { _ in try Task.checkCancellation() }
        }.value
        let package = work.appendingPathComponent(model.package, isDirectory: true)
        guard fm.fileExists(atPath: package.path) else {
            throw ModelError(message: "The model archive is missing \(model.package).")
        }
        let temporaryCompiled = try await MLModel.compileModel(at: package)
        defer { try? fm.removeItem(at: temporaryCompiled) }
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.moveItem(at: temporaryCompiled, to: compiled)
        try Data(model.sha256.utf8).write(to: dir.appendingPathComponent("sha256.txt"))
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = dir
        try? root.setResourceValues(values)
        return compiled
    }

    /// SHA-256 of a file, read 1 MiB at a time.
    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Background-session callbacks (any thread). The archive must be moved before `didFinishDownloadingTo` returns.
nonisolated final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var owner: ModelManager?
    private let lock = NSLock()
    private var outcomes: [Int: (archive: URL?, failure: String?)] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let raw = downloadTask.taskDescription, let id = ModelDescriptor.ID(rawValue: raw) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var outcome: (URL?, String?)
        if status != 200 {
            outcome = (nil, "The model server answered HTTP \(status).")
        } else if let staging = ModelManager.stagingURL(id) {
            let fm = FileManager.default
            try? fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: staging)
            do {
                try fm.moveItem(at: location, to: staging)
                outcome = (staging, nil)
            } catch {
                outcome = (nil, "Couldn't save the model (\(error.localizedDescription)).")
            }
        } else {
            outcome = (nil, "No storage for models.")
        }
        lock.lock()
        outcomes[downloadTask.taskIdentifier] = outcome
        lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let raw = downloadTask.taskDescription, let id = ModelDescriptor.ID(rawValue: raw) else { return }
        Task { @MainActor [weak owner] in
            owner?.progress(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let raw = task.taskDescription, let id = ModelDescriptor.ID(rawValue: raw) else { return }
        lock.lock()
        let outcome = outcomes.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if (error as? URLError)?.code == .cancelled { return }
        let failure = outcome?.failure ?? error.map { "The download failed (\($0.localizedDescription))." }
        let archive = failure == nil ? outcome?.archive : nil
        Task { @MainActor [weak owner] in
            owner?.finished(id, archive: archive, failure: failure ?? (archive == nil ? "The download failed." : nil))
        }
    }
}
