import SwiftUI
import UIKit

/// Settings › Appearance (Android `SettingsCategoryScreen` APPEARANCE): global theme, now playing, home collage,
/// navigation bar, lyrics screen, app navigation.
///
/// Dropped (Material-only, not meaningful with Liquid Glass): album-art palette style (iOS keeps the default
/// TonalSpot scheme), NavBar corner radius, smooth corners (every iOS corner is already continuous).
/// App language opens the system's per-app language setting (iOS apps can't switch language in-app).
struct AppearanceSettingsSection: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var appearance = settings.appearance
        @Bindable var lyrics = settings.lyrics
        @Bindable var behavior = settings.behavior
        SettingsCategoryScaffold(category: .appearance) {
            SettingsSubsection(title: L10n.settingsGlobalThemeSection) {
                SettingsItemRow(title: L10n.settingsAppLanguageTitle, subtitle: L10n.settingsAppLanguageSubtitle,
                                systemImage: "globe", showsChevron: true, identifier: "settings.appearance.language") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                ThemeSelectorRow(label: L10n.settingsAppThemeTitle, description: L10n.settingsAppThemeSubtitle,
                                 options: [SettingsOption(key: AppThemeMode.light.rawValue, label: L10n.settingsThemeLight),
                                           SettingsOption(key: AppThemeMode.dark.rawValue, label: L10n.settingsThemeDark),
                                           SettingsOption(key: AppThemeMode.followSystem.rawValue,
                                                          label: L10n.settingsThemeFollowSystem)],
                                 selectedKey: appearance.appThemeMode.rawValue, systemImage: "sun.max") {
                    appearance.appThemeMode = AppThemeMode(rawValue: $0) ?? .followSystem
                }
                SwitchSettingRow(title: L10n.settingsDisableBlurAllOverTitle,
                                 subtitle: L10n.settingsDisableBlurAllOverSubtitle,
                                 isOn: $appearance.disableBlurAllOver, systemImage: "circle.dotted")
                SwitchSettingRow(title: L10n.settingsShowScrollbarTitle, subtitle: L10n.settingsShowScrollbarSubtitle,
                                 isOn: $appearance.showScrollbar, systemImage: "arrow.up.and.down")
            }
            SettingsSubsection(title: L10n.settingsNowPlayingSection) {
                ThemeSelectorRow(label: L10n.settingsPlayerThemeTitle, description: L10n.settingsPlayerThemeSubtitle,
                                 options: [SettingsOption(key: PlayerThemePreference.albumArt.rawValue,
                                                          label: L10n.settingsPlayerThemeAlbumArt),
                                           SettingsOption(key: PlayerThemePreference.dynamic.rawValue,
                                                          label: L10n.settingsPlayerThemeDynamic)],
                                 selectedKey: appearance.playerTheme.rawValue, systemImage: "play.circle") {
                    appearance.playerTheme = PlayerThemePreference(rawValue: $0) ?? .albumArt
                }
                SwitchSettingRow(title: L10n.settingsShowPlayerFileInfoTitle,
                                 subtitle: L10n.settingsShowPlayerFileInfoSubtitle,
                                 isOn: $appearance.fullPlayerShowFileInfo, systemImage: "paperclip")
                ThemeSelectorRow(label: L10n.settingsCarouselStyleTitle, description: L10n.settingsCarouselStyleSubtitle,
                                 options: [SettingsOption(key: "no_peek", label: L10n.settingsCarouselNoPeek),
                                           SettingsOption(key: "one_peek", label: L10n.settingsCarouselOnePeek)],
                                 selectedKey: appearance.carouselStyle, systemImage: "square.stack") {
                    appearance.carouselStyle = $0
                }
            }
            SettingsSubsection(title: L10n.settingsHomeCollageSection) {
                ThemeSelectorRow(label: L10n.settingsCollagePatternTitle,
                                 description: L10n.settingsCollagePatternSubtitle,
                                 options: CollagePatternOption.all, selectedKey: appearance.collagePattern,
                                 systemImage: "rectangle.split.3x1") { appearance.collagePattern = $0 }
                SwitchSettingRow(title: L10n.settingsAutoRotatePatternsTitle,
                                 subtitle: L10n.settingsAutoRotatePatternsSubtitle,
                                 isOn: $appearance.collageAutoRotate, systemImage: "shuffle")
            }
            // The iOS-style tab bar has one shape, so Android's NavBar Style choice (default / full width) is gone;
            // compact mode still applies (icons only, shorter bar). `navBarStyle` stays stored for backups.
            SettingsSubsection(title: L10n.settingsNavigationBarSection) {
                SwitchSettingRow(title: L10n.settingsCompactModeTitle, subtitle: L10n.settingsCompactModeSubtitle,
                                 isOn: $appearance.navBarCompactMode, systemImage: "dock.rectangle")
            }
            SettingsSubsection(title: L10n.settingsLyricsScreenSection) {
                SwitchSettingRow(title: L10n.settingsImmersiveLyricsTitle, subtitle: L10n.settingsImmersiveLyricsSubtitle,
                                 isOn: $lyrics.immersiveLyricsEnabled, systemImage: "quote.bubble")
                if lyrics.immersiveLyricsEnabled {
                    ThemeSelectorRow(label: L10n.settingsAutoHideDelayTitle,
                                     description: L10n.settingsAutoHideDelaySubtitle,
                                     options: [SettingsOption(key: "3000", label: L10n.settingsAutoHideDelay3s),
                                               SettingsOption(key: "4000", label: L10n.settingsAutoHideDelay4s),
                                               SettingsOption(key: "5000", label: L10n.settingsAutoHideDelay5s),
                                               SettingsOption(key: "6000", label: L10n.settingsAutoHideDelay6s)],
                                     selectedKey: String(lyrics.immersiveLyricsTimeoutMs), systemImage: "timer") {
                        lyrics.immersiveLyricsTimeoutMs = Int($0) ?? 4000
                    }
                }
            }
            SettingsSubsection(title: L10n.settingsAppNavigationSection, addBottomSpace: false) {
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
            }
        }
        .animation(PixlMotion.state, value: lyrics.immersiveLyricsEnabled)
    }
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
