import Foundation
import PixlNet
import UIKit
import WebKit

/// Generates PoTokens by running Google's own BotGuard inside an off-screen `WKWebView` (Android `PoTokenWebView` +
/// `PixelPlayPoTokenProvider`, ported from NewPipe). Only the WEB-family token can be made this way (the native
/// clients' tokens come from DroidGuard/iOSGuard, closed outside those apps), so PixlNet asks for one only for the
/// signed-in WEB_REMIX fallback — VISIONOS, which leads the chain, needs none.
///
/// Flow: load `po_token.html` (the BotGuard interpreter glue) with the www.youtube.com origin → `Create` (the
/// challenge) → `runBotGuard(challenge)` in the page → `GenerateIT` (the integrity token, ~12 h) → per identifier,
/// `obtainPoToken(...)` mints a token. The streaming token is minted first, for the generator's own visitorData.
@MainActor
final class PoTokenGenerator {
    nonisolated struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private let http: any HTTPClient
    private let freshVisitorData: @Sendable () async -> String?
    private var webView: WKWebView?
    private var loader: PageLoader?
    private var createdAtSeconds: Int64 = 0
    private var lifetimeSeconds: Int64 = 0
    private var visitorData: String?
    private var streamingPoToken: String?
    private var building: Task<Void, any Error>?
    /// Why the last generation failed (diagnostics).
    private(set) var lastError: String?

    init(http: any HTTPClient, freshVisitorData: @escaping @Sendable () async -> String?) {
        self.http = http
        self.freshVisitorData = freshVisitorData
    }

    /// `getWebClientPoToken(videoId)`: nil (and `lastError`) when BotGuard could not run.
    func webClientPoToken(videoId: String) async -> PoTokenResult? {
        do {
            let result = try await token(videoId: videoId, forceRecreate: false)
            lastError = nil
            return result
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    private var isExpired: Bool {
        PoTokenJS.isExpired(createdAtSeconds: createdAtSeconds, lifetimeSeconds: lifetimeSeconds,
                            nowSeconds: Int64(Date().timeIntervalSince1970))
    }

    private func token(videoId: String, forceRecreate: Bool) async throws -> PoTokenResult {
        var recreated = false
        if webView == nil || forceRecreate || isExpired {
            try await recreate()
            recreated = true
        }
        do {
            let pot = try await mint(videoId)
            guard let visitorData, let streamingPoToken else { throw Failure("generator not ready") }
            return PoTokenResult(visitorData: visitorData, playerRequestPoToken: pot, streamingDataPoToken: streamingPoToken)
        } catch {
            // The web view may have been lost (app in background): rebuild once.
            if recreated { throw error }
            return try await token(videoId: videoId, forceRecreate: true)
        }
    }

    private func recreate() async throws {
        if let building { return try await building.value }
        let task = Task { @MainActor in try await self.build() }
        building = task
        defer { building = nil }
        try await task.value
    }

    private func build() async throws {
        close()
        guard let visitor = await freshVisitorData() else { throw Failure("no fresh visitorData") }
        guard let url = Bundle.main.url(forResource: "po_token", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else { throw Failure("po_token.html missing") }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        view.customUserAgent = PoTokenJS.userAgent
        view.isUserInteractionEnabled = false
        view.alpha = 0.01
        // In a window, so the page is not treated as hidden (timers BotGuard relies on keep running).
        Self.hostWindow()?.addSubview(view)
        let loader = PageLoader()
        view.navigationDelegate = loader
        self.loader = loader
        webView = view
        try await loader.load(html, baseURL: URL(string: PoTokenJS.pageBaseURL), in: view)

        let create = try await http.send(PoTokenJS.createRequest())
        guard create.statusCode == 200 else { throw Failure("Create: HTTP \(create.statusCode)") }
        let challenge = try PoTokenJS.parseChallengeData(create.text)
        let response = try await view.callAsyncJavaScript("""
            const result = await runBotGuard(JSON.parse(challenge));
            globalThis.webPoSignalOutput = result.webPoSignalOutput;
            return result.botguardResponse;
            """, arguments: ["challenge": challenge], in: nil, contentWorld: .page)
        guard let botguardResponse = response as? String, !botguardResponse.isEmpty else {
            throw Failure("runBotGuard returned nothing")
        }

        let generate = try await http.send(PoTokenJS.generateITRequest(botguardResponse: botguardResponse))
        guard generate.statusCode == 200 else { throw Failure("GenerateIT: HTTP \(generate.statusCode)") }
        let integrity = try PoTokenJS.parseIntegrityTokenData(generate.text)
        _ = try await view.callAsyncJavaScript("globalThis.integrityToken = new Uint8Array(bytes); return true;",
                                               arguments: ["bytes": integrity.token.map(Int.init)], in: nil,
                                               contentWorld: .page)
        createdAtSeconds = Int64(Date().timeIntervalSince1970)
        lifetimeSeconds = integrity.expiresInSeconds
        visitorData = visitor
        // The streaming token has to be generated first, for the visitorData.
        streamingPoToken = try await mint(visitor)
    }

    private func mint(_ identifier: String) async throws -> String {
        guard let webView else { throw Failure("no web view") }
        let result = try await webView.callAsyncJavaScript("""
            const token = obtainPoToken(globalThis.webPoSignalOutput, globalThis.integrityToken, new Uint8Array(identifier));
            return Array.from(token);
            """, arguments: ["identifier": Array(identifier.utf8).map(Int.init)], in: nil, contentWorld: .page)
        guard let numbers = result as? [NSNumber], !numbers.isEmpty else { throw Failure("obtainPoToken returned nothing") }
        let bytes = numbers.map { UInt8(truncatingIfNeeded: $0.intValue) }
        return PoTokenJS.bytesToBase64URL(bytes)
    }

    /// Tears the web view down (Android `closeInternal`).
    func close() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        loader = nil
        visitorData = nil
        streamingPoToken = nil
    }

    private static func hostWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow
    }

    /// Awaits the page load.
    final class PageLoader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, any Error>?

        func load(_ html: String, baseURL: URL?, in view: WKWebView) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.continuation = continuation
                view.loadHTMLString(html, baseURL: baseURL)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
