import PixlFoundation
import PixlModel
import SwiftUI

/// PixlAudio's mini player (Android `MiniPlayerContentInternal`): 64 pt tall, 44 pt circular art, title
/// (15 pt semibold, −0.2 tracking) over artist (13 pt, 70 %) in `onPrimaryContainer`, then previous / play-pause /
/// next as 36 pt circles with 22 pt icons — previous and next `onPrimary` with a `primary` icon, play `primary` with
/// an `onPrimary` icon. The bar itself is glass tinted with the album's `primaryContainer`, a 32 pt-cornered capsule
/// floating above the tab bar.
///
/// The transport circles sit on the glass, so they are fills (`PressScaleButtonStyle`), not glass-on-glass.
///
/// New UI (2026-11-16): the bar floats above the split-pill nav as its own see-through pill (`GlassTint.miniPlayer`),
/// and the song's progress is a thin ring round the play / pause circle (`MiniPlayerProgressRing`), not a line on the
/// pill's edge. Only the ring updates while playing, on its own timeline; nothing else here updates per second.
struct MiniPlayerBar: View {
    let song: Song
    let isPlaying: Bool
    var isPreparing = false
    var bottomCornerRadius: CGFloat = Tokens.Shell.navBarCornerRadius
    /// False when the bar is drawn inside the player sheet's card, which supplies the glass (stage 8).
    var drawsGlass = true
    /// Spotify Connect: the device playing the queue ("Playing on <device>" in place of the artist line).
    var remoteDeviceName: String?
    /// The playback clock the progress ring samples (nil: no ring, as in previews).
    var clock: PlaybackClock?
    /// Whether the ring may tick (the bar is on screen: not under the expanded player).
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
            ArtworkView(song: song, size: m.artSize, cornerRadius: m.artSize / 2)
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
                        .pixlFont(.custom(size: 13, weight: .semibold))
                        .foregroundStyle(theme.onPrimaryContainer.opacity(0.85))
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
            // The circles keep Android's 8 pt gaps and 12 pt end padding; each button's 44 pt touch area takes half
            // of the gap on either side (a tap between two circles used to open the full player).
            Spacer().frame(width: m.buttonSpacing - Self.hitInset)
            transportButton("backward.end.fill", label: "Previous", fill: theme.onPrimary, icon: theme.primary,
                            action: onPrevious)
            transportButton(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play",
                            fill: theme.primary, icon: theme.onPrimary, circleSize: m.playButtonSize,
                            action: onPlayPause)
                .accessibilityIdentifier("miniPlayer.playPause")
                .background {
                    if let clock {
                        MiniPlayerProgressRing(clock: clock, durationHintMs: song.duration, songId: song.id,
                                               isPlaying: isPlaying, isActive: showsProgress, color: theme.primary,
                                               track: theme.onPrimaryContainer.opacity(0.18))
                    }
                }
                .padding(.horizontal, m.ringSpacing)
            transportButton("forward.end.fill", label: "Next", fill: theme.onPrimary, icon: theme.primary,
                            action: onNext)
        }
        .padding(.leading, m.leadingPadding)
        .padding(.trailing, m.trailingPadding - Self.hitInset)
        .frame(height: Tokens.Shell.miniPlayerHeight)
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
        .modifier(MiniPlayerGlass(enabled: drawsGlass, shape: shape,
                                  tint: theme.primaryContainer.opacity(GlassTint.miniPlayer)))
        .pixlHaptic(.impact(weight: .light), trigger: isPlaying)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("miniPlayer")
    }

    /// How far a button's touch area reaches past its circle on each side.
    private static let hitInset = (Tokens.MiniPlayer.buttonHitSize - Tokens.MiniPlayer.buttonSize) / 2

    private func transportButton(_ symbol: String, label: LocalizedStringKey, fill: Color, icon: Color,
                                 circleSize: CGFloat = Tokens.MiniPlayer.buttonSize,
                                 action: @escaping () -> Void) -> some View {
        let m = Tokens.MiniPlayer.self
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: m.buttonIconSize * 0.8 * circleSize / m.buttonSize, weight: .semibold))
                .foregroundStyle(icon)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: circleSize, height: circleSize)
                .background(Circle().fill(fill))
                .frame(width: m.buttonHitSize, height: m.buttonHitSize)
                .contentShape(.rect)
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(isPreparing)
        .accessibilityLabel(label)
    }
}

/// The song's progress as a thin ring round the mini player's play / pause circle (new UI, 2026-11-16; Android draws
/// M3 Expressive's wavy circular indicator there). Position is never observable state: a `TimelineView` samples the
/// clock only while playing and on screen, as often as the arc's end moves about a point
/// (`ProgressRing.tickInterval`: about every 1.3 s for a 3-minute song), and only this small view redraws. Paused, it
/// draws once — again after a seek or a new song. The track ring is static, outside the timeline.
struct MiniPlayerProgressRing: View {
    let clock: PlaybackClock
    let durationHintMs: Int64
    let songId: String
    let isPlaying: Bool
    let isActive: Bool
    let color: Color
    let track: Color

    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        let m = Tokens.MiniPlayer.self
        // A seek or restart while paused redraws the arc once (the timeline doesn't tick then).
        let _ = playback.seekRevision
        let interval = ProgressRing.tickInterval(durationMs: durationHintMs, diameter: Double(m.ringDiameter))
        ZStack {
            Circle()
                .inset(by: m.ringLineWidth / 2)
                .stroke(track, lineWidth: m.ringLineWidth)
            TimelineView(.animation(minimumInterval: interval, paused: !(isPlaying && isActive))) { context in
                let _ = context.date
                let duration = PlaybackProgress.displayDuration(reportedMs: clock.durationMs, hintMs: durationHintMs)
                let fraction = ProgressRing.drawnFraction(
                    PlaybackProgress.fraction(positionMs: clock.positionMs, durationMs: duration))
                Circle()
                    .inset(by: m.ringLineWidth / 2)
                    .trim(from: 0, to: CGFloat(fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: m.ringLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: m.ringDiameter, height: m.ringDiameter)
        // A new song starts its ring from the top at once (no sweep back from the old position).
        .id(songId)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .longRunning("miniPlayer.progressRing (timeline)", active: isPlaying && isActive)
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
