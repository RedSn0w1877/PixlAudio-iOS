import PixlModel
import SwiftUI

/// Settings › Developer Options (Android `SettingsCategoryScreen` DEVELOPER): experiments (Experimental screen, test
/// setup flow), maintenance (daily mix, stats, album palettes), diagnostics (the iOS diagnostics screen, test crash).
struct DeveloperSettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var showsDailyMix = false
    @State private var showsStats = false
    @State private var showsAllPalettes = false
    @State private var showsPaletteSheet = false
    @State private var showsCrash = false
    @State private var bulk: (done: Int, total: Int)?
    @State private var toast: String?

    private var paletteTargets: [Song] {
        library.songs.filter { ArtworkSource(song: $0) != nil }
    }

    var body: some View {
        // Stops at the first song with artwork (the full filter, a URL parse per song, ran twice per body pass).
        let hasPaletteTargets = library.songs.contains { ArtworkSource(song: $0) != nil }
        SettingsCategoryScaffold(category: .developer, toast: $toast) {
            SettingsSubsection(title: L10n.settingsExperimentsSection) {
                SettingsItemRow(title: L10n.settingsExperimentalTitle, subtitle: L10n.settingsExperimentalSubtitle,
                                systemImage: "flask", showsChevron: true,
                                identifier: "settings.developer.experimental") { router.push(.experimental) }
                SettingsItemRow(title: L10n.settingsTestSetupTitle, subtitle: L10n.settingsTestSetupSubtitle,
                                systemImage: "flask", iconColor: theme.tertiary) {
                    settings.behavior.initialSetupDone = false
                    router.present(AppCover.setup)
                }
            }
            SettingsSubsection(title: L10n.settingsMaintenanceSection) {
                ActionSettingRow(title: L10n.settingsForceDailyMixTitle, subtitle: L10n.settingsForceDailyMixSubtitle,
                                 systemImage: "slider.horizontal.3",
                                 primaryLabel: L10n.settingsActionRegenerateDailyMix) { showsDailyMix = true }
                ActionSettingRow(title: L10n.settingsForceStatsTitle, subtitle: L10n.settingsForceStatsSubtitle,
                                 systemImage: "chart.line.uptrend.xyaxis",
                                 primaryLabel: L10n.settingsActionRegenerateStats) { showsStats = true }
                ActionSettingRow(title: L10n.settingsForcePaletteTitle,
                                 subtitle: hasPaletteTargets ? L10n.settingsForcePaletteSubtitle
                                                             : L10n.settingsForcePaletteEmpty,
                                 systemImage: "paintbrush",
                                 primaryLabel: bulk != nil ? L10n.settingsRegenerating : L10n.settingsActionRegenerateAll,
                                 onPrimary: { showsAllPalettes = true },
                                 secondaryLabel: L10n.settingsActionChooseSong,
                                 onSecondary: { showsPaletteSheet = true },
                                 enabled: hasPaletteTargets && bulk == nil)
            }
            SettingsSubsection(title: L10n.settingsDiagnosticsSection, addBottomSpace: false) {
                SettingsItemRow(title: L10n.settingsDiagnosticsSection,
                                subtitle: "Engine, library and playback self-checks for this iPhone.",
                                systemImage: "stethoscope", showsChevron: true,
                                identifier: "settings.diagnostics") { router.push(.diagnostics) }
                // Stage 11 (Android: the Spotify dashboard's YouTube card and "Test playback"; until the Accounts
                // screen lands, they are reachable here too).
                SettingsItemRow(title: "YouTube account", subtitle: "Sign in so streamed songs play reliably.",
                                systemImage: "play.circle", showsChevron: true,
                                identifier: "settings.youTubeLogin") { router.push(.youTubeLogin) }
                SettingsItemRow(title: "Test playback", subtitle: "Walk one streamed song through every step.",
                                systemImage: "ladybug", showsChevron: true,
                                identifier: "settings.playbackDiagnostics") { router.push(.playbackDiagnostics) }
                SettingsItemRow(title: L10n.settingsTriggerCrashTitle, subtitle: L10n.settingsTriggerCrashSubtitle,
                                systemImage: "exclamationmark.triangle", iconColor: theme.error) { showsCrash = true }
            }
        }
        .alert(L10n.settingsDialogRegenerateDailyMixTitle, isPresented: $showsDailyMix) {
            Button(L10n.commonCancel, role: .cancel) {}
            Button(L10n.settingsActionRegenerate) {
                NotificationCenter.default.post(name: .settingsRegenerateDailyMix, object: nil)
                toast = L10n.settingsToastDailyMixRegenerationStarted
            }
        } message: { Text(L10n.settingsDialogRegenerateDailyMixBody) }
        .alert(L10n.settingsDialogRegenerateStatsTitle, isPresented: $showsStats) {
            Button(L10n.commonCancel, role: .cancel) {}
            Button(L10n.settingsActionRegenerate) {
                NotificationCenter.default.post(name: .settingsRegenerateStats, object: nil)
                toast = L10n.settingsToastStatsRegenerationStarted
            }
        } message: { Text(L10n.settingsDialogRegenerateStatsBody) }
        .alert(L10n.settingsDialogRegeneratePalettesTitle, isPresented: $showsAllPalettes) {
            Button(L10n.commonCancel, role: .cancel) {}
            Button(L10n.settingsActionRegenerate) { regenerateAll() }
        } message: { Text(L10n.settingsDialogRegeneratePalettesBody(paletteTargets.count)) }
        .alert(L10n.settingsTriggerCrashTitle, isPresented: $showsCrash) {
            Button(L10n.commonCancel, role: .cancel) {}
            Button(L10n.settingsTriggerCrashTitle, role: .destructive) { fatalError("PixlAudio test crash") }
        }
        .sheet(isPresented: $showsPaletteSheet) {
            PaletteRegenerateSheet(songs: paletteTargets) { song in
                let ok = await regenerate(song)
                toast = ok ? L10n.settingsDialogPaletteRegenerated(song.title)
                           : L10n.settingsDialogPaletteRegenerateFailed(song.title)
                return ok
            }
            .pixlSheet(detents: [.large])
        }
        .overlay(alignment: .top) {
            if let bulk {
                Text(L10n.settingsDialogPaletteProgressFormat(bulk.done, bulk.total))
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
                    .padding(12)
                    .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.bar))
            }
        }
    }

    private func regenerate(_ song: Song) async -> Bool {
        guard let source = ArtworkSource(song: song) else { return false }
        let extractor = environment.colorExtractor
        await extractor.invalidate(source)
        let pair = await extractor.schemePair(for: source, style: settings.appearance.paletteStyle,
                                              accuracyLevel: settings.appearance.colorAccuracy)
        return pair != nil
    }

    private func regenerateAll() {
        let targets = paletteTargets
        bulk = (0, targets.count)
        Task {
            var success = 0
            for (index, song) in targets.enumerated() {
                if await regenerate(song) { success += 1 }
                bulk = (index + 1, targets.count)
            }
            bulk = nil
            toast = success == targets.count ? L10n.settingsToastRegeneratedPalettesAll(success)
                                             : L10n.settingsToastRegeneratedPalettesPartial(success, targets.count)
        }
    }
}

extension Notification.Name {
    /// Developer › Maintenance asks Home (stage 7b) to rebuild the Daily Mix now.
    static let settingsRegenerateDailyMix = Notification.Name("PixlAudio.settings.regenerateDailyMix")
    /// Developer › Maintenance asks Stats (stage 7b) to drop its cache and recompute.
    static let settingsRegenerateStats = Notification.Name("PixlAudio.settings.regenerateStats")
}

/// Android `PaletteRegenerateSongSheetContent`: title, hint, search field, and the matching songs (12 pt cards).
struct PaletteRegenerateSheet: View {
    let songs: [Song]
    let onSelect: (Song) async -> Bool

    @State private var query = ""
    @State private var isRunning = false
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var filtered: [Song] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return songs }
        return songs.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.displayArtist.localizedCaseInsensitiveContains(q)
                || $0.album.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.settingsForcePaletteTitle).pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
            Text(L10n.settingsForcePalettePartialHint).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
            SettingsTextField(placeholder: L10n.settingsSearchTitleArtistAlbumPlaceholder, text: $query)
                .disabled(isRunning)
            if isRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.settingsPaletteRegeneratingProgress)
                        .pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
                }
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    if filtered.isEmpty {
                        Text(L10n.settingsSearchNoSongsMatch)
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pixlGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                                       tint: theme.surfaceContainer.opacity(SettingsTint.row))
                    }
                    ForEach(filtered) { song in
                        Button {
                            guard !isRunning else { return }
                            isRunning = true
                            Task {
                                let ok = await onSelect(song)
                                isRunning = false
                                if ok { dismiss() }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title).pixlFont(.titleSmall).foregroundStyle(theme.onSurface).lineLimit(1)
                                Text(song.displayArtist).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
                                    .lineLimit(1)
                                if !song.album.isEmpty {
                                    Text(song.album).pixlFont(.bodySmall)
                                        .foregroundStyle(theme.onSurfaceVariant.opacity(0.8)).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .pixlGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                                   tint: theme.surfaceContainer.opacity(SettingsTint.row), interactive: true)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
    }
}
