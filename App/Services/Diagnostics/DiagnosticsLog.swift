import Foundation
import os
import PixlModel
import Synchronization

/// The in-app event log (Settings › Developer › Diagnostics › Share logs): app lifecycle, job lifecycle, abnormal-end
/// detection, safe-mode decisions and background windows, one redacted line each, kept in a ring-buffer file of about
/// 1 MB (`LogRing`, the newest whole lines survive). Every line also goes to `os.Logger`.
///
/// No personal data: callers pass job kinds, opaque ids and reasons, never a song title, a path or a URL; `LogRedactor`
/// is the second line of defence for error texts. Never call from the audio render path (it takes a lock and writes).
nonisolated final class DiagnosticsLog: Sendable {
    static let shared = DiagnosticsLog()

    private nonisolated struct State {
        var size = -1
        var handle: FileHandle?
    }

    private let queue = DispatchQueue(label: "io.github.redsn0w1877.pixlaudio.diagnostics-log", qos: .utility)
    private let state = Mutex(State())
    private let logger = Logger(subsystem: "io.github.redsn0w1877.pixlaudio", category: "diagnostics")
    private let limitBytes: Int
    let fileURL: URL?

    /// `directory`: where the log lives (tests pass a temporary one).
    init(directory: URL? = DiagnosticsFiles.directory, limitBytes: Int = LogRing.defaultLimitBytes) {
        self.limitBytes = limitBytes
        fileURL = directory?.appendingPathComponent("events.log", isDirectory: false)
    }

    /// Records one event. Returns at once; the write happens on a utility queue.
    func log(_ category: String, _ message: String) {
        let now = Date()
        let line = LogRing.format(timestamp: now, category: category, message: message)
        logger.info("\(line, privacy: .public)")
        queue.async { [self] in append(line) }
    }

    /// The whole log as text (waits for the writes queued before this call).
    func snapshot() -> String {
        queue.sync {
            guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Waits until everything logged so far is on disk (tests, and before the app is suspended).
    func flush() {
        queue.sync {}
    }

    /// Empties the log (Emergency stop keeps it: it is evidence; this is for tests).
    func reset() {
        queue.sync {
            state.withLock { state in
                try? state.handle?.close()
                state.handle = nil
                state.size = -1
            }
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        }
    }

    // MARK: On the queue

    private func append(_ line: String) {
        guard let fileURL else { return }
        let bytes = line.utf8.count
        state.withLock { state in
            if state.size < 0 {
                state.size = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
            }
            if state.size + bytes > limitBytes {
                // Rotate: keep the newest lines, rewrite the file once, and carry on appending.
                try? state.handle?.close()
                state.handle = nil
                let existing = (try? Data(contentsOf: fileURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                let trimmed = LogRing.appending(line, to: existing, limitBytes: limitBytes)
                try? Data(trimmed.utf8).write(to: fileURL, options: .atomic)
                state.size = trimmed.utf8.count
                return
            }
            if state.handle == nil {
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                state.handle = try? FileHandle(forWritingTo: fileURL)
                _ = try? state.handle?.seekToEnd()
            }
            if let handle = state.handle, (try? handle.write(contentsOf: Data(line.utf8))) != nil {
                state.size += bytes
            }
        }
    }
}

/// Where the diagnostics files live: Application Support/Diagnostics (not in Documents: the Files app should not show
/// them, and they are excluded from backups).
nonisolated enum DiagnosticsFiles {
    static let directory: URL? = {
        guard var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Diagnostics", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static var cleanExitMarker: URL? { directory?.appendingPathComponent("clean-exit", isDirectory: false) }
    static var inFlight: URL? { directory?.appendingPathComponent("in-flight.json", isDirectory: false) }
    static var metricKit: URL? {
        guard let url = directory?.appendingPathComponent("metrickit", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Job lifecycle in one call each: start / finish / fail / cancel, with the duration and the reason, to the event log,
/// plus the in-flight journal of the heavy ones (what an abnormal end interrupted). Opaque ids and kinds only.
nonisolated final class JobTelemetry: Sendable {
    static let shared = JobTelemetry(log: .shared, journalURL: DiagnosticsFiles.inFlight)

    nonisolated enum Outcome: Sendable {
        case finished
        case failed(String)
        case cancelled(String)
    }

    private nonisolated struct State {
        var startedAt: [String: UInt64] = [:]
        var entries: [InFlightEntry] = []
        var loaded = false
    }

    private let log: DiagnosticsLog
    private let journalURL: URL?
    private let state = Mutex(State())

    init(log: DiagnosticsLog, journalURL: URL?) {
        self.log = log
        self.journalURL = journalURL
    }

    /// `heavy`: also written to the in-flight journal, which survives a crash.
    func started(_ kind: String, id: String, heavy: Bool = true) {
        let now = DispatchTime.now().uptimeNanoseconds
        let key = "\(kind)|\(id)"
        let snapshot: [InFlightEntry]? = state.withLock { state in
            loadIfNeeded(&state)
            state.startedAt[key] = now
            guard heavy else { return nil }
            state.entries = InFlightJournal.adding(
                InFlightEntry(kind: kind, reference: id, startedAtMs: Int64(Date().timeIntervalSince1970 * 1000)),
                to: state.entries)
            return state.entries
        }
        if let snapshot { write(snapshot) }
        log.log("job", "start \(kind) \(Self.opaque(id))")
    }

    func ended(_ kind: String, id: String, _ outcome: Outcome) {
        let now = DispatchTime.now().uptimeNanoseconds
        let key = "\(kind)|\(id)"
        let (millis, snapshot): (Int64, [InFlightEntry]?) = state.withLock { state in
            loadIfNeeded(&state)
            let started = state.startedAt.removeValue(forKey: key)
            let before = state.entries.count
            state.entries = InFlightJournal.removing(kind: kind, reference: id, from: state.entries)
            return (started.map { Int64((now &- $0) / 1_000_000) } ?? -1, before != state.entries.count ? state.entries : nil)
        }
        if let snapshot { write(snapshot) }
        let words: String
        switch outcome {
        case .finished: words = "finish"
        case .failed(let reason): words = "fail (\(LogRedactor.line(reason, limit: 120)))"
        case .cancelled(let reason): words = "cancel (\(reason))"
        }
        log.log("job", "\(words) \(kind) \(Self.opaque(id)) after \(millis < 0 ? "?" : "\(millis / 1000).\(millis % 1000 / 100)s")")
    }

    /// What was in flight at the last write: at launch this is what the previous run left behind.
    func entries() -> [InFlightEntry] {
        state.withLock { state in
            loadIfNeeded(&state)
            return state.entries
        }
    }

    /// Forgets everything in flight (a launch after an abnormal end has read it; Emergency stop).
    func clearJournal() {
        state.withLock { state in
            state.entries = []
            state.startedAt = [:]
            state.loaded = true
        }
        write([])
    }

    /// How many jobs started in this process have not ended yet.
    var runningCount: Int { state.withLock { $0.startedAt.count } }

    /// A short opaque tag for a song or model id: the same id always gives the same tag, and it tells nothing.
    static func opaque(_ id: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return "#" + String(hash, radix: 16)
    }

    private func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        guard let journalURL, let data = try? Data(contentsOf: journalURL),
              let decoded = try? JSONDecoder().decode([InFlightEntry].self, from: data) else { return }
        state.entries = decoded
    }

    private func write(_ entries: [InFlightEntry]) {
        guard let journalURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: journalURL, options: .atomic)
    }
}
