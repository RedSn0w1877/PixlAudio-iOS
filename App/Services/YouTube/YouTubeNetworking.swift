import Foundation
import PixlNet

/// Transport for everything that talks to YouTube (Android `@YouTubeOkHttpClient`). Two rules from the Android app
/// hold here by construction:
/// - **no cookie jar**: a cookie set by one InnerTube answer must never reach the native clients (VISIONOS, IOS…
///   answer HTTP 400 to a cookie) — the signed-in cookie is attached explicitly by `InnerTubeClient`, only to clients
///   that accept it;
/// - **no rewritten User-Agent**: each request carries exactly the identity its InnerTube client declares.
nonisolated enum YouTubeNetwork {
    /// An ephemeral session without cookie storage, URL cache or default User-Agent rewriting.
    static func makeSession(timeout: TimeInterval = 20) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }

    /// Where YouTube support files live (`Library/Caches/YouTube/…`; freeable from Settings › Offline storage).
    static func cachesDirectory(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("YouTube", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// Application Support (kept across cache clears): the remote client config.
    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("YouTube", isDirectory: true)
    }
}

/// Caches base.js on disk per player version. `SignatureCipherSolver` downloads the iframe API (small, tells the
/// current player id) and then `…/s/player/<id>/…/base.js` (~2.5 MB); the second request is answered from disk
/// whenever that player version was seen before, so a cold start only costs the iframe request.
nonisolated final class BaseJsCachingHTTPClient: HTTPClient {
    let inner: any HTTPClient
    let directory: URL
    /// Player versions kept on disk.
    static let keep = 3

    init(inner: any HTTPClient, directory: URL = YouTubeNetwork.cachesDirectory("basejs")) {
        self.inner = inner
        self.directory = directory
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.method == .get, let playerId = Self.playerId(fromBaseJsURL: request.url) else {
            return try await inner.send(request)
        }
        let file = directory.appendingPathComponent("\(playerId).js")
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return HTTPResponse(statusCode: 200, headers: [HTTPHeader("Content-Type", "text/javascript")], body: data)
        }
        let response = try await inner.send(request)
        if response.isSuccessful, !response.body.isEmpty {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? response.body.write(to: file, options: .atomic)
            prune()
        }
        return response
    }

    /// The player id of a `https://www.youtube.com/s/player/<id>/…/base.js` URL.
    static func playerId(fromBaseJsURL url: String) -> String? {
        guard url.hasSuffix("/base.js"), let range = url.range(of: "/s/player/") else { return nil }
        let id = url[range.upperBound...].prefix { $0 != "/" }
        guard id.count >= 8, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            return nil
        }
        return String(id)
    }

    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let dated = files.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(Self.keep) { try? fm.removeItem(at: url) }
    }
}

/// Attaches the device-code sign-in's Google token to TVHTML5 `player` requests (Android `YouTubeAuthManager`:
/// only TVHTML5 accepts a Bearer token; every other client answers 400). YouTube rejects an API key next to an
/// `Authorization` header, so the key is dropped from the URL. Requests that already carry the cookie are untouched.
nonisolated struct GoogleBearerHTTPClient: HTTPClient {
    let inner: any HTTPClient
    let accessToken: @Sendable () async -> String?

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard Self.wantsBearer(request), let token = await accessToken() else { return try await inner.send(request) }
        var signed = request
        signed.setHeader("Authorization", GoogleDeviceAuth.authorizationHeader(accessToken: token))
        signed.url = Self.removingKey(request.url)
        return try await inner.send(signed)
    }

    static func wantsBearer(_ request: HTTPRequest) -> Bool {
        request.method == .post && request.url.contains("/youtubei/v1/player")
            && request.header("X-YouTube-Client-Name") == String(InnerTubeContexts.tvHTML5.clientNameId)
            && request.header("cookie") == nil && request.header("Authorization") == nil
    }

    /// The URL without its `key=` query parameter.
    static func removingKey(_ url: String) -> String {
        guard let q = url.firstIndex(of: "?") else { return url }
        let base = url[..<q]
        let kept = url[url.index(after: q)...].split(separator: "&").filter { !$0.hasPrefix("key=") }
        return kept.isEmpty ? String(base) : base + "?" + kept.joined(separator: "&")
    }
}
