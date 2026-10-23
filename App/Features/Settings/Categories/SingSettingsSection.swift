import PixlNet
import SwiftUI

/// Settings › Sing (a category of its own since the 2026-10-22 reorganisation, on Android too): the "Ready when you
/// play" card (automatic instrumentals, moved here from AI features), "Prepare ahead" (the cloud gets songs ready on
/// Wi-Fi: a switch, a monthly budget and a status line), and the Cloud rows — the Cloud processing screen and the Cloud
/// queue (the "Cloud processing" row left Experimental). In developer mode an "Advanced" block adds automatic lyric
/// sync, the studio's live status with its queue notes, the daily cap and the reasons behind the picked songs, and the
/// on-device models.
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
            SingPrepareAheadSection()
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
                SingPrepareDailyCapRow()
                SingPrepareWhyPanel()
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

// MARK: - Prepare ahead (2026-10-22)

/// Settings › Sing › Prepare ahead: PixlAudio picks songs you're likely to sing and has the cloud get them ready while
/// you're on Wi-Fi. Off until the person turns it on (the one way the cloud is used without a tap on a song); once on, the
/// monthly budget and the runner's status line show. The runner (`env.cloud.autoPrepare`) reads the switch, the budget
/// and the cap from `CloudSettings` itself.
struct SingPrepareAheadSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let cloud = env.cloud
        @Bindable var prepare = cloud.settings
        let enabled = prepare.autoPrepareEnabled
        // The slider tops out at $3.00, or at the monthly cap when that is lower; a budget above it shows as the top.
        let ceiling = SingPrepareControls.budgetCeiling(capMicroUSD: prepare.effectiveMonthlyCapMicroUSD)
        let budget = min(max(prepare.autoPrepareBudgetMicroUSD, 0), ceiling)
        SettingsSubsection(title: L10n.settingsSectionPrepareAhead) {
            SwitchSettingRow(title: L10n.settingsSingPrepareTitle, subtitle: L10n.settingsSingPrepareSubtitle,
                             isOn: $prepare.autoPrepareEnabled, systemImage: "wand.and.stars")
            if enabled {
                AIParameterRow(label: L10n.settingsSingPrepareBudgetTitle,
                               value: Binding(get: { SingPrepareControls.dollars(budget) },
                                              set: { prepare.autoPrepareBudgetMicroUSD = SingPrepareControls.snappedBudget(
                                                  dollars: $0, ceilingMicroUSD: ceiling) }),
                               range: 0...SingPrepareControls.dollars(ceiling),
                               steps: SingPrepareControls.budgetSliderSteps(ceilingMicroUSD: ceiling),
                               help: L10n.settingsSingPrepareSongsPerMonth(
                                   CloudAutoBudget.songsPerMonth(budgetMicroUSD: budget))) {
                    CloudCost.format(microUSD: SingPrepareControls.snappedBudget(dollars: $0, ceilingMicroUSD: ceiling))
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                if let line = cloud.autoPrepare?.statusLine, !line.isEmpty {
                    SingPrepareStatusRow(text: line)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(PixlMotion.state, value: enabled)
    }
}

/// The runner's status line ("3 songs today · $0.12 of $1.00 this month", "Waiting for Wi-Fi").
private struct SingPrepareStatusRow: View {
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemImage: "info.circle")
                .padding(.trailing, 4)
            Text(text)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .settingsRowGlass()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.sing.prepareStatus")
    }
}

/// Developer mode: the most songs prepared in one day (1–30, default 12).
struct SingPrepareDailyCapRow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var prepare = env.cloud.settings
        let range = SingPrepareControls.dailyCapRange
        AIParameterRow(label: L10n.settingsSingPrepareDailyCapTitle,
                       value: Binding(get: { Double(SingPrepareControls.clampedDailyCap(prepare.autoPrepareDailyCap)) },
                                      set: { prepare.autoPrepareDailyCap = SingPrepareControls.dailyCap(fromSlider: $0) }),
                       range: Double(range.lowerBound)...Double(range.upperBound),
                       steps: range.count - 2,
                       help: L10n.settingsSingPrepareDailyCapHelp) { "\(Int($0.rounded()))" }
    }
}

/// Developer mode: why the runner picked the songs it did (its latest ranked list, one line each).
struct SingPrepareWhyPanel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme

    var body: some View {
        let lines = env.cloud.autoPrepare?.whyLines ?? []
        SettingsPanel(spacing: 8) {
            Text(L10n.settingsSingPrepareWhyTitle)
                .pixlFont(.titleMedium)
                .foregroundStyle(theme.onSurface)
            if lines.isEmpty {
                Text(L10n.settingsSingPrepareWhyEmpty)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityIdentifier("settings.sing.prepareWhy")
    }
}

/// The numbers behind the Prepare ahead rows, apart from the views so they can be tested: the budget slider moves in
/// quarter-dollar steps from $0 to $3 (or to the monthly cap when that is lower), the daily cap from 1 to 30.
nonisolated enum SingPrepareControls {
    static let budgetStepMicroUSD: Int64 = 250_000
    static let budgetMaxMicroUSD: Int64 = 3_000_000
    static let dailyCapRange = 1...30

    /// The slider's top end in µ$: $3.00, or the cap rounded down to a step when it is lower (never below one step).
    static func budgetCeiling(capMicroUSD: Int64) -> Int64 {
        let capped = min(max(capMicroUSD, 0), budgetMaxMicroUSD)
        return max(capped / budgetStepMicroUSD, 1) * budgetStepMicroUSD
    }

    /// `SliderSettingRow`'s intermediate stops for that top end (one stop per step, so the slider lands on whole steps).
    static func budgetSliderSteps(ceilingMicroUSD: Int64) -> Int {
        max(Int(ceilingMicroUSD / budgetStepMicroUSD) - 1, 0)
    }

    static func dollars(_ microUSD: Int64) -> Double { Double(microUSD) / 1_000_000 }

    /// What the slider reports (dollars), as µ$ on a whole step inside 0...ceiling.
    static func snappedBudget(dollars: Double, ceilingMicroUSD: Int64) -> Int64 {
        guard dollars.isFinite else { return 0 }
        let steps = (dollars * 1_000_000 / Double(budgetStepMicroUSD)).rounded()
        return min(max(Int64(steps) * budgetStepMicroUSD, 0), ceilingMicroUSD)
    }

    static func clampedDailyCap(_ value: Int) -> Int {
        min(max(value, dailyCapRange.lowerBound), dailyCapRange.upperBound)
    }

    /// What the daily-cap slider reports, as a whole number of songs inside 1...30.
    static func dailyCap(fromSlider value: Double) -> Int {
        guard value.isFinite else { return dailyCapRange.lowerBound }
        return clampedDailyCap(Int(value.rounded()))
    }
}
