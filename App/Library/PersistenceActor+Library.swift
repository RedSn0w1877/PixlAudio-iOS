import Foundation
import PixlLibrary
import PixlModel
import SwiftData

/// A user-picked music folder as value type (`FolderSourceRecord`).
nonisolated struct FolderSource: Sendable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var bookmark: Data
    var addedAt: Int64
    var lastScanAt: Int64?
    var isEnabled: Bool
}

/// Stage 6's queries: folder sources, tag overrides and the diffed write of a scan.
extension PersistenceActor {
    // MARK: Folder sources

    func folderSources() throws -> [FolderSource] {
        try modelContext.fetch(FetchDescriptor<FolderSourceRecord>(sortBy: [SortDescriptor(\.addedAt)])).map {
            FolderSource(id: $0.id, displayName: $0.displayName, bookmark: $0.bookmark, addedAt: $0.addedAt,
                         lastScanAt: $0.lastScanAt, isEnabled: $0.isEnabled)
        }
    }

    @discardableResult
    func addFolderSource(displayName: String, bookmark: Data, addedAt: Int64) throws -> FolderSource {
        let record = FolderSourceRecord(displayName: displayName, bookmark: bookmark, addedAt: addedAt)
        modelContext.insert(record)
        try modelContext.save()
        return FolderSource(id: record.id, displayName: displayName, bookmark: bookmark, addedAt: addedAt,
                            lastScanAt: nil, isEnabled: true)
    }

    func updateFolderSource(id: String, bookmark: Data? = nil, lastScanAt: Int64? = nil, isEnabled: Bool? = nil) throws {
        guard let record = try folderRecord(id) else { return }
        if let bookmark { record.bookmark = bookmark }
        if let lastScanAt { record.lastScanAt = lastScanAt }
        if let isEnabled { record.isEnabled = isEnabled }
        try modelContext.save()
    }

    func removeFolderSource(id: String) throws {
        try modelContext.delete(model: FolderSourceRecord.self, where: #Predicate { $0.id == id })
        try modelContext.save()
    }

    private func folderRecord(_ id: String) throws -> FolderSourceRecord? {
        var descriptor = FetchDescriptor<FolderSourceRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    // MARK: Tag overrides

    func tagOverrides() throws -> [String: TagOverrideFields] {
        var result: [String: TagOverrideFields] = [:]
        for record in try modelContext.fetch(FetchDescriptor<TagOverrideRecord>()) {
            if let fields = TagOverrideFields.decode(record.fieldsJSON) { result[record.songId] = fields }
        }
        return result
    }

    /// Saves (or, for nil / empty fields, removes) the override of one song.
    func setTagOverride(songId: String, fields: TagOverrideFields?, updatedAt: Int64) throws {
        var descriptor = FetchDescriptor<TagOverrideRecord>(predicate: #Predicate { $0.songId == songId })
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first
        if let fields, !fields.isEmpty {
            let json = try fields.encoded()
            if let existing {
                existing.fieldsJSON = json
                existing.updatedAt = updatedAt
            } else {
                modelContext.insert(TagOverrideRecord(songId: songId, fieldsJSON: json, updatedAt: updatedAt))
            }
        } else if let existing {
            modelContext.delete(existing)
        }
        try modelContext.save()
    }

    // MARK: Scan results

    /// Writes a scan as a diff: inserts new songs, updates changed ones, deletes managed songs (`f:` / `mp:`) that are
    /// gone, rewrites their artist links, upserts album and artist rows and drops album / artist rows no song refers
    /// to any more. Songs of other sources (Spotify, YouTube) are never touched. The user's favourite flag, lyrics
    /// and date added on existing rows are kept (they may have changed while the scan ran). Saves every 500 changes.
    func applyLibraryScan(_ built: BuiltLibrary) throws -> LibraryImportSummary {
        var pending = 0
        func tick() throws {
            pending += 1
            if pending >= Self.batchSize {
                try modelContext.save()
                pending = 0
            }
        }

        var managed: [String: SongRecord] = [:]
        var otherAlbumIds = Set<Int64>()
        var otherArtistIds = Set<Int64>()
        for record in try modelContext.fetch(FetchDescriptor<SongRecord>()) {
            if LibraryIdentity.isManaged(record.id) {
                managed[record.id] = record
            } else {
                otherAlbumIds.insert(record.albumId)
                otherArtistIds.insert(record.artistId)
            }
        }

        var summary = LibraryImportSummary(added: 0, updated: 0, removed: 0)
        var newIds = Set<String>()
        for song in built.songs {
            newIds.insert(song.id)
            if let record = managed[song.id] {
                var merged = song
                merged.isFavorite = record.isFavorite
                merged.lyrics = record.lyrics
                merged.dateAdded = record.dateAdded
                if LibraryRecordMapping.song(record) != merged {
                    LibraryRecordMapping.update(record, from: merged)
                    summary.updated += 1
                    try tick()
                }
            } else {
                modelContext.insert(LibraryRecordMapping.record(song))
                summary.added += 1
                try tick()
            }
        }
        for (id, record) in managed where !newIds.contains(id) {
            modelContext.delete(record)
            summary.removed += 1
            try tick()
        }

        // Artist links of managed songs.
        var desired: [String: SongArtistLink] = [:]
        for link in built.links where desired["\(link.songId)|\(link.artistId)"] == nil {
            desired["\(link.songId)|\(link.artistId)"] = link
        }
        var present = Set<String>()
        for record in try modelContext.fetch(FetchDescriptor<SongArtistLinkRecord>()) {
            guard LibraryIdentity.isManaged(record.songId) else {
                otherArtistIds.insert(record.artistId)
                continue
            }
            if let link = desired[record.key], !present.contains(record.key) {
                present.insert(record.key)
                if record.isPrimary != link.isPrimary {
                    record.isPrimary = link.isPrimary
                    try tick()
                }
            } else {
                modelContext.delete(record)
                try tick()
            }
        }
        for (key, link) in desired where !present.contains(key) {
            modelContext.insert(SongArtistLinkRecord(songId: link.songId, artistId: link.artistId, isPrimary: link.isPrimary))
            try tick()
        }

        // Albums.
        var referencedAlbums = otherAlbumIds
        for song in built.songs { referencedAlbums.insert(song.albumId) }
        var albumRecords: [Int64: AlbumRecord] = [:]
        for record in try modelContext.fetch(FetchDescriptor<AlbumRecord>()) { albumRecords[record.id] = record }
        for album in built.albums {
            if let record = albumRecords[album.id] {
                if record.title != album.title || record.artistName != album.artistName
                    || record.artistId != album.artistId || record.artworkUri != album.albumArtUriString
                    || record.songCount != album.songCount || record.year != album.year
                    || record.albumArtist != album.albumArtist {
                    record.title = album.title
                    record.artistName = album.artistName
                    record.artistId = album.artistId
                    record.artworkUri = album.albumArtUriString
                    record.songCount = album.songCount
                    record.year = album.year
                    record.albumArtist = album.albumArtist
                    try tick()
                }
            } else {
                modelContext.insert(AlbumRecord(id: album.id, title: album.title, artistName: album.artistName,
                                                artistId: album.artistId, artworkUri: album.albumArtUriString,
                                                songCount: album.songCount, dateAdded: album.dateAdded,
                                                year: album.year, albumArtist: album.albumArtist))
                try tick()
            }
        }
        for (id, record) in albumRecords where id > 0 && !referencedAlbums.contains(id) {
            modelContext.delete(record)
            try tick()
        }

        // Artists.
        var referencedArtists = otherArtistIds
        for song in built.songs { referencedArtists.insert(song.artistId) }
        for link in built.links { referencedArtists.insert(link.artistId) }
        var artistRecords: [Int64: ArtistRecord] = [:]
        for record in try modelContext.fetch(FetchDescriptor<ArtistRecord>()) { artistRecords[record.id] = record }
        for artist in built.artists {
            if let record = artistRecords[artist.id] {
                if record.name != artist.name || record.trackCount != artist.songCount {
                    record.name = artist.name
                    record.trackCount = artist.songCount
                    try tick()
                }
            } else {
                modelContext.insert(ArtistRecord(id: artist.id, name: artist.name, trackCount: artist.songCount,
                                                 imageUrl: artist.imageUrl, customImageUri: artist.customImageUri))
                try tick()
            }
        }
        for (id, record) in artistRecords where id > 0 && !referencedArtists.contains(id) {
            modelContext.delete(record)
            try tick()
        }
        try modelContext.save()
        return summary
    }
}

nonisolated extension LibraryRecordMapping {
    /// Copies every field of `s` onto an existing record (the id stays).
    static func update(_ r: SongRecord, from s: Song) {
        r.title = s.title
        r.artistName = s.artist
        r.artistId = s.artistId
        r.artistsJSON = s.artists.isEmpty ? nil : (try? JSONEncoder().encode(s.artists)).map { String(decoding: $0, as: UTF8.self) }
        r.albumArtist = s.albumArtist
        r.albumName = s.album
        r.albumId = s.albumId
        r.contentUri = s.contentUriString
        r.artworkUri = s.albumArtUriString
        r.duration = s.duration
        r.genre = s.genre
        r.path = s.path
        r.parentDirectory = LibraryIdentity.parentDirectory(ofLibraryPath: s.path)
        r.isFavorite = s.isFavorite
        r.lyrics = s.lyrics
        r.trackNumber = s.trackNumber
        r.discNumber = s.discNumber
        r.year = s.year
        r.dateAdded = s.dateAdded
        r.dateModified = s.dateModified
        r.mimeType = s.mimeType
        r.bitrate = s.bitrate
        r.sampleRate = s.sampleRate
        r.spotifyId = s.spotifyId
    }
}
