import SwiftUI

/// Settings › Music Management (Android `SettingsCategoryScreen` LIBRARY): filtering sliders, offline storage, lyrics
/// management. The app is Spotify-only, so the music-folder, rescan and local-lyrics-file rows are gone.
struct LibrarySettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var minTracks: Double = 1
    @State private var cacheLimit: Double = 200
    @State private var showsTapTiming = false
    @State private var showsResetLyrics = false
    @State private var storage: OfflineStorageUsage?
    @State private var toast: String?

    var body: some View {
        @Bindable var lyrics = settings.lyrics
        SettingsCategoryScaffold(category: .library, toast: $toast) {
        SettingsSubsection(title: L10n.settingsFilteringSection) {
            SliderSettingRow(label: L10n.settingsMinTracksPerAlbum, value: $minTracks, range: 1...5, steps: 3,
                             onCommit: { settings.library.minTracksPerAlbum = Int(minTracks) },
                             valueText: { "\(Int($0))" })
            SliderSettingRow(label: L10n.settingsAlbumArtCacheLimit, value: $cacheLimit, range: 50...1500, steps: 28,
                             onCommit: { settings.library.albumArtCacheLimitMb = Int(cacheLimit) },
                             valueText: { "\(Int($0)) MB" })
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
            minTracks = Double(settings.library.minTracksPerAlbum)
            cacheLimit = Double(settings.library.albumArtCacheLimitMb)
        }
        .task { storage = await OfflineStorageUsage.measure() }
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
    }

    private func clearCache() {
        Task {
            let freed = await OfflineStorageUsage.clearCaches()
            storage = await OfflineStorageUsage.measure()
            toast = L10n.settingsStorageFreed(ByteFormat.short(freed))
        }
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
