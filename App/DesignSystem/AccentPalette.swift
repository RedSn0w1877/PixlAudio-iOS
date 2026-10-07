import PixlLibrary
import SwiftUI
import UIKit

/// Settings › Appearance › Accent Color (iOS-only, owner request 2026-10-07): the presets, the stored value's format
/// (`"#RRGGBB"`, `""` = PixlAudio's violet) and the scheme of a choice.
///
/// The accent replaces the brand scheme everywhere the app chrome is themed (`ThemeStore.colors(for:)`): a picked
/// colour becomes `ArtworkTheme.accentPair(seed:)` (TonalSpot surfaces and role tones, the primary at the pick's own
/// chroma: "vivid"). The default keeps `ArtworkTheme.brandPair`, so nothing changes until a colour is picked.
nonisolated enum AccentPalette {
    nonisolated struct Preset: Identifiable, Hashable, Sendable {
        /// Stable id (accessibility identifier `settings.accent.<id>`).
        let id: String
        let name: String
        /// The stored value: `"#RRGGBB"`, `""` for PixlAudio's violet.
        let hex: String

        /// The colour the swatch shows: the named colour itself (the seed). The app shows the scheme's tone of it
        /// (darker in light mode, pastel in dark mode) so text on it stays legible.
        var seed: UInt32 { AccentPalette.seed(hex: hex) ?? ArtworkTheme.brandSeed }
    }

    /// PixlAudio's violet, then the owner's list (Blue, Indigo, Purple, Pink, Red, Orange, Yellow, Green, Mint,
    /// Graphite); the grid adds Custom (the system colour picker). Seeds are the system colours' vivid values.
    static let presets: [Preset] = [
        Preset(id: "default", name: L10n.settingsAccentColorDefault, hex: ""),
        Preset(id: "blue", name: L10n.settingsAccentColorBlue, hex: "#0A84FF"),
        Preset(id: "indigo", name: L10n.settingsAccentColorIndigo, hex: "#5E5CE6"),
        Preset(id: "purple", name: L10n.settingsAccentColorPurple, hex: "#BF5AF2"),
        Preset(id: "pink", name: L10n.settingsAccentColorPink, hex: "#FF2D55"),
        Preset(id: "red", name: L10n.settingsAccentColorRed, hex: "#FF453A"),
        Preset(id: "orange", name: L10n.settingsAccentColorOrange, hex: "#FF9F0A"),
        Preset(id: "yellow", name: L10n.settingsAccentColorYellow, hex: "#FFD60A"),
        Preset(id: "green", name: L10n.settingsAccentColorGreen, hex: "#34C759"),
        Preset(id: "mint", name: L10n.settingsAccentColorMint, hex: "#00C7BE"),
        Preset(id: "graphite", name: L10n.settingsAccentColorGraphite, hex: "#8E8E93"),
    ]

    /// The preset a stored value names (`nil` = a custom colour). Compares seeds, so `"ff453a"` is Red.
    static func preset(for hex: String) -> Preset? {
        let wanted = AccentPalette.seed(hex: hex)
        return presets.first { preset in
            wanted == nil ? preset.hex.isEmpty : AccentPalette.seed(hex: preset.hex) == wanted
        }
    }

    /// The opaque ARGB seed of a stored value: an optional `#` and exactly six hex digits (any case, surrounding
    /// spaces ignored). `""` and anything unreadable are nil (PixlAudio's violet).
    static func seed(hex: String) -> UInt32? {
        var digits = Substring(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let rgb = UInt32(digits, radix: 16) else {
            return nil
        }
        return 0xFF00_0000 | rgb
    }

    /// The stored form of a colour: `"#RRGGBB"` (upper case; alpha dropped).
    static func hex(argb: UInt32) -> String {
        let rgb = argb & 0xFF_FFFF
        let digits = String(rgb, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    /// The scheme pair of a stored value: the accent scheme of its seed, or PixlAudio's own pair for `""`.
    static func pair(hex: String) -> ColorRolesPair {
        seed(hex: hex).map(ArtworkTheme.accentPair(seed:)) ?? ArtworkTheme.brandPair
    }

    /// The stored form of a picked SwiftUI colour (the custom picker): resolved in sRGB (extended range, clamped)
    /// and rounded to 8 bits per channel. A fresh `EnvironmentValues()` resolves it, so the row needn't observe the
    /// whole environment (a picked colour is static: no light/dark variants).
    @MainActor
    static func hex(_ color: Color) -> String {
        let resolved = color.resolve(in: EnvironmentValues())
        func byte(_ component: Float) -> UInt32 { UInt32((min(max(component, 0), 1) * 255).rounded()) }
        return hex(argb: byte(resolved.red) << 16 | byte(resolved.green) << 8 | byte(resolved.blue))
    }

    /// A UIKit colour that follows the trait collection's light/dark style: the scheme's `primary` of each mode.
    /// Built here, in a nonisolated function, from two precomputed (Sendable) colours, so UIKit may resolve it on
    /// any thread without a main-actor check.
    static func dynamicPrimary(_ pair: ColorRolesPair) -> UIColor {
        let light = uiColor(argb: pair.light.primary)
        let dark = uiColor(argb: pair.dark.primary)
        return UIColor(dynamicProvider: { traits in traits.userInterfaceStyle == .dark ? dark : light })
    }

    static func uiColor(argb: UInt32) -> UIColor {
        UIColor(red: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
                blue: CGFloat(argb & 0xFF) / 255, alpha: 1)
    }
}

/// Sets the accent as the tint of the app's windows, so UIKit-presented controls SwiftUI's `.tint` doesn't reach
/// (system alerts and confirmation dialogs, context menus, the colour picker) follow it too. Standard `UIView.tintColor`
/// inheritance; whether iOS 26/27's glass alerts show it is to be checked on the phone. Called only when the accent
/// changes (and once at launch), never per frame.
@MainActor
enum WindowTint {
    static func apply(_ pair: ColorRolesPair) {
        let color = AccentPalette.dynamicPrimary(pair)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.tintColor = color
            }
        }
    }
}
