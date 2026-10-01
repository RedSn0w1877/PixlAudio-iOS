// `.pxpl` container formats: detection (`BackupFormatDetector`), reading (`BackupReader`), writing (`BackupWriter`)
// and the v1/v2 adapter (`LegacyPayloadAdapter`), ported from the Android app's `data/backup/format/`.
//
// v3 (current): "PXPL" + a ZIP holding manifest.json and one `<module>.json` per module.
// v2: "PXPL" + gzip of one JSON object (`AppDataBackupPayload`, formatVersion 2).
// v1 / legacy: the same JSON gzip-compressed without the magic, or raw JSON.

import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel

/// `BackupFormatDetector.Format`.
public enum BackupFormat: String, Sendable, Hashable {
    case pxplV3Zip = "PXPL_V3_ZIP"
    case pxplV2Gzip = "PXPL_V2_GZIP"
    case legacyGzip = "LEGACY_GZIP"
    case legacyRaw = "LEGACY_RAW"
    case unknown = "UNKNOWN"
}

/// `BackupFormatDetector`.
public enum BackupFormatDetector {
    public static let pxplMagic: [UInt8] = Array("PXPL".utf8)
    public static let pxplMagicSize = 4
    /// Bytes `readHeader` looks at.
    public static let headerSize = 8

    /// `detect(header)`: the magic decides v3 (ZIP after it) or v2 (anything else, gzip expected); without it a
    /// gzip header is legacy gzip and `{` legacy raw JSON.
    public static func detect<C: Collection>(_ header: C) -> BackupFormat where C.Element == UInt8 {
        let h = Array(header.prefix(headerSize))
        if h.count < 4 { return .unknown }
        if Array(h[0..<4]) == pxplMagic {
            if h.count < 8 { return .pxplV2Gzip }
            if h[4] == UInt8(ascii: "P") && h[5] == UInt8(ascii: "K") { return .pxplV3Zip }
            return .pxplV2Gzip
        }
        if h[0] == 0x1F && h[1] == 0x8B { return .legacyGzip }
        if h[0] == UInt8(ascii: "{") { return .legacyRaw }
        return .unknown
    }
}

/// Reads a backup file held in memory (`BackupReader`). Errors carry Android's messages.
public struct BackupReader: Sendable {
    public static let maxManifestBytes = 512 * 1024
    public static let maxModulePayloadBytes = 16 * 1024 * 1024
    public static let maxLegacyBackupBytes = 32 * 1024 * 1024

    public let format: BackupFormat
    /// SHA-256 used to build checksums for legacy payloads.
    public let hasher: SHA256Hasher
    /// Clock for a manifest without `createdAt` (Kotlin's default).
    public let now: @Sendable () -> Int64
    /// The container, opened once (Android reopens the file for every read; the result is the same).
    private let zip: Result<ZipArchive, BackupError>?
    private let legacy: Result<LegacyPayloadAdapter.Result, BackupError>?

    public init(bytes: [UInt8], hasher: @escaping SHA256Hasher = BackupHashing.pureSwift,
                now: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        let format = BackupFormatDetector.detect(bytes)
        self.format = format
        self.hasher = hasher
        self.now = now
        switch format {
        case .pxplV3Zip:
            do {
                zip = .success(try Self.openZip(bytes))
            } catch {
                zip = .failure(error)
            }
            legacy = nil
        case .pxplV2Gzip, .legacyGzip, .legacyRaw:
            zip = nil
            do {
                legacy = .success(try Self.adaptLegacy(bytes, format: format, hasher: hasher))
            } catch {
                legacy = .failure(error)
            }
        case .unknown:
            zip = nil
            legacy = nil
        }
    }

    /// `readManifest()`.
    public func readManifest() throws(BackupError) -> BackupManifest {
        switch format {
        case .pxplV3Zip:
            guard let json = try readEntryFromZip(BackupManifest.manifestFilename, maxChars: Self.maxManifestBytes) else {
                throw BackupError("Manifest not found in backup archive")
            }
            do {
                guard let manifest = try BackupManifest.decode(json: json, now: now()) else {
                    throw BackupError("Backup manifest is empty.")
                }
                return manifest
            } catch let error as GsonError {
                throw BackupError(error.message)
            } catch let error as BackupError {
                throw error
            } catch {
                throw BackupError("\(error)")
            }
        case .pxplV2Gzip, .legacyGzip, .legacyRaw:
            return try adaptLegacy().manifest
        case .unknown:
            throw BackupError("Unrecognized backup file format")
        }
    }

    /// `readModulePayload(key)`.
    public func readModulePayload(_ moduleKey: String) throws(BackupError) -> String {
        switch format {
        case .pxplV3Zip:
            guard let payload = try readEntryFromZip(moduleKey + ".json", maxChars: Self.maxModulePayloadBytes) else {
                throw BackupError("Module '\(moduleKey)' not found in backup")
            }
            return payload
        case .pxplV2Gzip, .legacyGzip, .legacyRaw:
            guard let payload = try adaptLegacy().modules[moduleKey], let payload else {
                throw BackupError("Module '\(moduleKey)' not found in legacy backup")
            }
            return payload
        case .unknown:
            throw BackupError("Unrecognized backup file format")
        }
    }

    /// `readAllModulePayloads()`: every `.json` entry except the manifest, keyed without the extension (a later
    /// duplicate replaces the value but keeps the first position, like `LinkedHashMap`).
    public func readAllModulePayloads() throws(BackupError) -> GsonMap<String> {
        switch format {
        case .pxplV3Zip:
            let archive = try openZip()
            var out = GsonMap<String>()
            for entry in archive.entries where entry.name != BackupManifest.manifestFilename && entry.name.hasSuffix(".json") {
                let key = String(entry.name.dropLast(5))
                out.put(key, try text(of: entry, in: archive, maxChars: Self.maxModulePayloadBytes))
            }
            return out
        case .pxplV2Gzip, .legacyGzip, .legacyRaw:
            return try adaptLegacy().modules
        case .unknown:
            throw BackupError("Unrecognized backup file format")
        }
    }

    // MARK: ZIP

    func openZip() throws(BackupError) -> ZipArchive {
        guard let zip else { throw BackupError("Cannot read format: \(format.rawValue)") }
        return try zip.get()
    }

    static func openZip(_ bytes: [UInt8]) throws(BackupError) -> ZipArchive {
        guard bytes.count >= BackupFormatDetector.pxplMagicSize else { throw BackupError("Backup file is truncated.") }
        do {
            return try ZipArchive(bytes: Array(bytes[BackupFormatDetector.pxplMagicSize...]))
        } catch {
            throw BackupError(error.description)
        }
    }

    func readEntryFromZip(_ name: String, maxChars: Int) throws(BackupError) -> String? {
        let archive = try openZip()
        guard let entry = archive.entry(named: name) else { return nil }
        return try text(of: entry, in: archive, maxChars: maxChars)
    }

    /// Decodes an entry as UTF-8 and applies `readTextLimited`'s character (UTF-16 unit) limit.
    func text(of entry: ZipEntry, in archive: ZipArchive, maxChars: Int) throws(BackupError) -> String {
        let label = "Backup entry '\(entry.name)'"
        let data: [UInt8]
        do {
            // UTF-8 never has fewer bytes than UTF-16 units, so 3 bytes per unit bounds the work.
            data = try archive.data(for: entry, maxSize: maxChars.multipliedReportingOverflow(by: 3).overflow ? .max : maxChars * 3)
        } catch .entryTooLarge {
            throw BackupError(Self.limitMessage(label, maxChars))
        } catch {
            throw BackupError(error.description)
        }
        let text = String(decoding: data, as: UTF8.self)
        if text.utf16.count > maxChars { throw BackupError(Self.limitMessage(label, maxChars)) }
        return text
    }

    static func limitMessage(_ label: String, _ maxChars: Int) -> String {
        "\(label) exceeds the \(maxChars / (1024 * 1024))MB in-memory safety limit."
    }

    // MARK: Legacy

    static func decompressLegacy(_ bytes: [UInt8], format: BackupFormat) throws(BackupError) -> String {
        let data: [UInt8]
        switch format {
        case .pxplV2Gzip, .legacyGzip:
            let offset = format == .pxplV2Gzip ? BackupFormatDetector.pxplMagicSize : 0
            guard bytes.count >= offset else { throw BackupError("Backup file is truncated.") }
            do {
                data = try Gzip.decompress(bytes, from: offset, maxOutput: maxLegacyBackupBytes * 3)
            } catch .inflate(.outputLimitExceeded) {
                throw BackupError(limitMessage("Legacy backup payload", maxLegacyBackupBytes))
            } catch {
                throw BackupError(error.description)
            }
        case .legacyRaw:
            data = bytes
        default:
            throw BackupError("Cannot decompress format: \(format.rawValue)")
        }
        let text = String(decoding: data, as: UTF8.self)
        if text.utf16.count > maxLegacyBackupBytes {
            throw BackupError(limitMessage("Legacy backup payload", maxLegacyBackupBytes))
        }
        return text
    }

    static func adaptLegacy(_ bytes: [UInt8], format: BackupFormat, hasher: SHA256Hasher) throws(BackupError) -> LegacyPayloadAdapter.Result {
        let json = try decompressLegacy(bytes, format: format)
        do {
            return try LegacyPayloadAdapter.adapt(json, hasher: hasher)
        } catch {
            throw BackupError(error.message)
        }
    }

    func adaptLegacy() throws(BackupError) -> LegacyPayloadAdapter.Result {
        guard let legacy else { throw BackupError("Cannot decompress format: \(format.rawValue)") }
        return try legacy.get()
    }
}

/// Writes a v3 `.pxpl` (`BackupWriter`): manifest.json with per-module SHA-256 checksums, entry counts and sizes,
/// then each module payload, all as stored ZIP entries after the "PXPL" magic.
public enum BackupWriter {
    /// Builds the archive. Module order is kept (Android writes `LinkedHashMap` order).
    public static func write(manifest: BackupManifest, modulePayloads: [(key: String, payload: String)],
                             hasher: SHA256Hasher = BackupHashing.pureSwift,
                             onProgress: (_ current: Int, _ total: Int) -> Void = { _, _ in }) -> [UInt8] {
        let total = modulePayloads.count + 1
        var step = 0
        // A `LinkedHashMap` on Android: a repeated key keeps its first position and takes the last payload.
        var infos = GsonMap<BackupModuleInfo>()
        var payloadBytes = GsonMap<[UInt8]>()
        for (key, payload) in modulePayloads {
            let bytes = Array(payload.utf8)
            payloadBytes.put(key, bytes)
            infos.put(key, BackupModuleInfo(checksum: "sha256:" + BackupHashing.hex(bytes, hasher: hasher),
                                            entryCount: countJsonArrayEntries(payload), sizeBytes: Int64(bytes.count)))
        }
        var finalManifest = manifest
        finalManifest.modules = infos
        var zip = ZipWriter()
        zip.addStored(name: BackupManifest.manifestFilename, data: Array(finalManifest.json.utf8))
        step += 1
        onProgress(step, total)
        for (key, bytes) in payloadBytes.entries {
            zip.addStored(name: key + ".json", data: bytes ?? [])
            step += 1
            onProgress(step, total)
        }
        return BackupFormatDetector.pxplMagic + zip.finish()
    }

    /// `countJsonArrayEntries`: the size of a top-level array, 1 for anything else, 0 when the array is invalid.
    public static func countJsonArrayEntries(_ json: String) -> Int32 {
        let trimmed = json.kotlinTrimmed()
        guard trimmed.hasPrefix("[") else { return 1 }
        guard let value = try? Gson.parse(trimmed), case .array(let items) = value else { return 0 }
        return Int32(clamping: items.count)
    }
}

/// `LegacyPayloadAdapter`: turns a v1/v2 `AppDataBackupPayload` JSON into a v3 manifest and per-module payloads
/// (pretty-printed with the backup Gson, checksummed like the v3 writer).
public enum LegacyPayloadAdapter {
    public struct Result: Sendable, Hashable {
        public var manifest: BackupManifest
        public var modules: GsonMap<String>
    }

    /// Preference keys that belong to the playlists module (`PlaylistsModuleHandler.PLAYLIST_KEYS`).
    public static let playlistKeys: [String] = ["user_playlists_json_v1", "playlist_song_order_modes", "playlists_sort_option"]

    public static func adapt(_ legacyJson: String, hasher: SHA256Hasher = BackupHashing.pureSwift) throws(GsonError) -> Result {
        let root = try GsonElement.asObject(Gson.parseTree(legacyJson))
        let formatVersion = try Gson.member(root, "formatVersion").map(GsonElement.asInt) ?? 1
        let exportedAt = try Gson.member(root, "exportedAtEpochMs").map(GsonElement.asLong) ?? 0
        var availableSections = Set<String>()
        if let sections = try GsonElement.memberArray(root, "availableSections") {
            for s in sections { availableSections.insert(try GsonElement.asString(s)) }
        }
        var modules = GsonMap<String>()
        var infos = GsonMap<BackupModuleInfo>()

        func add(_ key: String, _ array: [JSONValue]) {
            let json = GsonWriter.backup(.array(array))
            modules.put(key, json)
            infos.put(key, moduleInfo(json, hasher: hasher))
        }

        if formatVersion == 1 {
            if let preferences = try GsonElement.memberArray(root, "preferences"), !preferences.isEmpty {
                var playlistEntries: [JSONValue] = []
                var globalEntries: [JSONValue] = []
                for element in preferences {
                    let obj = try GsonElement.asObject(element)
                    let key = try Gson.member(obj, "key").map(GsonElement.asString) ?? ""
                    if playlistKeys.contains(where: { KotlinText.equals($0, key) }) {
                        playlistEntries.append(element)
                    } else {
                        globalEntries.append(element)
                    }
                }
                if !playlistEntries.isEmpty && availableSections.contains("playlists") { add("playlists", playlistEntries) }
                if !globalEntries.isEmpty && availableSections.contains("global_settings") { add("global_settings", globalEntries) }
            }
        } else {
            try extract(root, "playlists", "playlists", availableSections, add)
            try extract(root, "globalSettings", "global_settings", availableSections, add)
        }
        try extract(root, "favorites", "favorites", availableSections, add)
        try extract(root, "lyrics", "lyrics", availableSections, add)
        try extract(root, "searchHistory", "search_history", availableSections, add)
        try extract(root, "transitions", "transitions", availableSections, add)
        try extract(root, "engagementStats", "engagement_stats", availableSections, add)
        try extract(root, "playbackHistory", "playback_history", availableSections, add)

        let manifest = BackupManifest(schemaVersion: formatVersion, appVersion: "legacy", appVersionCode: 0,
                                      createdAt: exportedAt, deviceInfo: DeviceInfo(), modules: infos)
        return Result(manifest: manifest, modules: modules)
    }

    static func extract(_ root: JSONObject, _ field: String, _ key: String, _ available: Set<String>,
                        _ add: (String, [JSONValue]) -> Void) throws(GsonError) {
        if let array = try GsonElement.memberArray(root, field), !array.isEmpty, available.contains(key) {
            add(key, array)
        }
    }

    static func moduleInfo(_ json: String, hasher: SHA256Hasher) -> BackupModuleInfo {
        let bytes = Array(json.utf8)
        return BackupModuleInfo(checksum: "sha256:" + BackupHashing.hex(bytes, hasher: hasher),
                                entryCount: BackupWriter.countJsonArrayEntries(json), sizeBytes: Int64(bytes.count))
    }
}
