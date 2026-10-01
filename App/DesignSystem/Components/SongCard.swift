import PixlModel
import SwiftUI

/// PixlAudio's song list item (Android `EnhancedSongListItem`) as a glass card: 50 pt art (10 pt corners), title
/// (`bodyLarge` semibold) over artist (`bodyMedium`, 70 %), the playing indicator, and the ⋮ button. 13×12 padding,
/// 22 pt corners. The current song becomes a capsule with circular art and brighter glass tinted with
/// `primaryContainer` (Android lerps the card to `primaryContainer` and its corners to 50 dp).
///
/// One glass layer per row (no container), so it stays cheap in lazy lists. The ⋮ button sits on the glass, so it
/// is a plain fill with `PressScaleButtonStyle`, not a second glass layer.
struct SongCard: View {
    let song: Song
    var isCurrent = false
    var isPlaying = false
    var showsMoreButton = true
    let onTap: () -> Void
    var onMore: () -> Void = {}

    @Environment(\.appTheme) private var theme

    var body: some View {
        let t = Tokens.SongCard.self
        let cornerRadius = isCurrent ? (t.artSize + 2 * t.verticalPadding) / 2 : t.cornerRadius
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let content = isCurrent ? theme.onPrimaryContainer : theme.onSurface
        HStack(spacing: 0) {
            ArtworkView(song: song, size: t.artSize, cornerRadius: isCurrent ? t.artSize / 2 : t.artCornerRadius)
            Spacer().frame(width: t.artSpacing)
            VStack(alignment: .leading, spacing: t.titleArtistSpacing) {
                Text(song.title)
                    .pixlFont(.bodyLarge, weight: .semibold)
                    .lineLimit(1)
                Text(song.displayArtist)
                    .pixlFont(.bodyMedium)
                    .opacity(0.7)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isCurrent {
                PlayingIndicator(isPlaying: isPlaying, color: content)
                    .padding(.leading, Tokens.Spacing.s)
            }
            if isCurrent || showsMoreButton {
                Spacer().frame(width: t.trailingSpacing)
            }
            if showsMoreButton {
                Button(action: onMore) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .rotationEffect(.degrees(90))
                        .foregroundStyle(isCurrent ? theme.primaryContainer : theme.onSurface)
                        .frame(width: t.moreButtonSize - t.moreButtonEndPadding,
                               height: t.moreButtonSize - t.moreButtonEndPadding)
                        .background(Circle().fill(isCurrent ? theme.onPrimaryContainer : theme.surfaceContainerHigh.opacity(0.85)))
                        .contentShape(.circle)
                }
                .buttonStyle(PressScaleButtonStyle())
                .padding(.trailing, t.moreButtonEndPadding)
                .accessibilityLabel("More options for \(song.title)")
            }
        }
        .foregroundStyle(content)
        .padding(.horizontal, t.horizontalPadding)
        .padding(.vertical, t.verticalPadding)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .pixlGlass(in: shape,
                   tint: isCurrent ? theme.primaryContainer.opacity(GlassTint.container + 0.15)
                                   : theme.surfaceContainerLow.opacity(GlassTint.surface),
                   interactive: true)
        .animation(PixlMotion.state, value: isCurrent)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("songCard.\(song.id)")
    }
}
