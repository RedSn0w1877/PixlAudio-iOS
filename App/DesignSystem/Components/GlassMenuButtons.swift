import SwiftUI

// Buttons that open small menus with the system's own liquid menu (SwiftUI `Menu`). On iOS 26 and later the menu
// morphs out of the button that opens it, as in the system apps. Hoa (2026-10-02) checked it against a recording of
// Messages' Edit menu:
// - the button's glass swells and bursts into a lens-like blob, with the menu inside it magnified and blurred;
// - the blob then settles into the panel, and the text shrinks and sharpens.
// Hoa wants this only on small menus (sort and filter, options), not on full-screen surfaces such as the queue.
// Large panels stay sheets.

/// A glass circle that opens a menu: Apple's glass button style, so the system morph starts from the button's own
/// glass. `prominentTint` makes it tinted (`glassProminent`), as a primary action.
struct GlassCircleMenu<MenuContent: View>: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    var iconSize: CGFloat = 18
    var foreground: Color?
    var prominentTint: Color?
    @ViewBuilder let content: () -> MenuContent

    @Environment(\.appTheme) private var theme

    var body: some View {
        let menu = Menu {
            content()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(foreground ?? theme.onSurface)
                .frame(width: 24, height: 24)
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel(accessibilityLabel)
        if let prominentTint {
            menu
                .buttonStyle(.glassProminent)
                .tint(prominentTint)
        } else {
            menu.buttonStyle(.glass)
        }
    }
}

/// A menu on PixlAudio's own glass shape (Library's segmented action row, the queue's ⋯ circle, the genre FAB):
/// the same label and glass as the matching button, and the system menu opening from it.
struct ShapedGlassMenu<MenuShape: Shape, MenuContent: View>: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    let shape: MenuShape
    var width: CGFloat
    var height: CGFloat
    var iconSize: CGFloat = 20
    var iconWeight: Font.Weight = .semibold
    var iconRotation: Double = 0
    var tint: Color?
    var foreground: Color
    @ViewBuilder let content: () -> MenuContent

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: iconWeight))
                .rotationEffect(.degrees(iconRotation))
                .foregroundStyle(foreground)
                .frame(width: width, height: height)
                .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: tint, interactive: true)
        .accessibilityLabel(accessibilityLabel)
    }
}
