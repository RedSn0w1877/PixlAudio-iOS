import SwiftUI

/// The tab capsule at the bottom of PixlAudio's sheets (song options OPTIONS / INFO, devices CONTROLS / DEVICES, the
/// song picker's LOCAL / CLOUD) on the system liquid lens, as the tab bar is: the accent pill at rest, lifting off as
/// clear glass that follows the finger and magnifies the labels under it. Hoa, 2026-10-03: "the navbar here isn't
/// Liquid Glass sliding implemented" (the devices sheet's tabs). `LiquidSegmentedPicker` does the work; this fixes
/// the theme roles, the 56 pt height and the selection haptic in one place.
struct LiquidTabCapsule<Value: Hashable>: View {
    struct Tab {
        let value: Value
        let title: String
        let systemImage: String
        /// Filled variant inside the lens (defaults to `systemImage`).
        var selectedSystemImage: String?
        /// The segment's accessibility identifier.
        let identifier: String
    }

    let tabs: [Tab]
    @Binding var selection: Value

    @Environment(\.appTheme) private var theme

    static var height: CGFloat { 56 }

    var body: some View {
        LiquidSegmentedPicker(
            options: tabs.map(\.value),
            items: tabs.map {
                LiquidSegmentItem(title: $0.title, systemImage: $0.systemImage,
                                  selectedSystemImage: $0.selectedSystemImage ?? $0.systemImage,
                                  identifier: $0.identifier)
            },
            selection: $selection,
            animation: PixlMotion.selection,
            pillColor: UIColor(theme.primary.opacity(GlassTint.prominent)),
            restingGlyphColor: UIColor(theme.onPrimary),
            liftedGlyphColor: UIColor(theme.primary),
            baseGlyphColor: UIColor(theme.onSurface))
            .frame(height: Self.height)
            .frame(maxWidth: .infinity)
            .pixlHaptic(.selection, trigger: selection)
    }
}
