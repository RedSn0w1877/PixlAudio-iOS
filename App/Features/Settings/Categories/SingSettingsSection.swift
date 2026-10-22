import SwiftUI

/// Settings › Sing (a category of its own since the 2026-10-22 reorganisation, on Android too): the "Ready when you
/// play" card (automatic instrumentals, moved here from AI features), and the Cloud rows — the Cloud processing screen
/// and the Cloud queue (the "Cloud processing" row left Experimental). In developer mode an "Advanced" block adds
/// automatic lyric sync, the studio's live status with its queue notes, and the on-device models.
struct SingSettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var lyrics = settings.lyrics
        @Bindable var playback = settings.playback
        let developerMode = settings.experimental.developerMode
        let cloud = env.cloud
        SettingsCategoryScaffold(category: .sing) {
            AutomaticInstrumentalsCard()
            Spacer().frame(height: 20)
            SettingsSubsection(title: L10n.settingsSectionCloud, addBottomSpace: developerMode) {
                SettingsItemRow(title: L10n.settingsSingCloudTitle,
                                subtitle: cloud.settings.isEnabled ? L10n.settingsSingCloudOn : L10n.settingsSingCloudOff,
                                systemImage: "icloud.and.arrow.up", showsChevron: true,
                                identifier: "settings.sing.cloudProcessing") { router.push(.cloudProcessing) }
                SettingsItemRow(title: L10n.settingsSingQueueTitle,
                                subtitle: cloud.summaryLine ?? L10n.settingsSingQueueFallback,
                                systemImage: "tray.full", showsChevron: true,
                                identifier: "settings.sing.cloudQueue") { router.push(.cloudQueue) }
            }
            SettingsAdvancedSubsection(addBottomSpace: true) {
                SwitchSettingRow(title: "Automatic lyric sync", subtitle: "Looks for word timings first.",
                                 isOn: $lyrics.automaticLyrics, systemImage: "quote.bubble")
                AutomaticStudioStatusPanel()
            }
            if developerMode {
                OnDeviceModelsPanel(tintStrength: SettingsTint.row)
            }
        }
        .onChange(of: lyrics.automaticLyrics) { _, _ in env.automaticStudio.scanNow() }
        .onChange(of: playback.automaticInstrumentals) { _, _ in env.automaticStudio.scanNow() }
    }
}

/// Android `AutomaticStudioSettingsCard` (tertiary-container card), the everyday half: automatic instrumentals, run by
/// `AutomaticStudioRunner` while PixlAudio is open (iOS gives apps no dependable background processing time). The
/// automatic lyric sync switch and the runner's status sit in Advanced (`AutomaticStudioStatusPanel`).
struct AutomaticInstrumentalsCard: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme

    var body: some View {
        @Bindable var playback = settings.playback
        GlassCard(cornerRadius: 28, tint: theme.tertiaryContainer) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.settingsSectionReady).pixlFont(.headlineSmall).foregroundStyle(theme.onTertiaryContainer)
                Text(L10n.settingsSingReadyBody).pixlFont(.bodyMedium).foregroundStyle(theme.onTertiaryContainer)
                HStack(spacing: 12) {
                    VStack(alignment: .leading) {
                        Text(L10n.settingsSingAutomaticTitle).pixlFont(.titleMedium).foregroundStyle(theme.onTertiaryContainer)
                        Text(L10n.settingsSingAutomaticSubtitle).pixlFont(.bodySmall).foregroundStyle(theme.onTertiaryContainer)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(L10n.settingsSingAutomaticTitle, isOn: $playback.automaticInstrumentals)
                        .labelsHidden()
                        .tint(theme.tertiary)
                        .accessibilityIdentifier("sing.automaticInstrumentals")
                }
                .frame(minHeight: 64)
                Text(L10n.settingsSingManualNote).pixlFont(.bodySmall).foregroundStyle(theme.onTertiaryContainer)
            }
            .padding(20)
        }
    }
}

/// The studio's live status and its queue notes (developer mode): what the automatic runner is doing, why it waits,
/// and "Check queue now".
struct AutomaticStudioStatusPanel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme
    @State private var showsDetails = false

    var body: some View {
        let lyrics = settings.lyrics, playback = settings.playback
        let automatic = lyrics.automaticLyrics || playback.automaticInstrumentals
        SettingsPanel {
            Text(automatic ? env.automaticStudio.status : "Off")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surfaceContainerHighest.opacity(0.8),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityIdentifier("ai.automaticStudio.status")
            SettingsFillButton(title: showsDetails ? "Hide queue details" : "Queue and diagnostics", style: .tonal) {
                showsDetails.toggle()
            }
            if showsDetails {
                Text("Runs while PixlAudio is open and nothing is playing, one song at a time, at most 8 songs every 6 hours. It waits during playback, below 40% battery unless charging, while the phone is hot or short of storage, and while you process songs by hand; songs over 6 minutes stay manual. It starts once the lyric sync or instrumental model is on this iPhone.")
                    .pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
                SettingsFillButton(title: "Check queue now", style: .outlined, enabled: automatic) {
                    env.automaticStudio.scanNow()
                }
            }
        }
        .animation(PixlMotion.state, value: showsDetails)
    }
}
