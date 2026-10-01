import AuthenticationServices
import PixlNet
import SwiftUI

/// Accounts (Android `presentation/screens/AccountsScreen`): the collapsing "Accounts" header, the hero card with
/// the Active / Available tiles, then either the linked services (Spotify's card: icon, account, Connected chip,
/// synced-content row, Open Service, Log out) or the empty card with a Connect button per service. Spotify is the
/// only remote source (as on Android). Cards are glass in Android's shapes (30 / 28 pt) tinted with their
/// `surfaceContainer*` role; tiles, chips and buttons on a card are fills (no glass on glass).
struct AccountsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var toast: String?

    private var spotify: SpotifyService { env.spotify }

    var body: some View {
        SettingsScaffold(title: "Accounts", screenID: "accounts", spacing: 14) {
            AccountsHeroSection(connectedCount: spotify.isLoggedIn ? 1 : 0, disconnectedCount: spotify.isLoggedIn ? 0 : 1)

            if spotify.isLoggedIn {
                Text("Linked Services")
                    .pixlFont(.titleLarge, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .padding(.leading, 4)
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                ConnectedAccountCard(
                    title: "Spotify",
                    accountLabel: spotify.accountName ?? spotify.accountEmail ?? "Linked account",
                    syncedContentLabel: "\(spotify.totalSongs) tracks · \(spotify.playlists.count) playlists",
                    isLoggingOut: spotify.isLoggingOut,
                    onManage: { router.push(.spotifyDashboard) },
                    onLogout: { Task { await spotify.logout() } })
            } else {
                EmptyAccountsCard(isConnecting: spotify.isSigningIn) {
                    Task {
                        await spotify.signIn { url in
                            try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: SpotifyAuth.redirectScheme,
                                                                            preferredBrowserSession: .shared)
                        }
                    }
                }
            }
        }
        .settingsToast($toast)
        .onChange(of: spotify.message) { _, message in
            guard let message else { return }
            toast = message
            spotify.clearMessage()
        }
        .task { await spotify.refreshLibraryState() }
    }
}

/// Android `AccountsHeroSection`: 30 pt `surfaceContainer` card, 16 pt padding, 10 pt gaps.
private struct AccountsHeroSection: View {
    let connectedCount: Int
    let disconnectedCount: Int
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connected Accounts")
                .pixlFont(.titleLarge, weight: .bold)
                .foregroundStyle(theme.onSurface)
            Text("Manage linked providers and keep each integration under your control.")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
            HStack(spacing: 8) {
                HeroStatTile(title: "Active", value: "\(connectedCount)")
                HeroStatTile(title: "Available", value: "\(connectedCount + disconnectedCount)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous),
                   tint: theme.surfaceContainer.opacity(GlassTint.surface))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("accounts.hero")
    }
}

/// Android `HeroStatTile`: 18 pt `surfaceContainerLow` tile, 12×10 padding, `labelMedium` title, `headlineSmall` bold value.
private struct HeroStatTile: View {
    let title: String
    let value: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .pixlFont(.labelMedium)
                .foregroundStyle(theme.onSurfaceVariant)
            Text(value)
                .pixlFont(.headlineSmall, weight: .bold)
                .foregroundStyle(theme.onSurface)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.surfaceContainerLow.opacity(0.7)))
        .accessibilityElement(children: .combine)
    }
}

/// Android `ServicePalette` for Spotify.
private enum SpotifyServicePalette {
    static let iconContainer = SpotifyBrand.green
    static let iconTint = Color.white
    static let statusContainer = Color(argb: 0xFFC9_F8E6)
    static let statusTint = Color(argb: 0xFF03_5C43)
}

/// Android `ConnectedAccountCard`: 28 pt `surfaceContainerHigh` card, 16 pt padding, 12 pt gaps.
private struct ConnectedAccountCard: View {
    let title: String
    let accountLabel: String
    let syncedContentLabel: String
    let isLoggingOut: Bool
    let onManage: () -> Void
    let onLogout: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SpotifyServicePalette.iconTint)
                    .frame(width: 20, height: 20)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SpotifyServicePalette.iconContainer))
                    .accessibilityHidden(true)
                Spacer().frame(width: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .pixlFont(.titleMedium, weight: .bold)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(2)
                    Text(accountLabel)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Connected")
                    .pixlFont(.labelMedium, weight: .semibold)
                    .foregroundStyle(SpotifyServicePalette.statusTint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SpotifyServicePalette.statusContainer))
            }

            // Synced content (Android: 14 pt `surfaceContainerLow` surface, 16 pt sync icon). Android tints the icon
            // with the palette's white icon tint, which vanishes on a light surface; the brand green keeps it visible.
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SpotifyBrand.green)
                    .frame(width: 16, height: 16)
                Text(syncedContentLabel)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surfaceContainerLow.opacity(0.7)))

            Rectangle()
                .fill(theme.outlineVariant.opacity(0.28))
                .frame(height: 1)

            SpotifyFilledButton(title: "Open Service", systemImage: "arrow.up.right.square", fill: theme.primaryContainer,
                                foreground: theme.onPrimaryContainer, fullWidth: true, height: 48, cornerRadius: 18,
                                isEnabled: !isLoggingOut, identifier: "accounts.openSpotify", action: onManage)
            SpotifyOutlinedButton(title: isLoggingOut ? "Logging out…" : "Log out",
                                  systemImage: "rectangle.portrait.and.arrow.right", fullWidth: true, height: 48,
                                  cornerRadius: 18, stroke: theme.onPrimaryContainer.opacity(0.45), isEnabled: !isLoggingOut,
                                  isBusy: isLoggingOut, identifier: "accounts.logout", action: onLogout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                   tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("accounts.spotifyCard")
    }
}

/// Android `EmptyAccountsCard`: 28 pt `surfaceContainer` card with a `FilledTonalButton` per service.
private struct EmptyAccountsCard: View {
    let isConnecting: Bool
    let onConnect: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No linked accounts yet")
                .pixlFont(.titleLarge, weight: .bold)
                .foregroundStyle(theme.onSurface)
            Text("Connect a provider to manage it from this screen.")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
            SpotifyFilledButton(title: isConnecting ? "Connecting to Spotify…" : "Connect Spotify", systemImage: "music.note",
                                fill: theme.secondaryContainer, foreground: theme.onSecondaryContainer, fullWidth: true,
                                height: 48, cornerRadius: 18, isEnabled: !isConnecting, identifier: "accounts.connectSpotify",
                                action: onConnect)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                   tint: theme.surfaceContainer.opacity(GlassTint.surface))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("accounts.empty")
    }
}
