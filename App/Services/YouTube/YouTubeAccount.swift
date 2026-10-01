import Foundation
import PixlNet

/// The user's YouTube session (Android `YouTubeAuthManager` + the visitorData half of `PixelPlayPoTokenProvider`),
/// in the Keychain: the music.youtube.com cookie (web sign-in or pasted), the visitorData captured with it, and the
/// device-code flow's Google tokens. It is what `InnerTubeClient` asks for every request:
/// - `cookie()` — only ever sent to clients that accept it (PixlNet checks `supportsCookies`);
/// - `anonymousVisitorData()` — a fresh one fetched once per process, so anonymous requests are not answered
///   "Sign in to confirm you're not a bot";
/// - `webClientPoToken(videoId:)` — BotGuard in the off-screen web view, for the signed-in WEB_REMIX fallback.
actor YouTubeAccount: YouTubeSessionProviding, GoogleTokenStore {
    static let cookieKey = "youtube.cookie"
    static let visitorDataKey = "youtube.visitorData"
    static let tokensKey = "youtube.googleTokens"

    private let visitorProvider: VisitorDataProvider
    private let poTokens: PoTokenGenerator?
    private var loaded = false
    private var storedCookie: String?
    private var storedVisitor: String?
    private var tokens: GoogleTokens?

    init(http: any HTTPClient, poTokens: PoTokenGenerator?) {
        visitorProvider = VisitorDataProvider(http: http)
        self.poTokens = poTokens
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        storedCookie = Self.string(Self.cookieKey)
        storedVisitor = Self.string(Self.visitorDataKey)
        if let data = try? KeychainStore.data(for: Self.tokensKey) {
            tokens = try? JSONDecoder().decode(GoogleTokens.self, from: data)
        }
    }

    // MARK: YouTubeSessionProviding

    func cookie() -> String? {
        loadIfNeeded()
        return storedCookie
    }

    func storedVisitorData() -> String {
        loadIfNeeded()
        return storedVisitor ?? YouTubeCookieAuth.defaultVisitorData
    }

    func anonymousVisitorData() async -> String? {
        await visitorProvider.visitorData()
    }

    func webClientPoToken(videoId: String) async -> PoTokenResult? {
        guard let poTokens else { return nil }
        return await poTokens.webClientPoToken(videoId: videoId)
    }

    nonisolated func nowSeconds() -> Int64 { Int64(Date().timeIntervalSince1970) }

    // MARK: Session state

    /// Signed in by cookie or by the device-code flow.
    var hasSession: Bool {
        loadIfNeeded()
        return storedCookie != nil || tokens?.refreshToken != nil
    }

    var hasCookie: Bool {
        loadIfNeeded()
        return storedCookie != nil
    }

    /// Android `saveCookie`. The cookie is normalised to `name=value; name=value`.
    func saveCookie(_ raw: String) {
        loadIfNeeded()
        let cookie = YouTubeCookieText.normalize(raw)
        storedCookie = cookie
        try? KeychainStore.set(Data(cookie.utf8), for: Self.cookieKey)
    }

    /// Android `saveVisitorData` (blank values are ignored).
    func saveVisitorData(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "undefined", trimmed != "null" else { return }
        loadIfNeeded()
        storedVisitor = trimmed
        try? KeychainStore.set(Data(trimmed.utf8), for: Self.visitorDataKey)
    }

    /// Android `signOut`: tokens and cookie go; the visitorData stays (it is not an account).
    func signOut() {
        loadIfNeeded()
        storedCookie = nil
        tokens = nil
        try? KeychainStore.delete(account: Self.cookieKey)
        try? KeychainStore.delete(account: Self.tokensKey)
    }

    // MARK: GoogleTokenStore (device-code flow)

    func load() -> GoogleTokens? {
        loadIfNeeded()
        return tokens
    }

    func save(_ newTokens: GoogleTokens) {
        loadIfNeeded()
        tokens = newTokens
        if let data = try? JSONEncoder().encode(newTokens) { try? KeychainStore.set(data, for: Self.tokensKey) }
    }

    func clear() {
        loadIfNeeded()
        tokens = nil
        try? KeychainStore.delete(account: Self.tokensKey)
    }

    private static func string(_ key: String) -> String? {
        guard let data = try? KeychainStore.data(for: key) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}

/// Cookie text handling for the paste fallback and the web sign-in.
nonisolated enum YouTubeCookieText {
    /// `name=value` pairs joined with `"; "` (what `YouTubeCookieAuth.parseCookieString` splits on). Accepts a header
    /// copied with or without a `Cookie:` prefix, newlines and stray spaces.
    static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") { text = String(text.dropFirst("cookie:".count)) }
        let pairs = text.split(whereSeparator: { $0 == ";" || $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("=") && !$0.hasPrefix("=") }
        return pairs.joined(separator: "; ")
    }

    /// The SAPISIDHASH needs `SAPISID` (Android waits for it before accepting a cookie).
    static func hasSAPISID(_ cookie: String) -> Bool {
        YouTubeCookieAuth.parseCookieString(normalize(cookie))["SAPISID"].map { !$0.isEmpty } ?? false
    }

    /// The cookie header for music.youtube.com from the web view's cookies (`.youtube.com` and `music.youtube.com`).
    static func header(from cookies: [(domain: String, name: String, value: String)]) -> String {
        var seen = Set<String>()
        var pairs: [String] = []
        for cookie in cookies {
            let domain = cookie.domain.lowercased()
            guard domain == ".youtube.com" || domain == "youtube.com" || domain.hasSuffix("music.youtube.com")
                    || domain == "www.youtube.com" else { continue }
            guard seen.insert(cookie.name).inserted else { continue }
            pairs.append("\(cookie.name)=\(cookie.value)")
        }
        return pairs.joined(separator: "; ")
    }
}
