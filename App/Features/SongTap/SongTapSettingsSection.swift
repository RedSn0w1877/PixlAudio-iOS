import SwiftUI

/// Settings › Song Tap (Android `SettingsSongTap`): the "Allow Song Tap" switch (off by default; the player's menu turns it on
/// too, and asks for the permission it needs only when it is first used) and a row that opens the screen.
struct SongTapSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
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
            }
        }
    }
}
