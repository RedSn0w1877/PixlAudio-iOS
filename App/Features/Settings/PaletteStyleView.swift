import SwiftUI

/// Album-art palette style (Android `PaletteStyleSettingsScreen`). Dropped on iOS: the palette styles are Material
/// dynamic-colour variants; the port keeps PixlAudio's default (TonalSpot) album-art scheme for every song, so the
/// route only explains that. Nothing in the app links here.
struct PaletteStyleView: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsScaffold(title: String(localized: "settings_palette_style_title", defaultValue: "Palette style"),
                         screenID: "paletteStyle") {
            SettingsPanel {
                Text(String(localized: "settings_palette_style_ios_note",
                            defaultValue: "Album colours always use the balanced style on iOS, tuned for Liquid Glass."))
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        }
    }
}
