import SwiftUI

/// How strongly a glass surface is tinted with a palette role. Android painted these roles as opaque Material
/// surfaces; the port keeps the colour as a tint on real Liquid Glass so the content behind shows through
/// ("liquid transparent"). One table so every screen tints the same way.
nonisolated enum GlassTint {
    /// The primary action or the selected item (Android: filled `primary`): strongest.
    static let prominent: Double = 0.85
    /// Album-coloured panels (mini player, playing song card, mix cards; Android: `primaryContainer` fills).
    static let container: Double = 0.62
    /// Neutral panels (Android `surfaceContainer*` fills): a hint of the scheme.
    static let surface: Double = 0.28
    /// The bottom bar: content scrolls under it, so it stays legible (Android draws it opaque).
    static let bar: Double = 0.6
}

extension View {
    /// PixlAudio's glass surface: regular Liquid Glass in `shape`, optionally tinted, optionally interactive
    /// (press highlight). Use for cards, rows, bars and buttons that replace a Material surface.
    func pixlGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
    }
}

/// Immediate press feedback for plain (non-glass) controls that sit *on* a glass surface, where a second glass
/// layer would be glass-on-glass (mini player transport, a song card's ⋮ button).
struct PressScaleButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Motion used by the design system (interruptible springs; Android's tween/spring specs mapped to iOS springs).
nonisolated enum PixlMotion {
    /// Selection changes (nav bubble, pill highlight): Android `DampingRatioMediumBouncy` / `StiffnessMedium`.
    static let selection = Animation.spring(response: 0.38, dampingFraction: 0.72)
    /// State changes of a card (playing highlight, Android `tween(400)`).
    static let state = Animation.spring(response: 0.4, dampingFraction: 0.86)
    /// Showing / hiding bars (Android `tween(220, LinearOutSlowIn)`).
    static let bars = Animation.spring(response: 0.3, dampingFraction: 0.9)
    /// The tab cross-fade: a cubic fit of `selection`'s visible curve (within 0.74 % opacity over 0–0.21 s) that ends
    /// at 0.21 s, where the clamped spring is already at 100 % but keeps both tabs composited until about 0.6 s.
    static let tabFade = Animation.timingCurve(0.25, 0.05, 0.45, 0.85, duration: 0.21)
}

/// Rounds only the top corners of a scroll area (Android clips its lists' top corners) and leaves the bottom open past
/// the view's frame, so the content keeps scrolling under the tab bar, the mini player and the home indicator instead
/// of stopping in a hard line at the safe area.
nonisolated struct TopRoundedClip: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var open = rect
        open.size.height += 2000
        return UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                      topTrailingRadius: radius, style: .continuous).path(in: open)
    }
}
