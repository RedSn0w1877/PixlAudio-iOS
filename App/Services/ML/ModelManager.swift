import CoreML
import CryptoKit
import Foundation
import Observation
import PixlFoundation
import PixlModel

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
    /// Downloaded and verified, but the install (extract + compile, the heaviest memory spike in the app) waits for the
    /// shared heavy lane (`HeavyJobGovernor`): Active jobs says "Waiting".
    private(set) var waitingToInstall: Set<ModelDescriptor.ID> = []

    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private let delegate = ModelDownloadDelegate()
    @ObservationIgnored private var waiters: [ModelDescriptor.ID: [UUID: CheckedContinuation<URL, any Error>]] = [:]
    @ObservationIgnored private var tasks: [ModelDescriptor.ID: URLSessionDownloadTask] = [:]
    /// The install (verify, extract, compile) of each model that has been downloaded: cancellable, so "Cancel" means it.
    @ObservationIgnored private var installTasks: [ModelDescriptor.ID: Task<Void, Never>] = [:]
    /// A download that stops moving (offline, a source that never answers) is failed after a couple of minutes: a
    /// background session would wait for connectivity for days and the job would sit at "downloading" for ever.
    @ObservationIgnored let stalls = StallMonitor<ModelDescriptor.ID>()
    @ObservationIgnored private var started = false

    init(isDemo: Bool) {
        self.isDemo = isDemo
        for model in ModelCatalog.all { states[model.id] = .notInstalled }
        stalls.onStall = { [weak self] id in self?.downloadStalled(id) }
    }

    func state(_ id: ModelDescriptor.ID) -> State { states[id] ?? .notInstalled }

    func isWaitingToInstall(_ id: ModelDescriptor.ID) -> Bool { waitingToInstall.contains(id) }

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
        // A previous launch that died mid-install left its archive behind (up to ~900 MB): an hour-old one is nobody's.
        Task.detached(priority: .utility) { Self.removeStaleStaging(olderThan: 3_600) }
        Task {
            for task in await session.allTasks {
                guard let raw = task.taskDescription, let id = ModelDescriptor.ID(rawValue: raw),
                      let download = task as? URLSessionDownloadTask else { continue }
                if task.state == .running || task.state == .suspended {
                    tasks[id] = download
                    if case .installed = state(id) {} else {
                        states[id] = .downloading(fraction: nil)
                        stalls.arm(id)
                    }
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
        // The local AI model is ~900 MB: say so up front rather than failing half-way through the install.
        if let free = Self.availableSpace(), free < Self.spaceNeeded(model) {
            let message = "Not enough free space on this iPhone: installing it needs about "
                + "\(ModelCatalog.formattedSize(Self.spaceNeeded(model))) free for a moment."
            states[id] = .failed(message)
            resume(id, with: .failure(ModelError(message: message)))
            return
        }
        states[id] = .downloading(fraction: 0)
        let task = makeSession().downloadTask(with: model.downloadURL)
        task.taskDescription = id.rawValue
        task.countOfBytesClientExpectsToReceive = model.bytes
        tasks[id] = task
        stalls.arm(id)
        task.resume()
    }

    /// Cancels a running download or install for real: the transfer stops, the install task is cancelled, every job
    /// waiting for the model is released with a cancel, and the row goes back to "not downloaded". A failure is left
    /// as it is (`reset` clears it).
    func cancel(_ id: ModelDescriptor.ID) {
        stalls.disarm(id)
        tasks.removeValue(forKey: id)?.cancel()
        installTasks.removeValue(forKey: id)?.cancel()
        waitingToInstall.remove(id)
        if state(id).isBusy { states[id] = .notInstalled }
        resume(id, with: .failure(CancellationError()))
    }

    /// "Delete download" / "Dismiss" after a failure (or a stuck transfer): stops whatever is left, forgets the error and
    /// takes the half-finished archive off the disk. An installed model is never touched (use `delete`).
    func reset(_ id: ModelDescriptor.ID) {
        if case .installed = state(id) { return }
        cancel(id)
        states[id] = .notInstalled
        if let staging = Self.stagingURL(id) { try? FileManager.default.removeItem(at: staging) }
    }

    /// Every model whose last try failed, with the reason (Active jobs lists them).
    var failures: [(id: ModelDescriptor.ID, message: String)] {
        ModelCatalog.all.compactMap { model -> (id: ModelDescriptor.ID, message: String)? in
            if case .failed(let message) = state(model.id) { return (model.id, message) }
            return nil
        }
    }

    /// "Clear finished": forgets every failure.
    func clearFailures() {
        for failure in failures { reset(failure.id) }
    }

    /// "Cancel all": every download and install that is going.
    func cancelAll() {
        for model in ModelCatalog.all where state(model.id).isBusy { cancel(model.id) }
    }

    /// The watchdog's verdict: nothing arrived for too long. The transfer is cancelled and the job fails with a reason.
    private func downloadStalled(_ id: ModelDescriptor.ID) {
        guard case .downloading = state(id) else { return }
        tasks.removeValue(forKey: id)?.cancel()
        let message = "The download stopped: no data is arriving. Check your connection and try again."
        states[id] = .failed(message)
        resume(id, with: .failure(ModelError(message: message)))
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
        stalls.note(id, mark: written)
        let total = expected > 0 ? expected : ModelCatalog.descriptor(id).bytes
        let fraction = min(max(Double(written) / Double(max(total, 1)), 0), 1)
        // Whole percents only: the card re-renders 100 times per download, not per packet.
        if let old, Int(old * 100) == Int(fraction * 100) { return }
        states[id] = .downloading(fraction: fraction)
    }

    fileprivate func finished(_ id: ModelDescriptor.ID, archive: URL?, failure: String?) {
        tasks[id] = nil
        stalls.disarm(id)
        guard failure == nil, let archive else {
            let message = JobFailureText.short(failure ?? "The download failed.")
            states[id] = .failed(message)
            resume(id, with: .failure(ModelError(message: message)))
            return
        }
        states[id] = .installing
        let model = ModelCatalog.descriptor(id)
        installTasks[id] = Task(priority: .utility) {
            defer {
                waitingToInstall.remove(id)
                installTasks[id] = nil
            }
            do {
                // Compiling a ~1 GB package next to a running lyric sync or separation is what gets an app ended for
                // memory: wait for the heavy lane (a lyric batch hands it over between songs).
                if HeavyJobGovernor.shared.isBusy { waitingToInstall.insert(id) }
                let lease = try await HeavyJobGovernor.shared.acquire()
                defer { lease.release() }
                waitingToInstall.remove(id)
                // Verifying and compiling can outlast a switch to another app: iOS's ~30 s of grace may finish it.
                let url = try await BackgroundGrace.run("Model install") { try await Self.install(model, archive: archive) }
                try Task.checkCancellation()
                states[id] = .installed(bytes: Self.installedSize(model) ?? model.bytes)
                resume(id, with: .success(url))
            } catch is CancellationError {
                // `cancel` already said so and released the waiters; only what an install that had finished left on the
                // disk decides what is true now.
                if let bytes = Self.installedSize(model) {
                    states[id] = .installed(bytes: bytes)
                } else if state(id) == .installing {
                    states[id] = .notInstalled
                }
                resume(id, with: .failure(CancellationError()))
            } catch {
                let message = JobFailureText.short(
                    (error as? ModelError)?.message ?? "Couldn't install the model (\(error.localizedDescription)).")
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

    /// Archives in the staging folder older than `seconds` (a launch that died mid-install left them): deleted. A fresh
    /// one may belong to an install that is about to start, so it stays.
    nonisolated static func removeStaleStaging(olderThan seconds: TimeInterval) {
        let fm = FileManager.default
        guard let folder = rootDirectory?.appendingPathComponent(".staging", isDirectory: true),
              let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > seconds { try? fm.removeItem(at: file) }
        }
    }

    /// `<id>/<name>`: a file the tar carries next to the package (the local AI model's tokenizer).
    nonisolated static func extraFileURL(_ model: ModelDescriptor, _ name: String) -> URL? {
        directory(for: model)?.appendingPathComponent(name, isDirectory: false)
    }

    /// The installed model's size, or nil when it isn't installed (or was built from another catalog pin).
    nonisolated static func installedSize(_ model: ModelDescriptor) -> Int64? {
        guard isInstalled(model), let compiled = compiledURL(model) else { return nil }
        var total = directorySize(compiled)
        for name in model.extraFiles {
            guard let url = extraFileURL(model, name) else { continue }
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Cheap check (no size walk): the pin matches and the compiled model and its extra files are in place.
    nonisolated static func isInstalled(_ model: ModelDescriptor) -> Bool {
        let fm = FileManager.default
        guard let dir = directory(for: model), let compiled = compiledURL(model),
              let pin = try? String(contentsOf: dir.appendingPathComponent("sha256.txt"), encoding: .utf8),
              pin.trimmingCharacters(in: .whitespacesAndNewlines) == model.sha256,
              fm.fileExists(atPath: compiled.path) else { return false }
        return model.extraFiles.allSatisfy { name in extraFileURL(model, name).map { fm.fileExists(atPath: $0.path) } ?? false }
    }

    /// What an install can hold on disk at once: the archive while it's extracted (then deleted), or the extracted
    /// package while it's compiled, plus room to spare.
    nonisolated static func spaceNeeded(_ model: ModelDescriptor) -> Int64 {
        model.bytes * 2 + 100_000_000
    }

    /// Free space for important data on the app's volume (nil when unknown).
    nonisolated static func availableSpace() -> Int64? {
        (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? nil
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
    @concurrent
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
        // Extracted: the archive's copy goes before the compile makes another (the phone's free space).
        try? fm.removeItem(at: archive)
        let package = work.appendingPathComponent(model.package, isDirectory: true)
        guard fm.fileExists(atPath: package.path) else {
            throw ModelError(message: "The model archive is missing \(model.package).")
        }
        for name in model.extraFiles where !fm.fileExists(atPath: work.appendingPathComponent(name).path) {
            throw ModelError(message: "The model archive is missing \(name).")
        }
        let temporaryCompiled = try await MLModel.compileModel(at: package)
        defer { try? fm.removeItem(at: temporaryCompiled) }
        // The package is compiled: its ~1 GB copy goes before the compiled one moves in (the phone's free space).
        try? fm.removeItem(at: package)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.moveItem(at: temporaryCompiled, to: compiled)
        for name in model.extraFiles {
            guard let destination = extraFileURL(model, name) else { continue }
            try fm.moveItem(at: work.appendingPathComponent(name), to: destination)
        }
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
            outcome = (nil, JobFailureText.httpStatus(status))
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
        let failure = outcome?.failure ?? error.map { error in
            (error as? URLError).flatMap { JobFailureText.urlError(code: $0.code.rawValue) }
                ?? "The download failed (\(error.localizedDescription))."
        }
        let archive = failure == nil ? outcome?.archive : nil
        Task { @MainActor [weak owner] in
            owner?.finished(id, archive: archive, failure: failure ?? (archive == nil ? "The download failed." : nil))
        }
    }
}
