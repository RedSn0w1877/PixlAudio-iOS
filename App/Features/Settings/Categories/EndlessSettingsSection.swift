import PixlLibrary
import SwiftUI

/// Settings › Endless Listening (Android `SettingsCategory.ENDLESS`): Host notes (on), Spoken host notes (off), Test the voice, How it works;
/// and, in developer mode only, the host voice log (the last 20 decisions, for calibrating the host on a real phone). A category of its
/// own so it shows without developer mode.
struct EndlessSettingsSection: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(SettingsStore.self) private var settings
    @State private var testing = false
    @State private var showsLog = false
    @State private var toast: String?

    var body: some View {
        @Bindable var endless = env.endless
        let developerMode = settings.experimental.developerMode
        SettingsCategoryScaffold(category: .endless, toast: $toast) {
            SettingsSubsection(title: EndlessStrings.settingsTitle, addBottomSpace: developerMode) {
                SwitchSettingRow(title: EndlessStrings.settingsHostNotes, subtitle: EndlessStrings.settingsHostNotesSummary,
                                 isOn: $endless.hostNotesEnabled, systemImage: "text.bubble")
                SwitchSettingRow(title: EndlessStrings.settingsSpoken, subtitle: EndlessStrings.settingsSpokenSummary,
                                 isOn: $endless.spokenNotesEnabled, systemImage: "waveform", enabled: endless.hostNotesEnabled)
                SettingsItemRow(title: EndlessStrings.settingsVoiceTest,
                                subtitle: testing ? EndlessStrings.settingsVoiceTestRunning : EndlessStrings.settingsVoiceTestSummary,
                                systemImage: "speaker.wave.2", identifier: "settings.endless.testVoice") { testVoice() }
                SettingsItemRow(title: EndlessStrings.settingsHow, subtitle: EndlessStrings.settingsHowSummary,
                                systemImage: "hand.tap", showsChevron: true,
                                identifier: "settings.endless.howItWorks") { router.present(AppCover.endlessIntro) }
            }
            SettingsAdvancedSubsection {
                SettingsItemRow(title: EndlessStrings.settingsVoiceLog, subtitle: EndlessStrings.settingsVoiceLogSummary,
                                systemImage: "ladybug", showsChevron: true,
                                identifier: "settings.endless.voiceLog") { showsLog = true }
            }
        }
        .sheet(isPresented: $showsLog) { HostVoiceLogSheet(voice: env.endless.voice) }
    }

    /// Says the sample (the one place the system voice starts because the person asked) and tells in plain words when it could not.
    private func testVoice() {
        guard !testing else { return }
        guard let voice = env.endless.voice else {
            toast = EndlessStrings.voiceTestNone
            return
        }
        testing = true
        Task {
            let result = await voice.testVoice()
            testing = false
            switch result {
            case .spoke: break
            case .noVoice: toast = EndlessStrings.voiceTestNone
            case .busy: toast = EndlessStrings.voiceTestBusy
            case .inCall: toast = EndlessStrings.voiceTestCall
            case .error: toast = EndlessStrings.voiceTestError
            }
        }
    }
}

/// The last 20 decisions of the spoken host, newest first: what was said or skipped, and why. Read when opened; nothing is kept on disk.
private struct HostVoiceLogSheet: View {
    let voice: HostVoiceController?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        let log = voice?.log ?? []
        NavigationStack {
            Group {
                if log.isEmpty {
                    Text(EndlessStrings.voiceLogEmpty)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(Array(log.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Date(timeIntervalSince1970: Double(entry.atMs) / 1000).formatted(date: .omitted, time: .standard))
                                .pixlFont(.labelSmall)
                                .foregroundStyle(theme.onSurfaceVariant)
                            Text(HostVoiceLog.describe(entry))
                                .pixlFont(.bodyMedium)
                                .foregroundStyle(theme.onSurface)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(EndlessStrings.settingsVoiceLog)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(EndlessStrings.voiceLogClose) { dismiss() } }
            }
        }
        .accessibilityIdentifier("settings.endless.voiceLogSheet")
    }
}
