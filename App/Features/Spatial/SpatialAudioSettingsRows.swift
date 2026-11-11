import PixlModel
import PixlNet
import SwiftUI

/// Settings › Playback › Sound, after Audio quality: Spatial audio's rows (cloud audio spec 6.5; Android
/// `SpatialAudioSettingsRows`, same rows, order and words). The profile row opens the same sheet as the full player;
/// "Cloud renders" writes `spatial.cloud` only, Cloud Studio's own master switch stays on the Cloud processing screen,
/// and while that one is off a row says so and leads there (spec 6.1 "Two switches"). Every row only writes a setting
/// through `env.spatial`. Several rows, laid out by the section's group like its other rows.
struct SpatialAudioSettingsRows: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var confirmsRemove = false

    var body: some View {
        let spatial = env.spatial
        let ui = SpatialSettingsUI.of(settings: spatial.settings, usage: spatial.usage,
                                      cloudRendersOn: spatial.cloudRendersOn, isRemoving: spatial.isRemovingRenders)
        SettingsItemRow(title: L10n.spatialAudio, subtitle: ui.profileSubtitle, systemImage: SpatialAudioUI.symbol,
                        showsChevron: true, identifier: "settings.spatial.profile") {
            router.present(AppSheet.spatialAudio(fromPlayer: false))
        }
        SwitchSettingRow(title: L10n.spatialSettingsCloudTitle, subtitle: L10n.spatialSettingsCloudSubtitle,
                         isOn: Binding(get: { spatial.settings.cloud },
                                       set: { isOn in withAnimation(PixlMotion.state) { spatial.setCloud(isOn) } }),
                         systemImage: "cloud")
        if ui.masterOff {
            // The switch above is on, but Cloud Studio's own "Process songs in the cloud" is off: say so, and lead there
            // instead of looking switched on and doing nothing. The master is never written from here.
            SettingsItemRow(title: L10n.spatialSettingsMasterOffTitle, subtitle: L10n.spatialSettingsMasterOffSubtitle,
                            systemImage: "icloud.slash", iconColor: theme.error, showsChevron: true,
                            identifier: "settings.spatial.masterOff") {
                router.push(.cloudProcessing)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        SwitchSettingRow(title: L10n.spatialSettingsPrepareTitle, subtitle: ui.prepareAheadSubtitle,
                         isOn: Binding(get: { spatial.settings.prepareAhead }, set: { spatial.setPrepareAhead($0) }),
                         systemImage: "sparkles", enabled: ui.prepareAheadEnabled)
        ActionSettingRow(title: ui.songsReadyTitle, subtitle: L10n.spatialSettingsSongsReadySubtitle,
                         systemImage: "internaldrive", primaryLabel: L10n.spatialSettingsRemove,
                         onPrimary: { confirmsRemove = true }, enabled: ui.canRemove)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.spatial.songsReady")
            .alert(L10n.spatialSettingsRemoveConfirmTitle, isPresented: $confirmsRemove) {
                Button(L10n.commonRemove, role: .destructive) {
                    Task { await spatial.removeDownloadedRenders() }
                }
                Button(L10n.commonCancel, role: .cancel) {}
            } message: {
                Text(L10n.spatialSettingsRemoveConfirmText)
            }
            // What the phone holds, asked again each time the page shows (the library answers from memory).
            .task { await spatial.refreshUsage() }
    }
}

/// Settings › Playback › Advanced (Developer mode only), Spatial audio's rows (spec 6.5; Android
/// `SpatialAudioDeveloperRows`): route mode, the monthly limit of library jobs, the storage budget, songs a day ahead,
/// and the diagnostics of the playing song. Hiding them never changes the values behind them (a stored `always` route is
/// honoured either way, spec 6.1).
struct SpatialAudioDeveloperRows: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let spatial = env.spatial
        let settings = spatial.settings
        ThemeSelectorRow(label: L10n.spatialDevRouteTitle, description: L10n.spatialDevRouteSubtitle,
                         options: [SettingsOption(key: SpatialRouteMode.headphones.rawValue,
                                                  label: L10n.spatialDevRouteHeadphones),
                                   SettingsOption(key: SpatialRouteMode.always.rawValue, label: L10n.spatialDevRouteAlways)],
                         selectedKey: settings.route.rawValue, systemImage: "headphones") { key in
            spatial.setRoute(SpatialRouteMode(storageValue: key))
        }
        ThemeSelectorRow(label: L10n.spatialDevCapTitle,
                         description: L10n.spatialDevCapSubtitle(CloudCost.format(microUSD: spatial.usage.spentThisMonthMicroUSD)),
                         options: SpatialCapOptions.options(stored: settings.monthlyCapUSD),
                         selectedKey: SpatialCapOptions.key(of: settings.monthlyCapUSD),
                         systemImage: "dollarsign.circle") { key in
            if let pick = SpatialCapOptions.pick(key) { spatial.setMonthlyCapUSD(pick.usd) }
        }
        SpatialStorageBudgetRow(storedMB: settings.storageMB) { spatial.setStorageMB($0) }
        SpatialDailyAheadRow(stored: settings.dailyAhead, sentToday: spatial.usage.sentToday) { spatial.setDailyAhead($0) }
        SpatialDiagnosticsPanel()
    }
}

/// The storage budget: a slider over fixed stops (256 MB … 64 GB) that follows the finger here and writes once it lets
/// go (nothing is written while dragging).
private struct SpatialStorageBudgetRow: View {
    let storedMB: Int
    let onCommit: (Int) -> Void

    @State private var position: Double

    init(storedMB: Int, onCommit: @escaping (Int) -> Void) {
        self.storedMB = storedMB
        self.onCommit = onCommit
        _position = State(initialValue: Double(SpatialStorageStops.index(ofStored: storedMB)))
    }

    var body: some View {
        SpatialSliderRow(title: L10n.spatialDevStorageTitle,
                         valueText: SpatialFormat.storage(megabytes: SpatialStorageStops.megabytes(at: position)),
                         caption: L10n.spatialDevStorageCaption, systemImage: "internaldrive",
                         value: $position, range: 0...Double(SpatialStorageStops.lastIndex), step: 1) {
            let picked = SpatialStorageStops.megabytes(at: position)
            if picked != storedMB { onCommit(picked) }
        }
        .onChange(of: storedMB) { _, stored in
            position = Double(SpatialStorageStops.index(ofStored: stored))
        }
    }
}

/// Songs a day ahead (1 … 100) and how many were sent today.
private struct SpatialDailyAheadRow: View {
    let stored: Int
    let sentToday: Int
    let onCommit: (Int) -> Void

    @State private var position: Double

    init(stored: Int, sentToday: Int, onCommit: @escaping (Int) -> Void) {
        self.stored = stored
        self.sentToday = sentToday
        self.onCommit = onCommit
        _position = State(initialValue: Double(stored))
    }

    var body: some View {
        SpatialSliderRow(title: L10n.spatialDevDailyTitle, valueText: String(SpatialDailyAhead.songs(at: position)),
                         caption: L10n.spatialDevDailyCaption(sentToday), systemImage: "calendar",
                         value: $position, range: SpatialDailyAhead.range, step: nil) {
            let picked = SpatialDailyAhead.songs(at: position)
            if picked != stored { onCommit(picked) }
        }
        .onChange(of: stored) { _, new in position = Double(new) }
    }
}

/// A settings row with its icon, title and value, a caption under the title and a slider below (Android
/// `SpatialSliderRow`), in the glass of the other rows. `step` nil: continuous.
private struct SpatialSliderRow: View {
    let title: String
    let valueText: String
    let caption: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let onCommit: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                SettingsIcon(systemImage: systemImage)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .pixlFont(.titleMedium)
                            .foregroundStyle(theme.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(valueText)
                            .pixlFont(.bodyMedium, weight: .bold)
                            .foregroundStyle(theme.primary)
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                    Text(caption)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            slider
                .tint(theme.primary)
                // VoiceOver names the setting and reads its value, not a bare percentage.
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(valueText))
        }
        .padding(16)
        .settingsRowGlass()
        .accessibilityIdentifier("settings.spatial.slider.\(title)")
    }

    @ViewBuilder
    private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step) { editing in
                if !editing { onCommit() }
            }
        } else {
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit() }
            }
        }
    }
}

/// The playing song's diagnostics (spec 6.5: rendition, source codec, stem mode, loudness, sample rate), one
/// "label: value" line each; the manifest's facts once the selected profile's render is on the phone.
private struct SpatialDiagnosticsPanel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @State private var rendition: LocalRendition?

    var body: some View {
        let spatial = env.spatial
        let rows = SpatialDiagnostics.rows(snapshot: spatial.snapshot, status: spatial.status, rendition: rendition)
        let key = SpatialDiagnosticsKey(videoId: spatial.snapshot.videoId, selection: spatial.selection,
                                        status: spatial.status)
        HStack(alignment: .top, spacing: 16) {
            SettingsIcon(systemImage: "chart.line.uptrend.xyaxis")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.spatialDevDiagTitle)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                if rows.isEmpty {
                    Text(L10n.spatialDevDiagNothing)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                ForEach(rows) { row in
                    Text(row.label + ": " + row.value)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .settingsRowGlass()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.spatial.diagnostics")
        // The manifest is read from the library (from memory) when the song, the profile or the status changes.
        .task(id: key) {
            guard key.videoId != nil, key.status == .ready, key.selection.isOn else {
                rendition = nil
                return
            }
            let renditions = await spatial.renditionsOfCurrentSong()
            guard !Task.isCancelled else { return }
            rendition = SpatialDiagnostics.currentRendition(among: renditions, selection: key.selection,
                                                            status: key.status)
        }
    }
}

/// What the diagnostics' manifest depends on.
nonisolated struct SpatialDiagnosticsKey: Equatable, Sendable {
    let videoId: String?
    let selection: SpatialSelection
    let status: RenditionStatus
}
