import SwiftUI

/// The full player's bottom split pills (new UI, owner decision 2026-11-16; mockup `iOSPlayer`): the bottom bar's
/// big-capsule + small-circle pair, here with
/// - the big capsule: Shuffle · Repeat · Like, three equal segments 4 pt apart inside a 5 pt inset. A segment that is
///   on sits in a tonal capsule — `primaryFixed` (shuffle), `secondaryFixed` (repeat), `tertiaryFixed` (like), the
///   colours of the toggle row it replaces (`PlayerToggleRow`, which the lyrics More sheet keeps) — and its symbol takes
///   the matching "on" colour; repeat-one shows `repeat.1`.
/// - the small circle: Lyrics, opening the lyrics screen as the old lyrics circle did.
///
/// Both shapes are clear glass (the player sits over media) tinted with the player's chrome breath, in one
/// `GlassEffectContainer` whose spacing is below their 10 pt gap. The tonal capsules are fills on the big capsule's
/// glass, not glass on glass. Only this view redraws for a shuffle / repeat / favourite change.
struct PlayerActionPills: View {
    let isShuffleOn: Bool
    let repeatMode: RepeatMode
    let isFavorite: Bool
    let onShuffle: () -> Void
    let onRepeat: () -> Void
    let onFavorite: () -> Void
    let onLyrics: () -> Void

    @Environment(\.playerTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = Tokens.PlayerPills.self
        let chrome = theme.onPrimary.opacity(GlassTint.playerChrome)
        GlassEffectContainer(spacing: Tokens.Shell.navPillSpacing * 0.4) {
            HStack(spacing: Tokens.Shell.navPillSpacing) {
                HStack(spacing: p.segmentSpacing) {
                    segment(active: isShuffleOn, systemImage: "shuffle", label: "Shuffle",
                            fill: theme.primaryFixed, icon: theme.onPrimaryFixed, action: onShuffle)
                        .accessibilityIdentifier("player.shuffle")
                    segment(active: repeatMode != .off, systemImage: repeatMode == .one ? "repeat.1" : "repeat",
                            label: repeatLabel, fill: theme.secondaryFixed, icon: theme.onSecondaryFixed,
                            action: onRepeat)
                        .accessibilityIdentifier("player.repeat")
                    segment(active: isFavorite, systemImage: isFavorite ? "heart.fill" : "heart",
                            label: isFavorite ? "Remove from favorites" : "Add to favorites",
                            fill: theme.tertiaryFixed, icon: theme.onTertiaryFixed, action: onFavorite)
                        .accessibilityIdentifier("player.favorite")
                }
                .padding(p.padding)
                .frame(maxWidth: .infinity)
                .frame(height: p.height)
                .playerGlass(in: Capsule(), tint: chrome)

                Button(action: onLyrics) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: p.iconSize, weight: .semibold))
                        .foregroundStyle(theme.primary)
                        .frame(width: p.height, height: p.height)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .playerGlass(in: Circle(), tint: chrome)
                .accessibilityLabel("Lyrics")
                .accessibilityIdentifier("player.lyrics")
            }
        }
        .frame(height: p.height)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : PixlMotion.selection, value: isShuffleOn)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : PixlMotion.selection, value: repeatMode)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : PixlMotion.selection, value: isFavorite)
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
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: Tokens.PlayerPills.iconSize, weight: .semibold))
                .foregroundStyle(active ? icon : theme.onSurface)
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    // Always mounted: turning on fades and swells the capsule in (no view inserted on a tap).
                    Capsule()
                        .fill(fill.opacity(active ? GlassTint.prominent : 0))
                        .scaleEffect(active || reduceMotion ? 1 : 0.86)
                }
                .contentShape(.capsule)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.94))
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
