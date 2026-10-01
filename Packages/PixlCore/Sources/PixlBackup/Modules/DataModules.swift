// Codecs for the table-like modules: favourites, lyrics, search history, transition rules, engagement stats,
// playback history, AI usage and artist images. Each `restore` reproduces what the Android handler does with a
// payload (including where it fails — Room rejects nulls in NOT NULL columns, Kotlin rejects nulls in non-null
// parameters) and returns PixlModel/PixlLibrary values; each `export` writes the JSON Android writes.

import Foundation
import PixlFoundation
import PixlLibrary
import PixlLyrics
import PixlModel

/// `gson.fromJson(payload, List<T>)` assigned to a Kotlin `List<T>`: an empty document or `null` fails, as does a
/// null element once the DAO touches it.
func decodeRequiredList<T: GsonRecord>(_ payload: String, _ type: T.Type, module: BackupSection) throws(BackupError) -> [(T, JSONObject)] {
    let value: JSONValue?
    do {
        value = try Gson.parse(payload)
    } catch {
        throw BackupError(error.message)
    }
    guard let value, case .array(let items) = value else {
        if value == nil || value == .null { throw BackupError("\(module.label) payload is empty.") }
        throw BackupError("Expected BEGIN_ARRAY but was \(GsonRead.tokenName(value!))")
    }
    var out: [(T, JSONObject)] = []
    out.reserveCapacity(items.count)
    for item in items {
        let record: T?
        do {
            record = try T.gsonDecode(item)
        } catch {
            throw BackupError(error.message)
        }
        guard let record, case .object(let object) = item else { throw BackupError("\(module.label) payload contains a null entry.") }
        out.append((record, object))
    }
    return out
}

/// The song id PixlAudio should resolve for a numeric-id row: its own `pixlSongId` when present, else Android's.
func backupSongId(numeric: Int64, object: JSONObject) -> String {
    if let v = Gson.member(object, BackupSongIds.pixlSongIdKey), case .string(let s) = v, !s.isEmpty { return s }
    return String(numeric)
}

// MARK: - Favourites

public struct FavoriteBackupEntry: Sendable, Hashable {
    /// The id in the backup (PixlAudio's own id for backups PixlAudio wrote, else Android's MediaStore id).
    public var backupSongId: String
    public var isFavorite: Bool
    public var timestamp: Int64

    public init(backupSongId: String, isFavorite: Bool = true, timestamp: Int64) {
        self.backupSongId = backupSongId
        self.isFavorite = isFavorite
        self.timestamp = timestamp
    }
}

public enum FavoritesModule {
    public static func restore(payload: String) throws(BackupError) -> [FavoriteBackupEntry] {
        try decodeRequiredList(payload, AndroidBackup.FavoritesEntity.self, module: .favorites).map { record, object in
            FavoriteBackupEntry(backupSongId: backupSongId(numeric: record.songId, object: object),
                                isFavorite: record.isFavorite, timestamp: record.timestamp)
        }
    }

    /// Canonical field names (`songId`, `isFavorite`, `timestamp`) plus `pixlSongId`.
    public static func export(_ favorites: [FavoriteBackupEntry]) -> String {
        GsonWriter.backup(.array(favorites.map { entry in
            var tree = AndroidBackup.FavoritesEntity(songId: BackupSongIds.numericId(for: entry.backupSongId),
                                                     isFavorite: entry.isFavorite, timestamp: entry.timestamp).gsonTree
            if case .object(var o) = tree {
                o.append(BackupSongIds.pixlSongIdKey, .string(entry.backupSongId))
                tree = .object(o)
            }
            return tree
        }))
    }
}

// MARK: - Lyrics

public struct LyricsBackupRow: Sendable, Hashable {
    public var backupSongId: String
    /// Raw lyrics text (LRC, TTML, LyricsDoc JSON …) — parse with `LyricsUtils.parseLyrics`.
    public var content: String
    public var isSynced: Bool
    public var source: String?

    public init(backupSongId: String, content: String, isSynced: Bool, source: String?) {
        self.backupSongId = backupSongId
        self.content = content
        self.isSynced = isSynced
        self.source = source
    }
}

/// A `filesDir/lyrics/<id>.json` cache file carried in the module (songs without a numeric id: streaming songs).
public struct LyricsBackupFile: Sendable, Hashable {
    public var fileName: String
    public var json: String

    /// The song id the file belongs to (the name without `.json`).
    public var songId: String { String(fileName.dropLast(5)) }

    /// The cache record (`LyricsData`); nil when the file is not a JSON object.
    public var cacheData: LyricsCacheData? { LyricsCacheData.decode(json) }
}

public enum LyricsModule {
    public static let fileKey = "jsonFile"
    public static let jsonKey = "json"
    public static let maxFileChars = 4 * 1024 * 1024

    /// `LyricsModuleHandler.restore`: Room rows and cache files; files with unsafe names or over 4M characters are
    /// dropped. Rows are bound by Gson's tree reader (numbers truncated like `getAsLong`).
    public static func restore(payload: String) throws(BackupError) -> (rows: [LyricsBackupRow], files: [LyricsBackupFile]) {
        let array: [JSONValue]
        do {
            array = try GsonElement.asArray(Gson.parseTree(payload))
        } catch {
            throw BackupError(error.message)
        }
        var rows: [LyricsBackupRow] = []
        var files: [LyricsBackupFile] = []
        for element in array {
            guard case .object(let obj) = element else { continue }
            if let fileValue = Gson.member(obj, fileKey), GsonElement.isPrimitive(fileValue) {
                let fileName = (try? GsonElement.asString(fileValue)) ?? ""
                guard let jsonValue = Gson.member(obj, jsonKey), GsonElement.isPrimitive(jsonValue),
                      let json = try? GsonElement.asString(jsonValue) else { continue }
                if isSafeNonNumericName(fileName) && json.utf16.count <= maxFileChars {
                    files.append(LyricsBackupFile(fileName: fileName, json: json))
                }
                continue
            }
            let record: AndroidBackup.LyricsEntity
            do {
                record = try AndroidBackup.LyricsEntity.gsonTreeDecode(obj)
            } catch {
                throw BackupError(error.message)
            }
            guard let content = record.content else { throw BackupError("Saved Lyrics payload has an entry without content.") }
            rows.append(LyricsBackupRow(backupSongId: backupSongId(numeric: record.songId, object: obj), content: content,
                                        isSynced: record.isSynced, source: record.source))
        }
        return (rows, files)
    }

    /// `isSafeNonNumericName`: `<id>.json`, at most 255 characters, no path separators, not hidden, and an id that
    /// is not a number (numeric ids live in Room rows).
    public static func isSafeNonNumericName(_ name: String) -> Bool {
        guard name.hasSuffixBytes(".json"), name.utf16.count <= 255 else { return false }
        if name.contains("/") || name.contains("\\") || name.hasPrefixBytes(".") { return false }
        let id = String(name.dropLast(5))
        return !id.isEmpty && JavaNumbers.parseLong(id) == nil
    }

    /// Rows with canonical names plus `pixlSongId`; cache files as `{"jsonFile", "json"}` elements.
    public static func export(rows: [LyricsBackupRow], files: [LyricsBackupFile] = []) -> String {
        var items: [JSONValue] = rows.map { row in
            var tree = AndroidBackup.LyricsEntity(songId: BackupSongIds.numericId(for: row.backupSongId), content: row.content,
                                                  isSynced: row.isSynced, source: row.source).gsonTree
            if case .object(var o) = tree {
                o.append(BackupSongIds.pixlSongIdKey, .string(row.backupSongId))
                tree = .object(o)
            }
            return tree
        }
        for file in files where isSafeNonNumericName(file.fileName) {
            items.append(GsonValue.object([(fileKey, .string(file.fileName)), (jsonKey, .string(file.json))]))
        }
        return GsonWriter.backup(.array(items))
    }
}

extension AndroidBackup.LyricsEntity {
    /// `gson.fromJson(JsonObject, LyricsEntity)`: Gson's `JsonTreeReader` reads numbers with `getAsLong`
    /// (`1.5` → 1) and strings with `Long.parseLong` (no decimal fallback).
    static func gsonTreeDecode(_ o: JSONObject) throws(GsonError) -> AndroidBackup.LyricsEntity {
        var r = AndroidBackup.LyricsEntity(songId: 0, content: nil, isSynced: false, source: nil)
        for m in o.members {
            switch m.key {
            case "songId", "song_id":
                switch m.value {
                case .null: break
                case .number, .string: r.songId = try GsonElement.asLong(m.value)
                default: throw .syntax("Expected a long but was \(GsonRead.tokenName(m.value))")
                }
            case "content": r.content = try GsonRead.string(m.value)
            case "isSynced", "is_synced": if let v = try GsonRead.bool(m.value) { r.isSynced = v }
            case "source": r.source = try GsonRead.string(m.value)
            default: break
            }
        }
        return r
    }
}

// MARK: - Search history

public enum SearchHistoryModule {
    public static func restore(payload: String) throws(BackupError) -> [SearchHistoryItem] {
        var out: [SearchHistoryItem] = []
        for (record, _) in try decodeRequiredList(payload, AndroidBackup.SearchHistoryEntity.self, module: .searchHistory) {
            guard let query = record.query else { throw BackupError("Search History payload has an entry without a query.") }
            out.append(SearchHistoryItem(id: record.id == 0 ? nil : record.id, query: query, timestamp: record.timestamp))
        }
        return out
    }

    public static func export(_ items: [SearchHistoryItem]) -> String {
        AndroidBackup.SearchHistoryEntity.encodeList(items.map {
            AndroidBackup.SearchHistoryEntity(id: $0.id ?? 0, query: $0.query, timestamp: $0.timestamp)
        })
    }
}

// MARK: - Transitions

public enum TransitionsModule {
    public static func restore(payload: String) throws(BackupError) -> [TransitionRule] {
        var out: [TransitionRule] = []
        for (record, _) in try decodeRequiredList(payload, AndroidBackup.TransitionRuleEntity.self, module: .transitions) {
            guard let playlistId = record.playlistId, let settings = record.settings,
                  settings.mode != nil, settings.curveIn != nil, settings.curveOut != nil else {
                throw BackupError("Transition Rules payload has an incomplete rule.")
            }
            out.append(TransitionRule(id: record.id, playlistId: playlistId, fromTrackId: record.fromTrackId,
                                      toTrackId: record.toTrackId, settings: settings.settings))
        }
        return out
    }

    public static func export(_ rules: [TransitionRule]) -> String {
        AndroidBackup.TransitionRuleEntity.encodeList(rules.map {
            AndroidBackup.TransitionRuleEntity(id: $0.id, playlistId: $0.playlistId, fromTrackId: $0.fromTrackId,
                                               toTrackId: $0.toTrackId, settings: AndroidBackup.TransitionSettingsRecord($0.settings))
        })
    }
}

// MARK: - Engagement stats

public struct EngagementBackupEntry: Sendable, Hashable {
    public var songId: String
    public var stats: EngagementStats

    public init(songId: String, stats: EngagementStats) {
        self.songId = songId
        self.stats = stats
    }
}

public enum EngagementStatsModule {
    /// `EngagementStatsModuleHandler.restore`: a JSON array is required; rows are read leniently (snake_case and
    /// legacy names, numbers or numeric strings, negatives clamped to 0), rows without a song id skipped and
    /// duplicates merged by maximum; a non-empty payload with no usable row fails.
    public static func restore(payload: String) throws(BackupError) -> [EngagementBackupEntry] {
        let parsed: JSONValue
        do {
            parsed = try Gson.parseTree(payload)
        } catch {
            throw BackupError(error.message)
        }
        guard case .array(let items) = parsed else { throw BackupError("Engagement stats payload must be a JSON array.") }
        let stats: [EngagementBackupEntry]
        do {
            stats = try parseEntries(items)
        } catch {
            throw BackupError(error.message)
        }
        if !items.isEmpty && stats.isEmpty {
            throw BackupError("Engagement stats backup does not contain any valid entries.")
        }
        return stats
    }

    static func parseEntries(_ items: [JSONValue]) throws(GsonError) -> [EngagementBackupEntry] {
        var merged: [EngagementBackupEntry] = []
        var position: [KotlinKey: Int] = [:]
        for item in items {
            guard let entry = try parseEntry(item) else { continue }
            if let i = position[KotlinKey(entry.songId)] {
                let existing = merged[i].stats
                merged[i].stats = EngagementStats(playCount: max(existing.playCount, entry.stats.playCount),
                                                  totalPlayDurationMs: max(existing.totalPlayDurationMs, entry.stats.totalPlayDurationMs),
                                                  lastPlayedTimestamp: max(existing.lastPlayedTimestamp, entry.stats.lastPlayedTimestamp))
            } else {
                position[KotlinKey(entry.songId)] = merged.count
                merged.append(entry)
            }
        }
        return merged
    }

    static func parseEntry(_ element: JSONValue) throws(GsonError) -> EngagementBackupEntry? {
        guard case .object(let obj) = element else { return nil }
        guard let songId = try readString(obj, "songId", "song_id")?.kotlinTrimmed(), !songId.isEmpty else { return nil }
        let playCount = Int32(truncatingIfNeeded: try readLong(obj, "playCount", "play_count", "score", "plays") ?? 0)
        let total = try readLong(obj, "totalPlayDurationMs", "total_play_duration_ms", "totalDuration", "total_duration",
                                 "durationMs", "duration_ms") ?? 0
        let last = try readLong(obj, "lastPlayedTimestamp", "last_played_timestamp", "lastPlayedAt", "last_played_at",
                                "timestamp") ?? 0
        return EngagementBackupEntry(songId: songId, stats: EngagementStats(playCount: Int(max(playCount, 0)),
                                                                             totalPlayDurationMs: max(total, 0),
                                                                             lastPlayedTimestamp: max(last, 0)))
    }

    static func readString(_ obj: JSONObject, _ keys: String...) throws(GsonError) -> String? {
        for key in keys {
            if let v = Gson.member(obj, key), GsonElement.isPrimitive(v) { return try GsonElement.asString(v) }
        }
        return nil
    }

    /// `readLongValue` over the keys in order: the first primitive that reads as a number.
    static func readLong(_ obj: JSONObject, _ keys: String...) throws(GsonError) -> Int64? {
        for key in keys {
            guard let v = Gson.member(obj, key) else { continue }
            switch v {
            case .number: return try GsonElement.asLong(v)
            case .string(let s): if let l = JavaNumbers.parseLong(s) { return l }
            default: continue
            }
        }
        return nil
    }

    /// Canonical names only (`songId`, `playCount`, `totalPlayDurationMs`, `lastPlayedTimestamp`).
    public static func export(_ entries: [EngagementBackupEntry]) -> String {
        AndroidBackup.SongEngagementEntity.encodeList(entries.map {
            AndroidBackup.SongEngagementEntity(songId: $0.songId, playCount: Int32(clamping: $0.stats.playCount),
                                               totalPlayDurationMs: $0.stats.totalPlayDurationMs,
                                               lastPlayedTimestamp: $0.stats.lastPlayedTimestamp)
        })
    }
}

// MARK: - Playback history

public enum PlaybackHistoryModule {
    /// `PlaybackHistoryModuleHandler.restore`: the events, sanitised and de-duplicated as
    /// `importEventsFromBackup(clearExisting = true)` stores them.
    public static func restore(payload: String) throws(BackupError) -> [PlaybackEvent] {
        var events: [PlaybackEvent] = []
        for (record, _) in try decodeRequiredList(payload, AndroidBackup.PlaybackHistoryBackupEntry.self, module: .playbackHistory) {
            guard let songId = record.songId else { throw BackupError("Playback History payload has an entry without a song id.") }
            events.append(PlaybackEvent(songId: songId, timestamp: record.timestamp, durationMs: record.durationMs,
                                        startTimestamp: record.startTimestamp, endTimestamp: record.endTimestamp))
        }
        return PlaybackStats.importingEvents(events, into: [], clearExisting: true)
    }

    public static func export(_ events: [PlaybackEvent]) -> String {
        AndroidBackup.PlaybackHistoryBackupEntry.encodeList(events.map {
            AndroidBackup.PlaybackHistoryBackupEntry(songId: $0.songId, timestamp: $0.timestamp, durationMs: $0.durationMs,
                                                     startTimestamp: $0.startTimestamp, endTimestamp: $0.endTimestamp)
        })
    }
}

// MARK: - AI usage

/// One AI request (`AiUsageEntity`).
public struct AiUsageRecord: Sendable, Hashable, Codable {
    public var id: Int64
    public var timestamp: Int64
    public var provider: String
    public var model: String
    public var promptType: String
    public var promptTokens: Int
    public var outputTokens: Int
    public var thoughtTokens: Int

    public init(id: Int64 = 0, timestamp: Int64, provider: String, model: String, promptType: String, promptTokens: Int,
                outputTokens: Int, thoughtTokens: Int) {
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

public enum AiUsageModule {
    public static func restore(payload: String) throws(BackupError) -> [AiUsageRecord] {
        var out: [AiUsageRecord] = []
        for (r, _) in try decodeRequiredList(payload, AndroidBackup.AiUsageEntity.self, module: .aiUsageLogs) {
            guard let provider = r.provider, let model = r.model, let promptType = r.promptType else {
                throw BackupError("AI Activity Logs payload has an incomplete entry.")
            }
            out.append(AiUsageRecord(id: r.id, timestamp: r.timestamp, provider: provider, model: model, promptType: promptType,
                                     promptTokens: Int(r.promptTokens), outputTokens: Int(r.outputTokens),
                                     thoughtTokens: Int(r.thoughtTokens)))
        }
        return out
    }

    /// The handler encodes with the app's default `Gson()`: compact, nulls dropped.
    public static func export(_ records: [AiUsageRecord]) -> String {
        GsonWriter.plain(.array(records.map {
            AndroidBackup.AiUsageEntity(id: $0.id, timestamp: $0.timestamp, provider: $0.provider, model: $0.model,
                                        promptType: $0.promptType, promptTokens: Int32(clamping: $0.promptTokens),
                                        outputTokens: Int32(clamping: $0.outputTokens),
                                        thoughtTokens: Int32(clamping: $0.thoughtTokens)).gsonTree
        }))
    }
}

// MARK: - Artist images

public struct ArtistImageRestore: Sendable, Hashable {
    public var artistName: String
    /// Deezer image URL to store when not blank.
    public var imageUrl: String?
    /// Decoded custom image (nil when absent or not valid Base64 — Android logs and skips those).
    public var customImage: [UInt8]?
}

public enum ArtistImagesModule {
    /// `ArtistImagesModuleHandler.restore`: entries are matched to artists by name by the app; blank URLs are not
    /// applied.
    public static func restore(payload: String) throws(BackupError) -> [ArtistImageRestore] {
        try decodeRequiredList(payload, AndroidBackup.ArtistImageBackupEntry.self, module: .artistImages).compactMap { r, _ in
            guard let name = r.artistName else { return nil }
            let url = r.imageUrl.flatMap { $0.isKotlinBlank ? nil : $0 }
            let image = r.customImageBase64.flatMap(BackupBase64.decode)
            return ArtistImageRestore(artistName: name, imageUrl: url, customImage: image)
        }
    }

    /// `export()`: artists with a URL or a custom image only.
    public static func export(_ artists: [(name: String, imageUrl: String?, customImage: [UInt8]?)]) -> String {
        AndroidBackup.ArtistImageBackupEntry.encodeList(artists.compactMap { artist in
            let url = artist.imageUrl.flatMap { $0.isKotlinBlank ? nil : $0 }
            let custom = artist.customImage.flatMap { $0.isEmpty ? nil : BackupBase64.encode($0) }
            if url == nil && custom == nil { return nil }
            return AndroidBackup.ArtistImageBackupEntry(artistName: artist.name, imageUrl: url ?? "", customImageBase64: custom)
        })
    }
}
