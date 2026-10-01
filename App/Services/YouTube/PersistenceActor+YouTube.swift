import Foundation
import PixlModel
import SwiftData

extension PersistenceActor {
    /// Inserts (or updates) a streamed song and its album / artist rows. Library scans never touch `yt:` rows
    /// (`LibraryIdentity.isManaged`), and their album / artist ids are negative, so a rescan keeps them.
    func upsertStreamSong(_ song: Song, album: Album, artist: Artist, favoriteAt: Int64?) throws {
        let songId = song.id
        if let record = try modelContext.fetch(FetchDescriptor<SongRecord>(predicate: #Predicate { $0.id == songId })).first {
            LibraryRecordMapping.update(record, from: song)
        } else {
            modelContext.insert(LibraryRecordMapping.record(song))
            modelContext.insert(SongArtistLinkRecord(songId: song.id, artistId: artist.id, isPrimary: true))
        }
        let albumId = album.id
        if try modelContext.fetch(FetchDescriptor<AlbumRecord>(predicate: #Predicate { $0.id == albumId })).isEmpty {
            modelContext.insert(LibraryRecordMapping.record(album))
        }
        let artistId = artist.id
        if try modelContext.fetch(FetchDescriptor<ArtistRecord>(predicate: #Predicate { $0.id == artistId })).isEmpty {
            modelContext.insert(LibraryRecordMapping.record(artist))
        }
        if let favoriteAt {
            try modelContext.delete(model: FavoriteRecord.self, where: #Predicate { $0.songId == songId })
            modelContext.insert(FavoriteRecord(songId: songId, isFavorite: true, timestamp: favoriteAt))
        }
        try modelContext.save()
    }
}
