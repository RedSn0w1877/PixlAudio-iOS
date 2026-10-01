// The JSON records inside Android `.pxpl` modules, bound and written exactly as Gson does with the Android classes
// (`FavoritesEntity`, `LyricsEntity`, `PreferenceBackupEntry`, `Playlist`, …): field order, `@SerializedName`
// alternates (last matching member wins), JVM zero values for classes without a no-arg constructor, Kotlin
// defaults for classes whose every parameter has one, and nulls where Gson leaves them (so a re-encoded record is
// byte-identical to what Android writes). The mapping onto PixlModel/PixlLibrary types lives in `Modules/`.

import Foundation
import PixlFoundation
import PixlModel

/// A record Gson binds and writes.
public protocol GsonRecord: Sendable, Hashable {
    /// Binds one JSON value; nil for JSON null.
    static func gsonDecode(_ value: JSONValue) throws(GsonError) -> Self?
    /// The JSON Gson writes for the record (fields in declaration order, nulls included).
    var gsonTree: JSONValue { get }
}

extension GsonRecord {
    /// `gson.fromJson(text, List<T>)`: nil for an empty document or `null`; elements may be null.
    public static func decodeList(_ text: String) throws(GsonError) -> [Self?]? {
        guard let value = try Gson.parse(text) else { return nil }
        return try GsonRead.list(value, gsonDecode)
    }

    /// `gson.fromJson(text, T)`.
    public static func decode(_ text: String) throws(GsonError) -> Self? {
        guard let value = try Gson.parse(text) else { return nil }
        return try gsonDecode(value)
    }

    /// The backup Gson's output for a list (pretty, nulls kept).
    public static func encodeList(_ items: [Self?]) -> String {
        GsonWriter.backup(.array(items.map { $0?.gsonTree ?? .null }))
    }
}

/// Namespace for the Android entity shapes.
public enum AndroidBackup {
    // MARK: favorites

    /// `FavoritesEntity`.
    public struct FavoritesEntity: GsonRecord {
        public var songId: Int64
        public var isFavorite: Bool
        public var timestamp: Int64

        public init(songId: Int64, isFavorite: Bool = true, timestamp: Int64) {
            self.songId = songId
            self.isFavorite = isFavorite
            self.timestamp = timestamp
        }

        public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> FavoritesEntity? {
            guard let o = try GsonRead.object(value) else { return nil }
            var r = FavoritesEntity(songId: 0, isFavorite: false, timestamp: 0)
            for m in o.members {
                switch m.key {
                case "songId", "song_id": if let v = try GsonRead.long(m.value) { r.songId = v }
                case "isFavorite", "is_favorite": if let v = try GsonRead.bool(m.value) { r.isFavorite = v }
                case "timestamp", "addedAt", "added_at": if let v = try GsonRead.long(m.value) { r.timestamp = v }
                default: break
                }
            }
            return r
        }

        public var gsonTree: JSONValue {
            GsonValue.object([("songId", GsonValue.long(songId)), ("isFavorite", .bool(isFavorite)),
                              ("timestamp", GsonValue.long(timestamp))])
        }
    }

    // MARK: lyrics

    /// `LyricsEntity`.
    public struct LyricsEntity: GsonRecord {
        public var songId: Int64
        public var content: String?
        public var isSynced: Bool
        public var source: String?

        public init(songId: Int64, content: String?, isSynced: Bool = false, source: String? = nil) {
            self.songId = songId
            self.content = content
            self.isSynced = isSynced
            self.source = source
        }

        public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> LyricsEntity? {
            guard let o = try GsonRead.object(value) else { return nil }
            var r = LyricsEntity(songId: 0, content: nil, isSynced: false, source: nil)
            for m in o.members {
                switch m.key {
                case "songId", "song_id": if let v = try GsonRead.long(m.value) { r.songId = v }
                case "content": r.content = try GsonRead.string(m.value)
                case "isSynced", "is_synced": if let v = try GsonRead.bool(m.value) { r.isSynced = v }
                case "source": r.source = try GsonRead.string(m.value)
                default: break
                }
            }
            return r
        }

        public var gsonTree: JSONValue {
            GsonValue.object([("songId", GsonValue.long(songId)), ("content", GsonValue.string(content)),
                              ("isSynced", .bool(isSynced)), ("source", GsonValue.string(source))])
        }
    }

    // MARK: search history

    /// `SearchHistoryEntity`.
    public struct SearchHistoryEntity: GsonRecord {
        public var id: Int64
        public var query: String?
        public var timestamp: Int64

        public init(id: Int64 = 0, query: String?, timestamp: Int64) {
            self.id = id
            self.query = query
            self.timestamp = timestamp
        }

        public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> SearchHistoryEntity? {
            guard let o = try GsonRead.object(value) else { return nil }
            var r = SearchHistoryEntity(id: 0, query: nil, timestamp: 0)
            for m in o.members {
                switch m.key {
                case "id": if let v = try GsonRead.long(m.value) { r.id = v }
                case "query": r.query = try GsonRead.string(m.value)
                case "timestamp": if let v = try GsonRead.long(m.value) { r.timestamp = v }
                default: break
                }
            }
            return r
        }

        public var gsonTree: JSONValue {
            GsonValue.object([("id", GsonValue.long(id)), ("query", GsonValue.string(query)),
                              ("timestamp", GsonValue.long(timestamp))])
        }
    }

    // MARK: transitions

    /// `TransitionSettings` (every parameter has a default, so Gson starts from OVERLAP / 2000 / S_CURVE). Enum
    /// fields hold the Kotlin constant name, or nil where Gson read an unknown name or null.
    public struct TransitionSettingsRecord: GsonRecord {
        public static let modes = TransitionMode.allCases.map(\.rawValue)
        public static let curves = TransitionCurve.allCases.map(\.rawValue)

        public var mode: String?
        public var durationMs: Int32
        public var curveIn: String?
        public var curveOut: String?

        public init(mode: String? = "OVERLAP", durationMs: Int32 = 2000, curveIn: String? = "S_CURVE",
                    curveOut: String? = "S_CURVE") {
            self.mode = mode
            self.durationMs = durationMs
            self.curveIn = curveIn
            self.curveOut = curveOut
        }

        public init(_ settings: TransitionSettings) {
            self.init(mode: settings.mode.rawValue, durationMs: Int32(clamping: settings.durationMs),
                      curveIn: settings.curveIn.rawValue, curveOut: settings.curveOut.rawValue)
        }

        public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> TransitionSettingsRecord? {
            guard let o = try GsonRead.object(value) else { return nil }
            var r = TransitionSettingsRecord()
            for m in o.members {
                switch m.key {
                case "mode": r.mode = try GsonRead.enumName(m.value, allowed: modes)
                case "durationMs": if let v = try GsonRead.int(m.value) { r.durationMs = v }
                case "curveIn": r.curveIn = try GsonRead.enumName(m.value, allowed: curves)
                case "curveOut": r.curveOut = try GsonRead.enumName(m.value, allowed: curves)
                default: break
                }
            }
            return r
        }

        public var gsonTree: JSONValue {
            GsonValue.object([("mode", GsonValue.string(mode)), ("durationMs", GsonValue.int(durationMs)),
                              ("curveIn", GsonValue.string(curveIn)), ("curveOut", GsonValue.string(curveOut))])
        }

        /// The PixlModel settings; unknown or null enum names fall back to Android's defaults.
        public var settings: TransitionSettings {
            TransitionSettings(mode: mode.flatMap(TransitionMode.init(rawValue:)) ?? .overlap, durationMs: Int(durationMs),
                               curveIn: curveIn.flatMap(TransitionCurve.init(rawValue:)) ?? .sCurve,
                               curveOut: curveOut.flatMap(TransitionCurve.init(rawValue:)) ?? .sCurve)
        }
    }

    /// `TransitionRuleEntity`.
    public struct TransitionRuleEntity: GsonRecord {
        public var id: Int64
        public var playlistId: String?
        public var fromTrackId: String?
        public var toTrackId: String?
        public var settings: TransitionSettingsRecord?

        public init(id: Int64 = 0, playlistId: String?, fromTrackId: String?, toTrackId: String?,
                    settings: TransitionSettingsRecord?) {
            self.id = id
            self.playlistId = playlistId
            self.fromTrackId = fromTrackId
            self.toTrackId = toTrackId
            self.settings = settings
        }

        public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> TransitionRuleEntity? {
            guard let o = try GsonRead.object(value) else { return nil }
            var r = TransitionRuleEntity(id: 0, playlistId: nil, fromTrackId: nil, toTrackId: nil, settings: nil)
            for m in o.members {
                switch m.key {
                case "id": if let v = try GsonRead.long(m.value) { r.id = v }
                case "playlistId": r.playlistId = try GsonRead.string(m.value)
                case "fromTrackId", "fromSongId", "from_song_id": r.fromTrackId = try GsonRead.string(m.value)
                case "toTrackId", "toSongId", "to_song_id": r.toTrackId = try GsonRead.string(m.value)
                case "settings": r.settings = try TransitionSettingsRecord.gsonDecode(m.value)
                default: break
                }
            }
            return r
        }

        public var gsonTree: JSONValue {
            GsonValue.object([("id", GsonValue.long(id)), ("playlistId", GsonValue.string(playlistId)),
                              ("fromTrackId", GsonValue.string(fromTrackId)), ("toTrackId", GsonValue.string(toTrackId)),
                              ("settings", settings?.gsonTree ?? .null)])
        }
    }

    // MARK: engagement

    /// `SongEngagementEntity`.
    public struct SongEngagementEntity: GsonRecord {
        public var songId: String?
        public var playCount: Int32
        public var totalPlayDurationMs: Int64
        public var lastPlayedTimestamp: Int64

        public init(songId: String?, playCount: Int32 = 0, totalPlayDurationMs: Int64 = 0, lastPlayedTimestamp: Int64 = 0) {
            self.songId = songId
            self.playCount = playCount
            self.totalPlayDurationMs = totalPlayDurationMs
            self.lastPlayedTimestamp = lastPlayedTimestamp
        }

        public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> SongEngagementEntity? {
            guard let o = try GsonRead.object(value) else { return nil }
            var r = SongEngagementEntity(songId: nil)
            for m in o.members {
                switch m.key {
                case "songId", "song_id": r.songId = try GsonRead.string(m.value)
                case "playCount", "play_count", "score", "plays": if let v = try GsonRead.int(m.value) { r.playCount = v }
                case "totalPlayDurationMs", "total_play_duration_ms", "totalDuration", "total_duration", "durationMs", "duration_ms":
                    if let v = try GsonRead.long(m.value) { r.totalPlayDurationMs = v }
                case "lastPlayedTimestamp", "last_played_timestamp", "lastPlayedAt", "last_played_at", "timestamp":
                    if let v = try GsonRead.long(m.value) { r.lastPlayedTimestamp = v }
                default: break
                }
            }
            return r
        }

        public var gsonTree: JSONValue {
            GsonValue.object([("songId", GsonValue.string(songId)), ("playCount", GsonValue.int(playCount)),
                              ("totalPlayDurationMs", GsonValue.long(totalPlayDurationMs)),
                              ("lastPlayedTimestamp", GsonValue.long(lastPlayedTimestamp))])
        }
    }

    // MARK: playback history

    /// `PlaybackHistoryBackupEntry`.
    public struct PlaybackHistoryBackupEntry: GsonRecord {
        public var songId: String?
        public var timestamp: Int64
        public var durationMs: Int64
        public var startTimestamp: Int64?
        public var endTimestamp: Int64?

        public init(songId: String?, timestamp: Int64, durationMs: Int64, startTimestamp: Int64? = nil,
                    endTimestamp: Int64? = nil) {
            self.songId = songId
            self.timestamp = timestamp
            self.durationMs = durationMs
            self.startTimestamp = startTimestamp
            self.endTimestamp = endTimestamp
        }

        public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> PlaybackHistoryBackupEntry? {
            guard let o = try GsonRead.object(value) else { return nil }
            var r = PlaybackHistoryBackupEntry(songId: nil, timestamp: 0, durationMs: 0)
            for m in o.members {
                switch m.key {
                case "songId": r.songId = try GsonRead.string(m.value)
                case "timestamp": if let v = try GsonRead.long(m.value) { r.timestamp = v }
                case "durationMs": if let v = try GsonRead.long(m.value) { r.durationMs = v }
                case "startTimestamp": r.startTimestamp = try GsonRead.long(m.value)
                case "endTimestamp": r.endTimestamp = try GsonRead.long(m.value)
                default: break
                }
            }
            return r
        }

        public var gsonTree: JSONValue {
            GsonValue.object([("songId", GsonValue.string(songId)), ("timestamp", GsonValue.long(timestamp)),
                              ("durationMs", GsonValue.long(durationMs)), ("startTimestamp", GsonValue.long(startTimestamp)),
                              ("endTimestamp", GsonValue.long(endTimestamp))])
        }
    }

    // MARK: AI usage

    /// `AiUsageEntity`.
    public struct AiUsageEntity: GsonRecord {
        public var id: Int64
        public var timestamp: Int64
        public var provider: String?
        public var model: String?
        public var promptType: String?
        public var promptTokens: Int32
        public var outputTokens: Int32
        public var thoughtTokens: Int32

        public init(id: Int64 = 0, timestamp: Int64, provider: String?, model: String?, promptType: String?,
                    promptTokens: Int32, outputTokens: Int32, thoughtTokens: Int32) {
            self.id = id
            self.timestamp = timestamp
            self.provider = provider
            self.model = model
            self.promptType = promptType
            self.promptTokens = promptTokens
            self.outputTokens = outputTokens
            self.thoughtTokens = thoughtTokens
        }

        public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> AiUsageEntity? {
            guard let o = try GsonRead.object(value) else { return nil }
            var r = AiUsageEntity(timestamp: 0, provider: nil, model: nil, promptType: nil, promptTokens: 0,
                                  outputTokens: 0, thoughtTokens: 0)
            for m in o.members {
                switch m.key {
                case "id": if let v = try GsonRead.long(m.value) { r.id = v }
                case "timestamp": if let v = try GsonRead.long(m.value) { r.timestamp = v }
                case "provider": r.provider = try GsonRead.string(m.value)
                case "model": r.model = try GsonRead.string(m.value)
                case "promptType": r.promptType = try GsonRead.string(m.value)
                case "promptTokens": if let v = try GsonRead.int(m.value) { r.promptTokens = v }
                case "outputTokens": if let v = try GsonRead.int(m.value) { r.outputTokens = v }
                case "thoughtTokens": if let v = try GsonRead.int(m.value) { r.thoughtTokens = v }
                default: break
                }
            }
            return r
        }

        public var gsonTree: JSONValue {
            GsonValue.object([("id", GsonValue.long(id)), ("timestamp", GsonValue.long(timestamp)),
                              ("provider", GsonValue.string(provider)), ("model", GsonValue.string(model)),
                              ("promptType", GsonValue.string(promptType)), ("promptTokens", GsonValue.int(promptTokens)),
                              ("outputTokens", GsonValue.int(outputTokens)), ("thoughtTokens", GsonValue.int(thoughtTokens))])
        }
    }

    // MARK: artist images

    /// `ArtistImageBackupEntry`.
    public struct ArtistImageBackupEntry: GsonRecord {
        public var artistName: String?
        public var imageUrl: String?
        public var customImageBase64: String?

        public init(artistName: String?, imageUrl: String?, customImageBase64: String? = nil) {
            self.artistName = artistName
            self.imageUrl = imageUrl
            self.customImageBase64 = customImageBase64
        }

        public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> ArtistImageBackupEntry? {
            guard let o = try GsonRead.object(value) else { return nil }
            var r = ArtistImageBackupEntry(artistName: nil, imageUrl: nil, customImageBase64: nil)
            for m in o.members {
                switch m.key {
                case "artistName": r.artistName = try GsonRead.string(m.value)
                case "imageUrl": r.imageUrl = try GsonRead.string(m.value)
                case "customImageBase64": r.customImageBase64 = try GsonRead.string(m.value)
                default: break
                }
            }
            return r
        }

        public var gsonTree: JSONValue {
            GsonValue.object([("artistName", GsonValue.string(artistName)), ("imageUrl", GsonValue.string(imageUrl)),
                              ("customImageBase64", GsonValue.string(customImageBase64))])
        }
    }

    // MARK: preferences

    /// `PreferenceBackupEntry`: one DataStore preference (settings, QuickFill, equalizer, legacy playlists).
    public struct PreferenceBackupEntry: GsonRecord {
        public static let validTypes: Set<String> = ["string", "int", "long", "boolean", "float", "double", "string_set"]

        public var key: String?
        public var type: String?
        public var stringValue: String?
        public var intValue: Int32?
        public var longValue: Int64?
        public var booleanValue: Bool?
        public var floatValue: Float?
        public var doubleValue: Double?
        public var stringSetValue: [String?]?

        public init(key: String?, type: String?, stringValue: String? = nil, intValue: Int32? = nil,
                    longValue: Int64? = nil, booleanValue: Bool? = nil, floatValue: Float? = nil,
                    doubleValue: Double? = nil, stringSetValue: [String?]? = nil) {
            self.key = key
            self.type = type
            self.stringValue = stringValue
            self.intValue = intValue
            self.longValue = longValue
            self.booleanValue = booleanValue
            self.floatValue = floatValue
            self.doubleValue = doubleValue
            self.stringSetValue = stringSetValue
        }

        public static func string(_ key: String, _ value: String) -> PreferenceBackupEntry {
            PreferenceBackupEntry(key: key, type: "string", stringValue: value)
        }

        public static func int(_ key: String, _ value: Int32) -> PreferenceBackupEntry {
            PreferenceBackupEntry(key: key, type: "int", intValue: value)
        }

        public static func long(_ key: String, _ value: Int64) -> PreferenceBackupEntry {
            PreferenceBackupEntry(key: key, type: "long", longValue: value)
        }

        public static func boolean(_ key: String, _ value: Bool) -> PreferenceBackupEntry {
            PreferenceBackupEntry(key: key, type: "boolean", booleanValue: value)
        }

        public static func float(_ key: String, _ value: Float) -> PreferenceBackupEntry {
            PreferenceBackupEntry(key: key, type: "float", floatValue: value)
        }

        public static func double(_ key: String, _ value: Double) -> PreferenceBackupEntry {
            PreferenceBackupEntry(key: key, type: "double", doubleValue: value)
        }

        public static func stringSet(_ key: String, _ value: [String]) -> PreferenceBackupEntry {
            var seen = Set<String>()
            return PreferenceBackupEntry(key: key, type: "string_set", stringSetValue: value.filter { seen.insert($0).inserted })
        }

        public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> PreferenceBackupEntry? {
            guard let o = try GsonRead.object(value) else { return nil }
            var r = PreferenceBackupEntry(key: nil, type: nil)
            for m in o.members {
                switch m.key {
                case "key": r.key = try GsonRead.string(m.value)
                case "type": r.type = try GsonRead.string(m.value)
                case "stringValue": r.stringValue = try GsonRead.string(m.value)
                case "intValue": r.intValue = try GsonRead.int(m.value)
                case "longValue": r.longValue = try GsonRead.long(m.value)
                case "booleanValue": r.booleanValue = try GsonRead.bool(m.value)
                case "floatValue": r.floatValue = try GsonRead.float(m.value)
                case "doubleValue": r.doubleValue = try GsonRead.double(m.value)
                case "stringSetValue": r.stringSetValue = try GsonRead.stringSet(m.value)
                default: break
                }
            }
            return r
        }

        public var gsonTree: JSONValue {
            GsonValue.object([("key", GsonValue.string(key)), ("type", GsonValue.string(type)),
                              ("stringValue", GsonValue.string(stringValue)), ("intValue", GsonValue.int(intValue)),
                              ("longValue", GsonValue.long(longValue)), ("booleanValue", GsonValue.bool(booleanValue)),
                              ("floatValue", GsonValue.float(floatValue)), ("doubleValue", GsonValue.double(doubleValue)),
                              ("stringSetValue", GsonValue.strings(stringSetValue))])
        }
    }

    // MARK: playlists

    /// The Android `Playlist` as Gson binds it (no no-arg constructor: missing fields are JVM zero values).
    public struct PlaylistRecord: GsonRecord {
        public var id: String?
        public var name: String?
        public var songIds: [String?]?
        public var createdAt: Int64
        public var lastModified: Int64
        public var isAiGenerated: Bool
        public var isQueueGenerated: Bool
        public var coverImageUri: String?
        public var coverColorArgb: Int32?
        public var coverIconName: String?
        public var coverShapeType: String?
        public var coverShapeDetail1: Float?
        public var coverShapeDetail2: Float?
        public var coverShapeDetail3: Float?
        public var coverShapeDetail4: Float?
        public var source: String?
        public var sortOrder: Int32

        public init(id: String?, name: String?, songIds: [String?]?, createdAt: Int64 = 0, lastModified: Int64 = 0,
                    isAiGenerated: Bool = false, isQueueGenerated: Bool = false, coverImageUri: String? = nil,
                    coverColorArgb: Int32? = nil, coverIconName: String? = nil, coverShapeType: String? = nil,
                    coverShapeDetail1: Float? = nil, coverShapeDetail2: Float? = nil, coverShapeDetail3: Float? = nil,
                    coverShapeDetail4: Float? = nil, source: String? = "LOCAL", sortOrder: Int32 = 0) {
            self.id = id
            self.name = name
            self.songIds = songIds
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
        }

        public init(_ p: Playlist) {
            self.init(id: p.id, name: p.name, songIds: p.songIds, createdAt: p.createdAt, lastModified: p.lastModified,
                      isAiGenerated: p.isAiGenerated, isQueueGenerated: p.isQueueGenerated, coverImageUri: p.coverImageUri,
                      coverColorArgb: p.coverColorArgb, coverIconName: p.coverIconName, coverShapeType: p.coverShapeType,
                      coverShapeDetail1: p.coverShapeDetail1, coverShapeDetail2: p.coverShapeDetail2,
                      coverShapeDetail3: p.coverShapeDetail3, coverShapeDetail4: p.coverShapeDetail4, source: p.source,
                      sortOrder: Int32(clamping: p.sortOrder))
        }

        public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> PlaylistRecord? {
            guard let o = try GsonRead.object(value) else { return nil }
            var r = PlaylistRecord(id: nil, name: nil, songIds: nil, source: nil)
            for m in o.members {
                switch m.key {
                case "id": r.id = try GsonRead.string(m.value)
                case "name": r.name = try GsonRead.string(m.value)
                case "songIds": r.songIds = try GsonRead.list(m.value, GsonRead.string)
                case "createdAt": if let v = try GsonRead.long(m.value) { r.createdAt = v }
                case "lastModified": if let v = try GsonRead.long(m.value) { r.lastModified = v }
                case "isAiGenerated": if let v = try GsonRead.bool(m.value) { r.isAiGenerated = v }
                case "isQueueGenerated": if let v = try GsonRead.bool(m.value) { r.isQueueGenerated = v }
                case "coverImageUri": r.coverImageUri = try GsonRead.string(m.value)
                case "coverColorArgb": r.coverColorArgb = try GsonRead.int(m.value)
                case "coverIconName": r.coverIconName = try GsonRead.string(m.value)
                case "coverShapeType": r.coverShapeType = try GsonRead.string(m.value)
                case "coverShapeDetail1": r.coverShapeDetail1 = try GsonRead.float(m.value)
                case "coverShapeDetail2": r.coverShapeDetail2 = try GsonRead.float(m.value)
                case "coverShapeDetail3": r.coverShapeDetail3 = try GsonRead.float(m.value)
                case "coverShapeDetail4": r.coverShapeDetail4 = try GsonRead.float(m.value)
                case "source": r.source = try GsonRead.string(m.value)
                case "sortOrder": if let v = try GsonRead.int(m.value) { r.sortOrder = v }
                default: break
                }
            }
            return r
        }

        public var gsonTree: JSONValue {
            GsonValue.object([
                ("id", GsonValue.string(id)), ("name", GsonValue.string(name)), ("songIds", GsonValue.strings(songIds)),
                ("createdAt", GsonValue.long(createdAt)), ("lastModified", GsonValue.long(lastModified)),
                ("isAiGenerated", .bool(isAiGenerated)), ("isQueueGenerated", .bool(isQueueGenerated)),
                ("coverImageUri", GsonValue.string(coverImageUri)), ("coverColorArgb", GsonValue.int(coverColorArgb)),
                ("coverIconName", GsonValue.string(coverIconName)), ("coverShapeType", GsonValue.string(coverShapeType)),
                ("coverShapeDetail1", GsonValue.float(coverShapeDetail1)), ("coverShapeDetail2", GsonValue.float(coverShapeDetail2)),
                ("coverShapeDetail3", GsonValue.float(coverShapeDetail3)), ("coverShapeDetail4", GsonValue.float(coverShapeDetail4)),
                ("source", GsonValue.string(source)), ("sortOrder", GsonValue.int(sortOrder)),
            ])
        }

        /// The PixlModel playlist. Android stores nulls Gson produced as-is; PixlAudio needs values, so null ids and
        /// names become "", null song ids are dropped and a null source is "LOCAL" (Kotlin's default).
        public var playlist: Playlist {
            Playlist(id: id ?? "", name: name ?? "", songIds: (songIds ?? []).compactMap { $0 }, createdAt: createdAt,
                     lastModified: lastModified, isAiGenerated: isAiGenerated, isQueueGenerated: isQueueGenerated,
                     coverImageUri: coverImageUri, coverColorArgb: coverColorArgb, coverIconName: coverIconName,
                     coverShapeType: coverShapeType, coverShapeDetail1: coverShapeDetail1, coverShapeDetail2: coverShapeDetail2,
                     coverShapeDetail3: coverShapeDetail3, coverShapeDetail4: coverShapeDetail4, source: source ?? "LOCAL",
                     sortOrder: Int(sortOrder))
        }
    }

    /// `PlaylistsModuleHandler.SongMetadataEntry`: what a song id meant on the device that wrote the backup.
    public struct SongMetadataEntry: GsonRecord {
        public var title: String?
        public var artist: String?
        public var album: String?
        public var duration: Int64

        public init(title: String?, artist: String?, album: String?, duration: Int64) {
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
        }

        public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> SongMetadataEntry? {
            guard let o = try GsonRead.object(value) else { return nil }
            var r = SongMetadataEntry(title: nil, artist: nil, album: nil, duration: 0)
            for m in o.members {
                switch m.key {
                case "title": r.title = try GsonRead.string(m.value)
                case "artist": r.artist = try GsonRead.string(m.value)
                case "album": r.album = try GsonRead.string(m.value)
                case "duration": if let v = try GsonRead.long(m.value) { r.duration = v }
                default: break
                }
            }
            return r
        }

        public var gsonTree: JSONValue {
            GsonValue.object([("title", GsonValue.string(title)), ("artist", GsonValue.string(artist)),
                              ("album", GsonValue.string(album)), ("duration", GsonValue.long(duration))])
        }
    }

    /// `PlaylistsModuleHandler.PlaylistsBackupPayload` (every field defaults to null).
    public struct PlaylistsBackupPayload: GsonRecord {
        public var playlists: [PlaylistRecord?]?
        public var playlistSongOrderModes: GsonMap<String>?
        public var playlistsSortOption: String?
        /// Song metadata for cross-device matching, keyed by the song id in the backup.
        public var songMetadata: GsonMap<SongMetadataEntry>?
        /// Base64 cover images keyed by playlist id.
        public var coverImages: GsonMap<String>?

        public init(playlists: [PlaylistRecord?]? = nil, playlistSongOrderModes: GsonMap<String>? = nil,
                    playlistsSortOption: String? = nil, songMetadata: GsonMap<SongMetadataEntry>? = nil,
                    coverImages: GsonMap<String>? = nil) {
            self.playlists = playlists
            self.playlistSongOrderModes = playlistSongOrderModes
            self.playlistsSortOption = playlistsSortOption
            self.songMetadata = songMetadata
            self.coverImages = coverImages
        }

        public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> PlaylistsBackupPayload? {
            guard let o = try GsonRead.object(value) else { return nil }
            var r = PlaylistsBackupPayload()
            for m in o.members {
                switch m.key {
                case "playlists": r.playlists = try GsonRead.list(m.value, PlaylistRecord.gsonDecode)
                case "playlistSongOrderModes": r.playlistSongOrderModes = try GsonRead.map(m.value, GsonRead.string)
                case "playlistsSortOption": r.playlistsSortOption = try GsonRead.string(m.value)
                case "songMetadata": r.songMetadata = try GsonRead.map(m.value, SongMetadataEntry.gsonDecode)
                case "coverImages": r.coverImages = try GsonRead.map(m.value, GsonRead.string)
                default: break
                }
            }
            return r
        }

        public var gsonTree: JSONValue {
            GsonValue.object([
                ("playlists", playlists.map { .array($0.map { $0?.gsonTree ?? .null }) } ?? .null),
                ("playlistSongOrderModes", GsonValue.map(playlistSongOrderModes) { .string($0) }),
                ("playlistsSortOption", GsonValue.string(playlistsSortOption)),
                ("songMetadata", GsonValue.map(songMetadata) { $0.gsonTree }),
                ("coverImages", GsonValue.map(coverImages) { .string($0) }),
            ])
        }
    }
}

// MARK: - Manifest

extension BackupModuleInfo: GsonRecord {
    public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> BackupModuleInfo? {
        guard let o = try GsonRead.object(value) else { return nil }
        var r = BackupModuleInfo()
        for m in o.members {
            switch m.key {
            case "checksum": r.checksum = try GsonRead.string(m.value)
            case "entryCount": if let v = try GsonRead.int(m.value) { r.entryCount = v }
            case "sizeBytes": if let v = try GsonRead.long(m.value) { r.sizeBytes = v }
            default: break
            }
        }
        return r
    }

    public var gsonTree: JSONValue {
        GsonValue.object([("checksum", GsonValue.string(checksum)), ("entryCount", GsonValue.int(entryCount)),
                          ("sizeBytes", GsonValue.long(sizeBytes))])
    }
}

extension DeviceInfo: GsonRecord {
    public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> DeviceInfo? {
        guard let o = try GsonRead.object(value) else { return nil }
        var r = DeviceInfo()
        for m in o.members {
            switch m.key {
            case "manufacturer": r.manufacturer = try GsonRead.string(m.value)
            case "model": r.model = try GsonRead.string(m.value)
            case "androidVersion": if let v = try GsonRead.int(m.value) { r.androidVersion = v }
            default: break
            }
        }
        return r
    }

    public var gsonTree: JSONValue {
        GsonValue.object([("manufacturer", GsonValue.string(manufacturer)), ("model", GsonValue.string(model)),
                          ("androidVersion", GsonValue.int(androidVersion))])
    }
}

extension BackupManifest: GsonRecord {
    public static func gsonDecode(_ value: JSONValue) throws(GsonError) -> BackupManifest? {
        try gsonDecode(value, now: currentTimeMillis())
    }

    /// Binds manifest.json; `now` is the Kotlin default for a missing `createdAt`.
    public static func gsonDecode(_ value: JSONValue, now: Int64) throws(GsonError) -> BackupManifest? {
        guard let o = try GsonRead.object(value) else { return nil }
        var r = BackupManifest(createdAt: now)
        for m in o.members {
            switch m.key {
            case "schemaVersion": if let v = try GsonRead.int(m.value) { r.schemaVersion = v }
            case "appVersion": r.appVersion = try GsonRead.string(m.value)
            case "appVersionCode": if let v = try GsonRead.int(m.value) { r.appVersionCode = v }
            case "createdAt": if let v = try GsonRead.long(m.value) { r.createdAt = v }
            case "deviceInfo": r.deviceInfo = try DeviceInfo.gsonDecode(m.value)
            case "modules": r.modules = try GsonRead.map(m.value, BackupModuleInfo.gsonDecode)
            default: break
            }
        }
        return r
    }

    /// Parses manifest.json text (`gson.fromJson(json, BackupManifest::class.java)`); nil for an empty document.
    public static func decode(json: String, now: Int64 = currentTimeMillis()) throws(GsonError) -> BackupManifest? {
        guard let value = try Gson.parse(json) else { return nil }
        return try gsonDecode(value, now: now)
    }

    public var gsonTree: JSONValue {
        GsonValue.object([
            ("schemaVersion", GsonValue.int(schemaVersion)), ("appVersion", GsonValue.string(appVersion)),
            ("appVersionCode", GsonValue.int(appVersionCode)), ("createdAt", GsonValue.long(createdAt)),
            ("deviceInfo", deviceInfo?.gsonTree ?? .null),
            ("modules", GsonValue.map(modules) { $0.gsonTree }),
        ])
    }

    /// manifest.json as the backup Gson writes it.
    public var json: String { GsonWriter.backup(gsonTree) }
}
