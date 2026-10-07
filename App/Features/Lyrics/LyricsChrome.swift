import PixlModel
import SwiftUI

/// Colours of the lyrics screen's chrome (Android `lyricsChromeColors`): built for the dark graded artwork in light and
/// dark mode alike, from the album scheme's *fixed* roles. Where Android filled a pill with `container`, the port
/// tints clear glass with it (light tint, decision 11).
struct LyricsChromeColors {
    let container: Color
    let content: Color
    let contentVariant: Color
    let accent: Color
    let accentTrack: Color
    let selected: Color
    let onSelected: Color
    let playPause: Color
    let onPlayPause: Color
    let syncAccent: Color
    let onSyncAccent: Color
    let emphasis: Color
    let onEmphasis: Color

    init(theme: ThemeColors, highContrast: Bool) {
        container = theme.onPrimaryFixedVariant.opacity(highContrast ? 0.92 : 0.62)
        content = theme.primaryFixed
        contentVariant = theme.primaryFixed.opacity(0.74)
        accent = theme.primaryFixedDim
        accentTrack = theme.primaryFixedDim.opacity(0.26)
        selected = theme.primaryFixedDim
        onSelected = theme.onPrimaryFixed
        playPause = theme.tertiaryFixedDim
        onPlayPause = theme.onTertiaryFixed
        syncAccent = theme.secondaryFixedDim
        onSyncAccent = theme.onSecondaryFixed
        emphasis = theme.primaryFixedDim
        onEmphasis = theme.onPrimaryFixed
    }

    /// Clear glass over the artwork (HIG: the clear variant over media), tinted with the container role; 35 % darker
    /// over bright art so the glyphs stay legible.
    func panelGlass(brightArt: Bool, interactive: Bool = false) -> Glass {
        Glass.clear.tint(brightArt ? Color.black.opacity(0.35) : container.opacity(0.55)).interactive(interactive)
    }
}

/// Lyrics screen geometry (Android `LyricsSheet.kt` constants).
enum LyricsChromeMetrics {
    /// The track pill's height over the lyrics (4 pt margin + 66 pt art + 8).
    static let headerInset: CGFloat = 78
    /// Extra top inset while the "sync it yourself" chip shows.
    static let syncChipInset: CGFloat = 48
    /// Lines fade in over this below the header, and out over `bottomFade` above the controls.
    static let topFade: CGFloat = 48
    static let bottomFade: CGFloat = 96
    static let showControlsSize: CGFloat = 52
    static let showControlsBottomGap: CGFloat = 24
    /// How far the controls slide while they hide.
    static let controlsSlide: CGFloat = 24
    /// The bottom scrim extends this far above the controls, up to this darkness.
    static let scrimExtra: CGFloat = 72
    static let scrimAlpha: Double = 0.38
    static let playPauseSize: CGFloat = 78
    static let playingCorner: CGFloat = 18
    static let pausedCorner: CGFloat = 39
    static let seekBarHeight: CGFloat = 50
    static let toggleHeight: CGFloat = 50
}

// MARK: - Header

/// The track pill (Android `LyricsHeader` + `LyricsTrackInfo`): spinning round art, title, artist, the playing bars.
struct LyricsHeader: View {
    let song: Song
    let isPlaying: Bool
    let chrome: LyricsChromeColors
    let brightArt: Bool

    var body: some View {
        HStack(spacing: 6) {
            SpinningArtwork(song: song, isPlaying: isPlaying)
                .padding(6)
            VStack(alignment: .leading, spacing: 0) {
                Text(song.title)
                    .pixlFont(.titleMedium, weight: .semibold)
                    .foregroundStyle(chrome.content)
                    .lineLimit(1)
                Text(song.displayArtist)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(chrome.contentVariant)
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
            .padding(.trailing, 6)
            .layoutPriority(-1)
            PlayingBarsIcon(color: chrome.content, isPlaying: isPlaying)
                .frame(width: 18, height: 16)
                .padding(.leading, 8)
                .padding(.trailing, 18)
        }
        .id(song.id)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .glassEffect(chrome.panelGlass(brightArt: brightArt), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// The album art turning like a record while playing (8 s per turn), pausing in place.
private struct SpinningArtwork: View {
    let song: Song
    let isPlaying: Bool
    @State private var spin = SpinClock()

    var body: some View {
        // Built once per body, not on every tick of the timeline.
        let art = ArtworkView(song: song, size: 54, cornerRadius: 27)
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isPlaying)) { timeline in
            art.rotationEffect(.degrees(spin.angle(at: timeline.date, playing: isPlaying)))
        }
        .frame(width: 54, height: 54)
    }
}

/// Accumulates rotation across pauses.
private final class SpinClock {
    private var base: Double = 0
    private var runningSince: Date?

    func angle(at date: Date, playing: Bool) -> Double {
        if playing {
            if runningSince == nil { runningSince = date }
        } else if let since = runningSince {
            base += date.timeIntervalSince(since) * 45
            runningSince = nil
        }
        let running = runningSince.map { date.timeIntervalSince($0) * 45 } ?? 0
        return (base + running).truncatingRemainder(dividingBy: 360)
    }
}

/// Android `PlayingEqIcon`: three rounded bars wandering while playing, morphing to dots when paused.
struct PlayingBarsIcon: View {
    let color: Color
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let bars = 3
                let gapFraction: CGFloat = 0.30
                let barW = size.width / (CGFloat(bars) + CGFloat(bars - 1) * (1 + gapFraction))
                let gap = barW * gapFraction
                let phase = (t.truncatingRemainder(dividingBy: 3.6)) / 3.6 * 2 * .pi
                let wander = (t.truncatingRemainder(dividingBy: 12)) / 12 * 2 * .pi
                for i in 0..<bars {
                    let fi = Double(i)
                    let slowShift = 0.6 * sin(wander + fi * 0.4)
                    let slowAmp = 0.85 + 0.15 * sin(wander * 0.5 + 1.1 + fi * 0.3)
                    let v = (sin(phase * (fi + 1) + fi * 0.9 + slowShift) * slowAmp + 1) * 0.5
                    let eased = v * v * (3 - 2 * v)
                    let barH = isPlaying ? size.height * CGFloat(0.28 + 0.72 * eased) : barW
                    let rect = CGRect(x: CGFloat(i) * (barW + gap), y: (size.height - barH) / 2, width: barW, height: barH)
                    context.fill(Path(roundedRect: rect, cornerRadius: barW / 2), with: .color(color))
                }
            }
        }
        .animation(.easeInOut(duration: 0.24), value: isPlaying)
        .accessibilityHidden(true)
    }
}

// MARK: - Bottom controls

/// The control cluster (Android `LyricsControlCluster`, Material mode): play/pause, the seek bar, then the toolbar
/// (back · Synced · Static · more), optionally the sync-offset row above — each a glass shape over the soft scrim.
struct LyricsControlCluster: View {
    let chrome: LyricsChromeColors
    let brightArt: Bool
    let isPlaying: Bool
    let showSyncControls: Bool
    let offsetMs: Int
    /// nil = no lyrics (the Synced/Static switch is hidden).
    let showSyncedLyrics: Bool?
    let hasSyncedLyrics: Bool
    let clock: PlaybackClock
    let onOffsetChange: (Int) -> Void
    let onPlayPause: () -> Void
    let onSeek: (Int64) -> Void
    let onSeekPreview: (Int64?) -> Void
    let onShowSyncedChange: (Bool) -> Void
    let onBack: () -> Void
    let onMore: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showSyncControls {
                LyricsSyncControls(offsetMs: offsetMs, chrome: chrome, brightArt: brightArt, onChange: onOffsetChange)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 12) {
                LyricsPlayPauseButton(isPlaying: isPlaying, chrome: chrome, action: onPlayPause)
                LyricsSeekBar(clock: clock, isPlaying: isPlaying, chrome: chrome, brightArt: brightArt, onSeek: onSeek,
                              onPreview: onSeekPreview)
                    .frame(height: LyricsChromeMetrics.seekBarHeight)
            }
            Spacer().frame(height: 16)
            LyricsToolbar(showSyncedLyrics: showSyncedLyrics, hasSyncedLyrics: hasSyncedLyrics, chrome: chrome,
                          brightArt: brightArt, onShowSyncedChange: onShowSyncedChange, onBack: onBack, onMore: onMore)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: showSyncControls)
    }
}

/// Play/pause: a squircle while playing (18 pt corners), a circle while paused — the primary action, tinted glass.
private struct LyricsPlayPauseButton: View {
    let isPlaying: Bool
    let chrome: LyricsChromeColors
    let action: () -> Void

    var body: some View {
        let corner = isPlaying ? LyricsChromeMetrics.playingCorner : LyricsChromeMetrics.pausedCorner
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(chrome.onPlayPause)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: LyricsChromeMetrics.playPauseSize, height: LyricsChromeMetrics.playPauseSize)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassEffect(Glass.clear.tint(chrome.playPause.opacity(GlassTint.prominent)).interactive(), in: shape)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: isPlaying)
        .pixlHaptic(.selection, trigger: isPlaying)
        .accessibilityLabel(isPlaying ? Text("Pause") : Text("Play"))
    }
}

/// The seek bar pill (Android `PlayerSeekBar` + `WavySliderExpressive`, 5 pt track, 8 pt thumb, 30 pt waves while
/// playing). Position is sampled ≤ 4 Hz from the player clock; a drag previews the position (the lyrics follow the
/// finger) and seeks on release.
private struct LyricsSeekBar: View {
    let clock: PlaybackClock
    let isPlaying: Bool
    let chrome: LyricsChromeColors
    let brightArt: Bool
    let onSeek: (Int64) -> Void
    let onPreview: (Int64?) -> Void

    @State private var dragFraction: Double?
    @State private var committedFraction: Double?
    @State private var committedAt = Date.distantPast

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let live = clock.fraction
            let fraction = dragFraction ?? stableFraction(live: live, now: timeline.date)
            GeometryReader { geometry in
                let inset: CGFloat = 16 + 8
                let trackWidth = max(geometry.size.width - 2 * inset, 1)
                WavyTrack(fraction: fraction, waving: isPlaying && dragFraction == nil, accent: chrome.accent,
                          track: chrome.accentTrack)
                    .padding(.horizontal, inset - 8)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let f = min(max((value.location.x - inset) / trackWidth, 0), 1)
                                dragFraction = f
                                onPreview(Int64(f * Double(clock.durationMs)))
                            }
                            .onEnded { value in
                                let f = min(max((value.location.x - inset) / trackWidth, 0), 1)
                                onSeek(Int64((f * Double(clock.durationMs)).rounded()))
                                onPreview(nil)
                                committedFraction = f
                                committedAt = Date()
                                dragFraction = nil
                            }
                    )
            }
        }
        .glassEffect(chrome.panelGlass(brightArt: brightArt), in: Capsule())
        .pixlHaptic(.selection, trigger: dragFraction.map { Int($0 * 20) })
        .accessibilityElement()
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text("\(Int(clock.fraction * 100)) %"))
        .accessibilityAdjustableAction { direction in
            let step = Int64(10_000)
            let now = clock.positionMs
            onSeek(direction == .increment ? now + step : max(now - step, 0))
        }
    }

    /// Android keeps showing the committed seek until the player catches up (or 5 s pass).
    private func stableFraction(live: Double, now: Date) -> Double {
        guard let committedFraction else { return live }
        if abs(live - committedFraction) < 0.04 || now.timeIntervalSince(committedAt) > 5 { return live }
        return committedFraction
    }
}

/// The wavy active track and thumb of the seek bar. The wave moves continuously on its own display-rate timeline
/// (≤ 60 Hz, paused while not waving) — on the position's 4 Hz timeline it jumped a quarter wavelength four times a
/// second — at Android `WavySliderExpressive`'s speed, half a wavelength per second.
private struct WavyTrack: View {
    let fraction: Double
    let waving: Bool
    let accent: Color
    let track: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !waving)) { timeline in
            wave(phase: timeline.date.timeIntervalSinceReferenceDate * 0.5)
        }
    }

    private func wave(phase: Double) -> some View {
        Canvas { context, size in
            let midY = size.height / 2
            let thumbR: CGFloat = 8
            let x = thumbR + CGFloat(fraction) * (size.width - 2 * thumbR)
            let stroke = StrokeStyle(lineWidth: 5, lineCap: .round)
            var inactive = Path()
            inactive.move(to: CGPoint(x: x, y: midY))
            inactive.addLine(to: CGPoint(x: size.width - thumbR, y: midY))
            context.stroke(inactive, with: .color(track), style: stroke)
            var active = Path()
            let wavelength: CGFloat = 30
            let amplitude: CGFloat = waving ? 3 : 0
            let shift = CGFloat(phase.truncatingRemainder(dividingBy: 1)) * wavelength
            active.move(to: CGPoint(x: thumbR, y: midY))
            var px = thumbR
            while px < x {
                let y = midY + amplitude * sin((px + shift) / wavelength * 2 * .pi)
                active.addLine(to: CGPoint(x: px, y: y))
                px += 2
            }
            active.addLine(to: CGPoint(x: x, y: midY))
            context.stroke(active, with: .color(accent), style: stroke)
            // End stop dot.
            let end = CGRect(x: size.width - thumbR - 2, y: midY - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: end), with: .color(accent))
            let thumb = CGRect(x: x - thumbR, y: midY - thumbR, width: 2 * thumbR, height: 2 * thumbR)
            context.fill(Path(ellipseIn: thumb), with: .color(accent))
        }
    }
}

/// Back · Synced · Static · more (Android `LyricsFloatingToolbar`).
private struct LyricsToolbar: View {
    let showSyncedLyrics: Bool?
    let hasSyncedLyrics: Bool
    let chrome: LyricsChromeColors
    let brightArt: Bool
    let onShowSyncedChange: (Bool) -> Void
    let onBack: () -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            toolbarCircle(systemImage: "arrow.left", label: "Back", action: onBack)
            if let showSyncedLyrics {
                HStack(spacing: 8) {
                    LyricsToggleSegment(title: "Synced", active: showSyncedLyrics, enabled: hasSyncedLyrics,
                                        chrome: chrome, brightArt: brightArt) { onShowSyncedChange(true) }
                    LyricsToggleSegment(title: "Static", active: !showSyncedLyrics, enabled: true,
                                        chrome: chrome, brightArt: brightArt) { onShowSyncedChange(false) }
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer().frame(maxWidth: .infinity).frame(height: LyricsChromeMetrics.toggleHeight)
            }
            toolbarCircle(systemImage: "ellipsis", label: "Lyrics options", rotated: true, action: onMore)
        }
    }

    private func toolbarCircle(systemImage: String, label: LocalizedStringKey, rotated: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .rotationEffect(.degrees(rotated ? 90 : 0))
                .foregroundStyle(chrome.content)
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(chrome.panelGlass(brightArt: brightArt, interactive: true), in: Circle())
        .accessibilityLabel(label)
    }
}

/// Android `ToggleSegmentButton`: active = accent capsule, inactive = 8 pt rounded rectangle.
private struct LyricsToggleSegment: View {
    let title: LocalizedStringKey
    let active: Bool
    let enabled: Bool
    let chrome: LyricsChromeColors
    let brightArt: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: active ? LyricsChromeMetrics.toggleHeight / 2 : 8, style: .continuous)
        Button(action: action) {
            Text(title)
                .pixlFont(.bodyMedium, weight: .bold)
                .foregroundStyle(active ? chrome.onSelected : chrome.content)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(height: LyricsChromeMetrics.toggleHeight)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .glassEffect(active
                     ? Glass.clear.tint(chrome.selected.opacity(enabled ? GlassTint.prominent : GlassTint.prominent / 2)).interactive()
                     : chrome.panelGlass(brightArt: brightArt, interactive: true),
                     in: shape)
        .opacity(enabled ? 1 : 0.5)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: active)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// The sync-offset row (Android `LyricsSyncControls`): −.5 −.1 [offset / reset] +.1 +.5 in one capsule.
private struct LyricsSyncControls: View {
    let offsetMs: Int
    let chrome: LyricsChromeColors
    let brightArt: Bool
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            button("−.5", weight: 1) { onChange(offsetMs - 500) }
            button("−.1", weight: 1) { onChange(offsetMs - 100) }
            button(offsetMs == 0 ? "0s" : String(format: "%+.1fs", Double(offsetMs) / 1000), weight: 1.3,
                   filled: offsetMs != 0, size: 12) { onChange(0) }
                .disabled(offsetMs == 0)
            button("+.1", weight: 1) { onChange(offsetMs + 100) }
            button("+.5", weight: 1) { onChange(offsetMs + 500) }
        }
        .padding(4)
        .frame(height: 52)
        .glassEffect(chrome.panelGlass(brightArt: brightArt), in: Capsule())
    }

    private func button(_ title: String, weight: CGFloat, filled: Bool = true, size: CGFloat = 11,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .pixlFont(.custom(size: size, weight: .bold))
                .lineLimit(1)
                .foregroundStyle(filled ? chrome.onSyncAccent : chrome.content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(filled ? chrome.syncAccent : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleButtonStyle())
        .frame(maxWidth: .infinity)
        .layoutPriority(weight)
    }
}

/// Immersive mode's "show controls" disc (Android `LyricsShowControlsButton`).
struct LyricsShowControlsButton: View {
    let chrome: LyricsChromeColors
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.up")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(chrome.onEmphasis)
                .frame(width: LyricsChromeMetrics.showControlsSize, height: LyricsChromeMetrics.showControlsSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(Glass.clear.tint(chrome.emphasis.opacity(GlassTint.prominent)).interactive(), in: Circle())
        .accessibilityLabel(Text("Show Controls"))
    }
}

/// "Make the words light up · Sync it yourself" (Android `LyricsSyncChip`).
struct LyricsSyncChip: View {
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Make the words light up · Sync it yourself")
                        .pixlFont(.labelLarge)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.leading, 14)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lyrics.syncChip")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .contentShape(.circle)
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel(Text("Dismiss"))
        }
        .glassEffect(Glass.clear.tint(.white.opacity(0.16)).interactive(), in: Capsule())
    }
}

/// The swipe feedback disc (previous / next song) sliding in from the edge.
struct LyricsSwipeIndicator: View {
    let towardsNext: Bool
    let progress: CGFloat
    let chrome: LyricsChromeColors

    var body: some View {
        let big: CGFloat = 50
        let small: CGFloat = 8
        let shape = UnevenRoundedRectangle(topLeadingRadius: towardsNext ? big : small,
                                           bottomLeadingRadius: towardsNext ? big : small,
                                           bottomTrailingRadius: towardsNext ? small : big,
                                           topTrailingRadius: towardsNext ? small : big, style: .continuous)
        Image(systemName: towardsNext ? "forward.end.fill" : "backward.end.fill")
            .font(.system(size: 40, weight: .bold))
            .foregroundStyle(chrome.onEmphasis)
            .frame(width: 94, height: 94)
            .glassEffect(Glass.clear.tint(chrome.emphasis.opacity(GlassTint.prominent)), in: shape)
            .scaleEffect(0.8 + progress * 0.2)
            .offset(x: (towardsNext ? 100 : -100) * (1 - progress))
            .accessibilityHidden(true)
    }
}
