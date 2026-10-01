import SwiftUI

/// The karaoke lyrics view (Android `presentation/lyrics/**`) — placeholder until stage 9. Always dark.
struct LyricsView: View {
    @Environment(Router.self) private var router

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            Text("Lyrics arrive in stage 9")
                .pixlFont(.titleLarge, weight: .bold)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            GlassCircleButton(systemImage: "chevron.down", accessibilityLabel: "Close lyrics", foreground: .white) {
                router.dismissCover()
            }
            .padding(Tokens.Spacing.l)
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screen.lyrics")
    }
}

/// Lyrics options (Android `LyricsMoreBottomSheet`: source, offset, import/export) — placeholder until stage 9.
struct LyricsOptionsSheet: View {
    let songId: String

    var body: some View {
        SheetScaffold("Lyrics") {
            Text("Lyrics options arrive in stage 9")
                .pixlFont(.bodyMedium)
                .padding(.horizontal, Tokens.Spacing.xxl)
        }
        .accessibilityIdentifier("screen.lyricsOptions")
    }
}
