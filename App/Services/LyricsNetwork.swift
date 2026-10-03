import Foundation
import PixlNet

/// Transport for BiniLyrics. The session never follows a redirect by itself: the 3xx comes back to
/// `BiniLyricsClient`, which follows it only to an allowlisted HTTPS host (`BiniLyricsMatching.allowedHosts`).
/// No cookies, short timeouts.
nonisolated enum LyricsNetwork {
    static let noRedirectSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = BiniLyricsClient.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
    }()

    /// The `HTTPClient` `BiniLyricsClient` is given.
    static func biniLyricsHTTPClient() -> any HTTPClient { URLSessionHTTPClient(session: noRedirectSession) }
}

/// Refuses every automatic redirect, so the redirect response itself is delivered to the caller.
nonisolated final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
