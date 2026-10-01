// Port of `data/spotify/SpotifyAuthManager.kt` and `SpotifyAuthApiService`: OAuth 2.0 with PKCE (no client secret).
// SHA-256 and random bytes are injected (PixlCore cannot use CryptoKit). **Spotify rotates the refresh token on every
// refresh**: `SpotifySession` persists the new one (awaiting the store) before it hands out the new access token, or
// the account dies after one rotation.

import Foundation
import PixlFoundation
import PixlModel

/// SHA-256 over bytes (the app passes CryptoKit's).
public typealias SHA256Function = @Sendable ([UInt8]) -> [UInt8]

/// PKCE and authorization URL helpers.
public enum SpotifyAuth {
    public static let authorizeEndpoint = "https://accounts.spotify.com/authorize"
    public static let accountsBaseURL = "https://accounts.spotify.com/"
    public static let apiBaseURL = "https://api.spotify.com/"
    /// The iOS redirect (`pixlaudio://spotify-callback`; the owner registers it with the Spotify app).
    public static let redirectScheme = "pixlaudio"
    public static let redirectHost = "spotify-callback"
    public static let redirectURI = "\(redirectScheme)://\(redirectHost)"
    /// Android's redirect, for reference.
    public static let androidRedirectURI = "pixelplay://spotify-callback"

    /// `user-top-read` (most-played) was added after the first release: accounts linked before must reconnect once.
    public static let scopes = "user-library-read playlist-read-private playlist-read-collaborative user-read-private user-top-read"

    public static let expiryMarginMs: Int64 = 300_000
    public static let defaultExpiresInSeconds: Int64 = 3600
    /// 64 random bytes → 86 base64url characters (RFC 7636 allows 43-128).
    public static let verifierByteCount = 64
    public static let stateLength = 24

    /// `generateCodeVerifier`: base64url (no padding) of the random bytes.
    public static func codeVerifier(randomBytes: [UInt8]) -> String { NetText.base64URL(randomBytes) }

    /// `deriveCodeChallenge`: base64url(SHA-256(ASCII verifier)).
    public static func codeChallenge(verifier: String, sha256: SHA256Function) -> String {
        NetText.base64URL(sha256(Array(verifier.utf8)))
    }

    /// The `state` value: the first 24 characters of another verifier.
    public static func state(randomBytes: [UInt8]) -> String { NetText.take(codeVerifier(randomBytes: randomBytes), stateLength) }

    /// The authorization URL (Android `Uri.Builder` encoding). `show_dialog=true` makes Spotify re-ask for the
    /// current scope list even for an account that approved this client before.
    public static func authorizationURL(clientId: String, codeChallenge: String, state: String,
                                        redirectURI: String = redirectURI, scopes: String = scopes) -> String {
        var url = authorizeEndpoint
        for (key, value) in [("client_id", clientId), ("response_type", "code"), ("redirect_uri", redirectURI),
                             ("code_challenge_method", "S256"), ("code_challenge", codeChallenge), ("scope", scopes),
                             ("state", state), ("show_dialog", "true")] {
            url = URLCoding.androidAppendingQueryParameter(url, key, value)
        }
        return url
    }

    /// `isCallbackUri`.
    public static func isCallbackURL(_ url: String, scheme: String = redirectScheme, host: String = redirectHost) -> Bool {
        URLCoding.scheme(url) == scheme && URLCoding.host(url) == host
    }

    /// The outcome of validating the browser's return.
    public enum CallbackResult: Sendable, Hashable {
        /// Exchange this code.
        case code(String)
        /// Spotify returned `error=…`.
        case providerError(String)
        /// `state` did not match (or nothing was pending).
        case stateMismatch
        /// No `code` parameter.
        case missingCode
    }

    /// `handleAuthorizationResponse`'s checks, in Android's order.
    public static func validateCallback(_ url: String, expectedState: String?) -> CallbackResult {
        if let error = URLCoding.androidQueryParameter(url, "error"), !NetText.isBlank(error) { return .providerError(error) }
        let received = URLCoding.androidQueryParameter(url, "state")
        guard let expectedState, expectedState == received else { return .stateMismatch }
        guard let code = URLCoding.androidQueryParameter(url, "code"), !NetText.isBlank(code) else { return .missingCode }
        return .code(code)
    }

    /// `POST api/token` (authorization_code).
    public static func exchangeCodeRequest(code: String, clientId: String, codeVerifier: String, redirectURI: String = redirectURI) -> HTTPRequest {
        tokenRequest([("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
                      ("client_id", clientId), ("code_verifier", codeVerifier)])
    }

    /// `POST api/token` (refresh_token).
    public static func refreshRequest(refreshToken: String, clientId: String) -> HTTPRequest {
        tokenRequest([("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientId)])
    }

    private static func tokenRequest(_ fields: [(name: String, value: String)]) -> HTTPRequest {
        HTTPRequest(method: .post, url: accountsBaseURL + "api/token",
                    headers: [HTTPHeader("Content-Type", "application/x-www-form-urlencoded")], body: URLCoding.formBody(fields))
    }

    /// `saveTokens`: the new access token, expiry, and the refresh token — **the rotated one whenever Spotify sent
    /// one**, else the previous. nil when the response has no access token.
    public static func tokens(from response: SpotifyTokenResponse, previousRefreshToken: String?, nowMs: Int64) -> SpotifyTokens? {
        guard let access = response.accessToken, !NetText.isBlank(access) else { return nil }
        let rotated = response.refreshToken.flatMap { NetText.isBlank($0) ? nil : $0 }
        return SpotifyTokens(accessToken: access, refreshToken: rotated ?? previousRefreshToken,
                             expiresAtMs: nowMs + (response.expiresIn ?? defaultExpiresInSeconds) * 1000,
                             scope: response.scope)
    }

    /// `ensureValidToken`'s freshness check (refresh 5 minutes early).
    public static func isAccessTokenValid(_ tokens: SpotifyTokens?, nowMs: Int64) -> Bool {
        guard let tokens, !NetText.isBlank(tokens.accessToken) else { return false }
        return nowMs < tokens.expiresAtMs - expiryMarginMs
    }
}

/// Stored Spotify tokens.
public struct SpotifyTokens: Sendable, Hashable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAtMs: Int64
    /// The scope Spotify actually granted (diagnostics: whether a re-login is needed for new scopes).
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAtMs: Int64, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAtMs = expiresAtMs
        self.scope = scope
    }

    /// Whether the granted scope includes `scope`.
    public func grants(_ scope: String) -> Bool {
        (self.scope ?? "").split(separator: " ").contains { $0 == scope }
    }
}

/// Persists Spotify tokens (the app's Keychain). `save` must not return before the tokens are durable.
public protocol SpotifyTokenStore: Sendable {
    func load() async -> SpotifyTokens?
    func save(_ tokens: SpotifyTokens) async throws
    func clear() async
}

/// Spotify sign-in failures (`Result.failure` messages on Android).
public struct SpotifyAuthError: Error, Sendable, Hashable, CustomStringConvertible {
    public let message: String
    /// The HTTP status of the token call, when there was one.
    public let statusCode: Int?

    public init(_ message: String, statusCode: Int? = nil) {
        self.message = message
        self.statusCode = statusCode
    }

    public var description: String { message }
}

/// A pending PKCE authorization (verifier + state), kept until the browser returns.
public struct SpotifyPendingAuthorization: Sendable, Hashable, Codable {
    public var codeVerifier: String
    public var state: String
    public var url: String
}

/// The Spotify session: authorization, code exchange, and serialized token refreshes.
public actor SpotifySession {
    private let http: any HTTPClient
    private let store: any SpotifyTokenStore
    private let clientId: @Sendable () async -> String
    private let sha256: SHA256Function
    private let randomBytes: @Sendable (Int) -> [UInt8]
    private let nowMs: @Sendable () -> Int64
    private let redirectURI: String

    private var pending: SpotifyPendingAuthorization?
    /// The latest tokens seen (kept even if persisting them failed, so this process can still refresh).
    private var memory: SpotifyTokens?
    private var refreshTask: Task<Result<String, SpotifyAuthError>, Never>?

    /// The last error, for the dashboard.
    public private(set) var lastError: String?

    public init(http: any HTTPClient, store: any SpotifyTokenStore, clientId: @escaping @Sendable () async -> String,
                sha256: @escaping SHA256Function, randomBytes: @escaping @Sendable (Int) -> [UInt8],
                nowMs: @escaping @Sendable () -> Int64 = { currentTimeMillis() },
                redirectURI: String = SpotifyAuth.redirectURI) {
        self.http = http
        self.store = store
        self.clientId = clientId
        self.sha256 = sha256
        self.randomBytes = randomBytes
        self.nowMs = nowMs
        self.redirectURI = redirectURI
    }

    private func currentTokens() async -> SpotifyTokens? {
        if let memory { return memory }
        memory = await store.load()
        return memory
    }

    /// Whether a refresh token exists (`isLoggedIn`).
    public func isLoggedIn() async -> Bool { await currentTokens()?.refreshToken != nil }

    // MARK: Sign-in

    /// `buildAuthorizationUri`: a new verifier and state, remembered until the callback; nil without a client id.
    public func beginAuthorization() async -> SpotifyPendingAuthorization? {
        let id = await clientId()
        if NetText.isBlank(id) {
            lastError = "Falta el client ID de Spotify"
            return nil
        }
        let verifier = SpotifyAuth.codeVerifier(randomBytes: randomBytes(SpotifyAuth.verifierByteCount))
        let state = SpotifyAuth.state(randomBytes: randomBytes(SpotifyAuth.verifierByteCount))
        let url = SpotifyAuth.authorizationURL(clientId: id, codeChallenge: SpotifyAuth.codeChallenge(verifier: verifier, sha256: sha256),
                                               state: state, redirectURI: redirectURI)
        let auth = SpotifyPendingAuthorization(codeVerifier: verifier, state: state, url: url)
        pending = auth
        return auth
    }

    /// Restores a pending authorization the app persisted (e.g. across a relaunch).
    public func restorePending(_ auth: SpotifyPendingAuthorization?) { pending = auth }

    /// `handleAuthorizationResponse`: validates the callback, exchanges the code and saves the tokens.
    public func handleCallback(_ url: String) async -> Result<SpotifyTokens, SpotifyAuthError> {
        switch SpotifyAuth.validateCallback(url, expectedState: pending?.state) {
        case .providerError(let error):
            lastError = error
            return .failure(SpotifyAuthError("Spotify devolvió: \(error)"))
        case .stateMismatch:
            lastError = "Respuesta de login no válida"
            return .failure(SpotifyAuthError("state no coincide"))
        case .missingCode:
            lastError = "Spotify returned no authorization code"
            return .failure(SpotifyAuthError("sin código de autorización"))
        case .code(let code):
            guard let verifier = pending?.codeVerifier else { return .failure(SpotifyAuthError("sin code_verifier guardado")) }
            let request = SpotifyAuth.exchangeCodeRequest(code: code, clientId: await clientId(), codeVerifier: verifier, redirectURI: redirectURI)
            let response: HTTPResponse
            do {
                response = try await http.send(request)
            } catch {
                lastError = String(describing: error)
                return .failure(SpotifyAuthError(String(describing: error)))
            }
            let body = OrgJSON.parse(response.body).flatMap(SpotifyTokenResponse.init(json:))
            guard response.isSuccessful, let body,
                  let tokens = SpotifyAuth.tokens(from: body, previousRefreshToken: nil, nowMs: nowMs()) else {
                let message = "Canje de código fallido (HTTP \(response.statusCode))"
                lastError = message
                return .failure(SpotifyAuthError(message, statusCode: response.statusCode))
            }
            memory = tokens
            do {
                try await store.save(tokens)
            } catch {
                lastError = "No se pudieron guardar los tokens de Spotify"
                return .failure(SpotifyAuthError("No se pudieron guardar los tokens de Spotify"))
            }
            pending = nil
            lastError = nil
            return .success(tokens)
        }
    }

    // MARK: Tokens

    /// `Authorization: Bearer …`, refreshing when due; nil without a session.
    public func authorizationHeader() async -> String? {
        guard let token = await validAccessToken() else { return nil }
        return "Bearer \(token)"
    }

    /// `ensureValidToken`.
    public func validAccessToken() async -> String? {
        let tokens = await currentTokens()
        if SpotifyAuth.isAccessTokenValid(tokens, nowMs: nowMs()), let tokens { return tokens.accessToken }
        return try? await refresh().get()
    }

    /// `forceRefresh` (after a 401).
    public func forceRefresh() async -> Result<String, SpotifyAuthError> { await refresh() }

    /// One refresh at a time; concurrent callers share it.
    private func refresh() async -> Result<String, SpotifyAuthError> {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    private func performRefresh() async -> Result<String, SpotifyAuthError> {
        guard let refreshToken = await currentTokens()?.refreshToken, !NetText.isBlank(refreshToken) else {
            return .failure(SpotifyAuthError("sin refresh token"))
        }
        let response: HTTPResponse
        do {
            response = try await http.send(SpotifyAuth.refreshRequest(refreshToken: refreshToken, clientId: await clientId()))
        } catch {
            lastError = String(describing: error)
            return .failure(SpotifyAuthError(String(describing: error)))
        }
        let body = OrgJSON.parse(response.body).flatMap(SpotifyTokenResponse.init(json:))
        guard response.isSuccessful, let body,
              let tokens = SpotifyAuth.tokens(from: body, previousRefreshToken: refreshToken, nowMs: nowMs()) else {
            // 400 (invalid_grant): the refresh token is dead — sign in again.
            if response.statusCode == 400 { await clearSession() }
            let message = "Refresco de token fallido (HTTP \(response.statusCode))"
            lastError = message
            return .failure(SpotifyAuthError(message, statusCode: response.statusCode))
        }
        // Persist the rotated refresh token BEFORE the new access token is used.
        memory = tokens
        do {
            try await store.save(tokens)
        } catch {
            lastError = "No se pudo guardar el refresh token rotado"
            return .failure(SpotifyAuthError("No se pudo guardar el refresh token rotado"))
        }
        return .success(tokens.accessToken)
    }

    /// `clearSession`.
    public func clearSession() async {
        memory = nil
        pending = nil
        await store.clear()
    }
}
