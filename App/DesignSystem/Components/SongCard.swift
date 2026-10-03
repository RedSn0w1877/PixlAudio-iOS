import PixlModel
import SwiftUI

/// PixlAudio's song list item (Android `EnhancedSongListItem`) as a glass card: 50 pt art (10 pt corners), title
/// (`bodyLarge` semibold) over artist (`bodyMedium`, 70 %), the playing indicator, and the ⋮ button. 13×12 padding,
/// 22 pt corners. The current song becomes a capsule with circular art and brighter glass tinted with
/// `primaryContainer` (Android lerps the card to `primaryContainer` and its corners to 50 dp).
///
/// Multi-selection (stage 7a): in selection mode a tap toggles, a long press always toggles; a selected card is
/// tinted `secondaryContainer`, shrinks to 0.98 with a 2.5 pt `primary` border, and its art shows the selection
/// number on a `primary` veil. `showsArtwork: false` and `corners` give the detail screens' grouped rows
/// (Android `showAlbumArt = false` + `customShape`).
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
    /// Android `showAlbumArt`.
    var showsArtwork = true
    /// Android `customShape` (used while not current): top and bottom corner radii.
    var corners: SongCardCorners?
    var isSelectionMode = false
    var isSelected = false
    /// 1-based position in the selection (shown on the art).
    var selectionIndex: Int?
    /// Long press (Android: starts / toggles multi-selection). Nil = no long-press action.
    var onLongPress: (() -> Void)?

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Stage 11: the offline badge of streamed songs (absent in previews / contexts without downloads).
    @Environment(DownloadBadges.self) private var downloadBadges: DownloadBadges?

    var body: some View {
        let t = Tokens.SongCard.self
        let highlighted = isCurrent && !isSelected
        let shape = cardShape(highlighted: isCurrent)
        let content = isSelected ? theme.onSecondaryContainer : (highlighted ? theme.onPrimaryContainer : theme.onSurface)
        let showsIndicator = isCurrent && !isSelectionMode
        let showsTrailing = showsMoreButton && !isSelectionMode
        HStack(spacing: 0) {
            // Art, title, artist, badge and indicator are one VoiceOver element — a button (selected in
            // multi-selection) whose activation does what the tap does; the long press is its Select action. The ⋮
            // button stays its own element.
            HStack(spacing: 0) {
                if showsArtwork {
                    artwork
                    Spacer().frame(width: t.artSpacing)
                } else {
                    Spacer().frame(width: 4)
                }
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
                if !isSelectionMode, let badge = downloadBadges?.kind(for: song) {
                    SongAvailabilityBadge(kind: badge, tint: content)
                }
                if showsIndicator {
                    PlayingIndicator(isPlaying: isPlaying, color: content)
                        .padding(.leading, Tokens.Spacing.s)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { activate() }
            .accessibilityActions {
                if let onLongPress {
                    Button(isSelected ? "Deselect" : "Select", action: onLongPress)
                }
            }
            if showsIndicator || showsTrailing {
                Spacer().frame(width: t.trailingSpacing)
            }
            if showsTrailing {
                Button(action: onMore) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .rotationEffect(.degrees(90))
                        .foregroundStyle(isCurrent ? theme.primaryContainer : theme.onSurface)
                        .frame(width: t.moreButtonSize - t.moreButtonEndPadding,
                               height: t.moreButtonSize - t.moreButtonEndPadding)
                        .background(Circle().fill(isCurrent ? theme.onPrimaryContainer : theme.surfaceContainerHigh.opacity(0.85)))
                        // A 44 pt touch area around the 32 pt circle (a near miss used to play the song instead).
                        .contentShape(Rectangle().inset(by: -6))
                }
                .buttonStyle(PressScaleButtonStyle())
                .padding(.trailing, t.moreButtonEndPadding)
                .accessibilityLabel("More options for \(song.title)")
                .accessibilityIdentifier("songCard.more.\(song.id)")
            }
        }
        .foregroundStyle(content)
        .padding(.horizontal, t.horizontalPadding)
        .padding(.vertical, t.verticalPadding)
        .contentShape(shape)
        .onTapGesture { activate() }
        .modifier(SongCardLongPress(action: onLongPress))
        .pixlGlass(in: shape, tint: tint(highlighted: highlighted), interactive: true)
        .overlay {
            if isSelected {
                shape.stroke(theme.primary, lineWidth: 2.5)
            }
        }
        .scaleEffect(isSelected ? 0.98 : 1)
        .animation(PixlMotion.state, value: isCurrent)
        // Reduce Motion: the selection shrink eases instead of bouncing.
        .animation(reduceMotion ? PixlMotion.state : .spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("songCard.\(song.id)")
    }

    /// A tap: in selection mode it toggles the selection (when the card can be selected), else it plays.
    private func activate() {
        if isSelectionMode, let onLongPress { onLongPress() } else { onTap() }
    }

    @ViewBuilder
    private var artwork: some View {
        let t = Tokens.SongCard.self
        let radius = isCurrent ? t.artSize / 2 : t.artCornerRadius
        ArtworkView(song: song, size: t.artSize, cornerRadius: radius)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(theme.primary.opacity(0.7))
                        .overlay {
                            if let selectionIndex {
                                Text("\(selectionIndex)")
                                    .pixlFont(.titleMedium, weight: .bold)
                                    .foregroundStyle(theme.onPrimary)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(theme.onPrimary)
                            }
                        }
                        .transition(.opacity)
                }
            }
    }

    private func cardShape(highlighted: Bool) -> UnevenRoundedRectangle {
        let t = Tokens.SongCard.self
        if highlighted {
            let pill = ((showsArtwork ? t.artSize : 44) + 2 * t.verticalPadding) / 2
            return UnevenRoundedRectangle(topLeadingRadius: pill, bottomLeadingRadius: pill, bottomTrailingRadius: pill,
                                          topTrailingRadius: pill, style: .continuous)
        }
        let top = corners?.top ?? t.cornerRadius
        let bottom = corners?.bottom ?? t.cornerRadius
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                                      topTrailingRadius: top, style: .continuous)
    }

    private func tint(highlighted: Bool) -> Color {
        if isSelected { return theme.secondaryContainer.opacity(GlassTint.container) }
        if highlighted { return theme.primaryContainer.opacity(GlassTint.container + 0.15) }
        return theme.surfaceContainerLow.opacity(GlassTint.surface)
    }
}

/// Top / bottom corner radii of a grouped song row (Android `RoundedCornerShape(top…, bottom…)`).
nonisolated struct SongCardCorners: Hashable, Sendable {
    var top: CGFloat
    var bottom: CGFloat

    /// Android's grouped-row rule: 16 pt outer corners, 4 pt where rows meet.
    static func grouped(index: Int, count: Int) -> SongCardCorners {
        if count <= 1 { return SongCardCorners(top: 16, bottom: 16) }
        if index == 0 { return SongCardCorners(top: 16, bottom: 4) }
        if index == count - 1 { return SongCardCorners(top: 4, bottom: 16) }
        return SongCardCorners(top: 4, bottom: 4)
    }
}

/// Attaches the long press only when the card has one (a plain card keeps scrolling gestures untouched).
private struct SongCardLongPress: ViewModifier {
    let action: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let action {
            content.onLongPressGesture(minimumDuration: 0.45) { action() }
        } else {
            content
        }
    }
}
