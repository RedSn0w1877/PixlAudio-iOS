import SwiftUI

/// A rounded glass container (Android `Card` / `Surface` panels: the greeting card, mix cards, settings groups).
/// `tint` carries the colour Android filled the card with (often the album palette), at `GlassTint.container`.
/// Put plain content inside — not more glass (use `glassEffectUnion` or fills for controls on a card).
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = Tokens.Radius.card
    var tint: Color?
    var interactive = false
    @ViewBuilder var content: Content

    init(cornerRadius: CGFloat = Tokens.Radius.card, tint: Color? = nil, interactive: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.interactive = interactive
        self.content = content()
    }

    var body: some View {
        content
            .pixlGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                       tint: tint.map { $0.opacity(GlassTint.container) }, interactive: interactive)
    }
}

/// Android `PlayingEqIcon` stand-in: animated bars while playing, static while paused (18×16 pt).
/// The animation is a symbol effect run by the system — nothing ticks in the view.
struct PlayingIndicator: View {
    let isPlaying: Bool
    var color: Color

    var body: some View {
        Image(systemName: "chart.bar.fill")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(color)
            .symbolEffect(.variableColor.iterative.reversing, isActive: isPlaying)
            .frame(width: 18, height: 16)
            .accessibilityLabel(isPlaying ? "Playing" : "Paused")
    }
}
