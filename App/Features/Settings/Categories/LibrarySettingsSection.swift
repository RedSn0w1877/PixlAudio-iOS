import SwiftUI

/// Settings › Music Management (Android `SettingsCategoryScreen` LIBRARY): library structure (music folders and
/// exclusions, artists), filtering sliders, sync and scanning, offline storage, lyrics management.
///
/// iOS: Android's storage explorer becomes the music-folder screen (folders the user picks with the system folder
/// picker plus the app's Documents folder, each browsable to exclude sub-folders).
struct LibrarySettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var minDuration: Double = 10_000
    @State private var minTracks: Double = 1
    @State private var cacheLimit: Double = 200
    @State private var showsFolders = false
    @State private var showsTapTiming = false
    @State private var showsResetLyrics = false
    @State private var showsRebuild = false
    @State private var isSyncing = false
    @State private var syncLabel: String?
    @State private var storage: OfflineStorageUsage?
    @State private var toast: String?

    var body: some View {
        @Bindable var lyrics = settings.lyrics
        VStack(alignment: .leading, spacing: 0) {
        SettingsSubsection(title: L10n.settingsLibraryStructureSection) {
            SettingsItemRow(title: L10n.settingsExcludedDirectoriesTitle,
                            subtitle: L10n.settingsExcludedDirectoriesSubtitle, systemImage: "folder",
                            showsChevron: true, identifier: "settings.library.folders") { showsFolders = true }
            SettingsItemRow(title: L10n.settingsArtistsTitle, subtitle: L10n.settingsArtistsSubtitle,
                            systemImage: "person", showsChevron: true,
                            identifier: "settings.library.artists") { router.push(.artistSettings) }
        }
        SettingsSubsection(title: L10n.settingsFilteringSection) {
            SliderSettingRow(label: L10n.settingsMinSongDuration, value: $minDuration, range: 0...120_000, steps: 23,
                             onCommit: { settings.library.minSongDurationMs = Int(minDuration) },
                             valueText: { "\(Int($0 / 1000))s" })
            SliderSettingRow(label: L10n.settingsMinTracksPerAlbum, value: $minTracks, range: 1...5, steps: 3,
                             onCommit: { settings.library.minTracksPerAlbum = Int(minTracks) },
                             valueText: { "\(Int($0))" })
            SliderSettingRow(label: L10n.settingsAlbumArtCacheLimit, value: $cacheLimit, range: 50...1500, steps: 28,
                             onCommit: { settings.library.albumArtCacheLimitMb = Int(cacheLimit) },
                             valueText: { "\(Int($0)) MB" })
        }
        SettingsSubsection(title: L10n.settingsSyncScanningSection) {
            RefreshLibraryRow(isSyncing: isSyncing, label: syncLabel, progress: library.lastImportProgress,
                              onFullSync: startFullRescan, onRebuild: { showsRebuild = true })
            SwitchSettingRow(title: L10n.settingsAutoScanLrcTitle, subtitle: L10n.settingsAutoScanLrcSubtitle,
                             isOn: $lyrics.autoScanLrcFiles, systemImage: "folder")
        }
        SettingsSubsection(title: L10n.settingsStorageSection) {
            let reclaimable = storage?.cachedBytes ?? 0
            ActionSettingRow(
                title: L10n.settingsStorageTitle,
                subtitle: storage.map {
                    L10n.settingsStorageSubtitle(ByteFormat.short($0.downloadedBytes), $0.downloadedCount,
                                                 ByteFormat.short($0.cachedBytes))
                } ?? L10n.settingsStorageSubtitleLoading,
                systemImage: "arrow.down.circle",
                primaryLabel: reclaimable > 0 ? L10n.settingsStorageActionFree(ByteFormat.short(reclaimable))
                                              : L10n.settingsStorageActionNothing,
                onPrimary: clearCache,
                enabled: reclaimable > 0)
        }
        SettingsSubsection(title: L10n.settingsLyricsManagementSection, addBottomSpace: false) {
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
                            systemImage: "hand.tap", identifier: "settings.library.tapTiming") { showsTapTiming = true }
            SettingsItemRow(title: L10n.settingsResetImportedLyricsTitle,
                            subtitle: L10n.settingsResetImportedLyricsSubtitle, systemImage: "text.badge.xmark",
                            identifier: "settings.library.resetLyrics") { showsResetLyrics = true }
        }
        }
        .onAppear {
            minDuration = Double(settings.library.minSongDurationMs)
            minTracks = Double(settings.library.minTracksPerAlbum)
            cacheLimit = Double(settings.library.albumArtCacheLimitMb)
        }
        .task { storage = await OfflineStorageUsage.measure() }
        .fullScreenCover(isPresented: $showsFolders) {
            MusicFoldersView().environment(\.appTheme, theme)
        }
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
        .alert(L10n.settingsDialogRebuildDatabaseTitle, isPresented: $showsRebuild) {
            Button(L10n.commonCancel, role: .cancel) {}
            Button(L10n.settingsActionRebuild, role: .destructive) { rebuild() }
        } message: {
            Text(L10n.settingsDialogRebuildDatabaseBody)
        }
        .settingsToast($toast)
    }

    private func startFullRescan() {
        guard !isSyncing else { return }
        syncLabel = L10n.settingsLabelSyncFullRescan
        toast = L10n.settingsToastFullRescanStarted
        runSync { try await library.refresh(mode: .full) }
    }

    private func rebuild() {
        guard !isSyncing else { return }
        syncLabel = L10n.settingsLabelSyncRebuilding
        toast = L10n.settingsToastRebuildingDatabase
        let persistence = environment.persistence
        runSync {
            try await persistence?.settingsClearLibraryForRebuild()
            try await library.refresh(mode: .full)
        }
    }

    private func runSync(_ work: @escaping () async throws -> Void) {
        isSyncing = true
        Task {
            try? await work()
            settings.library.artistSettingsRescanRequired = false
            isSyncing = false
            syncLabel = nil
            toast = L10n.settingsToastLibrarySyncFinished
        }
    }

    private func clearCache() {
        Task {
            let freed = await OfflineStorageUsage.clearCaches()
            storage = await OfflineStorageUsage.measure()
            toast = L10n.settingsStorageFreed(ByteFormat.short(freed))
        }
    }
}

/// Android `RefreshLibraryItem`: the sync icon, title / subtitle, "Full Rescan" (tonal) and "Rebuild Database"
/// (outlined, error) buttons, and the progress line while a scan runs.
struct RefreshLibraryRow: View {
    let isSyncing: Bool
    let label: String?
    let progress: LibraryImportProgress?
    let onFullSync: () -> Void
    let onRebuild: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                SettingsIcon(systemImage: "arrow.triangle.2.circlepath").padding(.trailing, 16)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.settingsRefreshLibraryTitle)
                        .pixlFont(.titleMedium)
                        .foregroundStyle(theme.onSurface)
                    Text(L10n.settingsRefreshLibrarySubtitle)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer().frame(height: 12)
            SettingsFillButton(title: L10n.settingsActionFullRescan, systemImage: "arrow.clockwise", style: .tonal,
                               enabled: !isSyncing, action: onFullSync)
                .accessibilityIdentifier("settings.library.fullRescan")
            Spacer().frame(height: 8)
            SettingsFillButton(title: L10n.settingsActionRebuildDatabase, systemImage: "trash", style: .destructive,
                               enabled: !isSyncing, action: onRebuild)
            if isSyncing {
                Spacer().frame(height: 12)
                let phase = label ?? progress?.phase ?? L10n.settingsSyncPhasePreparing
                if let progress, progress.total > 0 {
                    ProgressView(value: progress.fraction).tint(theme.primary)
                    Spacer().frame(height: 4)
                    Text(L10n.settingsSyncProgressDetailed(phase, Int(progress.fraction * 100), progress.completed,
                                                           progress.total))
                        .pixlFont(.labelMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(theme.primary)
                    Spacer().frame(height: 4)
                    Text(L10n.settingsSyncProgresIndeterminate(phase))
                        .pixlFont(.labelMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
        }
        .padding(16)
        .settingsRowGlass()
    }
}

/// How much space offline audio takes (Android `storageUsage`): downloaded songs (stage 11 fills the downloads
/// folder) and the temporary cache that can be freed (`Library/Caches`: streamed audio, artwork thumbnails).
nonisolated struct OfflineStorageUsage: Sendable, Equatable {
    var downloadedBytes: Int64
    var downloadedCount: Int
    var cachedBytes: Int64

    static var downloadsDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    static var cachesDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    static func measure() async -> OfflineStorageUsage {
        await Task.detached(priority: .utility) {
            let downloads = downloadsDirectory.map(directoryUsage) ?? (bytes: 0, files: 0)
            let caches = cachesDirectory.map(directoryUsage) ?? (bytes: 0, files: 0)
            return OfflineStorageUsage(downloadedBytes: downloads.bytes, downloadedCount: downloads.files,
                                       cachedBytes: caches.bytes)
        }.value
    }

    /// Deletes the cache folder's contents; returns the bytes freed.
    static func clearCaches() async -> Int64 {
        await Task.detached(priority: .utility) {
            guard let caches = cachesDirectory else { return 0 }
            let before = directoryUsage(caches).bytes
            let fm = FileManager.default
            for item in (try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: item)
            }
            return max(0, before - directoryUsage(caches).bytes)
        }.value
    }

    private static func directoryUsage(_ url: URL) -> (bytes: Int64, files: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return (0, 0)
        }
        var bytes: Int64 = 0
        var files = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }
}

/// Byte counts in the system's short format (Android `Formatter.formatShortFileSize`).
nonisolated enum ByteFormat {
    static func short(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}
