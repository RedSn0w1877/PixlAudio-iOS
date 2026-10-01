import Foundation
import PixlFoundation
import PixlLibrary
import PixlLyrics
import PixlModel
import Testing
@testable import PixlBackup

/// End-to-end imports of the synthetic Android backups (built by `BackupGen.java` exactly as the Android writers
/// build them) and round trips of the backups PixlAudio writes.
@Suite struct BackupImportTests {
    let manager = BackupManager(pipeline: ValidationPipeline(manifestValidator: ManifestValidator(now: { testNow })),
                                now: { testNow })

    func value(_ key: String, in restore: PreferenceRestore?) -> PreferenceValue? {
        restore?.values.first { $0.key == key }?.value
    }

    @Test func importsTheAndroidV3Backup() throws {
        let contents = try BackupImporter.importBackup(bytes: fixtureBytes("android-v3.pxpl"), fileName: "PixelPlay_Backup.pxpl",
                                                       library: fixtureLibrary, manager: manager)
        #expect(contents.format == .pxplV3Zip)
        #expect(contents.report.failed.isEmpty)
        #expect(contents.report.imported.count == 12)
        #expect(contents.report.warnings.isEmpty)
        #expect(contents.manifest.appVersion == "0.6.0-beta2")
        #expect(contents.manifest.deviceInfo?.model == "Pixel 9 Pro")

        // Playlists: Android ids 101/102/103 matched by title + artist; covers decoded, Android paths dropped.
        let playlists = try #require(contents.playlists)
        #expect(playlists.playlists.map(\.name) == ["Late Night", "Gym • AI"])
        #expect(playlists.playlists[0].songIds == ["f:music/M83/Midnight City.flac", "f:music/The xx/Intro.m4a", "mp:9001"])
        #expect(playlists.playlists[1].songIds == ["f:music/The xx/Intro.m4a"])
        #expect(playlists.playlists[1].isAiGenerated && playlists.playlists[1].source == "AI")
        #expect(playlists.playlists[1].coverShapeType == "Star" && playlists.playlists[1].coverShapeDetail4 == 6)
        #expect(playlists.playlists.allSatisfy { $0.coverImageUri == nil })
        #expect(playlists.coverImages == ["pl-1": [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]])
        #expect(playlists.playlistSongOrderModes == ["pl-1": "manual"])
        #expect(playlists.playlistsSortOption == "playlist_name_az")
        #expect(playlists.unresolvedCount == 0 && playlists.pendingPayload == nil)

        // Settings: portable ones applied, Android-only and per-device ones reported.
        let settings = try #require(contents.globalSettings)
        #expect(settings.clear == .allExcept(PreferencesModule.globalExcludedKeys))
        #expect(value("app_theme_mode", in: settings) == .string("dark"))
        #expect(value("crossfade_duration", in: settings) == .int(6000))
        #expect(value("is_crossfade_enabled", in: settings) == .bool(true))
        #expect(value("animated_lyrics_blur_strength", in: settings) == .float(2.5))
        #expect(value("artist_delimiters", in: settings) == .string("[\";\",\"/\"]"))
        #expect(value("lyrics_alignment", in: settings) == .string("start"))
        #expect(value("songs_sort_option", in: settings) == .string("song_title_az"))
        #expect(settings.skippedAndroidOnly == ["nav_bar_corner_radius", "allowed_directories"])
        #expect(settings.skippedDeviceState == ["last_sync_timestamp"])
        #expect(contents.report.skippedSettings == ["nav_bar_corner_radius", "allowed_directories", "last_sync_timestamp",
                                                    "custom_genre_icons"])

        // Favourites: 104 has no metadata in the backup, so it cannot be found here.
        #expect(contents.favorites == [FavoriteBackupEntry(backupSongId: "f:music/M83/Midnight City.flac", timestamp: 1_755_000_000_000)])
        #expect(contents.report.unresolvedSongs[.favorites] == 1)

        // Lyrics: two Room rows; the streaming song's cache file has no match; the unsafe file name was dropped.
        #expect(contents.lyrics?.map(\.backupSongId) == ["f:music/M83/Midnight City.flac", "mp:9001"])
        #expect(contents.lyrics?.first?.isSynced == true)
        #expect(contents.lyrics?.first?.source == "remote")
        #expect(contents.lyricsFiles == [])
        #expect(contents.report.unresolvedSongs[.lyrics] == 1)
        let parsed = LyricsUtils.parseLyrics(contents.lyrics![0].content)
        #expect(parsed.synced?.first?.line == "Waiting in a car")

        #expect(contents.searchHistory?.map(\.query) == ["massive attack", "café 🎵 <tag>"])
        #expect(contents.transitions == [
            TransitionRule(id: 1, playlistId: "pl-1", settings: TransitionSettings(mode: .smooth, durationMs: 6000)),
            TransitionRule(id: 2, playlistId: "pl-1", fromTrackId: "f:music/M83/Midnight City.flac",
                           toTrackId: "f:music/The xx/Intro.m4a",
                           settings: TransitionSettings(mode: .none, durationMs: 0, curveIn: .linear, curveOut: .linear)),
        ])
        #expect(contents.engagementStats == [
            EngagementBackupEntry(songId: "f:music/M83/Midnight City.flac",
                                  stats: EngagementStats(playCount: 12, totalPlayDurationMs: 2_900_000, lastPlayedTimestamp: 1_758_500_000_000)),
            EngagementBackupEntry(songId: "mp:9001",
                                  stats: EngagementStats(playCount: 3, totalPlayDurationMs: 990_000, lastPlayedTimestamp: 1_757_000_000_000)),
        ])
        #expect(contents.playbackHistory == [
            PlaybackEvent(songId: "f:music/M83/Midnight City.flac", timestamp: 1_758_500_000_000, durationMs: 243_000,
                          startTimestamp: 1_758_499_757_000, endTimestamp: 1_758_500_000_000),
            PlaybackEvent(songId: "mp:9001", timestamp: 1_758_600_000_000, durationMs: 120_000,
                          startTimestamp: 1_758_599_880_000, endTimestamp: 1_758_600_000_000),
        ])
        #expect(PreferencesModule.customGenres(from: try #require(contents.quickFill)) == ["Shoegaze", "City Pop"])
        let equalizer = try #require(contents.equalizer)
        #expect(PreferencesModule.customPresets(from: equalizer) == [
            EqualizerPreset(name: "custom_night", displayName: "NIGHT", bandLevels: [3, 2, 1, 0, 0, 0, -1, -2, -3, -4], isCustom: true),
        ])
        #expect(PreferencesModule.pinnedPresets(from: equalizer) == ["flat", "rock", "custom_night"])
        #expect(contents.artistImages == [
            ArtistImageRestore(artistName: "M83", imageUrl: "https://e-cdns-images.dzcdn.net/images/artist/m83.jpg", customImage: nil),
            ArtistImageRestore(artistName: "The xx", imageUrl: nil, customImage: [1, 2, 3, 4, 5]),
        ])
        #expect(contents.aiUsage == [AiUsageRecord(id: 1, timestamp: 1_758_000_000_000, provider: "GEMINI",
                                                   model: "gemini-2.5-flash", promptType: "playlist", promptTokens: 812,
                                                   outputTokens: 240, thoughtTokens: 0)])
    }

    @Test func importsSelectedModulesOnly() throws {
        let contents = try BackupImporter.importBackup(bytes: fixtureBytes("android-v3.pxpl"), fileName: "b.pxpl",
                                                       library: fixtureLibrary, sections: [.favorites, .searchHistory],
                                                       manager: manager)
        #expect(contents.report.imported == [.favorites, .searchHistory])
        #expect(contents.playlists == nil && contents.globalSettings == nil)
        // Without the playlists module there is no metadata: Android ids cannot be resolved.
        #expect(contents.favorites == [])
        #expect(contents.report.unresolvedSongs[.favorites] == 2)
    }

    @Test func importsTheLegacyV2Backup() throws {
        let contents = try BackupImporter.importBackup(bytes: fixtureBytes("android-v2-legacy.pxpl"), fileName: "old.pxpl",
                                                       library: fixtureLibrary, manager: manager)
        #expect(contents.format == .pxplV2Gzip)
        #expect(contents.manifest.schemaVersion == 2)
        #expect(contents.manifest.appVersion == "legacy")
        #expect(contents.report.warnings == ["This is a legacy backup (v2). Some new modules may not be available."])
        #expect(contents.report.imported == [.engagementStats, .favorites, .globalSettings, .playbackHistory, .playlists, .searchHistory])
        let playlists = try #require(contents.playlists)
        // The legacy format keeps ids as stored (no metadata to match with).
        #expect(playlists.playlists.map(\.id) == ["legacy-1"])
        #expect(playlists.playlists[0].songIds == ["101", "103"])
        #expect(playlists.playlistsSortOption == "playlist_name_za")
        #expect(playlists.playlistSongOrderModes == ["legacy-1": "manual"])
        #expect(value("app_theme_mode", in: contents.globalSettings) == .string("light"))
        #expect(contents.searchHistory == [SearchHistoryItem(id: 9, query: "old query", timestamp: 1_710_000_000_000)])
        #expect(contents.report.unresolvedSongs[.favorites] == 1)
        #expect(contents.report.unresolvedSongs[.engagementStats] == 1)
        #expect(contents.report.unresolvedSongs[.playbackHistory] == 1)
    }

    @Test func importsTheLegacyV1Backups() throws {
        for name in ["android-v1-legacy.json.gz", "android-v1-legacy.json"] {
            let contents = try BackupImporter.importBackup(bytes: fixtureBytes(name), fileName: name, library: fixtureLibrary,
                                                           manager: manager)
            #expect(contents.manifest.schemaVersion == 1)
            #expect(contents.report.failed.isEmpty, "\(name): \(contents.report.failed)")
            #expect(value("crossfade_duration", in: contents.globalSettings) == .int(4000))
            #expect(contents.playlists?.playlists == [])
            #expect(contents.transitions == [TransitionRule(id: 3, playlistId: "legacy-1",
                                                            settings: TransitionSettings(mode: .overlap, durationMs: 3000,
                                                                                         curveIn: .exp, curveOut: .log))])
            #expect(contents.lyrics == [])
            #expect(contents.report.unresolvedSongs[.lyrics] == 1)
        }
        // `.gz` is an accepted extension; raw JSON named .json gets the extension warning.
        let raw = try BackupImporter.importBackup(bytes: fixtureBytes("android-v1-legacy.json"), fileName: "android-v1-legacy.json",
                                                  library: [], manager: manager)
        #expect(raw.report.warnings.first == "File extension is not .pxpl. The file may not be a valid backup.")
    }

    /// The library PixlAudio exports from, and the same songs after a reinstall (new folder bookmark → new ids).
    static let ownLibrary: [BackupSongSummary] = [
        BackupSongSummary(id: "f:A1/Teardrop.flac", title: "Teardrop", artistName: "Massive Attack", albumName: "Mezzanine", duration: 330_000),
        BackupSongSummary(id: "f:A1/Angel.flac", title: "Angel", artistName: "Massive Attack", albumName: "Mezzanine", duration: 379_000),
        BackupSongSummary(id: "mp:42", title: "Intro", artistName: "The xx", albumName: "xx", duration: 127_000),
        BackupSongSummary(id: "yt:dQw4w9WgXcQ", title: "Streamed", artistName: "Someone", albumName: "", duration: 200_000),
    ]
    static let reinstalledLibrary: [BackupSongSummary] = ownLibrary.map {
        var s = $0
        s.id = s.id.replacingOccurrences(of: "f:A1/", with: "f:B7/")
        return s
    }

    func exportOwnBackup() -> [UInt8] {
        let playlists = [
            Playlist(id: "p-1", name: "Trip-hop <3", songIds: ["f:A1/Teardrop.flac", "yt:dQw4w9WgXcQ", "f:A1/Angel.flac"],
                     createdAt: 1_780_000_000_000, lastModified: 1_780_000_100_000, coverColorArgb: -14_000_000, source: "LOCAL",
                     sortOrder: 1),
            Playlist(id: "p-2", name: "Spotify import", songIds: ["sp:abc"], createdAt: 1, lastModified: 1, source: "SPOTIFY"),
        ]
        let favorites = [FavoriteBackupEntry(backupSongId: "mp:42", timestamp: 1_785_000_000_000)]
        let lyricsRows = [LyricsBackupRow(backupSongId: "f:A1/Angel.flac", content: "[00:01.00]Love, love is a verb", isSynced: true,
                                          source: "user")]
        let payloads: [(String, String)] = [
            ("playlists", PlaylistsModule.export(playlists: playlists, library: Self.ownLibrary,
                                                 playlistSongOrderModes: [("p-1", "manual")], playlistsSortOption: "playlist_custom_order",
                                                 extraSongIds: ["mp:42"], coverImage: { $0.id == "p-1" ? [9, 8, 7] : nil })),
            ("global_settings", PreferencesModule.export(.globalSettings, values: [
                ("app_theme_mode", .string("dark")), ("crossfade_duration", .int(4000)), ("custom_genres", .stringSet(["x"])),
                ("initial_setup_done", .bool(true)), ("lyrics_tap_offset_speaker_ms", .int(120)),
            ])),
            ("quick_fill", PreferencesModule.export(.quickFill, values: [("custom_genres", .stringSet(["Shoegaze"])),
                                                                         ("app_theme_mode", .string("dark"))])),
            ("favorites", FavoritesModule.export(favorites)),
            ("lyrics", LyricsModule.export(rows: lyricsRows)),
            ("search_history", SearchHistoryModule.export([SearchHistoryItem(id: 3, query: "angel", timestamp: 1_785_000_000_001)])),
            ("transitions", TransitionsModule.export([TransitionRule(id: 4, playlistId: "p-1", fromTrackId: "f:A1/Teardrop.flac",
                                                                     toTrackId: "f:A1/Angel.flac",
                                                                     settings: TransitionSettings(mode: .fadeInOut, durationMs: 1500))])),
            ("engagement_stats", EngagementStatsModule.export([EngagementBackupEntry(songId: "f:A1/Angel.flac", stats: EngagementStats(
                playCount: 7, totalPlayDurationMs: 2_000_000, lastPlayedTimestamp: 1_785_000_000_000))])),
            ("playback_history", PlaybackHistoryModule.export([PlaybackEvent(songId: "mp:42", timestamp: 1_785_000_000_000,
                                                                             durationMs: 127_000, startTimestamp: 1_784_999_873_000,
                                                                             endTimestamp: 1_785_000_000_000)])),
            ("artist_images", ArtistImagesModule.export([("Massive Attack", "https://example.com/ma.jpg", nil), ("Nobody", nil, nil)])),
            ("ai_usage_logs", AiUsageModule.export([AiUsageRecord(timestamp: 5, provider: "APPLE_FOUNDATION", model: "on-device",
                                                                  promptType: "playlist", promptTokens: 1, outputTokens: 2,
                                                                  thoughtTokens: 0)])),
        ]
        let manifest = BackupManifest(appVersion: "1.0.0", appVersionCode: 1, createdAt: testNow,
                                      deviceInfo: DeviceInfo(manufacturer: "", model: "iPhone17,1", androidVersion: 0))
        return BackupWriter.write(manifest: manifest, modulePayloads: payloads)
    }

    @Test func ownBackupsPassAndroidsValidationAndRoundTrip() throws {
        let bytes = exportOwnBackup()
        #expect(BackupFormatDetector.detect(bytes) == .pxplV3Zip)
        #expect(BackupFileValidator.validate(bytes: bytes, fileName: "PixlAudio.pxpl", fileSize: Int64(bytes.count)) == .valid)
        let reader = BackupReader(bytes: bytes)
        let manifest = try reader.readManifest()
        #expect(manifest.moduleKeys.count == 11)
        for key in manifest.moduleKeys {
            let payload = try reader.readModulePayload(key)
            #expect(ManifestValidator().verifyChecksum(moduleKey: key, payload: payload, manifest: manifest), "\(key)")
            let validation = try ValidationPipeline().validateModulePayload(BackupSection.fromKey(key)!, payload: payload, manifest: manifest)
            #expect(validation == .valid, "\(key): \(validation)")
        }

        let contents = try BackupImporter.importBackup(bytes: bytes, fileName: "PixlAudio.pxpl", library: Self.ownLibrary, manager: manager)
        #expect(contents.report.failed.isEmpty)
        #expect(contents.report.warnings.isEmpty)
        #expect(contents.report.unresolvedSongs.isEmpty)
        let playlists = try #require(contents.playlists)
        // Only local/AI playlists, streaming songs removed.
        #expect(playlists.playlists.map(\.id) == ["p-1"])
        #expect(playlists.playlists[0].songIds == ["f:A1/Teardrop.flac", "f:A1/Angel.flac"])
        #expect(playlists.playlists[0].name == "Trip-hop <3")
        #expect(playlists.playlists[0].coverColorArgb == -14_000_000)
        #expect(playlists.coverImages == ["p-1": [9, 8, 7]])
        #expect(playlists.playlistsSortOption == "playlist_custom_order")
        #expect(contents.favorites == [FavoriteBackupEntry(backupSongId: "mp:42", timestamp: 1_785_000_000_000)])
        #expect(contents.lyrics?.map(\.backupSongId) == ["f:A1/Angel.flac"])
        #expect(contents.lyrics?.first?.source == "user")
        #expect(contents.transitions?.first?.fromTrackId == "f:A1/Teardrop.flac")
        #expect(contents.engagementStats?.first?.stats.playCount == 7)
        #expect(contents.playbackHistory?.first?.songId == "mp:42")
        #expect(value("app_theme_mode", in: contents.globalSettings) == .string("dark"))
        #expect(value("lyrics_tap_offset_speaker_ms", in: contents.globalSettings) == .int(120))
        // Keys owned by other modules and the excluded key are not in global settings.
        #expect(value("custom_genres", in: contents.globalSettings) == nil)
        #expect(value("initial_setup_done", in: contents.globalSettings) == nil)
        #expect(PreferencesModule.customGenres(from: try #require(contents.quickFill)) == ["Shoegaze"])
        #expect(contents.artistImages == [ArtistImageRestore(artistName: "Massive Attack", imageUrl: "https://example.com/ma.jpg", customImage: nil)])
        #expect(contents.aiUsage?.first?.provider == "APPLE_FOUNDATION")
    }

    @Test func ownBackupsResolveByMetadataAfterAReinstall() throws {
        let contents = try BackupImporter.importBackup(bytes: exportOwnBackup(), fileName: "PixlAudio.pxpl",
                                                       library: Self.reinstalledLibrary, manager: manager)
        #expect(contents.playlists?.playlists.first?.songIds == ["f:B7/Teardrop.flac", "f:B7/Angel.flac"])
        #expect(contents.lyrics?.map(\.backupSongId) == ["f:B7/Angel.flac"])
        #expect(contents.engagementStats?.map(\.songId) == ["f:B7/Angel.flac"])
        #expect(contents.transitions?.first?.toTrackId == "f:B7/Angel.flac")
        // mp:42 kept its id.
        #expect(contents.favorites?.map(\.backupSongId) == ["mp:42"])
        #expect(contents.report.unresolvedSongs.isEmpty)
    }

    @Test func managerExportsThroughHandlers() async throws {
        let favorites = RecordingHandler(.favorites)
        await favorites.setExport(FavoritesModule.export([FavoriteBackupEntry(backupSongId: "f:x", timestamp: 1)]))
        let history = RecordingHandler(.searchHistory)
        await history.setExport(SearchHistoryModule.export([]))
        var steps: [String] = []
        let bytes = try await manager.export(sections: [.favorites, .searchHistory],
                                             handlers: [.favorites: favorites, .searchHistory: history],
                                             appInfo: BackupAppInfo(appVersion: "1.0", appVersionCode: 3)) { steps.append($0.title) }
        #expect(steps == ["Preparing backup", "Collecting Favorites", "Collecting Search History", "Packaging backup", "Backup complete"])
        let manifest = try BackupReader(bytes: bytes).readManifest()
        #expect(manifest.createdAt == testNow)
        #expect(manifest.appVersion == "1.0" && manifest.appVersionCode == 3)
        #expect(manifest.moduleKeys == ["favorites", "search_history"])
        #expect(manifest.module("search_history")?.entryCount == 0)
        #expect(manifest.module("favorites")?.entryCount == 1)
        await #expect(throws: BackupError("No handler for module lyrics")) {
            _ = try await manager.export(sections: [.lyrics], handlers: [:], appInfo: BackupAppInfo(appVersion: "1", appVersionCode: 1))
        }
    }

    @Test func restoreRunsEveryHandlerAndReportsProgress() async throws {
        let bytes = exportOwnBackup()
        let plan = try manager.inspectBackup(bytes: bytes, fileName: "PixlAudio.pxpl").selecting([.favorites, .searchHistory])
        let favorites = RecordingHandler(.favorites), search = RecordingHandler(.searchHistory)
        var updates: [BackupTransferProgressUpdate] = []
        let result = await manager.restore(bytes: bytes, plan: plan, handlers: [.favorites: favorites, .searchHistory: search]) {
            updates.append($0)
        }
        #expect(result == .success)
        #expect(updates.map(\.step) == Array(1...7))
        #expect(updates.allSatisfy { $0.totalSteps == 7 && $0.operation == .import })
        #expect(updates.map(\.title) == ["Creating safety snapshots", "Preparing restore", "Validated Favorites", "Restoring Favorites",
                                         "Validated Search History", "Restoring Search History", "Restore complete"])
        #expect(updates.last?.progress == 1)
        #expect(await favorites.restored.count == 1)
        #expect(await favorites.rolledBack.isEmpty)
        let entry = BackupManager.historyEntry(for: plan, uri: "file:///b.pxpl", displayName: nil, sizeBytes: Int64(bytes.count))
        #expect(entry.displayName == "backup.pxpl")
        #expect(entry.modules.count == 11)
        #expect(entry.appVersion == "1.0.0")
    }

    @Test func restoreReportsPartialFailureWhenRollbackFails() async throws {
        let bytes = exportOwnBackup()
        let plan = try manager.inspectBackup(bytes: bytes, fileName: "PixlAudio.pxpl").selecting([.favorites, .searchHistory])
        let favorites = RecordingHandler(.favorites), search = RecordingHandler(.searchHistory)
        await search.failRestore("disk full")
        await favorites.failRollback("locked")
        let result = await manager.restore(bytes: bytes, plan: plan, handlers: [.favorites: favorites, .searchHistory: search])
        #expect(result == .partialFailure(succeeded: [.favorites], failed: [.searchHistory: "disk full"], rolledBack: false))
        #expect(await search.rolledBack == ["snapshot"])
    }

    @Test func snapshotFailureStopsBeforeAnyRestore() async throws {
        actor FailingSnapshot: BackupModuleHandler {
            nonisolated let section = BackupSection.favorites
            func export() async throws -> String { "[]" }
            func countEntries() async throws -> Int { 0 }
            func snapshot() async throws -> String { throw BackupError("database locked") }
            func restore(_ payload: String) async throws {}
            func rollback(_ snapshot: String) async throws {}
        }
        let bytes = exportOwnBackup()
        let plan = try manager.inspectBackup(bytes: bytes, fileName: "PixlAudio.pxpl").selecting([.favorites])
        let result = await manager.restore(bytes: bytes, plan: plan, handlers: [.favorites: FailingSnapshot()])
        #expect(result == .totalFailure("Failed to capture current state: database locked"))
    }

    @Test func checksumMismatchIsFatal() throws {
        let bytes = makeBackup([("favorites", "[]")]) { manifest in
            manifest.modules?.put("favorites", BackupModuleInfo(checksum: "sha256:" + String(repeating: "1", count: 64), entryCount: 0, sizeBytes: 2))
        }
        #expect(throws: BackupError("Favorites: Checksum mismatch for module 'Favorites'. The backup may be corrupted.")) {
            try manager.inspectBackup(bytes: bytes, fileName: "b.pxpl")
        }
    }
}
