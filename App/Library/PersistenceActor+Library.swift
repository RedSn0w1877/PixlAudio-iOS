import Foundation
import PixlLibrary
import PixlModel
import SwiftData

/// Tag overrides (the Spotify-only app no longer scans files: folder sources and scan writes are gone).
extension PersistenceActor {
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
