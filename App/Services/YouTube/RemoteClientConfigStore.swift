import Foundation
import PixlNet

/// The InnerTube client table, with the repo's `remote/config.json` applied (architecture §2): when YouTube breaks a
/// client, bumping its version there fixes installed apps without a new build. Fetched at most every six hours,
/// kept in Application Support so it survives cache clears and launches offline; anything malformed is ignored
/// (`RemoteClientConfig.parse` keeps the no-cookie and host invariants).
actor RemoteClientConfigStore {
    static let url = "https://raw.githubusercontent.com/RedSn0w1877/PixlAudio-iOS/main/remote/config.json"
    static let refreshInterval: TimeInterval = 6 * 3600

    private let http: any HTTPClient
    private let file: URL
    private var config: RemoteClientConfig = .builtIn
    private var loadedFromDisk = false
    private var lastAttempt: Date?
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

    /// Fetches the remote file when the last attempt is older than six hours.
    func refreshIfNeeded() async {
        loadFromDiskIfNeeded()
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.refreshInterval { return }
        lastAttempt = Date()
        let request = HTTPRequest(url: Self.url, headers: [HTTPHeader("Accept", "application/json")], timeout: 10)
        guard let response = try? await http.send(request), response.isSuccessful,
              let parsed = RemoteClientConfig.parse(response.text) else { return }
        config = parsed
        source = "remote" + (parsed.note.map { " (\($0))" } ?? "")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? response.body.write(to: file, options: .atomic)
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
