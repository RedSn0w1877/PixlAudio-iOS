// Importing a whole backup into PixlAudio values: validates like Android's `inspectBackup`, decodes every selected
// module with the module codecs, maps song ids onto the current library and reports what was skipped. The app
// writes the result into its stores (and can instead drive `RestoreExecutor` with handlers for transactional
// per-module restores; both use the same codecs).

import Foundation
import PixlFoundation
import PixlLibrary
import PixlLyrics
import PixlModel

/// A lyrics cache file mapped to a library song.
public struct ResolvedLyricsFile: Sendable, Hashable {
    public var songId: String
    public var file: LyricsBackupFile
}

/// What an import produced and skipped.
public struct BackupImportReport: Sendable, Hashable {
    /// Modules decoded successfully, in key order.
    public var imported: [BackupSection] = []
    /// Modules that failed, with Android's message; nothing of theirs is in the contents.
    public var failed: [BackupSection: String] = [:]
    /// The inspection warnings (file, manifest, per-module validation).
    public var warnings: [String] = []
    /// Manifest modules this version does not know (Android skips them too).
    public var unknownModules: [String] = []
    /// Android-only / per-device / id-keyed / unknown preference keys that were not applied.
    public var skippedSettings: [String] = []
    /// Per module: entries whose song could not be found in the library (dropped).
    public var unresolvedSongs: [BackupSection: Int] = [:]
}

/// Everything decoded from a backup, song ids already mapped to the library.
public struct BackupContents: Sendable {
    public var manifest: BackupManifest
    public var format: BackupFormat
    public var playlists: PlaylistsRestore?
    public var globalSettings: PreferenceRestore?
    public var quickFill: PreferenceRestore?
    public var equalizer: PreferenceRestore?
    public var favorites: [FavoriteBackupEntry]?
    public var lyrics: [LyricsBackupRow]?
    public var lyricsFiles: [ResolvedLyricsFile]?
    public var searchHistory: [SearchHistoryItem]?
    public var transitions: [TransitionRule]?
    public var engagementStats: [EngagementBackupEntry]?
    public var playbackHistory: [PlaybackEvent]?
    public var artistImages: [ArtistImageRestore]?
    public var aiUsage: [AiUsageRecord]?
    public var report: BackupImportReport
}

public enum BackupImporter {
    /// Inspects and decodes a backup. Throws when Android's `inspectBackup` would fail (unreadable file, fatal
    /// validation error); a module whose restore fails is reported in `report.failed` and left out.
    public static func importBackup(bytes: [UInt8], fileName: String?, library: [BackupSongSummary],
                                    sections: Set<BackupSection>? = nil,
                                    manager: BackupManager = BackupManager()) throws(BackupError) -> BackupContents {
        let plan = try manager.inspectBackup(bytes: bytes, fileName: fileName)
        let reader = BackupReader(bytes: bytes, hasher: manager.hasher, now: manager.now)
        var contents = BackupContents(manifest: plan.manifest, format: reader.format, report: BackupImportReport())
        contents.report.warnings = plan.warnings
        contents.report.unknownModules = plan.manifest.moduleKeys.filter { BackupSection.fromKey($0) == nil }
        let selected = plan.availableModules.filter { sections?.contains($0) ?? true }
            .sorted { KotlinText.compare($0.key, $1.key) < 0 }
        var payloads: [BackupSection: String] = [:]
        for section in selected {
            do {
                let payload = try reader.readModulePayload(section.key)
                let validation = try manager.pipeline.validateModulePayload(section, payload: payload, manifest: plan.manifest)
                if let fatal = validation.fatalErrors.first { throw BackupError("Validation failed for \(section.label): \(fatal.message)") }
                payloads[section] = payload
            } catch {
                contents.report.failed[section] = backupErrorMessage(error)
            }
        }

        // Playlists first: their song metadata resolves the other modules' ids.
        var metadata = GsonMap<AndroidBackup.SongMetadataEntry>()
        if let payload = payloads[.playlists] {
            do {
                let restore = try PlaylistsModule.restore(payload: payload, library: library)
                metadata = restore.songMetadata
                contents.playlists = restore
                if restore.unresolvedCount > 0 { contents.report.unresolvedSongs[.playlists] = restore.unresolvedCount }
            } catch {
                contents.report.failed[.playlists] = backupErrorMessage(error)
            }
        }
        let resolver = BackupSongResolver(library: library)
        func resolve(_ id: String) -> String? { resolver.resolve(id, metadata: metadata[id] ?? nil) }

        for section in selected where section != .playlists {
            guard let payload = payloads[section] else { continue }
            do {
                switch section {
                case .playlists: break
                case .globalSettings, .quickFill, .equalizer:
                    let restore = try PreferencesModule.restore(section, payload: payload)
                    contents.report.skippedSettings.append(contentsOf: restore.skippedKeys)
                    switch section {
                    case .globalSettings: contents.globalSettings = restore
                    case .quickFill: contents.quickFill = restore
                    default: contents.equalizer = restore
                    }
                case .favorites:
                    var unresolved = 0
                    contents.favorites = try FavoritesModule.restore(payload: payload).compactMap { entry in
                        guard let id = resolve(entry.backupSongId) else { unresolved += 1; return nil }
                        var copy = entry
                        copy.backupSongId = id
                        return copy
                    }
                    if unresolved > 0 { contents.report.unresolvedSongs[.favorites] = unresolved }
                case .lyrics:
                    let (rows, files) = try LyricsModule.restore(payload: payload)
                    var unresolved = 0
                    contents.lyrics = rows.compactMap { row in
                        guard let id = resolve(row.backupSongId) else { unresolved += 1; return nil }
                        var copy = row
                        copy.backupSongId = id
                        return copy
                    }
                    contents.lyricsFiles = files.compactMap { file in
                        guard let id = resolve(file.songId) else { unresolved += 1; return nil }
                        return ResolvedLyricsFile(songId: id, file: file)
                    }
                    if unresolved > 0 { contents.report.unresolvedSongs[.lyrics] = unresolved }
                case .searchHistory:
                    contents.searchHistory = try SearchHistoryModule.restore(payload: payload)
                case .transitions:
                    var unresolved = 0
                    contents.transitions = try TransitionsModule.restore(payload: payload).compactMap { rule in
                        var copy = rule
                        if let from = rule.fromTrackId {
                            guard let id = resolve(from) else { unresolved += 1; return nil }
                            copy.fromTrackId = id
                        }
                        if let to = rule.toTrackId {
                            guard let id = resolve(to) else { unresolved += 1; return nil }
                            copy.toTrackId = id
                        }
                        return copy
                    }
                    if unresolved > 0 { contents.report.unresolvedSongs[.transitions] = unresolved }
                case .engagementStats:
                    var unresolved = 0
                    var merged: [EngagementBackupEntry] = []
                    var position: [KotlinKey: Int] = [:]
                    for entry in try EngagementStatsModule.restore(payload: payload) {
                        guard let id = resolve(entry.songId) else { unresolved += 1; continue }
                        if let i = position[KotlinKey(id)] {
                            let a = merged[i].stats, b = entry.stats
                            merged[i].stats = EngagementStats(playCount: max(a.playCount, b.playCount),
                                                              totalPlayDurationMs: max(a.totalPlayDurationMs, b.totalPlayDurationMs),
                                                              lastPlayedTimestamp: max(a.lastPlayedTimestamp, b.lastPlayedTimestamp))
                        } else {
                            position[KotlinKey(id)] = merged.count
                            merged.append(EngagementBackupEntry(songId: id, stats: entry.stats))
                        }
                    }
                    contents.engagementStats = merged
                    if unresolved > 0 { contents.report.unresolvedSongs[.engagementStats] = unresolved }
                case .playbackHistory:
                    var unresolved = 0
                    let events = try PlaybackHistoryModule.restore(payload: payload).compactMap { event -> PlaybackEvent? in
                        guard let id = resolve(event.songId) else { unresolved += 1; return nil }
                        var copy = event
                        copy.songId = id
                        return copy
                    }
                    contents.playbackHistory = PlaybackStats.importingEvents(events, into: [], clearExisting: true)
                    if unresolved > 0 { contents.report.unresolvedSongs[.playbackHistory] = unresolved }
                case .artistImages:
                    contents.artistImages = try ArtistImagesModule.restore(payload: payload)
                case .aiUsageLogs:
                    contents.aiUsage = try AiUsageModule.restore(payload: payload)
                }
            } catch {
                contents.report.failed[section] = backupErrorMessage(error)
            }
        }
        contents.report.imported = selected.filter { contents.report.failed[$0] == nil }
        return contents
    }
}
