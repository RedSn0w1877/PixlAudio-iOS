import PixlLibrary
import SwiftUI

/// One resolved colour scheme for SwiftUI: PixlAudio's palette roles (`primary`, `primaryContainer`,
/// `surfaceContainerHigh`, …) read as `Color`s, e.g. `theme.primaryContainer`. Role names are PixlAudio's, so a
/// Compose `colorScheme.onPrimaryContainer` ports to `theme.onPrimaryContainer` unchanged.
///
/// Where Android painted a role as an opaque surface, the iOS port uses it as a glass *tint* (see `GlassStyle`).
@dynamicMemberLookup
nonisolated struct ThemeColors: Sendable, Equatable {
    let roles: ColorRoles
    let isDark: Bool

    subscript(dynamicMember keyPath: KeyPath<ColorRoles, UInt32>) -> Color {
        Color(argb: roles[keyPath: keyPath])
    }

    /// The raw ARGB value of a role (for colour maths such as luminance).
    func argb(_ keyPath: KeyPath<ColorRoles, UInt32>) -> UInt32 { roles[keyPath: keyPath] }

    /// PixlAudio's violet (`ArtworkTheme.brandPair`): the default accent, and the environment's default before the
    /// shell injects the live colours. The app's real chrome scheme comes from `ThemeStore.colors(for:)`, which
    /// follows Settings › Appearance › Accent Color.
    static let brandLight = ThemeColors(roles: ArtworkTheme.brandPair.light, isDark: false)
    static let brandDark = ThemeColors(roles: ArtworkTheme.brandPair.dark, isDark: true)

    static func brand(_ scheme: ColorScheme) -> ThemeColors { scheme == .dark ? brandDark : brandLight }
}

extension Color {
    /// An sRGB colour from `0xAARRGGBB`.
    nonisolated init(argb: UInt32) {
        self.init(.sRGB,
                  red: Double((argb >> 16) & 0xFF) / 255,
                  green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255,
                  opacity: Double((argb >> 24) & 0xFF) / 255)
    }
}

extension EnvironmentValues {
    /// The app chrome's scheme (Android's `MaterialTheme.colorScheme` outside the player: the system dynamic scheme
    /// there; here the accent scheme — PixlAudio's violet by default, Settings › Appearance › Accent Color — or the
    /// album scheme when "Global" album theming is on).
    @Entry var appTheme: ThemeColors = .brandLight
    /// The current song's album-art scheme (Android `LocalMaterialTheme` inside the player sheet / mini player);
    /// equals `appTheme` when nothing is playing or album theming is off.
    @Entry var playerTheme: ThemeColors = .brandLight
}

/// WCAG relative luminance of an ARGB colour (0…1); > 0.6 counts as bright art (dim the glass, design.md).
nonisolated func relativeLuminance(argb: UInt32) -> Double {
    func lin(_ c: UInt32) -> Double {
        let v = Double(c) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin((argb >> 16) & 0xFF) + 0.7152 * lin((argb >> 8) & 0xFF) + 0.0722 * lin(argb & 0xFF)
}

extension View {
    /// For screens that are always dark (the lyrics screen, the lyrics sync editor): forces `.dark` for the
    /// presentation **and** re-resolves `appTheme` / `playerTheme` for dark.
    ///
    /// The shell resolves both palettes once, for the system's colour scheme, and hands them to every sheet and cover.
    /// `preferredColorScheme(.dark)` alone made the presentation (and every system sheet / alert presented from it)
    /// dark while the palette stayed the light one, so anything drawn with scheme roles — the lyrics More sheet's
    /// `onSurface` rows, its `surfaceContainer*` fills, the fetch dialog — came out near-black on a near-black sheet
    /// whenever the phone was in light mode. Sheets presented from below this modifier inherit the dark palette.
    /// The tint is re-resolved too: inside the cover's own (system-scheme) tint, so default-tinted controls take the
    /// accent's dark tone rather than its light one on black.
    func alwaysDarkTheme(_ store: ThemeStore) -> some View {
        let colors = store.colors(for: .dark)
        return environment(\.appTheme, colors.app)
            .environment(\.playerTheme, colors.player)
            .environment(\.colorScheme, .dark)
            .tint(colors.app.primary)
            .preferredColorScheme(.dark)
    }
}
