import PixlModel
import SwiftUI

/// PixlAudio's mini player (Android `MiniPlayerContentInternal`): 64 pt tall, 44 pt circular art, title
/// (15 pt semibold, −0.2 tracking) over artist (13 pt, 70 %) in `onPrimaryContainer`, then previous / play-pause /
/// next as 36 pt circles with 22 pt icons — previous and next `onPrimary` with a `primary` icon, play `primary` with
/// an `onPrimary` icon. The bar itself is glass tinted with the album's `primaryContainer`; its top corners are
/// 32 pt and its bottom corners 10 pt where it sits on the bottom bar (32 pt when the bar is hidden).
///
/// The transport circles sit on the glass, so they are fills (`PressScaleButtonStyle`), not glass-on-glass.
/// Nothing here updates per second.
struct MiniPlayerBar: View {
    let song: Song
    let isPlaying: Bool
    var isPreparing = false
    var bottomCornerRadius: CGFloat = Tokens.Shell.joinCornerRadius
    /// False when the bar is drawn inside the player sheet's card, which supplies the glass (stage 8).
    var drawsGlass = true
    let onOpen: () -> Void
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void

    @Environment(\.playerTheme) private var theme

    var body: some View {
        let m = Tokens.MiniPlayer.self
        let shape = UnevenRoundedRectangle(topLeadingRadius: Tokens.Shell.navBarCornerRadius,
                                           bottomLeadingRadius: bottomCornerRadius,
                                           bottomTrailingRadius: bottomCornerRadius,
                                           topTrailingRadius: Tokens.Shell.navBarCornerRadius, style: .continuous)
        HStack(spacing: 0) {
            ArtworkView(song: song, size: m.artSize, cornerRadius: m.artSize / 2)
                .environment(\.appTheme, theme)
            Spacer().frame(width: m.artSpacing)
            VStack(alignment: .leading, spacing: 0) {
                Text(isPreparing ? "Preparing playback…" : song.title)
                    .pixlFont(.custom(size: 15, weight: .semibold, tracking: -0.2))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .lineLimit(1)
                Text(isPreparing ? "Loading audio…" : song.displayArtist)
                    .pixlFont(.custom(size: 13))
                    .foregroundStyle(theme.onPrimaryContainer.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the player")
            .accessibilityIdentifier("miniPlayer.title")
            Spacer().frame(width: m.buttonSpacing)
            transportButton("backward.end.fill", label: "Previous", fill: theme.onPrimary, icon: theme.primary,
                            action: onPrevious)
            Spacer().frame(width: m.buttonSpacing)
            transportButton(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play",
                            fill: theme.primary, icon: theme.onPrimary, action: onPlayPause)
                .accessibilityIdentifier("miniPlayer.playPause")
            Spacer().frame(width: m.buttonSpacing)
            transportButton("forward.end.fill", label: "Next", fill: theme.onPrimary, icon: theme.primary,
                            action: onNext)
        }
        .padding(.leading, m.leadingPadding)
        .padding(.trailing, m.trailingPadding)
        .frame(height: Tokens.Shell.miniPlayerHeight)
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
        .modifier(MiniPlayerGlass(enabled: drawsGlass, shape: shape,
                                  tint: theme.primaryContainer.opacity(GlassTint.container)))
        .sensoryFeedback(.impact(weight: .light), trigger: isPlaying)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("miniPlayer")
    }

    private func transportButton(_ symbol: String, label: LocalizedStringKey, fill: Color, icon: Color,
                                 action: @escaping () -> Void) -> some View {
        let m = Tokens.MiniPlayer.self
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: m.buttonIconSize * 0.8, weight: .semibold))
                .foregroundStyle(icon)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: m.buttonSize, height: m.buttonSize)
                .background(Circle().fill(fill))
                .contentShape(.circle)
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(isPreparing)
        .accessibilityLabel(label)
    }
}

/// The mini player's own glass, skipped when the player sheet's card draws it.
private struct MiniPlayerGlass: ViewModifier {
    let enabled: Bool
    let shape: UnevenRoundedRectangle
    let tint: Color

    func body(content: Content) -> some View {
        if enabled {
            content.pixlGlass(in: shape, tint: tint, interactive: true)
        } else {
            content
        }
    }
}
