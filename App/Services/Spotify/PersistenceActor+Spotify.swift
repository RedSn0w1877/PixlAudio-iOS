import Foundation
import PixlLibrary
import PixlModel
import PixlNet
import SwiftData

/// Stage 12: the Spotify tables (Android `SpotifyDao` over `spotify_songs` / `spotify_playlists`) and the write of the
/// unified library rows. Lookups that SwiftData can't express portably (string ordering, GROUP BY) run in memory
/// on this actor — the Spotify tables are small (thousands of rows) and every call is off the main thread.
extension PersistenceActor: SpotifyLibraryStore {
    // MARK: Mapping

    private static func value(_ r: SpotifySongRecord) -> SpotifyTrackRecord {
        SpotifyTrackRecord(id: r.id, spotifyId: r.spotifyId, playlistId: r.playlistId, title: r.title, artist: r.artist,
                           album: r.album, albumId: r.albumId, durationMs: r.durationMs, albumArtUrl: r.albumArtUrl, isrc: r.isrc,
                           dateAdded: r.dateAdded, matchedVideoId: r.matchedVideoId, matchScore: r.matchScore.map(Float.init),
                           matchState: SpotifyMatchState(rawValue: r.matchState) ?? .pending, genre: r.genre)
    }

    private static func record(_ s: SpotifyTrackRecord) -> SpotifySongRecord {
        SpotifySongRecord(id: s.id, spotifyId: s.spotifyId, playlistId: s.playlistId, title: s.title, artist: s.artist,
                          album: s.album, albumId: s.albumId, durationMs: s.durationMs, albumArtUrl: s.albumArtUrl, isrc: s.isrc,
                          dateAdded: s.dateAdded, matchedVideoId: s.matchedVideoId, matchScore: s.matchScore.map(Double.init),
                          matchState: s.matchState.rawValue, genre: s.genre)
    }

    private static func update(_ r: SpotifySongRecord, from s: SpotifyTrackRecord) {
        r.spotifyId = s.spotifyId
        r.playlistId = s.playlistId
        r.title = s.title
        r.artist = s.artist
        r.album = s.album
        r.albumId = s.albumId
        r.durationMs = s.durationMs
        r.albumArtUrl = s.albumArtUrl
        r.isrc = s.isrc
        r.dateAdded = s.dateAdded
        r.matchedVideoId = s.matchedVideoId
        r.matchScore = s.matchScore.map(Double.init)
        r.matchState = s.matchState.rawValue
        r.genre = s.genre
    }

    private func songRecords(spotifyId: String) throws -> [SpotifySongRecord] {
        try modelContext.fetch(FetchDescriptor<SpotifySongRecord>(predicate: #Predicate { $0.spotifyId == spotifyId }))
    }

    // MARK: Playlists

    func allPlaylists() throws -> [SpotifyPlaylistRow] {
        try modelContext.fetch(FetchDescriptor<SpotifyPlaylistRecord>())
            .map { SpotifyPlaylistRow(id: $0.id, name: $0.name, coverUrl: $0.coverUrl, songCount: $0.songCount, lastSyncTime: $0.lastSyncTime) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func upsertPlaylist(_ playlist: SpotifyPlaylistRow) throws {
        let id = playlist.id
        var descriptor = FetchDescriptor<SpotifyPlaylistRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.name = playlist.name
            existing.coverUrl = playlist.coverUrl
            existing.songCount = playlist.songCount
            existing.lastSyncTime = playlist.lastSyncTime
        } else {
            modelContext.insert(SpotifyPlaylistRecord(id: id, name: playlist.name, coverUrl: playlist.coverUrl,
                                                      songCount: playlist.songCount, lastSyncTime: playlist.lastSyncTime))
        }
        try modelContext.save()
    }

    func deletePlaylist(id: String) throws {
        try modelContext.delete(model: SpotifyPlaylistRecord.self, where: #Predicate { $0.id == id })
        try modelContext.save()
    }

    // MARK: Songs

    func allSongs() throws -> [SpotifyTrackRecord] {
        try modelContext.fetch(FetchDescriptor<SpotifySongRecord>()).map(Self.value)
    }

    func insertSongs(_ songs: [SpotifyTrackRecord]) throws {
        let ids = songs.map(\.id)
        var existing: [String: SpotifySongRecord] = [:]
        for record in try modelContext.fetch(FetchDescriptor<SpotifySongRecord>(predicate: #Predicate { ids.contains($0.id) })) {
            existing[record.id] = record
        }
        var pending = 0
        for song in songs {
            if let record = existing[song.id] {
                Self.update(record, from: song)
            } else {
                let record = Self.record(song)
                modelContext.insert(record)
                existing[song.id] = record
            }
            pending += 1
            if pending >= Self.batchSize {
                try modelContext.save()
                pending = 0
            }
        }
        try modelContext.save()
    }

    /// One transaction: the playlist's rows are deleted and the new ones inserted before anything is saved, so a
    /// failure leaves the previous snapshot.
    func replaceSongs(playlistId: String, with songs: [SpotifyTrackRecord]) throws {
        try modelContext.transaction {
            try modelContext.delete(model: SpotifySongRecord.self, where: #Predicate { $0.playlistId == playlistId })
            var inserted = Set<String>()
            for song in songs where inserted.insert(song.id).inserted {
                modelContext.insert(Self.record(song))
            }
        }
    }

    func deleteSongs(playlistId: String) throws {
        try modelContext.delete(model: SpotifySongRecord.self, where: #Predicate { $0.playlistId == playlistId })
        try modelContext.save()
    }

    func deleteSong(spotifyId: String, playlistId: String) throws {
        try modelContext.delete(model: SpotifySongRecord.self,
                                where: #Predicate { $0.spotifyId == spotifyId && $0.playlistId == playlistId })
        try modelContext.save()
    }

    // MARK: Matches

    func knownMatches() throws -> [String: SpotifyMatchInfo] {
        let pending = SpotifyMatchState.pending.rawValue
        var result: [String: SpotifyMatchInfo] = [:]
        for record in try modelContext.fetch(FetchDescriptor<SpotifySongRecord>(predicate: #Predicate { $0.matchState != pending }))
        where result[record.spotifyId] == nil {
            result[record.spotifyId] = SpotifyMatchInfo(matchedVideoId: record.matchedVideoId, matchScore: record.matchScore.map(Float.init),
                                                        matchState: SpotifyMatchState(rawValue: record.matchState) ?? .pending)
        }
        return result
    }

    func pendingSongs(after: String, limit: Int) throws -> [SpotifyTrackRecord] {
        let pending = SpotifyMatchState.pending.rawValue
        var seen = Set<String>()
        let rows = try modelContext.fetch(FetchDescriptor<SpotifySongRecord>(predicate: #Predicate { $0.matchState == pending }))
            .filter { $0.spotifyId > after && seen.insert($0.spotifyId).inserted }
            .sorted { $0.spotifyId < $1.spotifyId }
        return rows.prefix(limit).map(Self.value)
    }

    func updateAutomaticMatch(spotifyId: String, videoId: String?, score: Float?, state: SpotifyMatchState) throws {
        for record in try songRecords(spotifyId: spotifyId)
        where record.matchState != SpotifyMatchState.manual.rawValue && (record.matchedVideoId ?? "").isEmpty {
            record.matchedVideoId = videoId
            record.matchScore = score.map(Double.init)
            record.matchState = state.rawValue
        }
        try modelContext.save()
    }

    func updateMatch(spotifyId: String, videoId: String?, score: Float?, state: SpotifyMatchState) throws {
        for record in try songRecords(spotifyId: spotifyId) {
            record.matchedVideoId = videoId
            record.matchScore = score.map(Double.init)
            record.matchState = state.rawValue
        }
        try modelContext.save()
    }

    func requeueUnmatched() throws -> Int {
        let unmatched = SpotifyMatchState.unmatched.rawValue
        let records = try modelContext.fetch(FetchDescriptor<SpotifySongRecord>(predicate: #Predicate { $0.matchState == unmatched }))
        for record in records {
            record.matchState = SpotifyMatchState.pending.rawValue
            record.matchedVideoId = nil
            record.matchScore = nil
        }
        try modelContext.save()
        return records.count
    }

    func countTracks(in state: SpotifyMatchState) throws -> Int {
        let raw = state.rawValue
        let records = try modelContext.fetch(FetchDescriptor<SpotifySongRecord>(predicate: #Predicate { $0.matchState == raw }))
        return Set(records.map(\.spotifyId)).count
    }

    func clearAll() throws {
        try modelContext.delete(model: SpotifySongRecord.self)
        try modelContext.delete(model: SpotifyPlaylistRecord.self)
        try modelContext.save()
    }

    /// `getMatchedVideoId`: the video a track plays from, if it has one.
    func matchedVideoId(spotifyId: String) throws -> String? {
        try songRecords(spotifyId: spotifyId).lazy.compactMap(\.matchedVideoId).first { !$0.isEmpty }
    }

    /// `getSongBySpotifyId`.
    func spotifySong(spotifyId: String) throws -> SpotifyTrackRecord? {
        try songRecords(spotifyId: spotifyId).first.map(Self.value)
    }

    // MARK: Unified library

    /// Writes the unified Spotify rows as a diff (`incrementalSyncMusicData`): `sp:` songs inserted / updated /
    /// deleted (the user's favourite flag and lyrics on existing rows are kept), their artist links rewritten, album
    /// and artist rows in the Spotify id bands upserted or dropped, and the `SPOTIFY` app playlists replaced.
    func applySpotifyUnifiedLibrary(_ built: SpotifyUnifiedLibrary.Built) throws {
        var pending = 0
        func tick() throws {
            pending += 1
            if pending >= Self.batchSize {
                try modelContext.save()
                pending = 0
            }
        }

        // Songs.
        var current: [String: SongRecord] = [:]
        for record in try modelContext.fetch(FetchDescriptor<SongRecord>(predicate: #Predicate { $0.spotifyId != nil }))
        where SpotifyUnifiedLibrary.isSpotifySongId(record.id) {
            current[record.id] = record
        }
        var wanted = Set<String>()
        for song in built.songs {
            wanted.insert(song.id)
            if let record = current[song.id] {
                var merged = song
                merged.isFavorite = record.isFavorite
                merged.lyrics = record.lyrics
                merged.dateAdded = record.dateAdded
                if LibraryRecordMapping.song(record) != merged {
                    LibraryRecordMapping.update(record, from: merged)
                    try tick()
                }
            } else {
                modelContext.insert(LibraryRecordMapping.record(song))
                try tick()
            }
        }
        let removed = current.keys.filter { !wanted.contains($0) }
        for id in removed {
            if let record = current[id] { modelContext.delete(record) }
            try tick()
        }
        if !removed.isEmpty {
            let ids = removed
            try modelContext.delete(model: FavoriteRecord.self, where: #Predicate { ids.contains($0.songId) })
            try modelContext.delete(model: PlaylistEntryRecord.self, where: #Predicate { ids.contains($0.songId) })
        }

        // Artist links of Spotify songs.
        var desired: [String: SongArtistLink] = [:]
        for link in built.links where desired["\(link.songId)|\(link.artistId)"] == nil { desired["\(link.songId)|\(link.artistId)"] = link }
        var present = Set<String>()
        for record in try modelContext.fetch(FetchDescriptor<SongArtistLinkRecord>()) where SpotifyUnifiedLibrary.isSpotifySongId(record.songId) {
            if let link = desired[record.key], !present.contains(record.key) {
                present.insert(record.key)
                if record.isPrimary != link.isPrimary { record.isPrimary = link.isPrimary }
            } else {
                modelContext.delete(record)
            }
            try tick()
        }
        for (key, link) in desired where !present.contains(key) {
            modelContext.insert(SongArtistLinkRecord(songId: link.songId, artistId: link.artistId, isPrimary: link.isPrimary))
            try tick()
        }

        // Albums in the Spotify band.
        let albumIds = Set(built.albums.map(\.id))
        var albumRecords: [Int64: AlbumRecord] = [:]
        for record in try modelContext.fetch(FetchDescriptor<AlbumRecord>()) where SpotifyUnifiedLibrary.isSpotifyAlbumId(record.id) {
            albumRecords[record.id] = record
        }
        for album in built.albums {
            let artistId = built.albumArtistIds[album.id] ?? 0
            if let record = albumRecords[album.id] {
                if record.title != album.title || record.artistName != album.artist || record.artistId != artistId
                    || record.artworkUri != album.albumArtUriString || record.songCount != album.songCount {
                    record.title = album.title
                    record.artistName = album.artist
                    record.artistId = artistId
                    record.artworkUri = album.albumArtUriString
                    record.songCount = album.songCount
                    try tick()
                }
            } else {
                modelContext.insert(AlbumRecord(id: album.id, title: album.title, artistName: album.artist, artistId: artistId,
                                                artworkUri: album.albumArtUriString, songCount: album.songCount,
                                                dateAdded: album.dateAdded, year: 0, albumArtist: nil))
                try tick()
            }
        }
        for (id, record) in albumRecords where !albumIds.contains(id) {
            modelContext.delete(record)
            try tick()
        }

        // Artists in the Spotify band.
        let artistIds = Set(built.artists.map(\.id))
        var artistRecords: [Int64: ArtistRecord] = [:]
        for record in try modelContext.fetch(FetchDescriptor<ArtistRecord>()) where SpotifyUnifiedLibrary.isSpotifyArtistId(record.id) {
            artistRecords[record.id] = record
        }
        for artist in built.artists {
            if let record = artistRecords[artist.id] {
                if record.name != artist.name || record.trackCount != artist.songCount {
                    record.name = artist.name
                    record.trackCount = artist.songCount
                    try tick()
                }
            } else {
                modelContext.insert(ArtistRecord(id: artist.id, name: artist.name, trackCount: artist.songCount, imageUrl: nil,
                                                 customImageUri: nil))
                try tick()
            }
        }
        for (id, record) in artistRecords where !artistIds.contains(id) {
            modelContext.delete(record)
            try tick()
        }

        // Mirrored playlists (fixed ids, so a re-import updates instead of duplicating).
        let source = SpotifyLibrary.playlistSource
        let existingPlaylists = try modelContext.fetch(FetchDescriptor<UserPlaylistRecord>(predicate: #Predicate { $0.source == source }))
        var playlistRecords: [String: UserPlaylistRecord] = [:]
        for record in existingPlaylists { playlistRecords[record.id] = record }
        let maxOrder = try modelContext.fetch(FetchDescriptor<UserPlaylistRecord>()).map(\.sortOrder).max() ?? -1
        var nextOrder = maxOrder + 1
        let wantedPlaylists = Set(built.playlists.map(\.id))
        for playlist in built.playlists {
            let id = playlist.id
            if let record = playlistRecords[id] {
                if record.name != playlist.name || record.coverImageUri != playlist.coverImageUri {
                    record.name = playlist.name
                    record.coverImageUri = playlist.coverImageUri
                    record.lastModified = playlist.lastModified
                }
            } else {
                var fresh = playlist
                fresh.sortOrder = nextOrder
                nextOrder += 1
                modelContext.insert(LibraryRecordMapping.record(fresh))
            }
            try modelContext.delete(model: PlaylistEntryRecord.self, where: #Predicate { $0.playlistId == id })
            for (position, songId) in playlist.songIds.enumerated() {
                modelContext.insert(PlaylistEntryRecord(playlistId: id, songId: songId, position: position))
            }
            try tick()
        }
        for (id, record) in playlistRecords where !wantedPlaylists.contains(id) {
            modelContext.delete(record)
            try modelContext.delete(model: PlaylistEntryRecord.self, where: #Predicate { $0.playlistId == id })
            try tick()
        }
        try modelContext.save()
    }

    /// The current `sp:` songs by id (their user state survives a rebuild).
    func spotifyUnifiedSongs() throws -> [String: Song] {
        var result: [String: Song] = [:]
        for record in try modelContext.fetch(FetchDescriptor<SongRecord>(predicate: #Predicate { $0.spotifyId != nil }))
        where SpotifyUnifiedLibrary.isSpotifySongId(record.id) {
            result[record.id] = LibraryRecordMapping.song(record)
        }
        return result
    }

    /// Rebuilds the unified Spotify rows from the Spotify tables (the sync's flush).
    func rebuildSpotifyUnifiedLibrary() throws {
        let built = SpotifyUnifiedLibrary.build(rows: try allSongs(), playlists: try allPlaylists(), existing: try spotifyUnifiedSongs())
        try applySpotifyUnifiedLibrary(built)
    }
}
