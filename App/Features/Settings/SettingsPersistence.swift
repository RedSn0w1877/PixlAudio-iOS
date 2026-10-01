import Foundation
import PixlModel
import SwiftData

/// A music folder the user picked (a `FolderSourceRecord`), as a value.
nonisolated struct MusicFolderSource: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let bookmark: Data
    let isEnabled: Bool
    let lastScanAt: Int64?
}

/// One AI request (Android `AiUsageEntity`), for the usage report.
nonisolated struct AIUsageEntry: Identifiable, Hashable, Sendable {
    let id: String
    let timestamp: Int64
    let provider: String
    let model: String
    let promptType: String
    let promptTokens: Int
    let outputTokens: Int
    let thoughtTokens: Int
}

/// Stage 7d's queries. Names carry a `settings` prefix so they never collide with other stages' extensions.
extension PersistenceActor {
    // MARK: Music folders (FolderSourceRecord)

    func settingsFolderSources() throws -> [MusicFolderSource] {
        try modelContext.fetch(FetchDescriptor<FolderSourceRecord>(sortBy: [SortDescriptor(\.addedAt)])).map {
            MusicFolderSource(id: $0.id, displayName: $0.displayName, bookmark: $0.bookmark, isEnabled: $0.isEnabled,
                              lastScanAt: $0.lastScanAt)
        }
    }

    func settingsAddFolderSource(displayName: String, bookmark: Data, addedAt: Int64) throws {
        modelContext.insert(FolderSourceRecord(displayName: displayName, bookmark: bookmark, addedAt: addedAt))
        try modelContext.save()
    }

    func settingsRemoveFolderSource(id: String) throws {
        try modelContext.delete(model: FolderSourceRecord.self, where: #Predicate { $0.id == id })
        try modelContext.save()
    }

    // MARK: Library maintenance

    /// Android `resetAllLyrics`: forget every stored / imported lyric.
    func settingsDeleteAllLyrics() throws {
        try modelContext.delete(model: LyricsRecord.self)
        try modelContext.save()
    }

    /// Android "Rebuild database": drop the scanned library with its lyrics and favourites (playlists stay); a full
    /// rescan follows.
    func settingsClearLibraryForRebuild() throws {
        try modelContext.delete(model: SongRecord.self)
        try modelContext.delete(model: AlbumRecord.self)
        try modelContext.delete(model: ArtistRecord.self)
        try modelContext.delete(model: SongArtistLinkRecord.self)
        try modelContext.delete(model: LyricsRecord.self)
        try modelContext.delete(model: FavoriteRecord.self)
        try modelContext.save()
    }

    // MARK: Transition rules (Android `TransitionRepository`, playlist defaults)

    /// The playlist's default rule (no from/to track), if any.
    func settingsPlaylistTransition(playlistId: String) throws -> TransitionSettings? {
        let records = try modelContext.fetch(FetchDescriptor<TransitionRuleRecord>(
            predicate: #Predicate { $0.playlistId == playlistId && $0.fromTrackId == nil && $0.toTrackId == nil }))
        guard let record = records.first, let data = record.settingsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TransitionSettings.self, from: data)
    }

    func settingsSavePlaylistTransition(playlistId: String, settings: TransitionSettings) throws {
        try settingsDeletePlaylistTransition(playlistId: playlistId)
        let json = String(data: try JSONEncoder().encode(settings), encoding: .utf8) ?? "{}"
        modelContext.insert(TransitionRuleRecord(playlistId: playlistId, fromTrackId: nil, toTrackId: nil,
                                                 settingsJSON: json))
        try modelContext.save()
    }

    func settingsDeletePlaylistTransition(playlistId: String) throws {
        try modelContext.delete(model: TransitionRuleRecord.self, where: #Predicate {
            $0.playlistId == playlistId && $0.fromTrackId == nil && $0.toTrackId == nil
        })
        try modelContext.save()
    }

    // MARK: AI usage (AIUsageRecord)

    /// The 50 most recent requests, newest first (Android `recentAiUsage`), and the all-time token totals.
    func settingsAiUsage() throws -> (recent: [AIUsageEntry], prompt: Int, output: Int, thought: Int) {
        let all = try modelContext.fetch(FetchDescriptor<AIUsageRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]))
        let recent = all.prefix(50).map {
            AIUsageEntry(id: $0.id, timestamp: $0.timestamp, provider: $0.provider, model: $0.model,
                         promptType: $0.promptType, promptTokens: $0.promptTokens, outputTokens: $0.outputTokens,
                         thoughtTokens: $0.thoughtTokens)
        }
        return (Array(recent), all.reduce(0) { $0 + $1.promptTokens }, all.reduce(0) { $0 + $1.outputTokens },
                all.reduce(0) { $0 + $1.thoughtTokens })
    }

    func settingsClearAiUsage() throws {
        try modelContext.delete(model: AIUsageRecord.self)
        try modelContext.save()
    }
}
