import SwiftUI

/// Previous / play-pause / next (Android `AnimatedPlaybackControls`): three pills 80 pt tall, 6 pt apart, sharing the
/// width by weight — the pressed one grows to 1.1 while the others shrink to 0.65, then they settle back (220 ms
/// after play/pause, 600 ms after a skip) on Android's fast spatial spring. Previous and next are `primary` with an
/// `onPrimary` icon; play/pause is `tertiaryFixedDim` with an `onTertiaryFixed` icon, a full pill while paused and a
/// 26 pt rounded rectangle while playing.
///
/// Material's filled pills become tinted Liquid Glass of the same shapes (the play button carries the strongest
/// tint), in one `GlassEffectContainer` whose spacing is below the 6 pt gaps so they never blend at rest.
struct AnimatedPlaybackControls: View {
    let isPlaying: Bool
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void
    var height: CGFloat = 80

    @Environment(\.playerTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private nonisolated enum Control: Hashable, Sendable { case previous, playPause, next }

    @State private var lastClicked: Control?
    @State private var clickCount = 0
    /// Seeded with the laid-out width when known (one layout pass instead of a measuring one first).
    @State private var width: CGFloat

    init(isPlaying: Bool, onPrevious: @escaping () -> Void, onPlayPause: @escaping () -> Void,
         onNext: @escaping () -> Void, height: CGFloat = 80, initialWidth: CGFloat = 0) {
        self.isPlaying = isPlaying
        self.onPrevious = onPrevious
        self.onPlayPause = onPlayPause
        self.onNext = onNext
        self.height = height
        _width = State(initialValue: initialWidth)
    }

    private static let spacing: CGFloat = 6
    /// `MotionScheme.expressive().fastSpatialSpec` (damping 0.6, stiffness 800).
    private static let pressSpring = Animation.interpolatingSpring(mass: 1, stiffness: 800,
                                                                   damping: 2 * 0.6 * 800.0.squareRoot())

    var body: some View {
        let widths = Self.widths(total: width, lastClicked: lastClicked)
        let playCorner: CGFloat = isPlaying ? 26 : height / 2
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: Self.spacing) {
                button(.previous, systemImage: "backward.end.fill", label: "Previous", iconSize: 26,
                       tint: theme.primary, icon: theme.onPrimary, shape: AnyShape(Capsule()), width: widths[0],
                       action: onPrevious)
                button(.playPause, systemImage: isPlaying ? "pause.fill" : "play.fill",
                       label: isPlaying ? "Pause" : "Play", iconSize: 30, tint: theme.tertiaryFixedDim,
                       icon: theme.onTertiaryFixed,
                       shape: AnyShape(RoundedRectangle(cornerRadius: playCorner, style: .continuous)),
                       width: widths[1], action: onPlayPause)
                    .accessibilityIdentifier("player.playPause")
                button(.next, systemImage: "forward.end.fill", label: "Next", iconSize: 26, tint: theme.primary,
                       icon: theme.onPrimary, shape: AnyShape(Capsule()), width: widths[2], action: onNext)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isPlaying)
        .pixlHaptic(.selection, trigger: clickCount)
        .task(id: clickCount) {
            guard let control = lastClicked else { return }
            let delay: Duration = control == .playPause ? .milliseconds(220) : .milliseconds(600)
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(Self.pressSpring) { lastClicked = nil }
        }
    }

    private func button(_ control: Control, systemImage: String, label: LocalizedStringKey, iconSize: CGFloat,
                        tint: Color, icon: Color, shape: AnyShape, width: CGFloat,
                        action: @escaping () -> Void) -> some View {
        Button {
            // Reduce Motion: the pills keep their widths (no bouncy grow / shrink); the haptic and action stay.
            if !reduceMotion { withAnimation(Self.pressSpring) { lastClicked = control } }
            clickCount += 1
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(icon)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: max(width, 1), height: height)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassEffect(Glass.clear.tint(tint.opacity(GlassTint.prominent)).interactive(), in: shape)
        .accessibilityLabel(label)
    }

    /// Android's weighted `Row`: base 1, pressed 1.1, the others 0.65.
    private static func widths(total: CGFloat, lastClicked: Control?) -> [CGFloat] {
        let controls: [Control] = [.previous, .playPause, .next]
        let weights = controls.map { control -> CGFloat in
            guard let lastClicked else { return 1 }
            return control == lastClicked ? 1.1 : 0.65
        }
        let available = max(total - spacing * 2, 0)
        let sum = weights.reduce(0, +)
        return weights.map { available * $0 / sum }
    }
}
