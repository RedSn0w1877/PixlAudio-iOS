import Foundation
import SwiftData

// SwiftData schema v2: the search history table grew (key, kind, target, image, count). Every other model is the
// version-1 class, unchanged, so only `SearchHistoryRecord` is a new class (`SchemaV2.SearchHistoryRecord`); the
// typealiases in `SchemaV1.swift` keep pointing at the unchanged ones. Never change a model of a shipped version: add
// `SchemaV3` and a stage in `PixlMigrationPlan`.

nonisolated enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [SongRecord.self, AlbumRecord.self, ArtistRecord.self, SongArtistLinkRecord.self, FavoriteRecord.self,
         UserPlaylistRecord.self, PlaylistEntryRecord.self, LyricsRecord.self, EngagementRecord.self,
         TransitionRuleRecord.self, SearchHistoryRecord.self, ArtworkThemeRecord.self, SpotifySongRecord.self,
         SpotifyPlaylistRecord.self, AICacheRecord.self, AIUsageRecord.self, StreamCacheRecord.self,
         TagOverrideRecord.self, FolderSourceRecord.self]
    }

    /// Android `search_history` (version 6 of its main database): one row per folded query.
    @Model nonisolated final class SearchHistoryRecord {
        #Index<SearchHistoryRecord>([\.key], [\.timestamp])
        @Attribute(.unique) var id: String
        /// As typed (trimmed, at most 100 characters): what the row shows.
        var query: String
        /// The folded query (`BrainText.fold`). Empty on a row saved before version 2 until the first read fills it.
        /// Not a unique attribute: a lightweight migration cannot give old rows distinct keys, so the write path
        /// (`SearchHistoryRules`) is what keeps one row per key.
        var key: String = ""
        /// `SearchHistoryKind` raw value, nil for a submitted search.
        var kind: String?
        var targetId: String?
        var targetTitle: String?
        var imageUrl: String?
        /// Last use, milliseconds since 1970.
        var timestamp: Int64
        var count: Int = 1

        init(id: String = UUID().uuidString, query: String, key: String = "", kind: String? = nil, targetId: String? = nil,
             targetTitle: String? = nil, imageUrl: String? = nil, timestamp: Int64, count: Int = 1) {
            self.id = id
            self.query = query
            self.key = key
            self.kind = kind
            self.targetId = targetId
            self.targetTitle = targetTitle
            self.imageUrl = imageUrl
            self.timestamp = timestamp
            self.count = count
        }
    }
}

typealias SearchHistoryRecord = SchemaV2.SearchHistoryRecord
