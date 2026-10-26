import SwiftUI

/// Settings › Library & storage (the `library` category; Android `SettingsCategoryScreen` LIBRARY): Blocked artists
/// (moved here from Behavior) and the offline storage — and, in developer mode, an "Advanced" block (minimum tracks
/// per album, album art cache limit). The app is Spotify-only, so the music-folder, rescan and local-lyrics-file rows
/// are gone; the lyrics rows moved to Lyrics. "Listening history" (spec B3) brings in Spotify and YouTube Music
/// listening for the recommendations: two switches, Import from a file, the status and Clear imported history.
struct LibrarySettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(BlockedArtistsStore.self) private var blocked
    @Environment(Router.self) private var router
    @Environment(AppEnvironment.self) private var env
    @Environment(AccountsStore.self) private var accounts
    @State private var confirmsClear = false

    @State private var minTracks: Double = 1
    @State private var cacheLimit: Double = 200
    @State private var storage: OfflineStorageUsage?
    @State private var toast: String?

    var body: some View {
        let developerMode = settings.experimental.developerMode
        SettingsCategoryScaffold(category: .library, toast: $toast) {
            SettingsSubsection(title: L10n.settingsSectionBlockedArtists) {
                SettingsItemRow(title: L10n.settingsSectionBlockedArtists, subtitle: blockedSubtitle,
                                systemImage: "nosign", showsChevron: true,
                                identifier: "settings.library.blockedArtists") { router.push(.blockedArtists) }
            }
            listeningHistory
            SettingsSubsection(title: L10n.settingsStorageSection, addBottomSpace: developerMode) {
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
            SettingsAdvancedSubsection {
                SliderSettingRow(label: L10n.settingsMinTracksPerAlbum, value: $minTracks, range: 1...5, steps: 3,
                                 onCommit: { settings.library.minTracksPerAlbum = Int(minTracks) },
                                 valueText: { "\(Int($0))" })
                SliderSettingRow(label: L10n.settingsAlbumArtCacheLimit, value: $cacheLimit, range: 50...1500, steps: 28,
                                 onCommit: { settings.library.albumArtCacheLimitMb = Int(cacheLimit) },
                                 valueText: { "\(Int($0)) MB" })
            }
        }
        .onAppear {
            minTracks = Double(settings.library.minTracksPerAlbum)
            cacheLimit = Double(settings.library.albumArtCacheLimitMb)
        }
        .task { storage = await OfflineStorageUsage.measure() }
    }

    // MARK: Listening history

    private var spotifySignedIn: Bool {
        if case .signedIn = accounts.spotify { return true }
        return false
    }

    private var youTubeSignedIn: Bool {
        if case .signedIn = accounts.youtube { return true }
        return false
    }

    @ViewBuilder
    private var listeningHistory: some View {
        @Bindable var history = env.importedHistory
        SettingsSubsection(title: "Listening history") {
            SwitchSettingRow(title: "Spotify listening history",
                             subtitle: spotifySignedIn ? "Your Spotify plays and favourites shape your mixes (they count the most)"
                                                       : "Connect Spotify to bring in what you play there",
                             isOn: $history.spotifyEnabled, systemImage: "music.note.list", enabled: spotifySignedIn)
            // YouTube sign-in lives in developer mode only (the cookie breaks the clients that return playable audio),
            // so everyone else would only ever see this switch disabled.
            if youTubeSignedIn || settings.experimental.developerMode {
                SwitchSettingRow(title: "YouTube Music history",
                                 subtitle: youTubeSignedIn ? "Your YouTube Music history counts too, a little less than Spotify"
                                                           : "Sign in to YouTube to bring in your YouTube Music history",
                                 isOn: $history.youTubeEnabled, systemImage: "play.circle", enabled: youTubeSignedIn)
            }
            SettingsItemRow(title: "Import from a file",
                            subtitle: "Your Spotify or Google data download — years of listening",
                            systemImage: "square.and.arrow.down", showsChevron: true,
                            identifier: "settings.library.historyImport") { router.push(.listeningHistory) }
            SettingsItemRow(title: "Ask Taizo's taste changes",
                            subtitle: TasteChangeText.summary(count: env.tasteAdjustments.count),
                            systemImage: "slider.horizontal.3", showsChevron: true,
                            identifier: "settings.library.tasteChanges") { router.push(.tasteChanges) }
            ActionSettingRow(title: ListeningHistoryText.totals(plays: history.playCount, artists: history.artistCount),
                             subtitle: ListeningHistoryText.status(store: history),
                             systemImage: "clock.arrow.circlepath",
                             primaryLabel: "Clear imported history", onPrimary: { confirmsClear = true },
                             enabled: history.playCount > 0)
        }
        .task {
            await history.ensureLoaded()
            await env.tasteAdjustments.ensureLoaded()
        }
        .confirmationDialog("Clear imported history?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear imported history", role: .destructive) {
                Task {
                    await history.clear()
                    toast = "Imported history cleared"
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Plays brought in from Spotify, YouTube Music and data downloads are removed from this phone. Your library and what you played in PixlAudio stay.")
        }
    }

    private func clearCache() {
        Task {
            let freed = await OfflineStorageUsage.clearCaches()
            storage = await OfflineStorageUsage.measure()
            toast = L10n.settingsStorageFreed(ByteFormat.short(freed))
        }
    }

    private var blockedSubtitle: String {
        switch blocked.count {
        case 0: L10n.settingsBlockedArtistsNone
        case 1: L10n.settingsBlockedArtistsOne
        default: L10n.settingsBlockedArtistsMany(blocked.count)
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
