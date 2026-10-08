import SwiftUI

/// Shuffle · repeat · favourite (Android `BottomToggleRow` + `ToggleSegmentButton`): three equal segments 6 pt apart.
/// A segment is off as clear glass with an `onSurface` icon; on, its glass fills with `primaryFixed` (shuffle),
/// `secondaryFixed` (repeat) or `tertiaryFixed` (favourite) and rounds into a full pill, as Android's segment does.
///
/// Liquid (Hoa, 2026-10-03: "the fab like shuffle repeat etc buttons navbar be liquidified"): each segment is its
/// own interactive Liquid Glass shape in one `GlassEffectContainer`, instead of opaque fills on a cream capsule, so
/// the player's background refracts through them, a press swells and lights the glass, and a segment's fill and
/// shape morph on the glass when it turns on or off.
struct PlayerToggleRow: View {
    let isShuffleOn: Bool
    let repeatMode: RepeatMode
    let isFavorite: Bool
    let onShuffle: () -> Void
    let onRepeat: () -> Void
    let onFavorite: () -> Void

    @Environment(\.playerTheme) private var theme

    private static let height: CGFloat = 58

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                segment(active: isShuffleOn, systemImage: "shuffle", label: "Shuffle",
                        fill: theme.primaryFixed, icon: theme.onPrimaryFixed, action: onShuffle)
                    .accessibilityIdentifier("player.shuffle")
                segment(active: repeatMode != .off, systemImage: repeatMode == .one ? "repeat.1" : "repeat",
                        label: repeatLabel, fill: theme.secondaryFixed, icon: theme.onSecondaryFixed, action: onRepeat)
                    .accessibilityIdentifier("player.repeat")
                segment(active: isFavorite, systemImage: isFavorite ? "heart.fill" : "heart",
                        label: isFavorite ? "Remove from favorites" : "Add to favorites",
                        fill: theme.tertiaryFixed, icon: theme.onTertiaryFixed, action: onFavorite)
                    .accessibilityIdentifier("player.favorite")
            }
        }
        .frame(height: Self.height)
    }

    private var repeatLabel: LocalizedStringKey {
        switch repeatMode {
        case .off: "Repeat off"
        case .all: "Repeat all"
        case .one: "Repeat one"
        }
    }

    private func segment(active: Bool, systemImage: String, label: LocalizedStringKey, fill: Color, icon: Color,
                         action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: active ? Self.height / 2 : 18, style: .continuous)
        return Button {
            // TEMPORARY diagnosis (s21-main-health): does the action run in the UI tests?
            if LaunchConfiguration.current.isUITest { print("[diag-app] segment action \(systemImage) active=\(active)") }
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(active ? icon : theme.onSurface)
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassEffect(Glass.clear
                        .tint(active ? fill.opacity(GlassTint.prominent) : theme.onPrimary.opacity(GlassTint.playerChrome))
                        .interactive(),
                     in: shape)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: active)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
