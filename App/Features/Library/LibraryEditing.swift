import Foundation
import PixlLibrary
import PixlModel
import SwiftData

// Library edits made from the Library and detail screens (Android `PlaylistViewModel` / `PlayerViewModel` actions):
// favourites, playlists (create, edit, delete, merge, reorder, add/remove songs) and removing songs. Each edit
// updates the in-memory snapshot first (the UI reacts at once) and then writes through `PersistenceActor` off the
// main thread, refreshing the launch snapshot cache.

/// One song's engagement row (Android `song_engagement`), for smart-playlist rules.
nonisolated struct EngagementEntry: Sendable, Hashable {
    let songId: String
    let stats: EngagementStats
}

extension PersistenceActor {
    /// Inserts or replaces a playlist and its entries. `smartRuleKey` is kept in `smartRulesJSON` as
    /// `{"rule":"<SmartPlaylistRule storage key>"}` (Android stores the rule key the playlist was built from).
    func upsertPlaylist(_ playlist: Playlist, smartRuleKey: String?) throws {
        let id = playlist.id
        var descriptor = FetchDescriptor<UserPlaylistRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first
        let rulesJSON = smartRuleKey.map { "{\"rule\":\"\($0)\"}" } ?? existing?.smartRulesJSON
        let transitionJSON = existing?.transitionJSON
        if let existing { modelContext.delete(existing) }
        let record = LibraryRecordMapping.record(playlist)
        record.smartRulesJSON = rulesJSON
        record.transitionJSON = transitionJSON
        modelContext.insert(record)
        try modelContext.delete(model: PlaylistEntryRecord.self, where: #Predicate { $0.playlistId == id })
        for (position, songId) in playlist.songIds.enumerated() {
            modelContext.insert(PlaylistEntryRecord(playlistId: id, songId: songId, position: position))
        }
        try modelContext.save()
    }

    func deletePlaylists(_ ids: [String]) throws {
        try modelContext.delete(model: UserPlaylistRecord.self, where: #Predicate { ids.contains($0.id) })
        try modelContext.delete(model: PlaylistEntryRecord.self, where: #Predicate { ids.contains($0.playlistId) })
        try modelContext.save()
    }

    /// Writes `sortOrder` for each playlist id in order (Android `savePlaylistOrder`).
    func savePlaylistOrder(_ ids: [String]) throws {
        let records = try modelContext.fetch(FetchDescriptor<UserPlaylistRecord>(predicate: #Predicate { ids.contains($0.id) }))
        let positions = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for record in records { record.sortOrder = positions[record.id] ?? record.sortOrder }
        try modelContext.save()
    }

    /// Marks songs as (un)liked: the song rows and the `favorites` table with the like time (Android
    /// `FavoritesDao`; the Liked tab sorts by that time).
    func setFavorites(_ songIds: [String], isFavorite: Bool, timestamp: Int64) throws {
        let songs = try modelContext.fetch(FetchDescriptor<SongRecord>(predicate: #Predicate { songIds.contains($0.id) }))
        for song in songs { song.isFavorite = isFavorite }
        try modelContext.delete(model: FavoriteRecord.self, where: #Predicate { songIds.contains($0.songId) })
        if isFavorite {
            for songId in songIds { modelContext.insert(FavoriteRecord(songId: songId, isFavorite: true, timestamp: timestamp)) }
        }
        try modelContext.save()
    }

    /// Like times by song id (Android `favorites.timestamp`).
    func favoriteTimestamps() throws -> [String: Int64] {
        let records = try modelContext.fetch(FetchDescriptor<FavoriteRecord>(predicate: #Predicate { $0.isFavorite }))
        return Dictionary(records.map { ($0.songId, $0.timestamp) }, uniquingKeysWith: { first, _ in first })
    }

    /// The engagement table in storage order (smart-playlist rules).
    func engagementEntries() throws -> [EngagementEntry] {
        try modelContext.fetch(FetchDescriptor<EngagementRecord>()).map {
            EngagementEntry(songId: $0.songId, stats: EngagementStats(playCount: $0.playCount,
                                                                     totalPlayDurationMs: $0.totalPlayDurationMs,
                                                                     lastPlayedTimestamp: $0.lastPlayedTimestamp))
        }
    }

    /// Sets the genre of songs (Android `batchEditGenre`, the Quick Fill dialog). Tag write-back is stage 6's job.
    func setGenre(_ songIds: [String], genre: String) throws {
        let songs = try modelContext.fetch(FetchDescriptor<SongRecord>(predicate: #Predicate { songIds.contains($0.id) }))
        for song in songs { song.genre = genre }
        try modelContext.save()
    }

    /// Removes songs from the library (Android "Delete" after the file is gone): rows, links, favourites, entries.
    func deleteSongs(_ songIds: [String]) throws {
        try modelContext.delete(model: SongRecord.self, where: #Predicate { songIds.contains($0.id) })
        try modelContext.delete(model: SongArtistLinkRecord.self, where: #Predicate { songIds.contains($0.songId) })
        try modelContext.delete(model: FavoriteRecord.self, where: #Predicate { songIds.contains($0.songId) })
        try modelContext.delete(model: PlaylistEntryRecord.self, where: #Predicate { songIds.contains($0.songId) })
        try modelContext.save()
    }
}

/// The edit actions, bound to the library store and the persistence actor. Get one from the environment:
/// `@Environment(AppEnvironment.self) var env` → `env.libraryEditor`.
@MainActor
struct LibraryEditor {
    let store: LibraryStore
    let persistence: PersistenceActor?
    /// UI tests keep the launch cache untouched.
    let writesCache: Bool

    // MARK: Favourites

    func isFavorite(_ songId: String) -> Bool { store.song(id: songId)?.isFavorite ?? false }

    func toggleFavorite(_ songId: String) {
        setFavorite([songId], !isFavorite(songId))
    }

    func setFavorite(_ songIds: [String], _ isFavorite: Bool) {
        guard !songIds.isEmpty else { return }
        let ids = Set(songIds)
        var snapshot = store.snapshot
        for index in snapshot.songs.indices where ids.contains(snapshot.songs[index].id) {
            snapshot.songs[index].isFavorite = isFavorite
        }
        commit(snapshot) { persistence in
            try await persistence.setFavorites(songIds, isFavorite: isFavorite, timestamp: currentTimeMillis())
        }
    }

    // MARK: Playlists

    /// Creates a playlist (Android `createPlaylist`); the new one goes last in the custom order.
    @discardableResult
    func createPlaylist(name: String, songIds: [String], coverImageUri: String? = nil, coverColorArgb: Int32? = nil,
                        coverIconName: String? = nil, coverShapeType: String? = nil, shapeDetails: [Float?] = [],
                        smartRuleKey: String? = nil, isAiGenerated: Bool = false) -> Playlist {
        let now = currentTimeMillis()
        let detail: (Int) -> Float? = { shapeDetails.indices.contains($0) ? shapeDetails[$0] : nil }
        let playlist = Playlist(id: UUID().uuidString, name: name, songIds: songIds.kotlinDistinctIds(), createdAt: now,
                                lastModified: now, isAiGenerated: isAiGenerated, coverImageUri: coverImageUri,
                                coverColorArgb: coverColorArgb, coverIconName: coverIconName,
                                coverShapeType: coverShapeType, coverShapeDetail1: detail(0),
                                coverShapeDetail2: detail(1), coverShapeDetail3: detail(2), coverShapeDetail4: detail(3),
                                sortOrder: (store.playlists.map(\.sortOrder).max() ?? -1) + 1)
        var snapshot = store.snapshot
        snapshot.playlists.append(playlist)
        commit(snapshot) { try await $0.upsertPlaylist(playlist, smartRuleKey: smartRuleKey) }
        return playlist
    }

    /// Replaces a playlist's fields (name, cover, songs).
    func updatePlaylist(_ playlist: Playlist) {
        var updated = playlist
        updated.lastModified = currentTimeMillis()
        var snapshot = store.snapshot
        guard let index = snapshot.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        snapshot.playlists[index] = updated
        commit(snapshot) { try await $0.upsertPlaylist(updated, smartRuleKey: nil) }
    }

    func deletePlaylists(_ ids: [String]) {
        let set = Set(ids)
        var snapshot = store.snapshot
        snapshot.playlists.removeAll { set.contains($0.id) }
        commit(snapshot) { try await $0.deletePlaylists(ids) }
    }

    /// Adds songs that are not in the playlist yet, at the end (Android `addSongsToPlaylist`).
    func addSongs(_ songIds: [String], toPlaylist playlistId: String) {
        guard var playlist = store.playlist(id: playlistId) else { return }
        let existing = Set(playlist.songIds)
        playlist.songIds += songIds.filter { !existing.contains($0) }.kotlinDistinctIds()
        updatePlaylist(playlist)
    }

    func removeSong(_ songId: String, fromPlaylist playlistId: String) {
        guard var playlist = store.playlist(id: playlistId) else { return }
        playlist.songIds.removeAll { $0 == songId }
        updatePlaylist(playlist)
    }

    /// Applies a drag order of the visible songs (`mergePlaylistOrder` keeps hidden entries).
    func setSongOrder(_ songIds: [String], inPlaylist playlistId: String) {
        guard var playlist = store.playlist(id: playlistId) else { return }
        playlist.songIds = LibrarySorting.mergePlaylistOrder(currentIds: playlist.songIds, requestedIds: songIds)
        updatePlaylist(playlist)
    }

    /// Saves the custom playlist order (Android `savePlaylistOrder`).
    func savePlaylistOrder(_ ids: [String]) {
        var snapshot = store.snapshot
        let positions = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for index in snapshot.playlists.indices {
            if let position = positions[snapshot.playlists[index].id] { snapshot.playlists[index].sortOrder = position }
        }
        snapshot.playlists.sort { $0.sortOrder < $1.sortOrder }
        commit(snapshot) { try await $0.savePlaylistOrder(ids) }
    }

    /// Android `mergePlaylistsIntoOne`: a new playlist with every song of the selection (in selection order,
    /// duplicates dropped); the originals are kept.
    func mergePlaylists(_ ids: [String], name: String) {
        let songIds = ids.compactMap { store.playlist(id: $0) }.flatMap(\.songIds)
        createPlaylist(name: name, songIds: songIds)
    }

    // MARK: Songs

    /// Removes songs from the library (Android "Delete" — on iOS the file itself is the import stage's job).
    func removeSongs(_ songIds: [String]) {
        let set = Set(songIds)
        var snapshot = store.snapshot
        snapshot.songs.removeAll { set.contains($0.id) }
        for index in snapshot.playlists.indices { snapshot.playlists[index].songIds.removeAll { set.contains($0) } }
        commit(snapshot) { try await $0.deleteSongs(songIds) }
    }

    /// Android `batchEditGenre`: gives every song the genre (Quick Fill).
    func setGenre(_ songIds: [String], genre: String) {
        let set = Set(songIds)
        var snapshot = store.snapshot
        for index in snapshot.songs.indices where set.contains(snapshot.songs[index].id) {
            snapshot.songs[index].genre = genre
        }
        commit(snapshot) { try await $0.setGenre(songIds, genre: genre) }
    }

    // MARK: Reads

    func favoriteTimestamps() async -> [String: Int64] {
        guard let persistence else { return [:] }
        return (try? await persistence.favoriteTimestamps()) ?? [:]
    }

    func engagementEntries() async -> [EngagementEntry] {
        guard let persistence else { return [] }
        return (try? await persistence.engagementEntries()) ?? []
    }

    // MARK: -

    private func commit(_ snapshot: LibrarySnapshot,
                        write: @escaping @Sendable (PersistenceActor) async throws -> Void) {
        store.apply(snapshot)
        guard let persistence else { return }
        let writesCache = self.writesCache
        Task.detached(priority: .utility) {
            try? await write(persistence)
            if writesCache {
                SnapshotLoader(persistence: persistence, cacheURL: SnapshotLoader.defaultCacheURL()).writeCache(snapshot)
            }
        }
    }
}

extension AppEnvironment {
    /// Library edits from the Library / detail screens.
    var libraryEditor: LibraryEditor {
        LibraryEditor(store: library, persistence: persistence, writesCache: !launch.isUITest)
    }
}

private extension Array where Element == String {
    /// Distinct, first occurrence wins (Kotlin `distinct()`).
    func kotlinDistinctIds() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
