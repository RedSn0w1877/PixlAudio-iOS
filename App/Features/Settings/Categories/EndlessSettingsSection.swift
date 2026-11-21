import SwiftUI

/// Settings › Endless Listening (Android `SettingsCategory.ENDLESS`): the host's notes (on by default) and a row that replays the
/// introduction. A category of its own so it shows without developer mode. The spoken notes come with their own switch later (milestone 2).
struct EndlessSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var endless = env.endless
        SettingsCategoryScaffold(category: .endless) {
            SettingsSubsection(title: EndlessStrings.settingsTitle) {
                SwitchSettingRow(title: EndlessStrings.settingsHostNotes, subtitle: EndlessStrings.settingsHostNotesSummary,
                                 isOn: $endless.hostNotesEnabled, systemImage: "text.bubble")
                SettingsItemRow(title: EndlessStrings.settingsHow, subtitle: EndlessStrings.settingsHowSummary,
                                systemImage: "hand.tap", showsChevron: true,
                                identifier: "settings.endless.howItWorks") { router.present(AppCover.endlessIntro) }
            }
        }
    }
}
