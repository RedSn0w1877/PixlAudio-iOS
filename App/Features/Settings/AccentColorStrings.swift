import Foundation

// Strings of Settings › Appearance › Accent Color (iOS-only, owner request 2026-10-07: Android has no accent setting,
// so these keys are iOS additions). `SettingsStrings.swift` is generated from Android and never hand-edited; the
// String Catalog picks these keys up on the next `tools/localization/android_strings_to_xcstrings.py` run.
// `nonisolated` because the nonisolated `AccentPalette.presets` reads the names.
nonisolated extension L10n {
    static let settingsAccentColorTitle = String(localized: "settings_accent_color_title", defaultValue: "Accent Color")
    static let settingsAccentColorSubtitle = String(localized: "settings_accent_color_subtitle",
                                                    defaultValue: "Colors buttons, switches, sliders, the tab bar and selected glass across the app. The player keeps its album colors (see Player Theme).")
    static let settingsAccentColorCustom = String(localized: "settings_accent_color_custom", defaultValue: "Custom")
    static let settingsAccentColorDefault = String(localized: "settings_accent_color_default", defaultValue: "PixlAudio")
    static let settingsAccentColorBlue = String(localized: "settings_accent_color_blue", defaultValue: "Blue")
    static let settingsAccentColorIndigo = String(localized: "settings_accent_color_indigo", defaultValue: "Indigo")
    static let settingsAccentColorPurple = String(localized: "settings_accent_color_purple", defaultValue: "Purple")
    static let settingsAccentColorPink = String(localized: "settings_accent_color_pink", defaultValue: "Pink")
    static let settingsAccentColorRed = String(localized: "settings_accent_color_red", defaultValue: "Red")
    static let settingsAccentColorOrange = String(localized: "settings_accent_color_orange", defaultValue: "Orange")
    static let settingsAccentColorYellow = String(localized: "settings_accent_color_yellow", defaultValue: "Yellow")
    static let settingsAccentColorGreen = String(localized: "settings_accent_color_green", defaultValue: "Green")
    static let settingsAccentColorMint = String(localized: "settings_accent_color_mint", defaultValue: "Mint")
    static let settingsAccentColorGraphite = String(localized: "settings_accent_color_graphite", defaultValue: "Graphite")
    /// Player Theme's `dynamic` option (Android "System Dynamic", which has no iOS source): the player uses the accent.
    /// A new key, because the catalog's "System Dynamic" value would override an edited default value.
    static let settingsPlayerThemeAccent = String(localized: "settings_player_theme_accent", defaultValue: "Accent Color")
}
