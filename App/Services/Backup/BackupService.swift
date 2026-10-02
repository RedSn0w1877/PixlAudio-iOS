import CryptoKit
import Foundation
import Observation
import PixlBackup
import PixlFoundation
import PixlLibrary
import PixlLyrics
import PixlModel
import UIKit

/// A backup file read and inspected (Android `inspectBackup`): its bytes, name and restore plan.
nonisolated struct InspectedBackup: Sendable, Identifiable {
    let id = UUID()
    let bytes: [UInt8]
    let fileName: String
    let plan: RestorePlan

    /// Written by the Android app (its manifest carries an Android SDK version).
    var isFromAndroid: Bool { (plan.manifest.deviceInfo?.androidVersion ?? 0) > 0 }
}

/// Backup and restore (Android `BackupManager` + `SettingsViewModel` / `SetupViewModel` backup actions) on PixlBackup:
/// exports a `.pxpl` of the selected modules, inspects a picked file (PixlAudio's or the Android app's v1/v2/v3
/// backups), and restores the selected modules into SwiftData, `UserDefaults`, the Keychain and the listening
/// history, producing a report of what was restored and what could not be matched.
///
/// Heavy work (reading, inflating, decoding, id matching) runs off the main actor; only the store updates run on it.
@Observable
final class BackupService {
    /// The running transfer (Android `dataTransferProgress`); nil when idle.
    private(set) var progress: BackupTransferProgressUpdate?
    private(set) var isBusy = false
    /// The sections the export flow writes (Settings › Backup & Restore shows "n of m" from it).
    var exportSelection: Set<BackupSection> = BackupSection.defaultSelection
    /// The export flow's closing message, toasted by Settings › Backup & Restore once the cover is gone.
    var exportMessage: String?
    /// Where the next `AppCover.backupImport` starts (the file step unless a caller has a backup already).
    @ObservationIgnored var importStart: BackupImportFlowView.Start = .pick
    /// A restore finished (whatever it restored): `AppEnvironment` re-reads caches the restored tables feed.
    @ObservationIgnored var onRestored: (() -> Void)?

    @ObservationIgnored private let persistence: PersistenceActor?
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let history: ListeningHistoryStore
    @ObservationIgnored private let playbackServices: PlaybackServices?
    @ObservationIgnored private let isUITest: Bool
    @ObservationIgnored private let manager = BackupManager(hasher: BackupService.sha256)
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var lastPendingSongCount = -1

    init(persistence: PersistenceActor?, library: LibraryStore, settings: SettingsStore, defaults: UserDefaults,
         history: ListeningHistoryStore, playbackServices: PlaybackServices?, isUITest: Bool) {
        self.persistence = persistence
        self.library = library
        self.settings = settings
        self.defaults = defaults
        self.history = history
        self.playbackServices = playbackServices
        self.isUITest = isUITest
    }

    /// CryptoKit's SHA-256 for the archive checksums (PixlBackup's pure-Swift one is the portable fallback).
    nonisolated static let sha256: SHA256Hasher = { bytes in Array(CryptoKit.SHA256.hash(data: bytes)) }

    /// Starts retrying a pending playlist restore whenever the library changes (Android resolves
    /// `pending_playlists_restore.json` after each sync).
    func start() {
        guard !isUITest else { return }
        observeLibrary()
    }

    // MARK: - Export

    /// The default file name (Android `settings_backup_file_name_format` with the current time), without extension.
    static func defaultFileName(nowMs: Int64 = currentTimeMillis()) -> String {
        let name = L10n.settingsBackupFileNameFormat(Int(nowMs))
        return name.hasSuffix(".pxpl") ? String(name.dropLast(5)) : name
    }

    /// Builds a `.pxpl` of `sections` (Android `exportAppData`), reporting progress.
    func export(sections: Set<BackupSection>) async throws -> BackupFileDocument {
        guard !isBusy else { throw BackupError("A backup transfer is already running.") }
        isBusy = true
        defer {
            isBusy = false
            progress = nil
        }
        progress = BackupTransferProgressUpdate(operation: .export, step: 0, totalSteps: 1,
                                                title: L10n.backupProgressPreparingBackup,
                                                detail: L10n.backupProgressStartingBackupTask)
        let ordered = BackupSection.allCases.filter(sections.contains)
        let payloads = try await collectPayloads(for: Set(ordered))
        let handlers: [BackupSection: any BackupModuleHandler] = Dictionary(uniqueKeysWithValues: payloads.map {
            ($0.key, ExportPayloadHandler(section: $0.key, payload: $0.value))
        })
        let appInfo = BackupAppInfo(appVersion: AppUpdateChecker.installedVersion,
                                    appVersionCode: Int32(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 1,
                                    deviceInfo: DeviceInfo(manufacturer: "", model: Self.machineIdentifier(),
                                                           androidVersion: 0))
        let manager = self.manager
        let (stream, continuation) = AsyncStream<BackupTransferProgressUpdate>.makeStream()
        let work = Task.detached(priority: .userInitiated) { () async throws -> [UInt8] in
            defer { continuation.finish() }
            return try await manager.export(sections: ordered, handlers: handlers, appInfo: appInfo) {
                continuation.yield($0)
            }
        }
        for await update in stream { progress = update }
        let bytes = try await work.value
        return BackupFileDocument(data: Data(bytes))
    }

    /// Each selected module's JSON payload, built from the stores (Android: every handler's `export()`).
    private func collectPayloads(for sections: Set<BackupSection>) async throws -> [BackupSection: String] {
        let snapshot = library.snapshot
        let songs = snapshot.songs.map(BackupSongSummary.init)
        let settingsValues = SettingsBackup.exportValues(defaults: defaults)
        let orderModes = (defaults.string(forKey: LibraryPreferences.playlistSongOrderModesKey)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:])
            .sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        let sortOption = defaults.string(forKey: PreferenceKeys.playlistsSortOption) ?? SortOption.playlistNameAZ.storageKey
        await history.ensureLoaded()
        let events = sections.contains(.playbackHistory) ? history.events : []
        let persistence = self.persistence

        return try await Task.detached(priority: .userInitiated) { () async throws -> [BackupSection: String] in
            var payloads: [BackupSection: String] = [:]
            var favorites: [FavoriteBackupEntry] = []
            var lyrics: [BackupLyricsRow] = []
            var engagement: [EngagementBackupEntry] = []
            var transitions: [TransitionRule] = []
            if let persistence {
                if sections.contains(.favorites) || sections.contains(.playlists) {
                    favorites = try await persistence.backupFavorites()
                }
                if sections.contains(.lyrics) || sections.contains(.playlists) { lyrics = try await persistence.backupLyrics() }
                if sections.contains(.engagementStats) || sections.contains(.playlists) {
                    engagement = try await persistence.engagementEntries().map { EngagementBackupEntry(songId: $0.songId, stats: $0.stats) }
                }
                if sections.contains(.transitions) || sections.contains(.playlists) {
                    transitions = try await persistence.transitionRules()
                }
            }
            if favorites.isEmpty {
                favorites = snapshot.songs.filter(\.isFavorite).map { FavoriteBackupEntry(backupSongId: $0.id, timestamp: 0) }
            }
            for section in sections {
                switch section {
                case .playlists:
                    // Metadata for every song the other modules mention, so they can be matched on another device.
                    var extra: [String] = []
                    var seen = Set<String>()
                    func add(_ id: String?) { if let id, seen.insert(id).inserted { extra.append(id) } }
                    favorites.forEach { add($0.backupSongId) }
                    lyrics.forEach { add($0.songId) }
                    engagement.forEach { add($0.songId) }
                    events.forEach { add($0.songId) }
                    transitions.forEach { add($0.fromTrackId); add($0.toTrackId) }
                    payloads[.playlists] = PlaylistsModule.export(
                        playlists: snapshot.playlists, library: songs, playlistSongOrderModes: orderModes,
                        playlistsSortOption: sortOption, extraSongIds: extra,
                        coverImage: { playlist in Self.fileBytes(playlist.coverImageUri) })
                case .globalSettings, .quickFill, .equalizer:
                    payloads[section] = PreferencesModule.export(section, values: settingsValues)
                case .favorites:
                    payloads[.favorites] = FavoritesModule.export(favorites)
                case .lyrics:
                    payloads[.lyrics] = LyricsModule.export(rows: lyrics.map {
                        LyricsBackupRow(backupSongId: $0.songId, content: $0.content, isSynced: $0.isSynced, source: $0.source)
                    })
                case .searchHistory:
                    payloads[.searchHistory] = SearchHistoryModule.export(try await persistence?.backupSearchHistory() ?? [])
                case .transitions:
                    payloads[.transitions] = TransitionsModule.export(transitions)
                case .engagementStats:
                    payloads[.engagementStats] = EngagementStatsModule.export(engagement)
                case .playbackHistory:
                    payloads[.playbackHistory] = PlaybackHistoryModule.export(events)
                case .artistImages:
                    let images = try await persistence?.backupArtistImages() ?? []
                    payloads[.artistImages] = ArtistImagesModule.export(images.map {
                        (name: $0.name, imageUrl: $0.imageUrl, customImage: Self.fileBytes($0.customImageUri))
                    })
                case .aiUsageLogs:
                    payloads[.aiUsageLogs] = AiUsageModule.export(try await persistence?.backupAIUsage() ?? [])
                }
            }
            return payloads
        }.value
    }

    // MARK: - Inspect

    /// Reads a picked file (security-scoped) and inspects it (Android `inspectBackupFile`).
    func inspect(url: URL) async throws -> InspectedBackup {
        guard !isBusy else { throw BackupError("A backup transfer is already running.") }
        isBusy = true
        defer { isBusy = false }
        let manager = self.manager
        return try await Task.detached(priority: .userInitiated) { () throws -> InspectedBackup in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > BackupReader.maxLegacyBackupBytes * 4 {
                throw BackupError("This file is too large to be a backup.")
            }
            let bytes = [UInt8](try Data(contentsOf: url, options: .mappedIfSafe))
            let plan = try manager.inspectBackup(bytes: bytes, fileName: url.lastPathComponent,
                                                 fileSize: Int64(bytes.count), backupUri: url.lastPathComponent)
            return InspectedBackup(bytes: bytes, fileName: url.lastPathComponent, plan: plan)
        }.value
    }

    // MARK: - Restore

    /// Restores `sections` of an inspected backup (Android `restoreFromPlan`) and reports what happened.
    func restore(_ backup: InspectedBackup, sections: Set<BackupSection>) async -> BackupRestoreReport {
        guard !isBusy else { return .failure("A backup transfer is already running.", fileName: backup.fileName) }
        isBusy = true
        defer {
            isBusy = false
            progress = nil
        }
        let selected = backup.plan.availableModules.filter(sections.contains)
            .sorted { $0.key < $1.key }
        let totalSteps = selected.count + 3
        var step = 0
        func report(_ title: String, _ detail: String, _ section: BackupSection? = nil) {
            step += 1
            progress = BackupTransferProgressUpdate(operation: .import, step: step, totalSteps: totalSteps, title: title,
                                                    detail: detail, section: section)
        }
        report(L10n.backupProgressPreparingRestore, L10n.backupProgressStartingTask)

        // Decode everything and map song ids onto this library, off the main actor.
        let songs = library.snapshot.songs.map(BackupSongSummary.init)
        let manager = self.manager
        let contents: BackupContents
        do {
            contents = try await Task.detached(priority: .userInitiated) { () throws -> BackupContents in
                try BackupImporter.importBackup(bytes: backup.bytes, fileName: backup.fileName, library: songs,
                                                sections: Set(selected), manager: manager)
            }.value
        } catch {
            return .failure(L10n.settingsRestoreFailedFormat(Self.message(of: error)), fileName: backup.fileName)
        }

        var result = BackupRestoreReport(fileName: backup.fileName, createdAt: backup.plan.manifest.createdAt,
                                         appVersion: backup.plan.manifest.appVersion ?? "",
                                         fromAndroid: backup.isFromAndroid, outcome: .success)
        result.warnings = contents.report.warnings
        result.skippedSettings = contents.report.skippedSettings
        for (section, message) in contents.report.failed {
            result.failures.append(.init(section: section, message: message))
        }

        var snapshot = library.snapshot
        let now = currentTimeMillis()
        for section in selected where contents.report.failed[section] == nil {
            report(L10n.backupProgressRestoring(section.label), section.description, section)
            let unmatched = contents.report.unresolvedSongs[section] ?? 0
            do {
                let restored = try await apply(section, contents: contents, snapshot: &snapshot, now: now)
                result.entries.append(.init(section: section, restored: restored,
                                            unmatched: section == .playlists ? 0 : unmatched))
                if section == .playlists { result.pendingPlaylistSongs = unmatched }
                if [.globalSettings, .quickFill, .equalizer].contains(section) { result.restoredSettings = true }
            } catch {
                result.failures.append(.init(section: section, message: Self.message(of: error)))
            }
        }
        result.failures.sort { $0.section.key < $1.section.key }

        report(L10n.backupProgressFinishing, L10n.backupProgressFinishingDetail)
        library.apply(snapshot)
        if let persistence, !isUITest {
            let cached = snapshot
            Task.detached(priority: .utility) {
                SnapshotLoader(persistence: persistence, cacheURL: SnapshotLoader.defaultCacheURL()).writeCache(cached)
            }
        }
        if result.restoredSettings {
            settings.reload(from: defaults)
            // The restore wrote AI keys (Keychain) and base URLs: the cached "is AI set up" answer is stale.
            AIProviderStatus.invalidate()
        }
        if selected.contains(.transitions) { await playbackServices?.reloadTransitionRules() }
        onRestored?()

        if result.entries.isEmpty, let first = result.failures.first {
            result.outcome = .failed(L10n.settingsRestoreFailedFormat("\(first.section.label): \(first.message)"))
        } else if !result.failures.isEmpty {
            result.outcome = .partial
        }
        return result
    }

    /// Writes one decoded module; returns how many items it restored.
    private func apply(_ section: BackupSection, contents: BackupContents, snapshot: inout LibrarySnapshot,
                       now: Int64) async throws -> Int {
        switch section {
        case .playlists:
            guard let restore = contents.playlists else { return 0 }
            var playlists = restore.playlists
            for index in playlists.indices {
                if let bytes = restore.coverImages[playlists[index].id],
                   let url = PlaylistCoverStore.save(Data(bytes), temporary: isUITest) {
                    playlists[index].coverImageUri = url.absoluteString
                }
            }
            try await persistence?.restorePlaylists(playlists)
            snapshot.playlists.removeAll { PlaylistsModule.localSources.contains($0.source) }
            let incoming = Set(playlists.map(\.id))
            snapshot.playlists.removeAll { incoming.contains($0.id) }
            snapshot.playlists.append(contentsOf: playlists)
            snapshot.playlists.sort { $0.sortOrder < $1.sortOrder }
            if let modes = try? JSONEncoder().encode(restore.playlistSongOrderModes) {
                defaults.set(String(decoding: modes, as: UTF8.self), forKey: LibraryPreferences.playlistSongOrderModesKey)
            }
            defaults.set(restore.playlistsSortOption, forKey: PreferenceKeys.playlistsSortOption)
            PendingPlaylistRestore.save(restore.pendingPayload, temporary: isUITest)
            return playlists.count

        case .globalSettings, .quickFill, .equalizer:
            let restore: PreferenceRestore? = switch section {
            case .globalSettings: contents.globalSettings
            case .quickFill: contents.quickFill
            default: contents.equalizer
            }
            guard let restore else { return 0 }
            let applied = SettingsBackup.apply(restore, defaults: defaults,
                                               keychainSet: isUITest ? { _, _ in false } : SettingsBackup.setKeychainString)
            return applied.applied + applied.keychain

        case .favorites:
            let entries = contents.favorites ?? []
            try await persistence?.restoreFavorites(entries)
            let liked = Set(entries.filter(\.isFavorite).map(\.backupSongId))
            for index in snapshot.songs.indices { snapshot.songs[index].isFavorite = liked.contains(snapshot.songs[index].id) }
            return liked.count

        case .lyrics:
            var rows = (contents.lyrics ?? []).map {
                BackupLyricsRow(songId: $0.backupSongId, content: $0.content, isSynced: $0.isSynced, source: $0.source)
            }
            let covered = Set(rows.map(\.songId))
            for file in contents.lyricsFiles ?? [] where !covered.contains(file.songId) {
                guard let cache = file.file.cacheData, let raw = cache.preferredRawLyrics else { continue }
                let synced = cache.lyricsDocument != nil || cache.syncedLyrics != nil || cache.wordByWordLyrics != nil
                rows.append(BackupLyricsRow(songId: file.songId, content: raw, isSynced: synced, source: "backup"))
            }
            try await persistence?.restoreLyrics(rows, updatedAt: now)
            return rows.count

        case .searchHistory:
            let items = contents.searchHistory ?? []
            try await persistence?.restoreSearchHistory(items)
            return items.count

        case .transitions:
            let rules = contents.transitions ?? []
            try await persistence?.restoreTransitionRules(rules)
            return rules.count

        case .engagementStats:
            let entries = contents.engagementStats ?? []
            try await persistence?.restoreEngagement(entries)
            return entries.count

        case .playbackHistory:
            let events = contents.playbackHistory ?? []
            await history.ensureLoaded()
            history.importEvents(events, clearExisting: true)
            return events.count

        case .artistImages:
            let restores = contents.artistImages ?? []
            let isUITest = self.isUITest
            let images = restores.map { restore in
                StoredArtistImage(name: restore.artistName, imageUrl: restore.imageUrl,
                                  customImageUri: restore.customImage.flatMap {
                                      PlaylistCoverStore.save(Data($0), temporary: isUITest)?.absoluteString
                                  })
            }
            let matched = try await persistence?.restoreArtistImages(images) ?? 0
            var byName: [String: StoredArtistImage] = [:]
            for image in images { byName[image.name.lowercased()] = image }
            for index in snapshot.artists.indices {
                guard let image = byName[snapshot.artists[index].name.lowercased()] else { continue }
                if let url = image.imageUrl { snapshot.artists[index].imageUrl = url }
                if let custom = image.customImageUri { snapshot.artists[index].customImageUri = custom }
            }
            return matched

        case .aiUsageLogs:
            let records = contents.aiUsage ?? []
            try await persistence?.restoreAIUsage(records)
            return records.count
        }
    }

    // MARK: - Pending playlists

    private func observeLibrary() {
        withObservationTracking {
            _ = library.snapshot
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.libraryChanged()
                self?.observeLibrary()
            }
        }
    }

    /// Android `resolvePendingPlaylists`: after a scan, re-match the pending payload and grow the playlists that
    /// now find more songs; the file goes once everything resolved.
    private func libraryChanged() {
        let songCount = library.snapshot.songs.count
        guard songCount != lastPendingSongCount, !isBusy, pendingTask == nil,
              let payload = PendingPlaylistRestore.load() else { return }
        lastPendingSongCount = songCount
        let current = library.snapshot.playlists
        let songs = library.snapshot.songs.map(BackupSongSummary.init)
        let persistence = self.persistence
        pendingTask = Task { [weak self] in
            let (updated, done) = await Task.detached(priority: .utility) {
                PlaylistsModule.resolvePending(payload: payload, current: current, library: songs)
            }.value
            guard let self else { return }
            if let updated {
                try? await persistence?.updatePlaylistSongs(updated)
                var snapshot = self.library.snapshot
                let byId = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for index in snapshot.playlists.indices {
                    if let playlist = byId[snapshot.playlists[index].id] { snapshot.playlists[index].songIds = playlist.songIds }
                }
                self.library.apply(snapshot)
            }
            if done { PendingPlaylistRestore.save(nil, temporary: false) }
            self.pendingTask = nil
        }
    }

    // MARK: - Helpers

    nonisolated private static func fileBytes(_ uri: String?) -> [UInt8]? {
        guard let uri, let url = URL(string: uri), url.isFileURL, let data = try? Data(contentsOf: url) else { return nil }
        return [UInt8](data)
    }

    nonisolated private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    nonisolated static func message(of error: any Error) -> String {
        if let error = error as? BackupError { return error.message }
        return error.localizedDescription
    }
}

/// Hands a prepared payload to `BackupManager.export` (the data was collected before packaging starts).
nonisolated private struct ExportPayloadHandler: BackupModuleHandler {
    let section: BackupSection
    let payload: String

    func export() async throws -> String { payload }
    func countEntries() async throws -> Int { Int(BackupWriter.countJsonArrayEntries(payload)) }
    func snapshot() async throws -> String { throw BackupError("Export only.") }
    func restore(_ payload: String) async throws { throw BackupError("Export only.") }
    func rollback(_ snapshot: String) async throws { throw BackupError("Export only.") }
}

/// Android's `pending_playlists_restore.json`: a playlists payload whose songs weren't all found yet.
nonisolated enum PendingPlaylistRestore {
    static func url(temporary: Bool = false) -> URL? {
        let base = temporary ? FileManager.default.temporaryDirectory
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("pending_playlists_restore.json")
    }

    static func load() -> String? {
        guard let url = url(), let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ payload: String?, temporary: Bool) {
        guard !temporary, let url = url() else { return }
        if let payload {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(payload.utf8).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
