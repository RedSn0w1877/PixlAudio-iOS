import Foundation
import PixlLibrary
import PixlModel
import SwiftData

/// The only code that touches SwiftData. A `@ModelActor`, so every read and write runs off the main thread on its
/// own context; it hands out `Sendable` value types (`LibrarySnapshot`, `ColorRolesPair`, …), never models.
/// Stages add their own queries in `extension PersistenceActor` files next to their feature.
@ModelActor
actor PersistenceActor {
    /// Writes are batched: `save()` every this many inserts (architecture §2).
    static let batchSize = 500

    /// The app's container: on disk normally, in memory for UI tests and previews.
    static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        // No App Group, no CloudKit (free signing, decision 4).
        let configuration = ModelConfiguration("PixlAudio", schema: schema, isStoredInMemoryOnly: inMemory,
                                               groupContainer: .none, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: PixlMigrationPlan.self, configurations: [configuration])
    }

    // MARK: Library snapshot

    /// How many times the whole song table was read (a snapshot, a scan's diff). Tests assert that a rescan with
    /// nothing to do reads it zero times.
    var fullLibraryReads = 0
    /// The pending coalesced save of album-art themes (`saveArtworkTheme`).
    private var themeSave: Task<Void, Never>?

    /// Reads the whole library into value types (called off the main thread at launch / after a scan).
    func loadLibrarySnapshot() throws -> LibrarySnapshot {
        fullLibraryReads += 1
        let decoder = JSONDecoder()
        let songs = try modelContext.fetch(FetchDescriptor<SongRecord>(sortBy: [SortDescriptor(\.title)]))
            .map { LibraryRecordMapping.song($0, decoder: decoder) }
        let albums = try modelContext.fetch(FetchDescriptor<AlbumRecord>(sortBy: [SortDescriptor(\.title)]))
            .map(LibraryRecordMapping.album)
        let artists = try modelContext.fetch(FetchDescriptor<ArtistRecord>(sortBy: [SortDescriptor(\.name)]))
            .map(LibraryRecordMapping.artist)
        let entries = try modelContext.fetch(FetchDescriptor<PlaylistEntryRecord>(sortBy: [SortDescriptor(\.position)]))
        var songIdsByPlaylist: [String: [String]] = [:]
        for entry in entries { songIdsByPlaylist[entry.playlistId, default: []].append(entry.songId) }
        let playlists = try modelContext.fetch(FetchDescriptor<UserPlaylistRecord>(sortBy: [SortDescriptor(\.sortOrder)]))
            .map { LibraryRecordMapping.playlist($0, songIds: songIdsByPlaylist[$0.id] ?? []) }
        return LibrarySnapshot(songs: songs, albums: albums, artists: artists, playlists: playlists)
    }

    /// Replaces the stored library with `snapshot` (demo data, a full rescan). Inserts in batches.
    func replaceLibrary(with snapshot: LibrarySnapshot) throws {
        try modelContext.delete(model: SongRecord.self)
        try modelContext.delete(model: AlbumRecord.self)
        try modelContext.delete(model: ArtistRecord.self)
        try modelContext.delete(model: SongArtistLinkRecord.self)
        try modelContext.delete(model: UserPlaylistRecord.self)
        try modelContext.delete(model: PlaylistEntryRecord.self)
        var pending = 0
        func tick() throws {
            pending += 1
            if pending >= Self.batchSize {
                try modelContext.save()
                pending = 0
            }
        }
        for song in snapshot.songs {
            modelContext.insert(LibraryRecordMapping.record(song))
            for ref in song.artists {
                modelContext.insert(SongArtistLinkRecord(songId: song.id, artistId: ref.id, isPrimary: ref.isPrimary))
            }
            try tick()
        }
        for album in snapshot.albums {
            modelContext.insert(LibraryRecordMapping.record(album))
            try tick()
        }
        for artist in snapshot.artists {
            modelContext.insert(LibraryRecordMapping.record(artist))
            try tick()
        }
        for playlist in snapshot.playlists {
            modelContext.insert(LibraryRecordMapping.record(playlist))
            for (position, songId) in playlist.songIds.enumerated() {
                modelContext.insert(PlaylistEntryRecord(playlistId: playlist.id, songId: songId, position: position))
            }
            try tick()
        }
        try modelContext.save()
    }

    // MARK: Album-art themes (Android `AlbumArtThemeDao`)

    func artworkTheme(key: String) throws -> ColorRolesPair? {
        var descriptor = FetchDescriptor<ArtworkThemeRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        return try? JSONDecoder().decode(ColorRolesPair.self, from: record.pairJSON)
    }

    /// A stored theme as plain data (the warm-up decodes the JSON off the actor).
    nonisolated struct ArtworkThemeRow: Sendable {
        let key: String
        let pairJSON: Data
    }

    /// Every stored theme of one palette (style + accuracy), for `ColorExtractor.warm`.
    func artworkThemeRows(paletteKey: String) throws -> [ArtworkThemeRow] {
        try modelContext.fetch(FetchDescriptor<ArtworkThemeRecord>(predicate: #Predicate { $0.paletteKey == paletteKey }))
            .map { ArtworkThemeRow(key: $0.key, pairJSON: $0.pairJSON) }
    }

    func saveArtworkTheme(key: String, artworkKey: String, paletteKey: String, pair: ColorRolesPair) throws {
        let data = try JSONEncoder().encode(pair)
        var descriptor = FetchDescriptor<ArtworkThemeRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.pairJSON = data
        } else {
            modelContext.insert(ArtworkThemeRecord(key: key, artworkKey: artworkKey, paletteKey: paletteKey, pairJSON: data))
        }
        scheduleThemeSave()
    }

    /// Themes are a cache: a burst of extractions (an album grid scrolling past) is saved once, half a second after the
    /// first of them, instead of one save per card on this serial actor. Reads on the context see the unsaved rows, and
    /// any other save on this context writes them too.
    private func scheduleThemeSave() {
        guard themeSave == nil else { return }
        themeSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.flushThemeSave()
        }
    }

    private func flushThemeSave() {
        themeSave = nil
        try? modelContext.save()
    }

    func deleteArtworkThemes(artworkKey: String) throws {
        // A batch delete works on the store, not on rows still waiting for their coalesced save: write those first.
        themeSave?.cancel()
        themeSave = nil
        try modelContext.save()
        try modelContext.delete(model: ArtworkThemeRecord.self, where: #Predicate { $0.artworkKey == artworkKey })
        try modelContext.save()
    }
}

/// Conversions between the PixlModel value types and the SwiftData records (pure functions, any thread).
nonisolated enum LibraryRecordMapping {
    static func song(_ r: SongRecord) -> Song { song(r, decoder: JSONDecoder()) }

    /// `song(_:)` with a decoder the caller shares across a fetch (one `JSONDecoder` per row costs more than the row).
    static func song(_ r: SongRecord, decoder: JSONDecoder) -> Song {
        let artists = r.artistsJSON.flatMap { try? decoder.decode([ArtistRef].self, from: Data($0.utf8)) } ?? []
        return Song(id: r.id, title: r.title, artist: r.artistName, artistId: r.artistId, artists: artists,
                    album: r.albumName, albumId: r.albumId, albumArtist: r.albumArtist, path: r.path,
                    contentUriString: r.contentUri, albumArtUriString: r.artworkUri, duration: r.duration,
                    genre: r.genre, lyrics: r.lyrics, isFavorite: r.isFavorite, trackNumber: r.trackNumber,
                    discNumber: r.discNumber, year: r.year, dateAdded: r.dateAdded, dateModified: r.dateModified,
                    mimeType: r.mimeType, bitrate: r.bitrate, sampleRate: r.sampleRate, spotifyId: r.spotifyId)
    }

    static func record(_ s: Song) -> SongRecord {
        let artistsJSON = s.artists.isEmpty ? nil : (try? JSONEncoder().encode(s.artists)).map { String(decoding: $0, as: UTF8.self) }
        let parent = (s.path as NSString).deletingLastPathComponent
        return SongRecord(id: s.id, title: s.title, artistName: s.artist, artistId: s.artistId, artistsJSON: artistsJSON,
                          albumArtist: s.albumArtist, albumName: s.album, albumId: s.albumId,
                          contentUri: s.contentUriString, artworkUri: s.albumArtUriString, duration: s.duration,
                          genre: s.genre, path: s.path, parentDirectory: parent, isFavorite: s.isFavorite,
                          lyrics: s.lyrics, trackNumber: s.trackNumber, discNumber: s.discNumber, year: s.year,
                          dateAdded: s.dateAdded, dateModified: s.dateModified, mimeType: s.mimeType,
                          bitrate: s.bitrate, sampleRate: s.sampleRate, spotifyId: s.spotifyId)
    }

    static func album(_ r: AlbumRecord) -> Album {
        Album(id: r.id, title: r.title, artist: r.artistName, year: r.year, dateAdded: r.dateAdded,
              albumArtUriString: r.artworkUri, songCount: r.songCount, albumArtist: r.albumArtist)
    }

    static func record(_ a: Album) -> AlbumRecord {
        AlbumRecord(id: a.id, title: a.title, artistName: a.artist, artistId: 0, artworkUri: a.albumArtUriString,
                    songCount: a.songCount, dateAdded: a.dateAdded, year: a.year, albumArtist: a.albumArtist)
    }

    static func artist(_ r: ArtistRecord) -> Artist {
        Artist(id: r.id, name: r.name, songCount: r.trackCount, imageUrl: r.imageUrl, customImageUri: r.customImageUri)
    }

    static func record(_ a: Artist) -> ArtistRecord {
        ArtistRecord(id: a.id, name: a.name, trackCount: a.songCount, imageUrl: a.imageUrl, customImageUri: a.customImageUri)
    }

    static func playlist(_ r: UserPlaylistRecord, songIds: [String]) -> Playlist {
        Playlist(id: r.id, name: r.name, songIds: songIds, createdAt: r.createdAt, lastModified: r.lastModified,
                 isAiGenerated: r.isAiGenerated, isQueueGenerated: r.isQueueGenerated, coverImageUri: r.coverImageUri,
                 coverColorArgb: r.coverColorArgb.map { Int32(truncatingIfNeeded: $0) }, coverIconName: r.coverIconName,
                 coverShapeType: r.coverShapeType, coverShapeDetail1: r.coverShapeDetail1.map(Float.init),
                 coverShapeDetail2: r.coverShapeDetail2.map(Float.init), coverShapeDetail3: r.coverShapeDetail3.map(Float.init),
                 coverShapeDetail4: r.coverShapeDetail4.map(Float.init), source: r.source, sortOrder: r.sortOrder)
    }

    static func record(_ p: Playlist) -> UserPlaylistRecord {
        UserPlaylistRecord(id: p.id, name: p.name, createdAt: p.createdAt, lastModified: p.lastModified,
                           isAiGenerated: p.isAiGenerated, isQueueGenerated: p.isQueueGenerated,
                           coverImageUri: p.coverImageUri, coverColorArgb: p.coverColorArgb.map(Int.init),
                           coverIconName: p.coverIconName, coverShapeType: p.coverShapeType,
                           coverShapeDetail1: p.coverShapeDetail1.map(Double.init),
                           coverShapeDetail2: p.coverShapeDetail2.map(Double.init),
                           coverShapeDetail3: p.coverShapeDetail3.map(Double.init),
                           coverShapeDetail4: p.coverShapeDetail4.map(Double.init), source: p.source,
                           sortOrder: p.sortOrder)
    }
}
