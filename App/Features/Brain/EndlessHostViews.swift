import PixlLibrary
import SwiftUI

/// The host's chips above Ask Taizo's composer when the chat was opened from "Ask the host" (Android `HostChips`, redesign batch 3: the
/// outlined chips of AndroidAskHost): one row that scrolls sideways, 40 pt chips with 12 pt corners, a 1 pt `outline` border, 14 pt side
/// padding, 14/20 medium, 8 pt apart; clear glass under the outline, all in one `GlassEffectContainer`. Each is answered on the phone with
/// no model call.
struct HostChipsRow: View {
    let enabled: Bool
    let onChip: (HostChip) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(HostChip.allCases, id: \.rawValue) { chip in
                        Button { onChip(chip) } label: {
                            Text(verbatim: EndlessStrings.label(of: chip))
                                .pixlFont(.redesignLabel)
                                .foregroundStyle(enabled ? theme.onSurface : theme.onSurface.opacity(0.38))
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .frame(height: 40)
                                .contentShape(shape)
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .overlay { shape.strokeBorder(theme.outline, lineWidth: 1).allowsHitTesting(false) }
                        .pixlGlass(in: shape, interactive: enabled)
                        .accessibilityIdentifier("host.chip.\(chip.rawValue)")
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollIndicators(.hidden)
        .padding(.top, 6)
    }
}

/// The host's mark (Android `HostBadge`, redesign batch 3): a mic in `onTertiary` on a Flower in `tertiary`, the mic half the badge. A fill
/// (it sits on glass cards and in the sheet's header).
struct HostBadge: View {
    let size: CGFloat
    @Environment(\.appTheme) private var theme

    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(theme.onTertiary)
            .frame(width: size, height: size)
            .background(ExpressiveBadgeShape(.flower).fill(theme.tertiary))
            .accessibilityHidden(true)
    }
}

/// Ask the host's header (Android `HostHeader`, AndroidAskHost): the 52 pt host badge, 12 pt, "Your host" 28/34 heavy (expanded + the
/// compressed accent in `tertiary`, −0.3) over "Endless Listening" 14/20 `onSurfaceVariant`; Back to station as a 48 pt / 16 pt-corner
/// neutral glass square (chevron down).
struct HostSheetHeader: View {
    let onClose: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                HostBadge(size: 52)
                VStack(alignment: .leading, spacing: 0) {
                    TwoToneTitle(wide: HomeRedesignStrings.hostTitleA, accent: HomeRedesignStrings.hostTitleB, size: 28,
                                 tracking: -0.3, accentColor: theme.tertiary, lines: 1)
                    Text(verbatim: EndlessStrings.title)
                        .pixlFont(.custom(size: 14, lineHeight: 20))
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            RedesignHeaderButton(systemImage: "chevron.down",
                                 accessibilityLabel: LocalizedStringKey(HomeRedesignStrings.backToStation), action: onClose)
                .accessibilityIdentifier("host.backToStation")
        }
    }
}

/// The now-playing strip of Ask the host (Android `HostNowPlaying`): 60 pt, 20 pt corners, `surfaceContainer` glass, 10/12 pt padding,
/// 12 pt gaps: the 40 pt art on a Sunny, title 14/20 medium over artist 13/18, "ON AIR" 12/16 bold in `tertiary` with an 8 pt `error` dot;
/// a 3 pt progress line 16 pt in, 4 pt above the bottom. Only the line reads the clock, on a `TimelineView` that runs while playing.
struct HostNowPlayingStrip: View {
    @Environment(PlaybackStore.self) private var playback
    @Environment(\.appTheme) private var theme

    var body: some View {
        if let song = playback.current {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            HStack(spacing: 12) {
                ArtworkView(song: song, size: 40, cornerRadius: 0)
                    .clipShape(ExpressiveBadgeShape(.sunny))
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: song.title)
                        .pixlFont(.redesignLabel)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(verbatim: song.displayArtist)
                        .pixlFont(.redesignRowSubtitle)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                OnAirLabel(color: theme.tertiary)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 60)
            .overlay(alignment: .bottom) {
                StationProgressLine(height: 3, track: theme.surfaceContainerHighest, fill: theme.primary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
            .pixlGlass(in: shape, tint: theme.surfaceContainer.opacity(GlassTint.surface))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("host.nowPlaying")
        }
    }
}

/// "ON AIR" with its red dot (12/16 bold, 0.4 tracking, 6 pt gap).
struct OnAirLabel: View {
    let color: Color
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(theme.error).frame(width: 8, height: 8)
            Text(verbatim: HomeRedesignStrings.onAir)
                .pixlFont(.custom(size: 12, weight: .bold, lineHeight: 16, tracking: 0.4))
                .foregroundStyle(color)
        }
    }
}

/// A thin read-only progress line of the playing song (the host strip): the clock is sampled on a `TimelineView` about twice a second
/// while playing, never while paused; only this line redraws.
struct StationProgressLine: View {
    let height: CGFloat
    let track: Color
    let fill: Color

    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        let _ = playback.seekRevision
        let playing = playback.isPlaying
        ZStack(alignment: .leading) {
            Capsule().fill(track)
            TimelineView(.animation(minimumInterval: 0.5, paused: !playing)) { context in
                let _ = context.date
                let duration = playback.durationMs()
                let fraction = duration > 0 ? min(max(Double(playback.positionMs()) / Double(duration), 0), 1) : 0
                Capsule().fill(fill)
                    .scaleEffect(x: CGFloat(fraction), y: 1, anchor: .leading)
            }
        }
        .frame(height: height)
        .id(playback.currentSongId)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Ask the host with no answer yet (Android `HostEmptyState`): the 72 pt badge, 16 pt, the hint 16/22 centred, 24 pt in.
struct HostEmptyState: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            HostBadge(size: 72)
            Text(verbatim: EndlessStrings.hostSheetHint)
                .pixlFont(.custom(size: 16, lineHeight: 22))
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Ask the host": one small glass capsule that opens Ask Taizo in host mode (queue header, player). It exists only while Endless Listening
/// is the queue's station; for any other queue the caller draws nothing.
struct AskHostButton: View {
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold))
                Text(verbatim: EndlessStrings.askHost).pixlFont(.labelLarge)
            }
            .foregroundStyle(theme.onSurface)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.container), interactive: true)
        .accessibilityIdentifier("endless.askHost")
    }
}

/// A host note as a small card (Endless Listening, Android `HostNoteCard`): the one line the host has about a song, a round surface with a voice
/// mark. It has no close button on purpose: a note is about the songs that come next, so skipping the song is what dismisses it (the note is
/// made again for every song, and a song with no note shows no card). `onAskHost` puts the "Ask the host" button beside the line; nil leaves
/// it out (the queue has the button in its header already).
///
/// The player's card is one glass shape (`glass`); the queue's is a flat tint, because rows scroll and are dragged and a glass layer per
/// row would be work for nothing. No blur of its own, no animation: it is drawn again only when its text changes.
struct HostNoteCard: View {
    let text: String
    var onAskHost: (() -> Void)?
    /// The text and mark colour; the theme's on-surface colour when nil.
    var color: Color?
    var glass = false

    @Environment(\.appTheme) private var theme

    var body: some View {
        let content = color ?? theme.onSecondaryContainer
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityHidden(true)
            Text(verbatim: text)
                .pixlFont(.labelLarge)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onAskHost {
                Button(action: onAskHost) {
                    Text(verbatim: EndlessStrings.askHost)
                        .pixlFont(.labelLarge)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .contentShape(.rect)
                }
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
                .accessibilityIdentifier("endless.askHost")
            }
        }
        .foregroundStyle(content)
        .padding(.leading, 14)
        .padding(.trailing, onAskHost == nil ? 14 : 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(HostCardSurface(glass: glass, tint: content.opacity(0.14), fill: theme.secondaryContainer, shape: shape))
        .accessibilityElement(children: onAskHost == nil ? .combine : .contain)
        .accessibilityIdentifier("endless.hostNote")
    }
}

/// The card's surface: one glass shape in the player, a flat fill in the queue.
private struct HostCardSurface: ViewModifier {
    let glass: Bool
    let tint: Color
    let fill: Color
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if glass {
            content.pixlGlass(in: shape, tint: tint)
        } else {
            content.background(fill, in: shape)
        }
    }
}
