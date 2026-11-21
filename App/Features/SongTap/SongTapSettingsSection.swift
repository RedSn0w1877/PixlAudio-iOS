import PixlLibrary
import SwiftUI

/// Settings › Song Tap (Android `SettingsSongTap`): the "Allow Song Tap" switch (off by default; the player's menu turns it on
/// too, and the system asks for Bluetooth only when Song Tap is first used), "Your name" (what other phones show, 1 to 20
/// characters), Sensitivity (Normal or High, the default, applied live), a row that opens the screen, and, with Developer mode on,
/// the diagnostics page.
struct SongTapSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var appSettings
    @Environment(Router.self) private var router
    @State private var editsName = false
    @State private var draft = ""

    var body: some View {
        let controller = env.songTap
        SettingsCategoryScaffold(category: .songTap) {
            SettingsSubsection(title: SongTapStrings.title) {
                SwitchSettingRow(title: SongTapStrings.allowTitle, subtitle: SongTapStrings.allowSubtitle,
                                 isOn: Binding(get: { controller.allowed }, set: { controller.setAllowed($0) }),
                                 systemImage: "iphone.radiowaves.left.and.right")
                SettingsItemRow(title: SongTapStrings.nameTitle, subtitle: SongTapStrings.nameSubtitle(controller.name),
                                systemImage: "person.crop.circle", showsChevron: true, identifier: "settings.songTap.name") {
                    draft = controller.name
                    editsName = true
                }
                ThemeSelectorRow(label: SongTapStrings.sensitivityTitle,
                                 description: SongTapStrings.sensitivitySubtitle(SongTapStrings.sensitivityName(controller.sensitivity)),
                                 options: SongTapSensitivity.allCases.map { SettingsOption(key: $0.code, label: SongTapStrings.sensitivityName($0)) },
                                 selectedKey: controller.sensitivity.code, systemImage: "hand.tap") { key in
                    controller.setSensitivity(SongTapSensitivity.fromCode(key))
                }
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
        .alert(SongTapStrings.nameDialogTitle, isPresented: $editsName) {
            TextField(SongTapStrings.nameTitle, text: $draft)
            Button(SongTapStrings.nameSave) { controller.setName(draft) }
            Button(SongTapStrings.nameUseDevice) { controller.setName("") }
            Button(SongTapStrings.dropArmedCancel, role: .cancel) {}
        } message: {
            Text(SongTapStrings.nameDialogBody + "\n" + SongTapStrings.nameCounter(SongTapNames.clean(draft).unicodeScalars.count, SongTapNames.maxChars))
        }
        .onChange(of: draft) { _, new in
            // At most 20 characters (Unicode scalars, the same count as the other phone's), never more in the field.
            if new.unicodeScalars.count > SongTapNames.maxChars {
                draft = String(String.UnicodeScalarView(new.unicodeScalars.prefix(SongTapNames.maxChars)))
            }
        }
    }
}
