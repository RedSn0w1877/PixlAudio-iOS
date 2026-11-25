import PixlFoundation
import PixlModel
import SwiftUI

/// PixlAudio's mini player (Android `MiniPlayerContentInternal`, redesign 2): 64 pt tall, 8 pt in / 6 pt end; a 48 pt
/// cover in the Cookie9 shape, 12 pt, title (15 pt semibold, −0.2 tracking) over artist (13 pt, 70 %) in
/// `onPrimaryContainer`, 2 pt, then Previous (bare glyph in 44 × 48), a 48 pt `primary` play / pause (16 pt corners
/// playing, a circle paused) and Next. The bar itself is a see-through glass pill tinted with the album's
/// `primaryContainer` (`GlassTint.miniPlayer`), floating above the split-pill nav.
///
/// The transport sits on the glass, so it is fills (`PressScaleButtonStyle`), not glass-on-glass.
///
/// Progress (redesign 2, owner: "a thin line near the bottom", it replaced the ring round play / pause): a 3 pt line
/// near the pill's bottom (`MiniPlayerProgressLine`). Only the line updates while playing, on its own timeline;
/// nothing else here updates per second.
struct MiniPlayerBar: View {
    let song: Song
    let isPlaying: Bool
    var isPreparing = false
    var bottomCornerRadius: CGFloat = Tokens.Shell.navBarCornerRadius
    /// False when the bar is drawn inside the player sheet's card, which supplies the glass (stage 8).
    var drawsGlass = true
    /// Spotify Connect: the device playing the queue ("Playing on <device>" in place of the artist line).
    var remoteDeviceName: String?
    /// The playback clock the progress line samples (nil: no line, as in previews).
    var clock: PlaybackClock?
    /// Whether the line may tick (the bar is on screen: not under the expanded player).
    var showsProgress = true
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
            // Android: a 48 dp cover in the Cookie9 shape.
            ArtworkView(song: song, size: m.artSize, cornerRadius: 0)
                .clipShape(ExpressiveBadgeShape(.cookie9))
                .environment(\.appTheme, theme)
            Spacer().frame(width: m.artSpacing)
            VStack(alignment: .leading, spacing: 0) {
                Text(isPreparing ? "Preparing playback…" : song.title)
                    .pixlFont(.custom(size: 15, weight: .semibold, tracking: -0.2))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .lineLimit(1)
                if let remoteDeviceName, !isPreparing {
                    Label(String(localized: "Playing on \(remoteDeviceName)"), systemImage: "hifispeaker.fill")
                        .labelStyle(MiniPlayerChipLabelStyle())
                        .pixlFont(.custom(size: 13))
                        .foregroundStyle(theme.onPrimaryContainer.opacity(0.7))
                        .lineLimit(1)
                        .accessibilityIdentifier("miniPlayer.remoteDevice")
                } else {
                    Text(isPreparing ? "Loading audio…" : song.displayArtist)
                        .pixlFont(.custom(size: 13))
                        .foregroundStyle(theme.onPrimaryContainer.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the player")
            .accessibilityIdentifier("miniPlayer.title")
            Spacer().frame(width: 2)
            glyphButton("backward.end.fill", label: "Previous", iconSize: m.previousIconSize, action: onPrevious)
            playPauseButton
                .accessibilityIdentifier("miniPlayer.playPause")
            glyphButton("forward.end.fill", label: "Next", iconSize: m.nextIconSize, action: onNext)
        }
        .padding(.leading, m.leadingPadding)
        .padding(.trailing, m.trailingPadding)
        .frame(height: Tokens.Shell.miniPlayerHeight)
        .background(alignment: .bottom) {
            // Redesign 2 (owner: "a thin line near the bottom"): the progress, in place of the ring round play.
            if let clock {
                MiniPlayerProgressLine(clock: clock, durationHintMs: song.duration, songId: song.id,
                                       isPlaying: isPlaying, isActive: showsProgress, color: theme.primary,
                                       track: theme.onPrimaryContainer.opacity(0.16))
            }
        }
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
        .modifier(MiniPlayerGlass(enabled: drawsGlass, shape: shape,
                                  tint: theme.primaryContainer.opacity(GlassTint.miniPlayer)))
        .pixlHaptic(.impact(weight: .light), trigger: isPlaying)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("miniPlayer")
    }

    /// Play / pause (Android `MiniPlayButtonSize`): 48 pt `primary` fill with an `onPrimary` glyph, 16 pt corners
    /// while playing, a circle while paused (the corners spring between the two). A fill on the pill's glass.
    private var playPauseButton: some View {
        let m = Tokens.MiniPlayer.self
        let corner = isPlaying ? m.playCornerPlaying : m.playButtonSize / 2
        return Button(action: onPlayPause) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: m.playIconSize, weight: .semibold))
                .foregroundStyle(theme.onPrimary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: m.playButtonSize, height: m.playButtonSize)
                .background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(theme.primary))
                .animation(PixlMotion.selection, value: isPlaying)
                .contentShape(.rect)
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(isPreparing)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    /// Previous / next: bare `onPrimaryContainer` glyphs in a 44 × 48 pt touch area (Android: no fill, a ripple).
    private func glyphButton(_ symbol: String, label: LocalizedStringKey, iconSize: CGFloat,
                             action: @escaping () -> Void) -> some View {
        let m = Tokens.MiniPlayer.self
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: m.buttonHitWidth, height: m.buttonHitHeight)
                .contentShape(.rect)
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(isPreparing)
        .accessibilityLabel(label)
    }
}

/// The song's progress as a thin line near the mini player's bottom (redesign 2, 2026-11-25; Android
/// `MiniPlayerContentInternal`'s `drawBehind`): 3 pt, round caps, 24 pt in from each end and 5 pt above the pill's
/// bottom edge; track `onPrimaryContainer` 16 %, progress `primary`. Position is never observable state: a
/// `TimelineView` samples the clock only while playing and on screen, as often as the line's end moves about a point
/// (`ProgressRing.tickInterval` over the line's length), and only this view redraws. Paused, it draws once — again
/// after a seek or a new song. The track is static, outside the timeline.
struct MiniPlayerProgressLine: View {
    let clock: PlaybackClock
    let durationHintMs: Int64
    let songId: String
    let isPlaying: Bool
    let isActive: Bool
    let color: Color
    let track: Color

    @Environment(PlaybackStore.self) private var playback

    /// A typical line length (390 pt pill minus 2 × 16 inset, minus 2 × 24): the tick rate is per point of it.
    private static let nominalLength: Double = 310

    var body: some View {
        let m = Tokens.MiniPlayer.self
        // A seek or restart while paused redraws the line once (the timeline doesn't tick then).
        let _ = playback.seekRevision
        let interval = ProgressRing.tickInterval(durationMs: durationHintMs, diameter: Self.nominalLength / .pi)
        ZStack(alignment: .leading) {
            Capsule().fill(track)
            TimelineView(.animation(minimumInterval: interval, paused: !(isPlaying && isActive))) { context in
                let _ = context.date
                let duration = PlaybackProgress.displayDuration(reportedMs: clock.durationMs, hintMs: durationHintMs)
                let fraction = ProgressRing.drawnFraction(
                    PlaybackProgress.fraction(positionMs: clock.positionMs, durationMs: duration), steps: 1000)
                Capsule()
                    .fill(color)
                    .scaleEffect(x: CGFloat(fraction), y: 1, anchor: .leading)
                    .opacity(fraction > 0 ? 1 : 0)
            }
        }
        .frame(height: m.lineHeight)
        .padding(.horizontal, m.lineInset)
        .padding(.bottom, m.lineBottom)
        // A new song starts its line from the left at once (no sweep back from the old position).
        .id(songId)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .longRunning("miniPlayer.progressLine (timeline)", active: isPlaying && isActive)
    }
}

/// The "Playing on <device>" line: a small icon before the text.
private struct MiniPlayerChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title
        }
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
