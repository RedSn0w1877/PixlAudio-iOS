import Foundation
import PixlNet

/// The InnerTube client table, with the repo's `remote/config.json` applied (architecture §2): when YouTube breaks a
/// client, bumping its version there fixes installed apps without a new build. Fetched at most every six hours,
/// kept in Application Support so it survives cache clears and launches offline; anything malformed is ignored
/// (`RemoteClientConfig.parse` keeps the no-cookie and host invariants).
///
/// Streaming speed R4: resolution never waits for the fetch (`refreshInBackground`); it uses the current table and a
/// fixed one applies from the next resolution. The six-hour gate survives relaunches: the saved file's date stands
/// for the last good fetch.
actor RemoteClientConfigStore {
    static let url = "https://raw.githubusercontent.com/RedSn0w1877/PixlAudio-iOS/main/remote/config.json"
    static let refreshInterval: TimeInterval = 6 * 3600

    private let http: any HTTPClient
    private let file: URL
    private var config: RemoteClientConfig = .builtIn
    private var loadedFromDisk = false
    private var lastAttempt: Date?
    private var seededLastAttempt = false
    /// Where the current table came from (diagnostics).
    private(set) var source = "built-in"

    init(http: any HTTPClient, directory: URL = YouTubeNetwork.supportDirectory()) {
        self.http = http
        file = directory.appendingPathComponent("remote-config.json")
    }

    /// The table to use now (never waits for the network).
    func current() -> RemoteClientConfig {
        loadFromDiskIfNeeded()
        return config
    }

    /// Starts `refreshIfNeeded` in the background at utility priority when a refresh is due; returns at once.
    func refreshInBackground() {
        guard isRefreshDue() else { return }
        Task(priority: .utility) { await self.refreshIfNeeded() }
    }

    /// Fetches the remote file when the last attempt is older than six hours.
    func refreshIfNeeded() async {
        guard isRefreshDue() else { return }
        // Set before the request, so concurrent callers don't fetch twice.
        lastAttempt = Date()
        let request = HTTPRequest(url: Self.url, headers: [HTTPHeader("Accept", "application/json")], timeout: 10)
        guard let response = try? await http.send(request), response.isSuccessful,
              let parsed = RemoteClientConfig.parse(response.text) else { return }
        config = parsed
        source = "remote" + (parsed.note.map { " (\($0))" } ?? "")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? response.body.write(to: file, options: .atomic)
    }

    private func isRefreshDue() -> Bool {
        loadFromDiskIfNeeded()
        seedLastAttemptIfNeeded()
        guard let lastAttempt else { return true }
        return Date().timeIntervalSince(lastAttempt) >= Self.refreshInterval
    }

    /// After a relaunch the saved file's modification date is the last successful fetch (only successes write it), so
    /// a relaunch within six hours of one makes no request. A date in the future (clock changes) is ignored.
    private func seedLastAttemptIfNeeded() {
        guard !seededLastAttempt else { return }
        seededLastAttempt = true
        guard lastAttempt == nil,
              let saved = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              saved <= Date() else { return }
        lastAttempt = saved
    }

    private func loadFromDiskIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let data = try? Data(contentsOf: file),
              let parsed = RemoteClientConfig.parse(String(decoding: data, as: UTF8.self)) else { return }
        config = parsed
        source = "cached remote" + (parsed.note.map { " (\($0))" } ?? "")
    }
}
