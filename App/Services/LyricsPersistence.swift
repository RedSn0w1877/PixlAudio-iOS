import Foundation
import SwiftData

/// One stored lyrics row (Android `LyricsEntity`): the raw lyrics content exactly as Android stores it (a
/// `LyricsDoc` JSON, word-by-word LRC, LRC or plain text — `LyricsUtils.parseLyrics` reads all of them), its source
/// (`"user"` for the user's own sync, `"manual"`, `"import"`, …) and whether it is synced.
nonisolated struct StoredLyricsRow: Sendable, Equatable {
    var content: String
    var source: String?
    var isSynced: Bool
}

/// Stage 9: the `lyrics` table (`LyricsRecord`). `docJSON` holds Android's raw `LyricsEntity.content`.
extension PersistenceActor {
    func storedLyrics(songId: String) throws -> StoredLyricsRow? {
        var descriptor = FetchDescriptor<LyricsRecord>(predicate: #Predicate { $0.songId == songId })
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        return StoredLyricsRow(content: record.docJSON, source: record.source, isSynced: record.isSynced)
    }

    func saveLyrics(songId: String, content: String, isSynced: Bool, source: String, updatedAt: Int64) throws {
        var descriptor = FetchDescriptor<LyricsRecord>(predicate: #Predicate { $0.songId == songId })
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            record.docJSON = content
            record.isSynced = isSynced
            record.source = source
            record.updatedAt = updatedAt
        } else {
            modelContext.insert(LyricsRecord(songId: songId, docJSON: content, isSynced: isSynced, source: source,
                                             updatedAt: updatedAt))
        }
        try modelContext.save()
    }

    func deleteLyrics(songId: String) throws {
        try modelContext.delete(model: LyricsRecord.self, where: #Predicate { $0.songId == songId })
        try modelContext.save()
    }
}
