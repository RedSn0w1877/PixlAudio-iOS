import SwiftUI

/// Settings › Lyrics (a category of its own since the 2026-10-22 reorganisation, on Android too): how the lyrics
/// screen looks — immersive lyrics with their auto-hide delay, and the blur on the lines that aren't being sung (moved
/// here from Experimental). In developer mode an "Advanced" block adds the lyrics source priority, the tap timing and
/// "Reset imported lyrics" (moved here from Music Management).
struct LyricsSettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var environment

    @State private var showsTapTiming = false
    @State private var showsResetLyrics = false

    var body: some View {
        @Bindable var lyrics = settings.lyrics
        let developerMode = settings.experimental.developerMode
        SettingsCategoryScaffold(category: .lyrics) {
            SettingsSubsection(title: L10n.settingsSectionLyricsScreen, addBottomSpace: developerMode) {
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
                SwitchSettingRow(title: L10n.settingsExpLyricsBlurTitle, subtitle: L10n.settingsRowLyricsBlurSubtitle,
                                 isOn: $lyrics.animatedBlurEnabled, systemImage: "circle.dotted")
                if lyrics.animatedBlurEnabled {
                    SliderSettingRow(label: L10n.settingsExpLyricsBlurStrengthTitle, value: $lyrics.animatedBlurStrength,
                                     range: 0.1...2.0, steps: 10,
                                     valueText: { L10n.settingsExpLyricsBlurStrengthValue($0) })
                }
            }
            SettingsAdvancedSubsection {
                ThemeSelectorRow(label: L10n.settingsLyricsSourcePriorityTitle,
                                 description: L10n.settingsLyricsSourcePrioritySubtitle,
                                 options: [SettingsOption(key: "EMBEDDED_FIRST", label: L10n.settingsLyricsEmbeddedFirst),
                                           SettingsOption(key: "API_FIRST", label: L10n.settingsLyricsOnlineFirst),
                                           SettingsOption(key: "LOCAL_FIRST", label: L10n.settingsLyricsLocalFirst)],
                                 selectedKey: lyrics.sourcePreference, systemImage: "quote.bubble") {
                    lyrics.sourcePreference = $0
                }
                SettingsItemRow(title: L10n.settingsLyricsTapTiming,
                                subtitle: L10n.settingsLyricsTapTimingSub(lyrics.tapOffsetSpeakerMs),
                                systemImage: "hand.tap", identifier: "settings.lyrics.tapTiming") { showsTapTiming = true }
                SettingsItemRow(title: L10n.settingsResetImportedLyricsTitle,
                                subtitle: L10n.settingsResetImportedLyricsSubtitle, systemImage: "text.badge.xmark",
                                identifier: "settings.lyrics.resetLyrics") { showsResetLyrics = true }
            }
        }
        .animation(PixlMotion.state, value: lyrics.immersiveLyricsEnabled)
        .animation(PixlMotion.state, value: lyrics.animatedBlurEnabled)
        .sheet(isPresented: $showsTapTiming) {
            LyricsTapTimingSheet()
        }
        .alert(L10n.settingsDialogResetImportedLyricsTitle, isPresented: $showsResetLyrics) {
            Button(L10n.commonCancel, role: .cancel) {}
            Button(L10n.commonConfirm, role: .destructive) {
                Task { try? await environment.persistence?.settingsDeleteAllLyrics() }
            }
        } message: {
            Text(L10n.settingsDialogResetImportedLyricsBody)
        }
    }
}
