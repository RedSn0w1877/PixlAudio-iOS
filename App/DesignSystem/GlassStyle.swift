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
}
