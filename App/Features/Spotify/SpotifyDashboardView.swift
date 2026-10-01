import AuthenticationServices
import PixlNet
import SwiftUI

/// Spotify dashboard (Android `presentation/spotify/dashboard/SpotifyDashboardScreen`): the account card (sign in /
/// sync / find audio / test playback / disconnect), the YouTube account card, the browse button, the reconnect and
/// last-error notices, the playback test report and the imported playlists — in Android's order and geometry
/// (16 pt side padding, 12 pt gaps, 24 pt account cards, 20 pt notice cards and rows). Material cards are glass tinted
/// with their container colour; buttons on a card are fills.
///
/// Dropped from Android: the "Deep probe (debug)" tool (a temporary googlevideo 403 hunt; stage 11's diagnostics
/// cover the stream chain). iOS adds a client-ID link under the sign-in button, since a sideloaded build may ship
/// without one (Android reads it from local.properties only).
struct SpotifyDashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(AccountsStore.self) private var accounts
    @Environment(PlaybackStore.self) private var playback
    @Environment(\.appTheme) private var theme
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var toast: String?
    @State private var dismissedPlaybackError: String?
    @State private var isEditingClientId = false
    @State private var clientIdDraft = ""

    private var spotify: SpotifyService { env.spotify }

    var body: some View {
        SpotifyScaffold(title: "Spotify", screenID: "spotifyDashboard") {
            accountCard

            youTubeCard

            if spotify.isLoggedIn {
                browseButton
            }

            if spotify.playlistAccessDenied {
                reconnectCard
            }

            if let error = playback.lastError, error != dismissedPlaybackError, playback.current?.spotifyId != nil {
                playbackErrorCard(error)
            }

            if spotify.isTesting || spotify.testReport != nil {
                SpotifyPlaybackTestCard(isRunning: spotify.isTesting, report: spotify.testReport,
                                        onDismiss: spotify.dismissTestReport)
            }

            if !spotify.playlists.isEmpty {
                Text("Imported playlists")
                    .pixlFont(.titleMedium, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .padding(.leading, 4)
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(spotify.playlists, id: \.id) { playlist in
                    SpotifyPlaylistRowView(playlist: playlist)
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
        .alert("Spotify client ID", isPresented: $isEditingClientId) {
            TextField("Client ID", text: $clientIdDraft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Save") { spotify.setClientIdOverride(clientIdDraft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste the client ID of your Spotify app. Its redirect URI must be pixlaudio://spotify-callback. Leave it empty to use the one built into the app.")
        }
    }

    // MARK: Account card (Android `AccountCard`)

    private var accountCard: some View {
        SpotifyCard(cornerRadius: 24, tint: theme.surfaceContainer) {
            if !spotify.isLoggedIn {
                signedOutContent
            } else {
                signedInContent
            }
        }
        .accessibilityIdentifier("spotify.accountCard")
    }

    @ViewBuilder
    private var signedOutContent: some View {
        Text("Not connected")
            .pixlFont(.titleLarge, weight: .bold)
            .foregroundStyle(theme.onSurface)
        Text("Sign in to bring your liked songs and playlists into PixlAudio.")
            .pixlFont(.bodyMedium)
            .foregroundStyle(theme.onSurfaceVariant)
        SpotifyFilledButton(title: spotify.isSigningIn ? "Connecting to Spotify…" : "Sign in with Spotify",
                            systemImage: "music.note", fill: SpotifyBrand.green, foreground: .black,
                            isEnabled: !spotify.isSigningIn, identifier: "spotify.signIn") {
            Task { await spotify.signIn(authenticate: authenticate) }
        }
        Button {
            clientIdDraft = spotify.clientIdOverride
            isEditingClientId = true
        } label: {
            Text(spotify.hasClientId ? "Use your own client ID" : "No client ID in this build — set one")
                .pixlFont(.labelMedium)
                .foregroundStyle(spotify.hasClientId ? theme.primary : theme.error)
                .padding(.vertical, 4)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityIdentifier("spotify.clientId")
    }

    @ViewBuilder
    private var signedInContent: some View {
        Text(spotify.accountName ?? "Spotify account")
            .pixlFont(.titleLarge, weight: .bold)
            .foregroundStyle(theme.onSurface)
        if let email = spotify.accountEmail {
            Text(email)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
        }
        Text("\(spotify.totalSongs) tracks across \(spotify.playlists.count) playlists")
            .pixlFont(.bodyMedium)
            .foregroundStyle(theme.onSurfaceVariant)

        let tracked = spotify.matchedCount + spotify.pendingMatchCount + spotify.unmatchedCount
        if tracked > 0 {
            Text("\(spotify.matchedCount) ready to play · \(spotify.pendingMatchCount) still looking · \(spotify.unmatchedCount) no match found")
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
            SpotifyLinearProgress(fraction: Double(spotify.matchedCount) / Double(tracked))
        }

        if spotify.isSyncing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(theme.primary)
                Text(spotify.syncStatus.map { "Importing \($0)…" } ?? "Importing…")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
            }
        }

        HStack(spacing: 8) {
            SpotifyFilledButton(title: "Sync", systemImage: "arrow.triangle.2.circlepath", fill: theme.primary,
                                foreground: theme.onPrimary, iconSpacing: 6, isEnabled: !spotify.isSyncing,
                                identifier: "spotify.sync") { spotify.syncNow() }
            SpotifyOutlinedButton(title: "Find audio", systemImage: "magnifyingglass", isEnabled: spotify.totalSongs > 0,
                                  identifier: "spotify.findAudio") { spotify.startMatching(retryFailed: true) }
        }

        SpotifyOutlinedButton(title: "Test playback", systemImage: "ladybug", fullWidth: true, isEnabled: !spotify.isTesting,
                              identifier: "spotify.testPlayback") { spotify.runPlaybackTest() }

        SpotifyOutlinedButton(title: "Disconnect Spotify", systemImage: "rectangle.portrait.and.arrow.right", fullWidth: true,
                              isEnabled: !spotify.isLoggingOut, isBusy: spotify.isLoggingOut,
                              identifier: "spotify.disconnect") { Task { await spotify.logout() } }
    }

    // MARK: YouTube card (Android `YouTubeAccountCard`; the sign-in itself is stage 11's screen)

    private var youTubeSignedIn: Bool {
        if case .signedIn = accounts.youtube { return true }
        return false
    }

    private var youTubeCard: some View {
        SpotifyCard(cornerRadius: 24, tint: theme.surfaceContainer) {
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SpotifyBrand.youTubeRed)
                Text(youTubeSignedIn ? "YouTube connected" : "YouTube account")
                    .pixlFont(.titleMedium, weight: .bold)
                    .foregroundStyle(theme.onSurface)
            }
            Text(youTubeSignedIn
                 ? "Signed in. Playback requests now go out as your account, which gets past YouTube's \"not a bot\" checks."
                 : "Sign in with a Google account to let songs play reliably. You'll enter a short code on Google's own page — the app never sees your password.")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
            if youTubeSignedIn {
                SpotifyOutlinedButton(title: "Disconnect YouTube", fullWidth: true, identifier: "spotify.youtubeDisconnect") {
                    router.push(.youTubeLogin)
                }
            } else {
                SpotifyFilledButton(title: "Connect YouTube", systemImage: "play.circle.fill", fill: SpotifyBrand.youTubeRed,
                                    foreground: .white, fullWidth: true, identifier: "spotify.youtubeConnect") {
                    router.push(.youTubeLogin)
                }
            }
        }
    }

    // MARK: Browse button (Android full-width green `Button`; standalone, so glass)

    private var browseButton: some View {
        Button { router.push(.spotifyBrowse(query: "")) } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .semibold))
                Text("Browse artists, albums & top songs")
                    .pixlFont(.labelLarge)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, 24)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: SpotifyBrand.green.opacity(GlassTint.prominent), interactive: true)
        .accessibilityIdentifier("spotify.browse")
    }

    // MARK: Notices

    private var reconnectCard: some View {
        SpotifyCard(cornerRadius: 20, tint: theme.errorContainer, strength: GlassTint.container, padding: 16, spacing: 8) {
            Text("Reconnect Spotify to import playlists")
                .pixlFont(.titleMedium, weight: .bold)
                .foregroundStyle(theme.onErrorContainer)
            Text("Spotify is refusing to hand over the songs inside your playlists (HTTP 403). Your login is from before the app asked for that permission, so the saved token never got it — which is why every playlist imports empty while Liked Songs works fine.\n\nSigning in again fixes it. This keeps your library and the audio already matched — it only replaces the login.")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onErrorContainer)
            SpotifyFilledButton(title: "Sign in to Spotify again", fill: theme.error, foreground: theme.onError,
                                identifier: "spotify.reconnect") {
                Task { await spotify.reconnect(authenticate: authenticate) }
            }
        }
    }

    /// Android `PlaybackErrorCard`: the player's last failure while a Spotify song was current.
    private func playbackErrorCard(_ error: String) -> some View {
        SpotifyCard(cornerRadius: 20, tint: theme.errorContainer, strength: GlassTint.container, padding: 16, spacing: 8) {
            Text("Last playback error")
                .pixlFont(.titleMedium, weight: .bold)
                .foregroundStyle(theme.onErrorContainer)
            if let title = playback.current?.title {
                Text(title)
                    .pixlFont(.bodyMedium, weight: .semibold)
                    .foregroundStyle(theme.onErrorContainer)
            }
            Text(error)
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onErrorContainer)
                .textSelection(.enabled)
            SpotifyOutlinedButton(title: "Clear", stroke: theme.onErrorContainer.opacity(0.5), foreground: theme.onErrorContainer) {
                dismissedPlaybackError = error
            }
        }
    }

    // MARK: Sign-in

    /// ASWebAuthenticationSession through SwiftUI's environment: returns the `pixlaudio://spotify-callback` URL.
    private func authenticate(_ url: URL) async throws -> URL {
        try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: SpotifyAuth.redirectScheme,
                                                        preferredBrowserSession: .shared)
    }
}

/// Android `DiagnosticsCard`: each step with a pass / fail mark, then the verdict.
struct SpotifyPlaybackTestCard: View {
    let isRunning: Bool
    let report: SpotifyPlaybackTestReport?
    let onDismiss: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        SpotifyCard(cornerRadius: 20, tint: theme.surfaceContainerHigh, padding: 16, spacing: 10) {
            Text("Playback test")
                .pixlFont(.titleMedium, weight: .bold)
                .foregroundStyle(theme.onSurface)
            if isRunning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(theme.primary)
                    Text("Trying one song end to end…")
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurface)
                }
            } else if let report {
                ForEach(report.steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: step.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(step.ok ? SpotifyBrand.green : theme.error)
                            .frame(width: 18, height: 18)
                            .accessibilityLabel(step.ok ? "Passed" : "Failed")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(step.title)
                                .pixlFont(.bodyMedium, weight: .semibold)
                                .foregroundStyle(theme.onSurface)
                            Text(step.detail)
                                .pixlFont(.bodySmall)
                                .foregroundStyle(theme.onSurfaceVariant)
                                .textSelection(.enabled)
                        }
                    }
                }
                Text(report.succeeded ? "Everything works — this song is playable." : "The first red line above is where it breaks.")
                    .pixlFont(.bodyMedium, weight: .semibold)
                    .foregroundStyle(theme.onSurface)
                SpotifyOutlinedButton(title: "Close", identifier: "spotify.testClose", action: onDismiss)
            } else {
                Text("The test could not run.")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
            }
        }
        .accessibilityIdentifier("spotify.testReport")
    }
}

/// Android `PlaylistRow`: 52 pt cover (12 pt corners), name (`titleSmall`) and track count, on a 20 pt card.
struct SpotifyPlaylistRowView: View {
    let playlist: SpotifyPlaylistRow
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(source: ArtworkSource(uriString: playlist.coverUrl), size: 52, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .pixlFont(.titleSmall)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text("\(playlist.songCount) tracks")
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(GlassTint.surface))
        .accessibilityElement(children: .combine)
    }
}
