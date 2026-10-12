import SwiftUI

/// The empty state of Home and Library while no Spotify account is linked (the app is Spotify-only: the library is the
/// account's playlists and liked songs, so there is nothing to show until the person connects).
struct ConnectSpotifyEmptyState: View {
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 18) {
            LibraryEmptyState(systemImage: "music.note.list", title: "Connect Spotify",
                              subtitle: "Sign in with Spotify to bring in your playlists and liked songs.")
                .frame(maxHeight: 220)
            GlassPillButton(title: "Connect Spotify", systemImage: "link",
                            tint: theme.primary.opacity(GlassTint.prominent), foreground: theme.onPrimary,
                            style: .titleMedium, horizontalPadding: 24, verticalPadding: 14) {
                router.push(.spotifyDashboard)
            }
            .accessibilityIdentifier("connectSpotify.button")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityIdentifier("connectSpotify.empty")
    }
}

extension AccountsStore {
    /// No Spotify account is linked (or being linked): Home and Library show `ConnectSpotifyEmptyState`.
    var needsSpotifyConnection: Bool {
        switch spotify {
        case .signedOut, .failed: true
        case .signingIn, .signedIn, .needsReconnect: false
        }
    }
}
