import Foundation
import Observation

/// Linked accounts as the UI shows them (Android `AccountsScreen`, Spotify dashboard, YouTube login). Stage 12
/// (Spotify) and stage 11 (YouTube) own the sign-in flows and update this store; tokens live in the Keychain
/// (`KeychainStore`), never here.
@Observable
final class AccountsStore {
    nonisolated enum LinkState: Equatable, Sendable {
        case signedOut
        case signingIn
        case signedIn(displayName: String)
        /// Linked before a scope was added (e.g. Spotify `user-top-read`): must reconnect once.
        case needsReconnect(displayName: String)
        case failed(message: String)
    }

    var spotify: LinkState = .signedOut
    var youtube: LinkState = .signedOut

    /// Whether a Spotify client id is configured (Android `SpotifyAuthManager.hasClientId()`): CI injects
    /// `SpotifyClientID` into Info.plist; empty disables Spotify sign-in.
    let hasSpotifyClientId: Bool

    init(bundle: Bundle = .main) {
        let id = bundle.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? ""
        hasSpotifyClientId = !id.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
