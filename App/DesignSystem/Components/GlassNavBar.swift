import SwiftUI

/// The bottom tab bar, behaving like the real iOS tab bar. Hoa, 2026-10-02: "the pill doesnt go clear or expand,
/// and it doesnt refract text underneath. use like a demo thing online".
///
/// It is a floating capsule of interactive Liquid Glass with Home, Search and Library: symbol over a small label,
/// or symbols only in compact mode (Settings › Appearance). The selection is the system's own liquid lens
/// (`LiquidTabBar`, after the open-source FabBar).
/// - At rest it is a pill tinted with the accent colour (`primary`), with the glyph in `onPrimary`.
/// - On touch it lifts off as clear glass, swells past the bar, follows the finger and magnifies the glyphs under
///   it, which turn the accent colour.
/// - On release it settles on the tab under the finger and fills with the accent again.
/// Re-tapping the selected tab pops it to its root.
///
/// It is not the system `TabView` bar because that bar's selection platter can't take the accent colour, and the
/// player sheet expands from the mini player slot that floats above this bar (stage 8).
struct GlassNavBar: View {
    let selection: RootTab
    var compact = false
    let onSelect: (RootTab) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        LiquidTabBar(selection: selection,
                     compact: compact,
                     pillColor: UIColor(theme.primary.opacity(GlassTint.prominent)),
                     restingGlyphColor: UIColor(theme.onPrimary),
                     liftedGlyphColor: UIColor(theme.primary),
                     onSelect: onSelect)
            .frame(height: compact ? Tokens.Shell.navBarCompactHeight : Tokens.Shell.navBarHeight)
            .frame(maxWidth: .infinity)
            .sensoryFeedback(.selection, trigger: selection)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("navBar")
    }
}
