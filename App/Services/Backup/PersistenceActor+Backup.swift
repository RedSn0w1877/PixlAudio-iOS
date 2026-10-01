import Foundation
import PixlBackup
import PixlLibrary
import PixlModel
import SwiftData

// The backup modules' data in SwiftData (Android: each `BackupModuleHandler`'s DAO calls). Reads hand out PixlBackup /
// PixlModel values; restores replace a module's table the way the Android handlers do (clear, then insert).

/// A lyrics row as stored here (`LyricsRecord`): the raw text (document JSON, LRC or plain), like Android's
/// `lyrics.content`.
nonisolated struct StoredLyricsRow: Sendable, Hashable {
    var songId: String
    var content: String
    var isSynced: Bool
    var source: String?
}

/// An artist's image fields (`ArtistRecord.imageUrl` / `customImageUri`).
nonisolated struct StoredArtistImage: Sendable, Hashable {
    var name: String
    var imageUrl: String?
    var customImageUri: String?
}

extension PersistenceActor {
    // MARK: Reads (export)

    /// `FavoritesDao.getAll`: liked songs with their like time.
    func backupFavorites() throws -> [FavoriteBackupEntry] {
        try modelContext.fetch(FetchDescriptor<FavoriteRecord>(sortBy: [SortDescriptor(\.timestamp)]))
            .filter(\.isFavorite)
            .map { FavoriteBackupEntry(backupSongId: $0.songId, isFavorite: true, timestamp: $0.timestamp) }
    }

    func backupLyrics() throws -> [StoredLyricsRow] {
        try modelContext.fetch(FetchDescriptor<LyricsRecord>(sortBy: [SortDescriptor(\.songId)])).map {
            StoredLyricsRow(songId: $0.songId, content: $0.docJSON, isSynced: $0.isSynced, source: $0.source)
        }
    }

    func backupSearchHistory() throws -> [SearchHistoryItem] {
        try modelContext.fetch(FetchDescriptor<SearchHistoryRecord>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)]))
            .map { SearchHistoryItem(id: nil, query: $0.query, timestamp: $0.timestamp) }
    }

    func backupAIUsage() throws -> [AiUsageRecord] {
        try modelContext.fetch(FetchDescriptor<AIUsageRecord>(sortBy: [SortDescriptor(\.timestamp)])).enumerated().map {
            AiUsageRecord(id: Int64($0.offset + 1), timestamp: $0.element.timestamp, provider: $0.element.provider,
                          model: $0.element.model, promptType: $0.element.promptType,
                          promptTokens: $0.element.promptTokens, outputTokens: $0.element.outputTokens,
                          thoughtTokens: $0.element.thoughtTokens)
        }
    }

    func backupArtistImages() throws -> [StoredArtistImage] {
        try modelContext.fetch(FetchDescriptor<ArtistRecord>(sortBy: [SortDescriptor(\.name)])).compactMap {
            guard $0.imageUrl != nil || $0.customImageUri != nil else { return nil }
            return StoredArtistImage(name: $0.name, imageUrl: $0.imageUrl, customImageUri: $0.customImageUri)
        }
    }

    // MARK: Restores

    /// Replaces the local and AI playlists (`PlaylistsModuleHandler.restore`); other sources are kept.
    func restorePlaylists(_ playlists: [Playlist]) throws {
        let existing = try modelContext.fetch(FetchDescriptor<UserPlaylistRecord>())
        let replaced = existing.filter { PlaylistsModule.localSources.contains($0.source) }.map(\.id)
        if !replaced.isEmpty {
            try modelContext.delete(model: UserPlaylistRecord.self, where: #Predicate { replaced.contains($0.id) })
            try modelContext.delete(model: PlaylistEntryRecord.self, where: #Predicate { replaced.contains($0.playlistId) })
        }
        let incoming = playlists.map(\.id)
        try modelContext.delete(model: UserPlaylistRecord.self, where: #Predicate { incoming.contains($0.id) })
        try modelContext.delete(model: PlaylistEntryRecord.self, where: #Predicate { incoming.contains($0.playlistId) })
        for playlist in playlists {
            modelContext.insert(LibraryRecordMapping.record(playlist))
            for (position, songId) in playlist.songIds.enumerated() {
                modelContext.insert(PlaylistEntryRecord(playlistId: playlist.id, songId: songId, position: position))
            }
        }
        try modelContext.save()
    }

    /// Updates playlists in place (a pending restore that resolved more songs after a scan).
    func updatePlaylistSongs(_ playlists: [Playlist]) throws {
        for playlist in playlists {
            let id = playlist.id
            try modelContext.delete(model: PlaylistEntryRecord.self, where: #Predicate { $0.playlistId == id })
            for (position, songId) in playlist.songIds.enumerated() {
                modelContext.insert(PlaylistEntryRecord(playlistId: id, songId: songId, position: position))
            }
        }
        try modelContext.save()
    }

    /// `FavoritesModuleHandler.restore`: clears every like, then likes the restored songs.
    func restoreFavorites(_ entries: [FavoriteBackupEntry]) throws {
        try modelContext.delete(model: FavoriteRecord.self)
        let liked = try modelContext.fetch(FetchDescriptor<SongRecord>(predicate: #Predicate { $0.isFavorite }))
        for song in liked { song.isFavorite = false }
        var seen = Set<String>()
        let ids = entries.filter(\.isFavorite).map(\.backupSongId)
        let songs = try modelContext.fetch(FetchDescriptor<SongRecord>(predicate: #Predicate { ids.contains($0.id) }))
        for song in songs { song.isFavorite = true }
        for entry in entries where entry.isFavorite && seen.insert(entry.backupSongId).inserted {
            modelContext.insert(FavoriteRecord(songId: entry.backupSongId, isFavorite: true, timestamp: entry.timestamp))
        }
        try modelContext.save()
    }

    /// `LyricsModuleHandler.restore`: the restored rows replace the stored lyrics of those songs.
    func restoreLyrics(_ rows: [StoredLyricsRow], updatedAt: Int64) throws {
        let ids = rows.map(\.songId)
        try modelContext.delete(model: LyricsRecord.self, where: #Predicate { ids.contains($0.songId) })
        var seen = Set<String>()
        for row in rows.reversed() where seen.insert(row.songId).inserted {
            modelContext.insert(LyricsRecord(songId: row.songId, docJSON: row.content, isSynced: row.isSynced,
                                             source: row.source, updatedAt: updatedAt))
        }
        try modelContext.save()
    }

    func restoreSearchHistory(_ items: [SearchHistoryItem]) throws {
        try modelContext.delete(model: SearchHistoryRecord.self)
        var seen = Set<String>()
        for item in items.sorted(by: { $0.timestamp > $1.timestamp }) where seen.insert(item.query).inserted {
            modelContext.insert(SearchHistoryRecord(query: item.query, timestamp: item.timestamp))
        }
        try modelContext.save()
    }

    /// `TransitionsModuleHandler.restore`: every rule replaced (`TransitionSettings` stored as JSON).
    func restoreTransitionRules(_ rules: [TransitionRule]) throws {
        try modelContext.delete(model: TransitionRuleRecord.self)
        let encoder = JSONEncoder()
        for rule in rules {
            guard let data = try? encoder.encode(rule.settings), let json = String(data: data, encoding: .utf8) else { continue }
            modelContext.insert(TransitionRuleRecord(playlistId: rule.playlistId, fromTrackId: rule.fromTrackId,
                                                     toTrackId: rule.toTrackId, settingsJSON: json))
        }
        try modelContext.save()
    }

    func restoreEngagement(_ entries: [EngagementBackupEntry]) throws {
        try modelContext.delete(model: EngagementRecord.self)
        for entry in entries {
            modelContext.insert(EngagementRecord(songId: entry.songId, playCount: entry.stats.playCount,
                                                 totalPlayDurationMs: entry.stats.totalPlayDurationMs,
                                                 lastPlayedTimestamp: entry.stats.lastPlayedTimestamp))
        }
        try modelContext.save()
    }

    func restoreAIUsage(_ records: [AiUsageRecord]) throws {
        try modelContext.delete(model: AIUsageRecord.self)
        for r in records {
            modelContext.insert(AIUsageRecord(timestamp: r.timestamp, provider: r.provider, model: r.model,
                                              promptType: r.promptType, promptTokens: r.promptTokens,
                                              outputTokens: r.outputTokens, thoughtTokens: r.thoughtTokens))
        }
        try modelContext.save()
    }

    /// `ArtistImagesModuleHandler.restore`: matched by artist name (case-insensitive); returns how many matched.
    func restoreArtistImages(_ images: [StoredArtistImage]) throws -> Int {
        var byName: [String: StoredArtistImage] = [:]
        for image in images { byName[image.name.lowercased()] = image }
        var matched = 0
        for artist in try modelContext.fetch(FetchDescriptor<ArtistRecord>()) {
            guard let image = byName[artist.name.lowercased()] else { continue }
            if let url = image.imageUrl { artist.imageUrl = url }
            if let custom = image.customImageUri { artist.customImageUri = custom }
            matched += 1
        }
        try modelContext.save()
        return matched
    }
}
