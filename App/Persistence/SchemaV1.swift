import Foundation
import SwiftData

// SwiftData schema v1: one model per Android Room table (architecture §2), used as a *store only* — no
// relationships, string ids; the app works from the in-memory `LibrarySnapshot` value types. Field names follow
// the Room entities (`data/database/*Entity.kt`) so backup/restore and ports map 1:1.
//
// Rules: never change a model of a shipped version — add `SchemaV2` and a stage in `PixlMigrationPlan`. Models are
// `nonisolated` so `PersistenceActor` (a `@ModelActor`) can use them off the main actor.

nonisolated enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [SongRecord.self, AlbumRecord.self, ArtistRecord.self, SongArtistLinkRecord.self, FavoriteRecord.self,
         UserPlaylistRecord.self, PlaylistEntryRecord.self, LyricsRecord.self, EngagementRecord.self,
         TransitionRuleRecord.self, SearchHistoryRecord.self, ArtworkThemeRecord.self, SpotifySongRecord.self,
         SpotifyPlaylistRecord.self, AICacheRecord.self, AIUsageRecord.self, StreamCacheRecord.self,
         TagOverrideRecord.self, FolderSourceRecord.self]
    }

    /// Android `songs`. `id`: `f:<folder>/<relative path>`, `mp:<persistentID>`, `yt:<videoId>`, `sp:<spotifyId>`.
    @Model nonisolated final class SongRecord {
        #Index<SongRecord>([\.title], [\.albumId], [\.artistId], [\.dateAdded], [\.parentDirectory])
        @Attribute(.unique) var id: String
        var title: String
        var artistName: String
        var artistId: Int64
        /// `[ArtistRef]` as JSON (Android `artists_json`).
        var artistsJSON: String?
        var albumArtist: String?
        var albumName: String
        var albumId: Int64
        var contentUri: String
        var artworkUri: String?
        var duration: Int64
        var genre: String?
        var path: String
        var parentDirectory: String
        var isFavorite: Bool
        var lyrics: String?
        var trackNumber: Int
        var discNumber: Int?
        var year: Int
        var dateAdded: Int64
        var dateModified: Int64
        var mimeType: String?
        var bitrate: Int?
        var sampleRate: Int?
        var spotifyId: String?

        init(id: String, title: String, artistName: String, artistId: Int64, artistsJSON: String?, albumArtist: String?,
             albumName: String, albumId: Int64, contentUri: String, artworkUri: String?, duration: Int64, genre: String?,
             path: String, parentDirectory: String, isFavorite: Bool, lyrics: String?, trackNumber: Int, discNumber: Int?,
             year: Int, dateAdded: Int64, dateModified: Int64, mimeType: String?, bitrate: Int?, sampleRate: Int?,
             spotifyId: String?) {
            self.id = id
            self.title = title
            self.artistName = artistName
            self.artistId = artistId
            self.artistsJSON = artistsJSON
            self.albumArtist = albumArtist
            self.albumName = albumName
            self.albumId = albumId
            self.contentUri = contentUri
            self.artworkUri = artworkUri
            self.duration = duration
            self.genre = genre
            self.path = path
            self.parentDirectory = parentDirectory
            self.isFavorite = isFavorite
            self.lyrics = lyrics
            self.trackNumber = trackNumber
            self.discNumber = discNumber
            self.year = year
            self.dateAdded = dateAdded
            self.dateModified = dateModified
            self.mimeType = mimeType
            self.bitrate = bitrate
            self.sampleRate = sampleRate
            self.spotifyId = spotifyId
        }
    }

    /// Android `albums`.
    @Model nonisolated final class AlbumRecord {
        @Attribute(.unique) var id: Int64
        var title: String
        var artistName: String
        var artistId: Int64
        var artworkUri: String?
        var songCount: Int
        var dateAdded: Int64
        var year: Int
        var albumArtist: String?

        init(id: Int64, title: String, artistName: String, artistId: Int64, artworkUri: String?, songCount: Int,
             dateAdded: Int64, year: Int, albumArtist: String?) {
            self.id = id
            self.title = title
            self.artistName = artistName
            self.artistId = artistId
            self.artworkUri = artworkUri
            self.songCount = songCount
            self.dateAdded = dateAdded
            self.year = year
            self.albumArtist = albumArtist
        }
    }

    /// Android `artists`.
    @Model nonisolated final class ArtistRecord {
        @Attribute(.unique) var id: Int64
        var name: String
        var trackCount: Int
        var imageUrl: String?
        var customImageUri: String?

        init(id: Int64, name: String, trackCount: Int, imageUrl: String?, customImageUri: String?) {
            self.id = id
            self.name = name
            self.trackCount = trackCount
            self.imageUrl = imageUrl
            self.customImageUri = customImageUri
        }
    }

    /// Android `song_artist_cross_ref`. `key` = `<songId>|<artistId>`.
    @Model nonisolated final class SongArtistLinkRecord {
        #Index<SongArtistLinkRecord>([\.songId], [\.artistId])
        @Attribute(.unique) var key: String
        var songId: String
        var artistId: Int64
        var isPrimary: Bool

        init(songId: String, artistId: Int64, isPrimary: Bool) {
            key = "\(songId)|\(artistId)"
            self.songId = songId
            self.artistId = artistId
            self.isPrimary = isPrimary
        }
    }

    /// Android `favorites`.
    @Model nonisolated final class FavoriteRecord {
        @Attribute(.unique) var songId: String
        var isFavorite: Bool
        var timestamp: Int64

        init(songId: String, isFavorite: Bool = true, timestamp: Int64) {
            self.songId = songId
            self.isFavorite = isFavorite
            self.timestamp = timestamp
        }
    }

    /// Android `playlists`, plus the smart-playlist rules and the playlist's transition override as JSON.
    @Model nonisolated final class UserPlaylistRecord {
        @Attribute(.unique) var id: String
        var name: String
        var createdAt: Int64
        var lastModified: Int64
        var isAiGenerated: Bool
        var isQueueGenerated: Bool
        var coverImageUri: String?
        var coverColorArgb: Int?
        var coverIconName: String?
        var coverShapeType: String?
        var coverShapeDetail1: Double?
        var coverShapeDetail2: Double?
        var coverShapeDetail3: Double?
        var coverShapeDetail4: Double?
        var source: String
        var sortOrder: Int
        var smartRulesJSON: String?
        var transitionJSON: String?

        init(id: String, name: String, createdAt: Int64, lastModified: Int64, isAiGenerated: Bool = false,
             isQueueGenerated: Bool = false, coverImageUri: String? = nil, coverColorArgb: Int? = nil,
             coverIconName: String? = nil, coverShapeType: String? = nil, coverShapeDetail1: Double? = nil,
             coverShapeDetail2: Double? = nil, coverShapeDetail3: Double? = nil, coverShapeDetail4: Double? = nil,
             source: String = "LOCAL", sortOrder: Int = 0, smartRulesJSON: String? = nil, transitionJSON: String? = nil) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.lastModified = lastModified
            self.isAiGenerated = isAiGenerated
            self.isQueueGenerated = isQueueGenerated
            self.coverImageUri = coverImageUri
            self.coverColorArgb = coverColorArgb
            self.coverIconName = coverIconName
            self.coverShapeType = coverShapeType
            self.coverShapeDetail1 = coverShapeDetail1
            self.coverShapeDetail2 = coverShapeDetail2
            self.coverShapeDetail3 = coverShapeDetail3
            self.coverShapeDetail4 = coverShapeDetail4
            self.source = source
            self.sortOrder = sortOrder
            self.smartRulesJSON = smartRulesJSON
            self.transitionJSON = transitionJSON
        }
    }

    /// Android `playlist_songs`. `key` = `<playlistId>|<position>`.
    @Model nonisolated final class PlaylistEntryRecord {
        #Index<PlaylistEntryRecord>([\.playlistId])
        @Attribute(.unique) var key: String
        var playlistId: String
        var songId: String
        var position: Int

        init(playlistId: String, songId: String, position: Int) {
            key = "\(playlistId)|\(position)"
            self.playlistId = playlistId
            self.songId = songId
            self.position = position
        }
    }

    /// Android `lyrics`: the parsed `LyricsDoc` as JSON (`LyricsDocCodec`), its source and the user's sync offset.
    @Model nonisolated final class LyricsRecord {
        @Attribute(.unique) var songId: String
        var docJSON: String
        var isSynced: Bool
        var source: String?
        var offsetMs: Int
        var updatedAt: Int64

        init(songId: String, docJSON: String, isSynced: Bool, source: String?, offsetMs: Int = 0, updatedAt: Int64) {
            self.songId = songId
            self.docJSON = docJSON
            self.isSynced = isSynced
            self.source = source
            self.offsetMs = offsetMs
            self.updatedAt = updatedAt
        }
    }

    /// Android `song_engagements`.
    @Model nonisolated final class EngagementRecord {
        @Attribute(.unique) var songId: String
        var playCount: Int
        var totalPlayDurationMs: Int64
        var lastPlayedTimestamp: Int64

        init(songId: String, playCount: Int = 0, totalPlayDurationMs: Int64 = 0, lastPlayedTimestamp: Int64 = 0) {
            self.songId = songId
            self.playCount = playCount
            self.totalPlayDurationMs = totalPlayDurationMs
            self.lastPlayedTimestamp = lastPlayedTimestamp
        }
    }

    /// Android `transition_rules` (`TransitionSettings` as JSON).
    @Model nonisolated final class TransitionRuleRecord {
        #Index<TransitionRuleRecord>([\.playlistId])
        @Attribute(.unique) var id: String
        var playlistId: String
        var fromTrackId: String?
        var toTrackId: String?
        var settingsJSON: String

        init(id: String = UUID().uuidString, playlistId: String, fromTrackId: String?, toTrackId: String?,
             settingsJSON: String) {
            self.id = id
            self.playlistId = playlistId
            self.fromTrackId = fromTrackId
            self.toTrackId = toTrackId
            self.settingsJSON = settingsJSON
        }
    }

    /// Android `search_history`.
    @Model nonisolated final class SearchHistoryRecord {
        @Attribute(.unique) var id: String
        var query: String
        var timestamp: Int64

        init(id: String = UUID().uuidString, query: String, timestamp: Int64) {
            self.id = id
            self.query = query
            self.timestamp = timestamp
        }
    }

    /// Android `album_art_themes`: one scheme pair per artwork and palette key (`ColorRolesPair` as JSON).
    @Model nonisolated final class ArtworkThemeRecord {
        #Index<ArtworkThemeRecord>([\.artworkKey])
        /// `<artwork key>|<style>|accuracy_<n>|algo_v7`.
        @Attribute(.unique) var key: String
        var artworkKey: String
        var paletteKey: String
        var pairJSON: Data

        init(key: String, artworkKey: String, paletteKey: String, pairJSON: Data) {
            self.key = key
            self.artworkKey = artworkKey
            self.paletteKey = paletteKey
            self.pairJSON = pairJSON
        }
    }

    /// Android `spotify_songs`.
    @Model nonisolated final class SpotifySongRecord {
        #Index<SpotifySongRecord>([\.playlistId], [\.spotifyId])
        @Attribute(.unique) var id: String
        var spotifyId: String
        var playlistId: String
        var title: String
        var artist: String
        var album: String
        var albumId: String?
        var durationMs: Int64
        var albumArtUrl: String?
        var isrc: String?
        var dateAdded: Int64
        var matchedVideoId: String?
        var matchScore: Double?
        var matchState: Int
        var genre: String?

        init(id: String, spotifyId: String, playlistId: String, title: String, artist: String, album: String,
             albumId: String?, durationMs: Int64, albumArtUrl: String?, isrc: String?, dateAdded: Int64,
             matchedVideoId: String? = nil, matchScore: Double? = nil, matchState: Int = 0, genre: String? = nil) {
            self.id = id
            self.spotifyId = spotifyId
            self.playlistId = playlistId
            self.title = title
            self.artist = artist
            self.album = album
            self.albumId = albumId
            self.durationMs = durationMs
            self.albumArtUrl = albumArtUrl
            self.isrc = isrc
            self.dateAdded = dateAdded
            self.matchedVideoId = matchedVideoId
            self.matchScore = matchScore
            self.matchState = matchState
            self.genre = genre
        }
    }

    /// Android `spotify_playlists`.
    @Model nonisolated final class SpotifyPlaylistRecord {
        @Attribute(.unique) var id: String
        var name: String
        var coverUrl: String?
        var songCount: Int
        var lastSyncTime: Int64

        init(id: String, name: String, coverUrl: String?, songCount: Int, lastSyncTime: Int64) {
            self.id = id
            self.name = name
            self.coverUrl = coverUrl
            self.songCount = songCount
            self.lastSyncTime = lastSyncTime
        }
    }

    /// Android `ai_cache`.
    @Model nonisolated final class AICacheRecord {
        @Attribute(.unique) var promptHash: String
        var responseJSON: String
        var timestamp: Int64

        init(promptHash: String, responseJSON: String, timestamp: Int64) {
            self.promptHash = promptHash
            self.responseJSON = responseJSON
            self.timestamp = timestamp
        }
    }

    /// Android `ai_usage`.
    @Model nonisolated final class AIUsageRecord {
        @Attribute(.unique) var id: String
        var timestamp: Int64
        var provider: String
        var model: String
        var promptType: String
        var promptTokens: Int
        var outputTokens: Int
        var thoughtTokens: Int

        init(id: String = UUID().uuidString, timestamp: Int64, provider: String, model: String, promptType: String,
             promptTokens: Int, outputTokens: Int, thoughtTokens: Int) {
            self.id = id
            self.timestamp = timestamp
            self.provider = provider
            self.model = model
            self.promptType = promptType
            self.promptTokens = promptTokens
            self.outputTokens = outputTokens
            self.thoughtTokens = thoughtTokens
        }
    }

    /// Android `song_cache` (streamed / downloaded audio on disk).
    @Model nonisolated final class StreamCacheRecord {
        @Attribute(.unique) var songId: String
        var filePath: String
        var sizeBytes: Int64
        var isPermanent: Bool
        var isComplete: Bool
        var createdAt: Int64
        var lastAccessedAt: Int64

        init(songId: String, filePath: String, sizeBytes: Int64, isPermanent: Bool, isComplete: Bool, createdAt: Int64,
             lastAccessedAt: Int64) {
            self.songId = songId
            self.filePath = filePath
            self.sizeBytes = sizeBytes
            self.isPermanent = isPermanent
            self.isComplete = isComplete
            self.createdAt = createdAt
            self.lastAccessedAt = lastAccessedAt
        }
    }

    /// iOS only: tag edits kept as overrides (title, artist, …) when the file can't be rewritten.
    @Model nonisolated final class TagOverrideRecord {
        @Attribute(.unique) var songId: String
        var fieldsJSON: String
        var updatedAt: Int64

        init(songId: String, fieldsJSON: String, updatedAt: Int64) {
            self.songId = songId
            self.fieldsJSON = fieldsJSON
            self.updatedAt = updatedAt
        }
    }

    /// iOS only: a user-picked music folder (security-scoped bookmark).
    @Model nonisolated final class FolderSourceRecord {
        @Attribute(.unique) var id: String
        var displayName: String
        var bookmark: Data
        var addedAt: Int64
        var lastScanAt: Int64?
        var isEnabled: Bool

        init(id: String = UUID().uuidString, displayName: String, bookmark: Data, addedAt: Int64,
             lastScanAt: Int64? = nil, isEnabled: Bool = true) {
            self.id = id
            self.displayName = displayName
            self.bookmark = bookmark
            self.addedAt = addedAt
            self.lastScanAt = lastScanAt
            self.isEnabled = isEnabled
        }
    }
}

typealias SongRecord = SchemaV1.SongRecord
typealias AlbumRecord = SchemaV1.AlbumRecord
typealias ArtistRecord = SchemaV1.ArtistRecord
typealias SongArtistLinkRecord = SchemaV1.SongArtistLinkRecord
typealias FavoriteRecord = SchemaV1.FavoriteRecord
typealias UserPlaylistRecord = SchemaV1.UserPlaylistRecord
typealias PlaylistEntryRecord = SchemaV1.PlaylistEntryRecord
typealias LyricsRecord = SchemaV1.LyricsRecord
typealias EngagementRecord = SchemaV1.EngagementRecord
typealias TransitionRuleRecord = SchemaV1.TransitionRuleRecord
typealias SearchHistoryRecord = SchemaV1.SearchHistoryRecord
typealias ArtworkThemeRecord = SchemaV1.ArtworkThemeRecord
typealias SpotifySongRecord = SchemaV1.SpotifySongRecord
typealias SpotifyPlaylistRecord = SchemaV1.SpotifyPlaylistRecord
typealias AICacheRecord = SchemaV1.AICacheRecord
typealias AIUsageRecord = SchemaV1.AIUsageRecord
typealias StreamCacheRecord = SchemaV1.StreamCacheRecord
typealias TagOverrideRecord = SchemaV1.TagOverrideRecord
typealias FolderSourceRecord = SchemaV1.FolderSourceRecord

/// The migration plan (only v1 so far). Add a stage with every new schema version.
nonisolated enum PixlMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
