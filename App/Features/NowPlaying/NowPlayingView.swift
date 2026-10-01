import SwiftUI

/// The expanded player (Android `UnifiedPlayerSheetV2` / `FullPlayerContent`) — placeholder until stage 8.
/// Opened full screen from the mini player; album-art themed via `playerTheme`.
struct NowPlayingView: View {
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.playerTheme) private var theme

    var body: some View {
        VStack(spacing: Tokens.Spacing.xxl) {
            HStack {
                GlassCircleButton(systemImage: "chevron.down", accessibilityLabel: "Close player",
                                  foreground: theme.onPrimaryContainer) {
                    router.dismissCover()
                }
                Spacer()
            }
            .padding(.horizontal, Tokens.Spacing.l)
            Spacer()
            ArtworkView(song: playback.current, size: 280, cornerRadius: Tokens.Radius.mixCard)
                .environment(\.appTheme, theme)
            VStack(spacing: Tokens.Spacing.xs) {
                Text(playback.current?.title ?? "Nothing playing")
                    .pixlFont(.headlineSmall, weight: .bold)
                Text(playback.current?.displayArtist ?? "")
                    .pixlFont(.bodyLarge)
                    .opacity(0.75)
            }
            .foregroundStyle(theme.onPrimaryContainer)
            Text("Player arrives in stage 8")
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onPrimaryContainer.opacity(0.6))
            Spacer()
        }
        .padding(.vertical, Tokens.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryContainer.ignoresSafeArea())
        .accessibilityIdentifier("screen.nowPlaying")
    }
}
