import SwiftUI
import UIKit

/// Settings › Appearance (Android `SettingsCategoryScreen` APPEARANCE): theme, now playing, home, navigation — and, in
/// developer mode, an "Advanced" block (player file info, album art resolution). The lyrics screen's switches live in
/// Lyrics; the player background moved here from Playback.
///
/// Dropped (Material-only, not meaningful with Liquid Glass): album-art palette style (iOS keeps the default
/// TonalSpot scheme), NavBar style and corner radius, smooth corners (every iOS corner is already continuous).
/// App language opens the system's per-app language setting (iOS apps can't switch language in-app); it shows only
/// when the app has more than one localisation.
///
/// iOS-only (owner request 2026-10-07): Accent Color under Theme, after App Theme (`AccentColorRow`). It takes the
/// place of Android's wallpaper colours, so Player Theme's "System Dynamic" option (stored as `dynamic`) reads
/// "Accent Color" here: the player uses the accent instead of the album colours.
struct AppearanceSettingsSection: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var appearance = settings.appearance
        @Bindable var playback = settings.playback
        @Bindable var behavior = settings.behavior
        let developerMode = settings.experimental.developerMode
        SettingsCategoryScaffold(category: .appearance) {
            SettingsSubsection(title: L10n.settingsSectionTheme) {
                // iOS lists a per-app Language choice only for apps with more than one localisation; while the app
                // ships English only (owner decision 12) the row would open a page with nothing to pick.
                if AppLocalizations.offersLanguageChoice {
                    SettingsItemRow(title: L10n.settingsAppLanguageTitle, subtitle: L10n.settingsAppLanguageSubtitle,
                                    systemImage: "globe", showsChevron: true, identifier: "settings.appearance.language") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                ThemeSelectorRow(label: L10n.settingsAppThemeTitle, description: L10n.settingsAppThemeSubtitle,
                                 options: [SettingsOption(key: AppThemeMode.light.rawValue, label: L10n.settingsThemeLight),
                                           SettingsOption(key: AppThemeMode.dark.rawValue, label: L10n.settingsThemeDark),
                                           SettingsOption(key: AppThemeMode.followSystem.rawValue,
                                                          label: L10n.settingsThemeFollowSystem)],
                                 selectedKey: appearance.appThemeMode.rawValue, systemImage: "sun.max") {
                    appearance.appThemeMode = AppThemeMode(rawValue: $0) ?? .followSystem
                }
                AccentColorRow(selectedHex: appearance.accentColor) { appearance.accentColor = $0 }
                SwitchSettingRow(title: L10n.settingsDisableBlurAllOverTitle,
                                 subtitle: L10n.settingsDisableBlurAllOverSubtitle,
                                 isOn: $appearance.disableBlurAllOver, systemImage: "circle.dotted")
                SwitchSettingRow(title: L10n.settingsShowScrollbarTitle, subtitle: L10n.settingsRowShowScrollbarSubtitle,
                                 isOn: $appearance.showScrollbar, systemImage: "arrow.up.and.down")
            }
            SettingsSubsection(title: L10n.settingsSectionNowPlaying) {
                ThemeSelectorRow(label: L10n.settingsPlayerThemeTitle, description: L10n.settingsPlayerThemeSubtitle,
                                 options: [SettingsOption(key: PlayerThemePreference.albumArt.rawValue,
                                                          label: L10n.settingsPlayerThemeAlbumArt),
                                           SettingsOption(key: PlayerThemePreference.dynamic.rawValue,
                                                          label: L10n.settingsPlayerThemeAccent)],
                                 selectedKey: appearance.playerTheme.rawValue, systemImage: "play.circle") {
                    appearance.playerTheme = PlayerThemePreference(rawValue: $0) ?? .albumArt
                }
                // Moved here from Playback (it is how the player looks, not how it plays).
                ThemeSelectorRow(label: L10n.settingsRowPlayerBackgroundTitle,
                                 description: L10n.settingsPlayerAmbientEffectsSubtitle,
                                 options: [SettingsOption(key: "OFF", label: L10n.settingsPlayerAmbientStyleOff),
                                           SettingsOption(key: "BLENDED_COVER",
                                                          label: L10n.settingsPlayerAmbientStyleBlendedCover),
                                           SettingsOption(key: "FLOWING_GRADIENT",
                                                          label: L10n.settingsPlayerAmbientStyleFlowingGradient),
                                           SettingsOption(key: "LOW_POLY_MESH",
                                                          label: L10n.settingsPlayerAmbientStyleLowPolyMesh),
                                           SettingsOption(key: "AUDIO_WAVEFORM",
                                                          label: L10n.settingsPlayerAmbientStyleAudioWaveform)],
                                 selectedKey: playback.playerAmbientStyle, systemImage: "rectangle.on.rectangle") {
                    playback.playerAmbientStyle = $0
                }
                ThemeSelectorRow(label: L10n.settingsCarouselStyleTitle, description: L10n.settingsCarouselStyleSubtitle,
                                 options: [SettingsOption(key: "no_peek", label: L10n.settingsCarouselNoPeek),
                                           SettingsOption(key: "one_peek", label: L10n.settingsCarouselOnePeek)],
                                 selectedKey: appearance.carouselStyle, systemImage: "square.stack") {
                    appearance.carouselStyle = $0
                }
            }
            SettingsSubsection(title: L10n.settingsSectionHome) {
                ThemeSelectorRow(label: L10n.settingsCollagePatternTitle,
                                 description: L10n.settingsCollagePatternSubtitle,
                                 options: CollagePatternOption.all, selectedKey: appearance.collagePattern,
                                 systemImage: "rectangle.split.3x1") { appearance.collagePattern = $0 }
                SwitchSettingRow(title: L10n.settingsAutoRotatePatternsTitle,
                                 subtitle: L10n.settingsAutoRotatePatternsSubtitle,
                                 isOn: $appearance.collageAutoRotate, systemImage: "shuffle")
            }
            // The iOS-style tab bar has one shape, so Android's navigation bar style choice (default / full width) is
            // gone; compact mode still applies (icons only, shorter bar). `navBarStyle` stays stored for backups.
            SettingsSubsection(title: L10n.settingsSectionNavigation, addBottomSpace: developerMode) {
                ThemeSelectorRow(label: L10n.settingsDefaultTabTitle, description: L10n.settingsDefaultTabSubtitle,
                                 options: [SettingsOption(key: RootTab.home.launchTabKey, label: L10n.settingsDefaultTabHome),
                                           SettingsOption(key: RootTab.search.launchTabKey, label: L10n.commonSearch),
                                           SettingsOption(key: RootTab.library.launchTabKey,
                                                          label: L10n.settingsDefaultTabLibrary)],
                                 selectedKey: behavior.launchTab.launchTabKey, systemImage: "menubar.rectangle") { key in
                    behavior.launchTab = RootTab.allCases.first { $0.launchTabKey == key } ?? .home
                }
                ThemeSelectorRow(label: L10n.settingsLibraryNavigationTitle,
                                 description: L10n.settingsLibraryNavigationSubtitle,
                                 options: [SettingsOption(key: "tab_row", label: L10n.settingsLibraryNavTabRow),
                                           SettingsOption(key: "compact_pill", label: L10n.settingsLibraryNavCompactPill)],
                                 selectedKey: appearance.libraryNavigationMode, systemImage: "music.note.square.stack") {
                    appearance.libraryNavigationMode = $0
                }
                SwitchSettingRow(title: L10n.settingsCompactModeTitle, subtitle: L10n.settingsRowCompactModeSubtitle,
                                 isOn: $appearance.navBarCompactMode, systemImage: "dock.rectangle")
            }
            SettingsAdvancedSubsection {
                SwitchSettingRow(title: L10n.settingsShowPlayerFileInfoTitle,
                                 subtitle: L10n.settingsShowPlayerFileInfoSubtitle,
                                 isOn: $appearance.fullPlayerShowFileInfo, systemImage: "paperclip")
                // Moved here from Experimental.
                ThemeSelectorRow(label: L10n.settingsExpAlbumArtResolution,
                                 description: L10n.settingsRowAlbumArtResolutionSubtitle,
                                 options: [SettingsOption(key: "LOW", label: L10n.settingsExpAlbumArtQualityLowLine),
                                           SettingsOption(key: "MEDIUM", label: L10n.settingsExpAlbumArtQualityMediumLine),
                                           SettingsOption(key: "HIGH", label: L10n.settingsExpAlbumArtQualityHighLine),
                                           SettingsOption(key: "ORIGINAL", label: L10n.settingsExpAlbumArtQualityOriginalLine)],
                                 selectedKey: appearance.albumArtQuality, systemImage: "photo") {
                    appearance.albumArtQuality = $0
                }
            }
        }
    }
}

/// The app's localisations (`Bundle.localizations`, Base excluded).
nonisolated enum AppLocalizations {
    static let offersLanguageChoice: Bool = Bundle.main.localizations.filter { $0 != "Base" }.count > 1
}

/// Android `CollagePattern` (storage key, label).
nonisolated enum CollagePatternOption {
    static let all: [SettingsOption] = [
        SettingsOption(key: "cosmic_swirl", label: "Cosmic Swirl"),
        SettingsOption(key: "honeycomb_groove", label: "Honeycomb Groove"),
        SettingsOption(key: "vinyl_stack", label: "Vinyl Stack"),
        SettingsOption(key: "pixel_mosaic", label: "Pixel Mosaic"),
        SettingsOption(key: "stardust_scatter", label: "Stardust Scatter"),
    ]
}
