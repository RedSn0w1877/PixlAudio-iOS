import PixlLibrary
import SwiftUI

// The beam: what Song Tap looks like when two phones touch (Android `SongTapBeam.kt`).
//
// The motion is the pure timeline in PixlCore (`SongTapTimeline.frame`, in permille): there is no animation state here, only the
// clock. A `TimelineView` that runs only while a beam plays (it is paused the rest of the time, so an idle screen draws nothing
// per frame) asks the timeline for the frame of that moment and applies it with scale, offset and opacity, which the render
// server handles without a layout pass. Both phones start at the same T0 (the handshake in the core), so the two halves are one
// motion. With Reduce Motion the timeline itself is the 150 ms cross-fade; the haptics stay.

/// Milliseconds since the beam's T0 for the frame drawn at `date`.
private func beamMs(_ date: Date, startMs: Int64) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1000) - startMs
}

// MARK: The glow at the top edge

/// The glow at the top edge of the screen. Its strength is the larger of the approach (the smoothed signal of the phone coming
/// closer, 0...500) and the beam's own glow, plus a short pulse at the moment of contact. One radial gradient drawn with an
/// opacity: no blur, nothing allocated per frame beyond the frame's own value.
struct SongTapGlowLayer: View {
    let model: SongTapGlowModel
    let beamRole: SongTapRole?
    let beamStartMs: Int64
    let reduced: Bool
    /// When the moment of contact happened, for the one-off pulse.
    let pulseAt: Date?
    @Environment(\.appTheme) private var theme

    private static let pulseSeconds = 0.6

    /// 0...0.7: the larger of the approach and the beam's own glow, plus the pulse of the moment of contact.
    private static func strength(approach: Int, beamRole: SongTapRole?, beamStartMs: Int64, reduced: Bool, pulseAt: Date?,
                                 at date: Date) -> Double {
        var beamGlow = 0
        if let beamRole {
            beamGlow = SongTapTimeline.frame(role: beamRole, tMs: beamMs(date, startMs: beamStartMs), reducedMotion: reduced).glow
        }
        var pulse = 0.0
        if let pulseAt { pulse = max(0, 1 - date.timeIntervalSince(pulseAt) / pulseSeconds) }
        return min(0.7, Double(max(approach, beamGlow)) / 1000 + pulse * 0.28)
    }

    var body: some View {
        let approach = model.value
        let running = beamRole != nil || pulseAt != nil
        GeometryReader { geo in
            TimelineView(.animation(paused: !running)) { context in
                let strength = Self.strength(approach: approach, beamRole: beamRole, beamStartMs: beamStartMs, reduced: reduced,
                                             pulseAt: pulseAt, at: context.date)
                RadialGradient(colors: [theme.primary, theme.primary.opacity(0)], center: .top, startRadius: 0,
                               endRadius: geo.size.width * 0.95)
                    .opacity(strength)
            }
        }
        .animation(.linear(duration: 0.12), value: approach)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: The sender's artwork

/// The sender's artwork: it lifts, shrinks to 40 percent and leaves through the top, then comes back (the first 1.5 s of
/// `SongTapTimeline`). At rest it is just the picture.
struct SongTapBeamArtwork: View {
    let artUrl: String?
    let beamRole: SongTapRole?
    let beamStartMs: Int64
    let reduced: Bool
    /// The height of the screen it flies across.
    let rootHeight: CGFloat
    let size: CGFloat

    var body: some View {
        let playing = beamRole == .send
        TimelineView(.animation(paused: !playing)) { context in
            let frame = playing
                ? SongTapTimeline.frame(role: .send, tMs: beamMs(context.date, startMs: beamStartMs), reducedMotion: reduced)
                : SongTapBeamFrame(0, 1000, 0, 1000, 0, 0, 0, 0)
            let lift = Double(frame.shadow) / 1000
            ArtworkView(source: ArtworkSource(uriString: artUrl), size: size, cornerRadius: 28)
                .shadow(color: .black.opacity(0.32 * lift), radius: 24 * lift, y: 10 * lift)
                .scaleEffect(CGFloat(frame.scale) / 1000)
                .offset(y: CGFloat(frame.translateY) / 1000 * rootHeight)
                .opacity(Double(frame.alpha) / 1000)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(SongTapStrings.beamArtwork)
    }
}

// MARK: The receiver's card

/// The receiver's card: the artwork enters from the top at 40 percent and springs into a Liquid Glass card, then the title, the
/// line "Added to your library" and the Undo chip come in (the receiver half of `SongTapTimeline`). It rests for six seconds with
/// Undo, then slides away. The card and the Undo chip share one `GlassEffectContainer`: the chip grows out of the card's lower
/// edge (`glassEffectID`, matched geometry) instead of fading in over it.
struct SongTapReceiveBeamCard: View {
    let card: SongTapCard
    let phase: SongTapPhase
    let alreadyHad: Bool
    let beamStartMs: Int64
    let reduced: Bool
    let rootHeight: CGFloat
    let onUndo: () -> Void
    @Environment(\.appTheme) private var theme
    @Namespace private var glassNamespace

    private static let cardShape = RoundedRectangle(cornerRadius: 32, style: .continuous)

    var body: some View {
        let canUndo = phase == .saved && !alreadyHad
        TimelineView(.animation) { context in
            let frame = SongTapTimeline.frame(role: .receive, tMs: beamMs(context.date, startMs: beamStartMs), reducedMotion: reduced)
            let showChip = canUndo && frame.undoAlpha > 0
            GlassEffectContainer(spacing: 24) {
                VStack(spacing: 14) {
                    cardBody(frame)
                    if showChip {
                        undoChip(frame)
                    }
                }
            }
            .animation(reduced ? nil : .spring(response: 0.45, dampingFraction: 0.78), value: showChip)
            .scaleEffect(CGFloat(frame.scale) / 1000)
            .offset(y: CGFloat(frame.translateY) / 1000 * rootHeight)
            .opacity(Double(frame.alpha) / 1000)
        }
        .frame(maxWidth: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("songTap.beamCard")
    }

    private func cardBody(_ frame: SongTapBeamFrame) -> some View {
        VStack(spacing: 6) {
            ArtworkView(source: ArtworkSource(uriString: card.artUrl), size: 132, cornerRadius: 22)
            VStack(spacing: 2) {
                Text(card.title)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text(card.artist)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                Text(phase == .saved ? (alreadyHad ? SongTapStrings.cardAlready : SongTapStrings.cardSaved) : SongTapStrings.cardAdding)
                    .pixlFont(.labelLarge)
                    .foregroundStyle(theme.primary)
                    .padding(.top, 6)
            }
            .opacity(Double(frame.textAlpha) / 1000)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background {
            Self.cardShape
                .fill(.clear)
                .glassEffect(Glass.regular.tint(theme.surfaceContainerHigh.opacity(GlassTint.container)), in: Self.cardShape)
                .opacity(Double(frame.cardAlpha) / 1000)
                .glassEffectID("card", in: glassNamespace)
        }
    }

    private func undoChip(_ frame: SongTapBeamFrame) -> some View {
        Button {
            if beamMs(Date(), startMs: beamStartMs) >= SongTapTimeline.receiveUndoStartMs { onUndo() }
        } label: {
            Text(SongTapStrings.cardUndo)
                .pixlFont(.labelLarge, weight: .semibold)
                .foregroundStyle(theme.primary)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(Glass.regular.interactive(), in: Capsule())
        .glassEffectID("undo", in: glassNamespace)
        .glassEffectTransition(.matchedGeometry)
        .opacity(Double(frame.undoAlpha) / 1000)
        .accessibilityIdentifier("songTap.undo")
    }
}
