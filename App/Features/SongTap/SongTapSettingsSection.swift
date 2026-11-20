import SwiftUI

/// Settings › Song Tap (Android `SettingsSongTap`): the "Allow Song Tap" switch (off by default; the player's menu turns it on
/// too, and the system asks for Bluetooth only when Song Tap is first used), a row that opens the screen, and, with Developer
/// mode on, the diagnostics page.
struct SongTapSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var appSettings
    @Environment(Router.self) private var router

    var body: some View {
        let controller = env.songTap
        SettingsCategoryScaffold(category: .songTap) {
            SettingsSubsection(title: SongTapStrings.title) {
                SwitchSettingRow(title: SongTapStrings.allowTitle, subtitle: SongTapStrings.allowSubtitle,
                                 isOn: Binding(get: { controller.allowed }, set: { controller.setAllowed($0) }),
                                 systemImage: "iphone.radiowaves.left.and.right")
                SettingsItemRow(title: SongTapStrings.settingsOpen, subtitle: SongTapStrings.settingsOpenSubtitle,
                                systemImage: "qrcode", showsChevron: true, identifier: "settings.songTap.open") {
                    router.present(AppCover.songTap)
                }
                if appSettings.experimental.developerMode {
                    SettingsItemRow(title: SongTapStrings.diagTitle, subtitle: SongTapStrings.diagSettingsSubtitle,
                                    systemImage: "waveform.path.ecg", showsChevron: true, identifier: "settings.songTap.diagnostics") {
                        router.push(.songTapDiagnostics)
                    }
                }
            }
        }
    }
}
