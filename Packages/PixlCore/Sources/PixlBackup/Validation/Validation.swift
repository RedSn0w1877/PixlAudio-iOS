// Backup validation, ported from the Android app's `data/backup/validation/`: `ContentSanitizer`,
// `BackupFileValidator` (container safety), `ManifestValidator` (schema version, timestamps, module keys,
// checksums), `ModuleSchemaValidator` (per-module JSON shape) and `ValidationPipeline`. Codes, messages and
// severities are Android's; the JSON is read with Gson's semantics (`GsonElement`), so a payload that makes the
// Android validator throw also throws here.

import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel

/// `ContentSanitizer`.
public enum ContentSanitizer {
    public static let defaultMaxLength = 10_000

    /// `sanitizeString`: Kotlin `trim()`, keep the first `maxLength` UTF-16 units, then drop C0 controls except
    /// tab/LF/CR, and DEL. (A surrogate pair cut in half by the length limit loses its dangling half.)
    public static func sanitizeString(_ input: String, maxLength: Int = defaultMaxLength) -> String {
        var result = input.kotlinTrimmed()
        if result.utf16.count > maxLength {
            var units = Array(result.utf16.prefix(max(maxLength, 0)))
            if let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
            result = String(decoding: units, as: UTF16.self)
        }
        var scalars = String.UnicodeScalarView()
        for s in result.unicodeScalars where !isStrippedControl(s) { scalars.append(s) }
        return String(scalars)
    }

    /// `sanitizeUrl`: sanitised, and only `https://` or `http://` (case-sensitive) survive; anything else is "".
    public static func sanitizeUrl(_ url: String, maxLength: Int = 2000) -> String {
        let sanitized = sanitizeString(url, maxLength: maxLength)
        if !sanitized.isEmpty && !sanitized.hasPrefixBytes("https://") && !sanitized.hasPrefixBytes("http://") { return "" }
        return sanitized
    }

    /// `isValidModuleKey`: `^[a-z_]+$`, at most 50 characters.
    public static func isValidModuleKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf16.count <= 50 && key.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }
    }

    /// `[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]`.
    static func isStrippedControl(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F: return true
        default: return false
        }
    }
}

extension String {
    func hasPrefixBytes(_ prefix: String) -> Bool { utf8.starts(with: prefix.utf8) }
    func hasSuffixBytes(_ suffix: String) -> Bool { utf8.reversed().starts(with: suffix.utf8.reversed()) }
}

/// `BackupFileValidator`: the file as a whole — empty, too large, extension, format, and for ZIP archives entry
/// names (path traversal, unexpected files) and decompression bombs.
public enum BackupFileValidator {
    public static let maxBackupSizeBytes: Int64 = 50 * 1024 * 1024
    /// Maximum decompressed/compressed ratio.
    public static let maxZipRatio: Int64 = 100
    static let maxTotalDecompressedBytes: Int64 = 256 * 1024 * 1024

    /// Validates a backup. `fileName` and `fileSize` are what the document provider reports (nil when unknown);
    /// `bytes` is the file content.
    public static func validate(bytes: [UInt8], fileName: String?, fileSize: Int64?) -> BackupValidationResult {
        var errors: [ValidationError] = []
        let header = bytes.prefix(BackupFormatDetector.headerSize)
        if header.isEmpty {
            return .invalid([ValidationError(code: "FILE_EMPTY", message: "Backup file is empty or inaccessible.")])
        }
        let format = BackupFormatDetector.detect(header)
        if let fileSize, fileSize > maxBackupSizeBytes {
            return .invalid([ValidationError(code: "FILE_TOO_LARGE",
                                             message: "Backup file exceeds the \(maxBackupSizeBytes / (1024 * 1024))MB limit.")])
        }
        if let fileName, !hasSuffixIgnoringCase(fileName, ".pxpl"), !hasSuffixIgnoringCase(fileName, ".gz") {
            errors.append(ValidationError(code: "FILE_EXTENSION",
                                          message: "File extension is not .pxpl. The file may not be a valid backup.",
                                          severity: .warning))
        }
        if format == .unknown {
            errors.append(ValidationError(code: "FORMAT_UNKNOWN", message: "File is not a recognized PixelPlay backup format."))
            return .invalid(errors)
        }
        if format == .pxplV3Zip {
            validateZipSafety(bytes: bytes, fileSize: fileSize, offset: BackupFormatDetector.pxplMagicSize, errors: &errors)
        }
        return .from(errors)
    }

    static func hasSuffixIgnoringCase(_ s: String, _ suffix: String) -> Bool {
        let units = Array(s.utf16), suffixUnits = Array(suffix.utf16)
        guard units.count >= suffixUnits.count else { return false }
        return zip(units.suffix(suffixUnits.count), suffixUnits).allSatisfy { a, b in
            a == b || (a < 0x80 && b < 0x80 && (a | 0x20) == (b | 0x20) && (a | 0x20) >= 0x61 && (a | 0x20) <= 0x7A)
        }
    }

    /// Walks the entries in order like `ZipInputStream`, counting decompressed bytes per entry and overall.
    static func validateZipSafety(bytes: [UInt8], fileSize: Int64?, offset: Int, errors: inout [ValidationError]) {
        let compressedZipBytes = fileSize.map { max($0 - Int64(offset), 0) }
        guard bytes.count >= offset else {
            errors.append(ValidationError(code: "ZIP_CORRUPT", message: "Backup ZIP archive is corrupted: Backup file is truncated."))
            return
        }
        let archive: ZipArchive
        do {
            archive = try ZipArchive(bytes: Array(bytes[offset...]))
        } catch {
            errors.append(ValidationError(code: "ZIP_CORRUPT", message: "Backup ZIP archive is corrupted: \(error.description)"))
            return
        }
        var totalDecompressed: Int64 = 0
        for entry in archive.entries {
            let name = entry.name
            if name.contains("..") || name.hasPrefixBytes("/") || name.hasPrefixBytes("\\") {
                errors.append(ValidationError(code: "ZIP_PATH_TRAVERSAL", message: "Suspicious zip entry path: \(name)"))
                return
            }
            if !name.hasSuffixBytes(".json") {
                errors.append(ValidationError(code: "ZIP_UNEXPECTED_ENTRY", message: "Unexpected file in backup: \(name)",
                                              severity: .warning))
            }
            let perEntryLimit = Int64(name == BackupManifest.manifestFilename ? BackupReader.maxManifestBytes
                                                                               : BackupReader.maxModulePayloadBytes)
            // Decode at most one byte past the tightest limit that applies, so a bomb never fully expands.
            var limit = perEntryLimit
            limit = min(limit, maxTotalDecompressedBytes - totalDecompressed)
            if let compressedZipBytes, compressedZipBytes > 0 {
                limit = min(limit, compressedZipBytes * maxZipRatio - totalDecompressed)
            }
            let size: Int64
            do {
                size = Int64(try archive.data(for: entry, maxSize: Int(max(limit, 0) + 1)).count)
            } catch .entryTooLarge {
                size = max(limit, 0) + 1
            } catch {
                errors.append(ValidationError(code: "ZIP_CORRUPT", message: "Backup ZIP archive is corrupted: \(error.description)"))
                return
            }
            totalDecompressed += size
            if size > perEntryLimit {
                errors.append(ValidationError(
                    code: "ZIP_ENTRY_TOO_LARGE",
                    message: "Backup entry '\(name)' exceeds the \(perEntryLimit / (1024 * 1024))MB in-memory safety limit."))
                return
            }
            if totalDecompressed > maxTotalDecompressedBytes {
                errors.append(ValidationError(
                    code: "ZIP_TOO_LARGE",
                    message: "Backup file expands beyond the \(maxTotalDecompressedBytes / (1024 * 1024))MB safety limit."))
                return
            }
            if let compressedZipBytes, compressedZipBytes > 0, totalDecompressed > compressedZipBytes * maxZipRatio {
                errors.append(ValidationError(code: "ZIP_BOMB", message: "Backup file has suspicious compression ratio."))
                return
            }
        }
    }
}

/// `ManifestValidator`. `now` is injected (Android reads the clock).
public struct ManifestValidator: Sendable {
    public let now: @Sendable () -> Int64
    public let hasher: SHA256Hasher

    public init(now: @escaping @Sendable () -> Int64 = { currentTimeMillis() }, hasher: @escaping SHA256Hasher = BackupHashing.pureSwift) {
        self.now = now
        self.hasher = hasher
    }

    public func validate(_ manifest: BackupManifest) throws(BackupError) -> BackupValidationResult {
        var errors: [ValidationError] = []
        if manifest.schemaVersion < BackupManifest.minSupportedVersion {
            errors.append(ValidationError(code: "SCHEMA_TOO_OLD",
                                          message: "Backup schema version \(manifest.schemaVersion) is not supported."))
        }
        if manifest.schemaVersion > BackupManifest.currentSchemaVersion {
            errors.append(ValidationError(
                code: "SCHEMA_TOO_NEW",
                message: "Backup was created with a newer app version (schema v\(manifest.schemaVersion)). Some data may not be restored.",
                severity: .warning))
        }
        if manifest.createdAt > now() &+ 86_400_000 {
            errors.append(ValidationError(code: "TIMESTAMP_FUTURE", message: "Backup has a timestamp in the future.", severity: .warning))
        }
        if manifest.createdAt < 1_700_000_000_000 {
            errors.append(ValidationError(code: "TIMESTAMP_OLD", message: "Backup has an unusually old timestamp.", severity: .warning))
        }
        // `manifest.modules.keys` (a null modules map is a NullPointerException on Android).
        guard let modules = manifest.modules else { throw BackupError("Backup manifest has no module list.") }
        for key in modules.keys where BackupSection.fromKey(key) == nil {
            errors.append(ValidationError(code: "UNKNOWN_MODULE", message: "Unknown module '\(key)' in backup. It will be skipped.",
                                          module: key, severity: .warning))
        }
        return .from(errors)
    }

    /// `verifyChecksum`: true when the manifest has no `sha256:` checksum for the module, else whether the
    /// payload's UTF-8 SHA-256 matches (lowercase hex, compared exactly).
    public func verifyChecksum(moduleKey: String, payload: String, manifest: BackupManifest) -> Bool {
        guard let info = manifest.module(moduleKey), let expected = info.checksum else { return true }
        guard expected.hasPrefixBytes("sha256:") else { return true }
        let expectedHash = String(expected.dropFirst(7))
        return KotlinText.equals(expectedHash, BackupHashing.hex(Array(payload.utf8), hasher: hasher))
    }
}

/// `ModuleSchemaValidator`.
public enum ModuleSchemaValidator {
    public static let maxStringLength = 50_000
    public static let maxEntriesPerModule = 100_000

    /// Validates one module payload. Throws where the Android validator throws (a Gson accessor on the wrong
    /// kind of value, e.g. `"content": null`), with the Java exception's class as the message.
    public static func validate(_ section: BackupSection, payload: String) throws(GsonError) -> BackupValidationResult {
        var errors: [ValidationError] = []
        let element: JSONValue
        do {
            element = try Gson.parseTree(payload)
        } catch {
            return .invalid([ValidationError(code: "INVALID_JSON", message: "Module '\(section.key)' contains invalid JSON.",
                                             module: section.key)])
        }
        if section == .playlists {
            try validatePlaylistsModule(element, &errors)
            return .from(errors)
        }
        if section != .quickFill && section != .equalizer {
            guard case .array(let array) = element else {
                return .invalid([ValidationError(code: "NOT_ARRAY", message: "Module '\(section.key)' should be a JSON array.",
                                                 module: section.key)])
            }
            if array.count > maxEntriesPerModule {
                return .invalid([ValidationError(
                    code: "TOO_MANY_ENTRIES",
                    message: "Module '\(section.key)' has \(array.count) entries (max \(maxEntriesPerModule)).",
                    module: section.key)])
            }
        }
        switch section {
        case .playlists: break
        case .favorites: try validateFavorites(element, &errors)
        case .lyrics: try validateLyrics(element, &errors)
        case .searchHistory: try validateSearchHistory(element, &errors)
        case .engagementStats: try validateEngagementStats(element, &errors)
        case .playbackHistory: try validatePlaybackHistory(element, &errors)
        case .artistImages: try validateArtistImages(element, &errors)
        case .transitions: try validateTransitions(element, &errors)
        case .globalSettings, .quickFill, .equalizer: try validatePreferenceEntries(element, section.key, &errors)
        case .aiUsageLogs: break
        }
        return .from(errors)
    }

    static func objects(_ element: JSONValue) -> [(Int, JSONObject)] {
        guard case .array(let items) = element else { return [] }
        return items.enumerated().compactMap { i, v in
            if case .object(let o) = v { return (i, o) }
            return nil
        }
    }

    static func validatePlaylistsModule(_ element: JSONValue, _ errors: inout [ValidationError]) throws(GsonError) {
        let key = BackupSection.playlists.key
        if case .array = element {
            try validatePreferenceEntries(element, key, &errors)
            return
        }
        guard case .object(let obj) = element else {
            errors.append(ValidationError(code: "INVALID_PLAYLISTS_PAYLOAD",
                                          message: "Module '\(key)' should be a JSON object or legacy array.", module: key))
            return
        }
        let playlists = try GsonElement.memberArray(obj, "playlists")
        if let playlists, playlists.count > maxEntriesPerModule {
            errors.append(ValidationError(code: "TOO_MANY_ENTRIES",
                                          message: "Module '\(key)' has \(playlists.count) playlists (max \(maxEntriesPerModule)).",
                                          module: key))
            return
        }
        for (index, element) in (playlists ?? []).enumerated() {
            guard case .object(let playlist) = element else {
                errors.append(ValidationError(code: "INVALID_PLAYLIST_ENTRY", message: "Playlists[\(index)] is not a JSON object.",
                                              module: key, severity: .warning))
                continue
            }
            let id = try Gson.member(playlist, "id").map(GsonElement.asString)
            let name = try Gson.member(playlist, "name").map(GsonElement.asString)
            if id?.isKotlinBlank ?? true {
                errors.append(ValidationError(code: "MISSING_PLAYLIST_ID", message: "Playlists[\(index)] is missing id.",
                                              module: key, severity: .warning))
            }
            if name?.isKotlinBlank ?? true {
                errors.append(ValidationError(code: "MISSING_PLAYLIST_NAME", message: "Playlists[\(index)] is missing name.",
                                              module: key, severity: .warning))
            }
        }
        if let sortOption = try Gson.member(obj, "playlistsSortOption").map(GsonElement.asString), sortOption.utf16.count > 200 {
            errors.append(ValidationError(code: "INVALID_SORT_OPTION", message: "playlistsSortOption looks invalid (too long).",
                                          module: key, severity: .warning))
        }
    }

    static func validateFavorites(_ element: JSONValue, _ errors: inout [ValidationError]) throws(GsonError) {
        for (i, obj) in objects(element) {
            let songId = try readNumericField(obj, "songId", "song_id")
            if !songId.present || songId.value == nil || songId.value! <= 0 {
                errors.append(ValidationError(code: "INVALID_SONG_ID", message: "Favorites[\(i)]: invalid songId",
                                              module: "favorites", severity: .warning))
            }
        }
    }

    static func validateLyrics(_ element: JSONValue, _ errors: inout [ValidationError]) throws(GsonError) {
        for (i, obj) in objects(element) {
            let content = try Gson.member(obj, "content").map(GsonElement.asString) ?? ""
            if content.utf16.count > maxStringLength {
                errors.append(ValidationError(code: "LYRICS_TOO_LONG", message: "Lyrics[\(i)]: content exceeds max length",
                                              module: "lyrics", severity: .warning))
            }
        }
    }

    static func validateSearchHistory(_ element: JSONValue, _ errors: inout [ValidationError]) throws(GsonError) {
        for (i, obj) in objects(element) {
            let query = try Gson.member(obj, "query").map(GsonElement.asString) ?? ""
            if query.utf16.count > 500 {
                errors.append(ValidationError(code: "QUERY_TOO_LONG", message: "SearchHistory[\(i)]: query exceeds 500 chars",
                                              module: "search_history", severity: .warning))
            }
        }
    }

    static func validateEngagementStats(_ element: JSONValue, _ errors: inout [ValidationError]) throws(GsonError) {
        guard case .array(let items) = element else { return }
        var seen = Set<KotlinKey>()
        let module = "engagement_stats"
        for (i, item) in items.enumerated() {
            guard case .object(let obj) = item else {
                errors.append(ValidationError(code: "INVALID_ENGAGEMENT_ENTRY", message: "EngagementStats[\(i)]: entry is not a JSON object",
                                              module: module, severity: .warning))
                continue
            }
            let songId = try readStringField(obj, "songId", "song_id")?.kotlinTrimmed()
            if songId?.isEmpty ?? true {
                errors.append(ValidationError(code: "MISSING_SONG_ID", message: "EngagementStats[\(i)]: missing songId",
                                              module: module, severity: .warning))
            } else if let songId, !seen.insert(KotlinKey(songId)).inserted {
                errors.append(ValidationError(code: "DUPLICATE_SONG_ID", message: "EngagementStats[\(i)]: duplicate songId '\(songId)'",
                                              module: module, severity: .warning))
            }
            try checkNumber(obj, ["play_count", "playCount", "score", "plays"], i, &errors,
                            invalid: ("INVALID_PLAY_COUNT", "play count is not numeric"),
                            negative: ("NEGATIVE_PLAY_COUNT", "negative play count"))
            try checkNumber(obj, ["total_play_duration_ms", "totalPlayDurationMs", "totalDuration", "total_duration", "durationMs", "duration_ms"],
                            i, &errors, invalid: ("INVALID_TOTAL_DURATION", "total duration is not numeric"),
                            negative: ("NEGATIVE_TOTAL_DURATION", "negative total duration"))
            try checkNumber(obj, ["last_played_timestamp", "lastPlayedTimestamp", "lastPlayedAt", "last_played_at", "timestamp"],
                            i, &errors, invalid: ("INVALID_LAST_PLAYED_TIMESTAMP", "last played timestamp is not numeric"),
                            negative: ("NEGATIVE_LAST_PLAYED_TIMESTAMP", "negative last played timestamp"))
        }
    }

    static func checkNumber(_ obj: JSONObject, _ keys: [String], _ i: Int, _ errors: inout [ValidationError],
                            invalid: (String, String), negative: (String, String)) throws(GsonError) {
        let field = try readNumericField(obj, keys)
        if field.present && field.value == nil {
            errors.append(ValidationError(code: invalid.0, message: "EngagementStats[\(i)]: \(invalid.1)",
                                          module: "engagement_stats", severity: .warning))
        } else if (field.value ?? 0) < 0 {
            errors.append(ValidationError(code: negative.0, message: "EngagementStats[\(i)]: \(negative.1)",
                                          module: "engagement_stats", severity: .warning))
        }
    }

    static func validatePlaybackHistory(_ element: JSONValue, _ errors: inout [ValidationError]) throws(GsonError) {
        for (i, obj) in objects(element) {
            let durationMs = try Gson.member(obj, "durationMs").map(GsonElement.asLong) ?? 0
            if durationMs < 0 {
                errors.append(ValidationError(code: "NEGATIVE_DURATION", message: "PlaybackHistory[\(i)]: negative duration",
                                              module: "playback_history", severity: .warning))
            }
        }
    }

    static func validateArtistImages(_ element: JSONValue, _ errors: inout [ValidationError]) throws(GsonError) {
        for (i, obj) in objects(element) {
            let imageUrl = try Gson.member(obj, "imageUrl").map(GsonElement.asString) ?? ""
            if !imageUrl.isEmpty && !imageUrl.hasPrefixBytes("https://") {
                errors.append(ValidationError(code: "INSECURE_URL", message: "ArtistImages[\(i)]: URL is not HTTPS",
                                              module: "artist_images", severity: .warning))
            }
            if imageUrl.utf16.count > 2000 {
                errors.append(ValidationError(code: "URL_TOO_LONG", message: "ArtistImages[\(i)]: URL exceeds 2000 chars",
                                              module: "artist_images", severity: .warning))
            }
        }
    }

    static func validateTransitions(_ element: JSONValue, _ errors: inout [ValidationError]) throws(GsonError) {
        for (i, obj) in objects(element) {
            if let settings = try GsonElement.memberObject(obj, "settings") {
                let durationMs = try Gson.member(settings, "durationMs").map(GsonElement.asInt) ?? 0
                if durationMs < 0 || durationMs > 30_000 {
                    errors.append(ValidationError(code: "INVALID_TRANSITION_DURATION", message: "Transitions[\(i)]: duration out of range",
                                                  module: "transitions", severity: .warning))
                }
            }
        }
    }

    static func validatePreferenceEntries(_ element: JSONValue, _ moduleKey: String, _ errors: inout [ValidationError]) throws(GsonError) {
        for (i, obj) in objects(element) {
            let key = try Gson.member(obj, "key").map(GsonElement.asString)
            let type = try Gson.member(obj, "type").map(GsonElement.asString)
            if key?.isKotlinBlank ?? true {
                errors.append(ValidationError(code: "MISSING_PREF_KEY", message: "Preference[\(i)]: missing key",
                                              module: moduleKey, severity: .warning))
            }
            if type == nil || !AndroidBackup.PreferenceBackupEntry.validTypes.contains(where: { KotlinText.equals($0, type!) }) {
                errors.append(ValidationError(code: "INVALID_PREF_TYPE", message: "Preference[\(i)]: invalid type '\(type ?? "null")'",
                                              module: moduleKey, severity: .warning))
            }
        }
    }

    /// `readStringField`: the first key whose value is a primitive, as a string.
    static func readStringField(_ obj: JSONObject, _ keys: String...) throws(GsonError) -> String? {
        for key in keys {
            if let v = Gson.member(obj, key), GsonElement.isPrimitive(v) { return try GsonElement.asString(v) }
        }
        return nil
    }

    struct NumericField {
        var present: Bool
        var value: Int64?
    }

    static func readNumericField(_ obj: JSONObject, _ keys: String...) throws(GsonError) -> NumericField {
        try readNumericField(obj, keys)
    }

    /// `readNumericField`: the first key holding a primitive — numbers via `asNumber.toLong()`, strings via
    /// `toLongOrNull()`, booleans present but not numeric.
    static func readNumericField(_ obj: JSONObject, _ keys: [String]) throws(GsonError) -> NumericField {
        for key in keys {
            guard let v = Gson.member(obj, key), GsonElement.isPrimitive(v) else { continue }
            switch v {
            case .number: return NumericField(present: true, value: try GsonElement.asLong(v))
            case .string(let s): return NumericField(present: true, value: JavaNumbers.parseLong(s))
            default: return NumericField(present: true, value: nil)
            }
        }
        return NumericField(present: false, value: nil)
    }
}

/// `ValidationPipeline`: file → manifest → checksum + schema per module.
public struct ValidationPipeline: Sendable {
    public let manifestValidator: ManifestValidator

    public init(manifestValidator: ManifestValidator = ManifestValidator()) {
        self.manifestValidator = manifestValidator
    }

    public func validateFile(bytes: [UInt8], fileName: String?, fileSize: Int64?) -> BackupValidationResult {
        BackupFileValidator.validate(bytes: bytes, fileName: fileName, fileSize: fileSize)
    }

    public func validateManifest(_ manifest: BackupManifest) throws(BackupError) -> BackupValidationResult {
        try manifestValidator.validate(manifest)
    }

    /// Checksum first (a mismatch is fatal and stops), then the module schema.
    public func validateModulePayload(_ section: BackupSection, payload: String,
                                      manifest: BackupManifest? = nil) throws(BackupError) -> BackupValidationResult {
        if let manifest, !manifestValidator.verifyChecksum(moduleKey: section.key, payload: payload, manifest: manifest) {
            return .invalid([ValidationError(code: "CHECKSUM_MISMATCH",
                                             message: "Checksum mismatch for module '\(section.label)'. The backup may be corrupted.",
                                             module: section.key)])
        }
        do {
            return .from(try ModuleSchemaValidator.validate(section, payload: payload).errors)
        } catch {
            throw BackupError(error.message.isEmpty ? error.kind : error.message)
        }
    }

    /// `collectWarnings`.
    public func collectWarnings(_ results: BackupValidationResult...) -> [ValidationError] {
        results.flatMap(\.warnings)
    }
}
