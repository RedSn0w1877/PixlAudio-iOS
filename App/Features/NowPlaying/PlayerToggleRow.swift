import SwiftUI

/// Shuffle · repeat · favourite (Android `BottomToggleRow` + `ToggleSegmentButton`): a 66 pt capsule
/// (`surfaceContainerLowest` at 70 %) with 6 pt padding holding three equal segments 6 pt apart. A segment is
/// `onSurface` at 7 % with an `onSurface` icon when off; on, it fills with `primaryFixed` (shuffle),
/// `secondaryFixed` (repeat) or `tertiaryFixed` (favourite) and rounds from 8 pt corners to a full pill.
///
/// The capsule is glass; the segments sitting on it are fills with press feedback (no glass on glass).
struct PlayerToggleRow: View {
    let isShuffleOn: Bool
    let repeatMode: RepeatMode
    let isFavorite: Bool
    let onShuffle: () -> Void
    let onRepeat: () -> Void
    let onFavorite: () -> Void

    @Environment(\.playerTheme) private var theme

    var body: some View {
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
        .padding(6)
        .frame(height: 66)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerLowest.opacity(0.7 * GlassTint.container))
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
        let shape = RoundedRectangle(cornerRadius: active ? 27 : 8, style: .continuous)
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(active ? icon : theme.onSurface)
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(shape.fill(active ? fill : theme.onSurface.opacity(0.07)))
                .contentShape(shape)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.94))
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: active)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
