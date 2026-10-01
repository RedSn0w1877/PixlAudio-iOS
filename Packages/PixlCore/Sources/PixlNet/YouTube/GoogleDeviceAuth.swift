// Port of `data/network/youtube/GoogleOAuthService.kt` and the device-flow half of `YouTubeAuthManager.kt`: Google's
// OAuth 2.0 flow for limited-input devices (RFC 8628) with the YouTube TV app's public client credentials. The app
// shows a short code, the user types it at google.com/device, and the password never passes through the app.

import Foundation
import PixlFoundation
import PixlModel

/// `DeviceCodeResponse`.
public struct GoogleDeviceCode: Sendable, Hashable {
    public var deviceCode: String
    public var userCode: String
    public var verificationUrl: String?
    /// Some responses say `verification_uri`.
    public var verificationUri: String?
    public var expiresIn: Int64
    public var interval: Int64?

    public init(deviceCode: String, userCode: String, verificationUrl: String?, verificationUri: String?, expiresIn: Int64, interval: Int64?) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationUrl = verificationUrl
        self.verificationUri = verificationUri
        self.expiresIn = expiresIn
        self.interval = interval
    }

    /// Where the user types the code, whatever the field is called.
    public var verification: String { verificationUrl ?? verificationUri ?? "https://www.google.com/device" }

    /// Decodes the JSON body (nil when a required field is missing).
    public init?(json: JSONValue) {
        guard let o = json.objectValue,
              let deviceCode = LenientJSON.string(o["device_code"]),
              let userCode = LenientJSON.string(o["user_code"]),
              let expiresIn = LenientJSON.long(o["expires_in"]) else { return nil }
        self.init(deviceCode: deviceCode, userCode: userCode, verificationUrl: LenientJSON.string(o["verification_url"]),
                  verificationUri: LenientJSON.string(o["verification_uri"]), expiresIn: expiresIn,
                  interval: LenientJSON.long(o["interval"]))
    }
}

/// `TokenResponse` (Google).
public struct GoogleTokenResponse: Sendable, Hashable {
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresIn: Int64?
    public var tokenType: String?
    public var scope: String?
    /// `authorization_pending`, `slow_down`, `access_denied`, `expired_token`, `invalid_grant`…
    public var error: String?

    public init(accessToken: String? = nil, refreshToken: String? = nil, expiresIn: Int64? = nil, tokenType: String? = nil,
                scope: String? = nil, error: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
        self.scope = scope
        self.error = error
    }

    public init?(json: JSONValue) {
        guard let o = json.objectValue else { return nil }
        self.init(accessToken: LenientJSON.string(o["access_token"]), refreshToken: LenientJSON.string(o["refresh_token"]),
                  expiresIn: LenientJSON.long(o["expires_in"]), tokenType: LenientJSON.string(o["token_type"]),
                  scope: LenientJSON.string(o["scope"]), error: LenientJSON.string(o["error"]))
    }
}

/// Stored YouTube OAuth tokens.
public struct GoogleTokens: Sendable, Hashable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAtMs: Int64

    public init(accessToken: String, refreshToken: String?, expiresAtMs: Int64) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAtMs = expiresAtMs
    }
}

/// The device flow.
public enum GoogleDeviceAuth {
    /// YouTube TV app OAuth client (public; used by yt-dlp and others).
    public static let clientId = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
    public static let clientSecret = "SboVhoG9s0rNafixCSGGKXAT"
    public static let scope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
    public static let oauthBaseURL = "https://oauth2.googleapis.com/"
    public static let deviceCodeGrantType = "urn:ietf:params:oauth:grant-type:device_code"
    public static let expiryMarginMs: Int64 = 300_000
    public static let defaultIntervalSeconds: Int64 = 5
    public static let slowDownIncrementMs: Int64 = 2000
    public static let defaultExpiresInSeconds: Int64 = 3600

    private static func form(_ path: String, _ fields: [(name: String, value: String)]) -> HTTPRequest {
        HTTPRequest(method: .post, url: oauthBaseURL + path,
                    headers: [HTTPHeader("Content-Type", "application/x-www-form-urlencoded")],
                    body: URLCoding.formBody(fields))
    }

    /// Step 1: `POST device/code` (client_id, scope).
    public static func deviceCodeRequest() -> HTTPRequest {
        form("device/code", [("client_id", clientId), ("scope", scope)])
    }

    /// Step 2: `POST token` with the device code (polled until the user finishes).
    public static func pollRequest(deviceCode: String) -> HTTPRequest {
        form("token", [("client_id", clientId), ("client_secret", clientSecret), ("device_code", deviceCode),
                       ("grant_type", deviceCodeGrantType)])
    }

    /// `POST token` with the refresh token.
    public static func refreshRequest(refreshToken: String) -> HTTPRequest {
        form("token", [("client_id", clientId), ("client_secret", clientSecret), ("refresh_token", refreshToken),
                       ("grant_type", "refresh_token")])
    }

    /// What one poll response means.
    public enum PollStep: Sendable, Hashable {
        /// Tokens arrived: persist them.
        case success(GoogleTokens)
        /// Keep polling (`authorization_pending`, or an unparseable/failed response that names no error).
        case pending
        /// Keep polling, `slowDownIncrementMs` slower.
        case slowDown
        /// Stop: show this reason.
        case failed(String)
    }

    /// `pollForToken`'s handling of one response.
    public static func pollStep(statusCode: Int, body: GoogleTokenResponse?, nowMs: Int64) -> PollStep {
        if let access = body?.accessToken, !NetText.isBlank(access) {
            return .success(GoogleTokens(accessToken: access, refreshToken: body?.refreshToken,
                                         expiresAtMs: nowMs + (body?.expiresIn ?? defaultExpiresInSeconds) * 1000))
        }
        switch body?.error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .failed("Sign-in was denied.")
        case "expired_token": return .failed("The code expired. Try again.")
        default:
            if !(200...299).contains(statusCode), let error = body?.error { return .failed(error) }
            return .pending
        }
    }

    /// The message when the code expires before the user finishes.
    public static let timedOutMessage = "Timed out waiting for sign-in."

    /// Whether the stored access token is still good (refreshed 5 minutes before expiry).
    public static func isAccessTokenValid(_ tokens: GoogleTokens?, nowMs: Int64) -> Bool {
        guard let tokens, !NetText.isBlank(tokens.accessToken) else { return false }
        return nowMs < tokens.expiresAtMs - expiryMarginMs
    }

    /// The outcome of a refresh response.
    public enum RefreshOutcome: Sendable, Hashable {
        /// New tokens (the device flow does not rotate the refresh token, but a new one is kept if sent).
        case refreshed(GoogleTokens)
        /// `invalid_grant`: the session is dead — sign out.
        case signedOut
        /// Any other failure: keep the session, no token now.
        case failed
    }

    public static func refreshOutcome(_ body: GoogleTokenResponse?, previousRefreshToken: String, nowMs: Int64) -> RefreshOutcome {
        guard let access = body?.accessToken, !NetText.isBlank(access) else {
            return body?.error == "invalid_grant" ? .signedOut : .failed
        }
        return .refreshed(GoogleTokens(accessToken: access, refreshToken: body?.refreshToken ?? previousRefreshToken,
                                       expiresAtMs: nowMs + (body?.expiresIn ?? defaultExpiresInSeconds) * 1000))
    }

    /// `Authorization: Bearer <token>`.
    public static func authorizationHeader(accessToken: String) -> String { "Bearer \(accessToken)" }
}

/// Persists Google tokens (the app's Keychain).
public protocol GoogleTokenStore: Sendable {
    func load() async -> GoogleTokens?
    func save(_ tokens: GoogleTokens) async
    func clear() async
}

/// The device flow over an `HTTPClient`, with a single refresh at a time.
public actor GoogleDeviceAuthClient {
    private let http: any HTTPClient
    private let store: any GoogleTokenStore
    private let nowMs: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void

    public init(http: any HTTPClient, store: any GoogleTokenStore,
                nowMs: @escaping @Sendable () -> Int64 = { currentTimeMillis() },
                sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) }) {
        self.http = http
        self.store = store
        self.nowMs = nowMs
        self.sleep = sleep
    }

    /// Step 1: the code to show, or nil when Google did not answer.
    public func requestDeviceCode() async -> GoogleDeviceCode? {
        guard let response = try? await http.send(GoogleDeviceAuth.deviceCodeRequest()), response.isSuccessful,
              let json = OrgJSON.parse(response.body) else { return nil }
        return GoogleDeviceCode(json: json)
    }

    /// The outcome of the sign-in wait.
    public enum SignInResult: Sendable, Hashable {
        case success
        case failed(String)
    }

    /// Step 2: polls until the user finishes or the code expires; saves the tokens on success.
    public func pollForToken(_ device: GoogleDeviceCode) async throws -> SignInResult {
        var intervalMs = (device.interval ?? GoogleDeviceAuth.defaultIntervalSeconds) * 1000
        let deadline = nowMs() + device.expiresIn * 1000
        while nowMs() < deadline {
            try await sleep(intervalMs)
            let response: HTTPResponse
            do {
                response = try await http.send(GoogleDeviceAuth.pollRequest(deviceCode: device.deviceCode))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            let body = OrgJSON.parse(response.body).flatMap(GoogleTokenResponse.init(json:))
            switch GoogleDeviceAuth.pollStep(statusCode: response.statusCode, body: body, nowMs: nowMs()) {
            case .success(let tokens):
                var toSave = tokens
                if toSave.refreshToken.map(NetText.isBlank) ?? true {
                    toSave.refreshToken = await store.load()?.refreshToken
                }
                await store.save(toSave)
                return .success
            case .pending: continue
            case .slowDown: intervalMs += GoogleDeviceAuth.slowDownIncrementMs
            case .failed(let reason): return .failed(reason)
            }
        }
        return .failed(GoogleDeviceAuth.timedOutMessage)
    }

    /// A valid access token, refreshing it when due; nil without a session or when the refresh failed.
    public func validAccessToken() async -> String? {
        let tokens = await store.load()
        if GoogleDeviceAuth.isAccessTokenValid(tokens, nowMs: nowMs()), let tokens { return tokens.accessToken }
        guard let refreshToken = tokens?.refreshToken, !NetText.isBlank(refreshToken) else { return nil }
        guard let response = try? await http.send(GoogleDeviceAuth.refreshRequest(refreshToken: refreshToken)) else { return nil }
        let body = OrgJSON.parse(response.body).flatMap(GoogleTokenResponse.init(json:))
        switch GoogleDeviceAuth.refreshOutcome(body, previousRefreshToken: refreshToken, nowMs: nowMs()) {
        case .refreshed(let newTokens):
            await store.save(newTokens)
            return newTokens.accessToken
        case .signedOut:
            await store.clear()
            return nil
        case .failed:
            return nil
        }
    }
}
