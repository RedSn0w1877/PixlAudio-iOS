import Foundation
import PixlNet

/// What happened to one Cloud Studio transfer.
nonisolated enum CloudTransferEvent: Sendable, Hashable {
    /// The song is in R2 (`in/<jobKey>.<ext>`).
    case uploaded(jobKey: String)
    /// `httpStatus` 403 usually means the presigned PUT expired: re-sign and upload again.
    case uploadFailed(jobKey: String, message: String, httpStatus: Int?)
    /// A result file is on the phone, in `staging/`; the receiver verifies and moves it (or deletes it).
    case downloaded(jobKey: String, slot: String, stagedFile: URL)
    case downloadFailed(jobKey: String, slot: String, message: String, httpStatus: Int?)
}

/// Cloud Studio's background `URLSession` (design §7.1 `CloudTransfers`, §7.4): the song upload (a presigned PUT,
/// `uploadTask(with:fromFile:)`) and the large result downloads (presigned GETs). Transfers continue in the system's
/// transfer daemon while PixlAudio is suspended or terminated by the system, and iOS relaunches the app in the
/// background when they finish; a force-quit cancels them.
///
/// Only presigned R2 URLs ever go through here: they carry no reusable secret, while a background request is
/// persisted by the daemon with its headers (§5). RunPod calls use an ordinary session from the app process.
///
/// - `taskDescription` is `"<jobKey>|<slot>"`; the upload's slot is `input`.
/// - Low Data Mode is respected (`allowsConstrainedNetworkAccess = false`); cellular follows `allowsCellular`.
/// - A transfer created while the app is in the background is discretionary (iOS may hold it for Wi-Fi and power),
///   so callers create transfers in the foreground whenever they can.
/// - Events arrive on a private serial queue. Events that arrive before `onEvent` is set (a background relaunch
///   delivers them as soon as the session exists) are kept and handed over when it is set.
nonisolated final class CloudTransfers: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "io.github.redsn0w1877.pixlaudio.cloud"
    /// The slot name of the song upload.
    static let uploadSlot = "input"
    /// The one session for the identifier (iOS allows one live session per background identifier). Touch it early
    /// at launch, so a background relaunch reconnects to the transfers in flight.
    static let shared = CloudTransfers()

    private let lock = NSLock()
    private var session: URLSession!
    private var eventHandler: (@Sendable (CloudTransferEvent) -> Void)?
    private var progressHandler: (@Sendable (_ jobKey: String, _ slot: String, _ fraction: Double) -> Void)?
    private var pendingEvents: [CloudTransferEvent] = []
    private var cellular = false
    /// Download task id → its staged file; task id → a failure seen before completion.
    private var stagedFiles: [Int: URL] = [:]
    private var failures: [Int: (message: String, status: Int?)] = [:]
    private var lastPercent: [Int: Int] = [:]
    private var backgroundCompletion: (@Sendable () -> Void)?
    /// `urlSessionDidFinishEvents` came before the app handed over its completion handler.
    private var eventsFinishedWithoutHandler = false

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsConstrainedNetworkAccess = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "PixlAudio.CloudTransfers"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    // MARK: Configuration

    /// Every event; setting it delivers the events that arrived before.
    var onEvent: (@Sendable (CloudTransferEvent) -> Void)? {
        get { lock.withLock { eventHandler } }
        set {
            let backlog: [CloudTransferEvent] = lock.withLock {
                eventHandler = newValue
                guard newValue != nil else { return [] }
                defer { pendingEvents.removeAll() }
                return pendingEvents
            }
            if let newValue { backlog.forEach(newValue) }
        }
    }

    /// Whole-percent progress of a running transfer (at most one call per percent).
    var onProgress: (@Sendable (_ jobKey: String, _ slot: String, _ fraction: Double) -> Void)? {
        get { lock.withLock { progressHandler } }
        set { lock.withLock { progressHandler = newValue } }
    }

    /// Settings › Cloud processing › "Use cellular data" (off by default). Applies to transfers created afterwards.
    var allowsCellular: Bool {
        get { lock.withLock { cellular } }
        set { lock.withLock { cellular = newValue } }
    }

    // MARK: Transfers

    /// Uploads `fileURL` (inside the app's container) with a presigned PUT. A transfer already running for the same
    /// job and slot is left alone.
    func upload(fileURL: URL, to url: URL, jobKey: String, contentType: String) {
        let description = Self.taskDescription(jobKey: jobKey, slot: Self.uploadSlot)
        guard url.scheme?.lowercased() == "https" else {
            emit(.uploadFailed(jobKey: jobKey, message: "Upload links must be HTTPS", httpStatus: nil))
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            emit(.uploadFailed(jobKey: jobKey, message: "The prepared file is gone", httpStatus: nil))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.allowsConstrainedNetworkAccess = false
        request.allowsExpensiveNetworkAccess = allowsCellular
        session.getAllTasks { [self] tasks in
            guard !tasks.contains(where: { $0.taskDescription == description && $0.state != .completed }) else { return }
            let task = session.uploadTask(with: request, fromFile: fileURL)
            task.taskDescription = description
            task.resume()
        }
    }

    /// Downloads a result file with a presigned GET into `staging/`. A transfer already running for the same job and
    /// slot is left alone.
    func download(from url: URL, jobKey: String, slot: String) {
        let description = Self.taskDescription(jobKey: jobKey, slot: slot)
        guard url.scheme?.lowercased() == "https" else {
            emit(.downloadFailed(jobKey: jobKey, slot: slot, message: "Download links must be HTTPS", httpStatus: nil))
            return
        }
        var request = URLRequest(url: url)
        request.allowsConstrainedNetworkAccess = false
        request.allowsExpensiveNetworkAccess = allowsCellular
        session.getAllTasks { [self] tasks in
            guard !tasks.contains(where: { $0.taskDescription == description && $0.state != .completed }) else { return }
            let task = session.downloadTask(with: request)
            task.taskDescription = description
            task.resume()
        }
    }

    /// Cancels every transfer of a job (its events then report the cancellation).
    func cancel(jobKey: String) async {
        for task in await session.allTasks where Self.parse(task.taskDescription)?.jobKey == jobKey {
            task.cancel()
        }
    }

    /// `"<jobKey>|<slot>"` of every transfer still running or waiting (after a relaunch: what is still in flight).
    func pendingTaskDescriptions() async -> [String] {
        await session.allTasks.compactMap { task in
            task.state == .running || task.state == .suspended ? task.taskDescription : nil
        }
    }

    /// The app was launched or woken for this session (`.backgroundTask(.urlSession(…))`): `completion` runs on the
    /// main queue once the session has delivered every pending event.
    func handleBackgroundEvents(completion: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if eventsFinishedWithoutHandler {
                eventsFinishedWithoutHandler = false
                return true
            }
            backgroundCompletion = completion
            return false
        }
        if runNow { DispatchQueue.main.async { completion() } }
    }

    // MARK: Staging

    /// `Application Support/CloudStudio/staging` (created; `CloudStudio` is excluded from backups).
    static func stagingDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CloudAudioPreparer.Failure(message: "No Application Support folder")
        }
        var root = base.appendingPathComponent("CloudStudio", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return staging
    }

    /// `staging/<jobKey>-<slot>.<ext>`, the extension taken from the URL's object key (so AVFoundation can read it).
    static func stagedURL(jobKey: String, slot: String, sourceURL: URL?) throws -> URL? {
        guard CloudKeys.isValidJobKey(jobKey), isSafeSlot(slot) else { return nil }
        let ext = sourceURL?.pathExtension.lowercased() ?? ""
        let safeExt = !ext.isEmpty && ext.count <= 5 && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? ext : "bin"
        return try stagingDirectory().appendingPathComponent("\(jobKey)-\(slot).\(safeExt)")
    }

    /// Deletes a job's staged files.
    static func removeStaged(jobKey: String) {
        guard CloudKeys.isValidJobKey(jobKey), let directory = try? stagingDirectory() else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(jobKey + "-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Task descriptions

    static func taskDescription(jobKey: String, slot: String) -> String { "\(jobKey)|\(slot)" }

    static func parse(_ description: String?) -> (jobKey: String, slot: String)? {
        guard let description else { return nil }
        let parts = description.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, CloudKeys.isValidJobKey(String(parts[0])), isSafeSlot(String(parts[1])) else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    static func isSafeSlot(_ slot: String) -> Bool {
        !slot.isEmpty && slot.count <= 32 && slot.unicodeScalars.allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "_"
        }
    }

    // MARK: Events

    private func emit(_ event: CloudTransferEvent) {
        let handler: (@Sendable (CloudTransferEvent) -> Void)? = lock.withLock {
            if let eventHandler { return eventHandler }
            pendingEvents.append(event)
            return nil
        }
        handler?(event)
    }

    private func reportProgress(_ task: URLSessionTask, done: Int64, total: Int64) {
        guard total > 0, let identity = Self.parse(task.taskDescription) else { return }
        let fraction = min(max(Double(done) / Double(total), 0), 1)
        let percent = Int(fraction * 100)
        let handler: (@Sendable (String, String, Double) -> Void)? = lock.withLock {
            guard lastPercent[task.taskIdentifier] != percent else { return nil }
            lastPercent[task.taskIdentifier] = percent
            return progressHandler
        }
        handler?(identity.jobKey, identity.slot, fraction)
    }

    // MARK: URLSession delegate (the session's serial queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let identity = Self.parse(downloadTask.taskDescription) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            lock.withLock {
                failures[downloadTask.taskIdentifier] = ("Storage answered HTTP \(status)", status == 0 ? nil : status)
            }
            return
        }
        // The file must be moved before this method returns.
        do {
            guard let destination = try Self.stagedURL(jobKey: identity.jobKey, slot: identity.slot,
                                                       sourceURL: downloadTask.originalRequest?.url) else { return }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { stagedFiles[downloadTask.taskIdentifier] = destination }
        } catch {
            lock.withLock { failures[downloadTask.taskIdentifier] = ("Couldn't save the result file", nil) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        reportProgress(downloadTask, done: totalBytesWritten, total: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        reportProgress(task, done: totalBytesSent, total: totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let identity = Self.parse(task.taskDescription) else { return }
        let (staged, failure): (URL?, (message: String, status: Int?)?) = lock.withLock {
            lastPercent[task.taskIdentifier] = nil
            return (stagedFiles.removeValue(forKey: task.taskIdentifier), failures.removeValue(forKey: task.taskIdentifier))
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let errorMessage = error.map { Self.message(for: $0) }
        if identity.slot == Self.uploadSlot {
            if let errorMessage {
                emit(.uploadFailed(jobKey: identity.jobKey, message: errorMessage, httpStatus: nil))
            } else if let status, (200...299).contains(status) {
                emit(.uploaded(jobKey: identity.jobKey))
            } else {
                emit(.uploadFailed(jobKey: identity.jobKey, message: "Storage answered HTTP \(status ?? 0)",
                                   httpStatus: status))
            }
            return
        }
        if let staged, errorMessage == nil {
            emit(.downloaded(jobKey: identity.jobKey, slot: identity.slot, stagedFile: staged))
            return
        }
        if let staged { try? FileManager.default.removeItem(at: staged) }
        emit(.downloadFailed(jobKey: identity.jobKey, slot: identity.slot,
                             message: errorMessage ?? failure?.message ?? "The download didn't finish",
                             httpStatus: failure?.status ?? status))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion: (@Sendable () -> Void)? = lock.withLock {
            if let backgroundCompletion {
                self.backgroundCompletion = nil
                return backgroundCompletion
            }
            eventsFinishedWithoutHandler = true
            return nil
        }
        if let completion { DispatchQueue.main.async { completion() } }
    }

    /// Plain words for a transfer error; never a URL (it would carry a signature).
    private static func message(for error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                let reason = (urlError as NSError).userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int
                return reason == NSURLErrorCancelledReasonUserForceQuitApplication
                    ? "Stopped because PixlAudio was swiped away" : "Cancelled"
            case .notConnectedToInternet, .networkConnectionLost: return "No internet connection"
            case .timedOut: return "The transfer timed out"
            case .dataNotAllowed: return "Cellular data is off for cloud transfers"
            default: return CloudRedaction.redact(urlError.localizedDescription)
            }
        }
        return CloudRedaction.redact(error.localizedDescription)
    }
}
