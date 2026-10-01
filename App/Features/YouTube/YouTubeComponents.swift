import SwiftUI

/// Shared pieces of the YouTube screens.
nonisolated enum YouTubeMetrics {
    /// Android `Color(0xFFFF0000)` (the YouTube card icon and "Connect YouTube" button).
    static let youTubeRed = Color(red: 1, green: 0, blue: 0)
    /// Android `SpotifyBrandGreen` (the playback test's passed icon).
    static let passedGreen = Color(red: 0x1D / 255, green: 0xB9 / 255, blue: 0x54 / 255)
    /// Dashboard `LazyColumn` padding / spacing.
    static let screenPadding: CGFloat = 16
    static let itemSpacing: CGFloat = 12
}

/// Android's small `TopAppBar` (back arrow + `titleLarge` title) with the back button as a glass circle. Keeps the
/// edge back-swipe (the system navigation bar is hidden).
struct YouTubeTopBar: View {
    let title: String
    var onBack: (() -> Void)?

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 12) {
            GlassCircleButton(systemImage: "arrow.left", accessibilityLabel: "Back",
                              tint: theme.surfaceContainerLow.opacity(GlassTint.surface)) {
                if let onBack { onBack() } else { dismiss() }
            }
            .accessibilityIdentifier("youtube.back")
            Text(title)
                .pixlFont(.titleLarge)
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(height: Tokens.TopBar.height)
        .background(SettingsBackSwipeEnabler().frame(width: 0, height: 0))
    }
}

/// A full-width capsule action (Android `Button` / `OutlinedButton` with a leading icon): tinted glass for a filled
/// button, plain glass for an outlined one. On a glass card (`onGlass`) it is a fill with press feedback instead,
/// so there is no glass on glass.
struct YouTubeWideButton: View {
    let title: String
    var systemImage: String?
    var tint: Color?
    var foreground: Color?
    var enabled = true
    var onGlass = false
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        if onGlass {
            label
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
                .background(tint ?? theme.onSurface.opacity(0.08), in: Capsule())
        } else {
            label
                .buttonStyle(.plain)
                .pixlGlass(in: Capsule(), tint: tint, interactive: enabled)
        }
    }

    private var label: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                Text(title)
                    .pixlFont(.labelLarge)
                    .lineLimit(1)
            }
            .foregroundStyle(foreground ?? theme.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.capsule)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
