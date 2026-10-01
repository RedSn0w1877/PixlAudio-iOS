import CryptoKit
import Foundation
import PixlNet
import Security

/// The platform pieces PixlNet's Spotify code is injected with: CryptoKit's SHA-256, secure random bytes, the
/// Keychain token store and the small non-secret preferences (client-id override, cached profile).
nonisolated enum SpotifyPlatform {
    /// SHA-256 for PKCE (`code_challenge`) and synthetic YouTube Music ids.
    static let sha256: SHA256Function = { bytes in Array(SHA256.hash(data: Data(bytes))) }

    /// Cryptographically secure random bytes (`SecRandomCopyBytes`) for the PKCE verifier and `state`.
    static let randomBytes: @Sendable (Int) -> [UInt8] = { count in
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        if status != errSecSuccess {
            // Never fall back to a predictable verifier: SystemRandomNumberGenerator is also a CSPRNG on Darwin.
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        }
        return bytes
    }
}

/// Spotify tokens in the Keychain (generic password, after-first-unlock so background refreshes work, no access
/// group). `save` returns only once the item is written — the rotated refresh token is durable before it is used.
nonisolated struct KeychainSpotifyTokenStore: SpotifyTokenStore {
    static let account = "spotify.tokens"

    func load() async -> SpotifyTokens? {
        guard let data = try? KeychainStore.data(for: Self.account) else { return nil }
        return try? JSONDecoder().decode(SpotifyTokens.self, from: data)
    }

    func save(_ tokens: SpotifyTokens) async throws {
        try KeychainStore.set(try JSONEncoder().encode(tokens), for: Self.account)
    }

    func clear() async {
        try? KeychainStore.delete(account: Self.account)
    }
}

/// Non-secret Spotify preferences in `UserDefaults` (Android keeps them in the same encrypted prefs as the tokens;
/// none of these is a credential — a PKCE client id is public).
nonisolated struct SpotifyPreferences: @unchecked Sendable {
    static let clientIdOverrideKey = "spotify_client_id_override"
    static let accountNameKey = "spotify_account_name"
    static let accountEmailKey = "spotify_account_email"
    static let lastSyncKey = "spotify_last_full_sync_ms"

    let defaults: UserDefaults
    let bundle: Bundle

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
    }

    /// The build's client id (`SpotifyClientID` in Info.plist, from the `SPOTIFY_CLIENT_ID` build setting).
    var bundledClientId: String {
        (bundle.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Android `clientId()`: the user's override when set, else the build's.
    var clientId: String {
        let override = clientIdOverride
        return override.isEmpty ? bundledClientId : override
    }

    var clientIdOverride: String {
        (defaults.string(forKey: Self.clientIdOverrideKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setClientIdOverride(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { defaults.removeObject(forKey: Self.clientIdOverrideKey) } else { defaults.set(trimmed, forKey: Self.clientIdOverrideKey) }
    }

    var accountName: String? { defaults.string(forKey: Self.accountNameKey).flatMap { $0.isEmpty ? nil : $0 } }
    var accountEmail: String? { defaults.string(forKey: Self.accountEmailKey).flatMap { $0.isEmpty ? nil : $0 } }

    /// `cacheAccount`.
    func cacheAccount(name: String?, email: String?) {
        defaults.set(name ?? "", forKey: Self.accountNameKey)
        defaults.set(email ?? "", forKey: Self.accountEmailKey)
    }

    var lastFullSyncMs: Int64 { Int64(defaults.double(forKey: Self.lastSyncKey)) }
    func setLastFullSync(_ ms: Int64) { defaults.set(Double(ms), forKey: Self.lastSyncKey) }

    /// `clearSession`'s profile part.
    func clearAccount() {
        defaults.removeObject(forKey: Self.accountNameKey)
        defaults.removeObject(forKey: Self.accountEmailKey)
        defaults.removeObject(forKey: Self.lastSyncKey)
    }
}
