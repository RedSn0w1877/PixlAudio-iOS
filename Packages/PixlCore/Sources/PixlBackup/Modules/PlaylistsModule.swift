// The playlists module (`PlaylistsModuleHandler`): v3 object payload with cross-device song metadata and Base64
// cover images, or the v1/v2 legacy array of preference entries.

import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel

/// What restoring a playlists payload produces; the app stores it.
public struct PlaylistsRestore: Sendable, Hashable {
    /// Playlists with song ids resolved to the current library. `coverImageUri` is cleared (a path on the device that
    /// wrote the backup means nothing here); the app writes `coverImages` to files and sets the URIs.
    public var playlists: [Playlist]
    public var playlistSongOrderModes: [String: String]
    public var playlistsSortOption: String
    /// Decoded cover images by playlist id (entries that failed to decode are absent, as on Android).
    public var coverImages: [String: [UInt8]]
    /// Distinct backup song ids that matched nothing.
    public var unresolvedCount: Int
    /// The payload to keep for another resolution attempt after the next library scan (Android's
    /// `pending_playlists_restore.json`); nil when everything resolved.
    public var pendingPayload: String?
    /// The song metadata table, reused to resolve the other modules' song ids.
    public var songMetadata: GsonMap<AndroidBackup.SongMetadataEntry>
}

public enum PlaylistsModule {
    /// Playlist sources that are backed up (cloud playlists are tied to an account).
    public static let localSources: Set<String> = ["LOCAL", "AI"]
    public static let legacyUserPlaylistsKey = "user_playlists_json_v1"
    public static let legacyPlaylistOrderModesKey = "playlist_song_order_modes"
    public static let legacyPlaylistSortOptionKey = "playlists_sort_option"
    public static let playlistKeys: Set<String> = [legacyUserPlaylistsKey, legacyPlaylistOrderModesKey, legacyPlaylistSortOptionKey]

    /// `restore(payload)`: malformed JSON throws; a JSON array is the legacy format; an object that Gson cannot
    /// bind becomes an empty payload (Android's `runCatching { … }.getOrNull() ?: PlaylistsBackupPayload()`).
    public static func restore(payload: String, library: [BackupSongSummary]) throws(BackupError) -> PlaylistsRestore {
        let element: JSONValue
        do {
            element = try Gson.parseTree(payload)
        } catch {
            throw BackupError(error.message)
        }
        if case .array = element { return try restoreLegacy(payload: payload) }

        let backup = (try? AndroidBackup.PlaylistsBackupPayload.gsonDecode(element)) ?? AndroidBackup.PlaylistsBackupPayload()
        let playlists = (backup.playlists ?? []).compactMap { $0?.playlist }
        let metadata = backup.songMetadata ?? GsonMap()
        var resolved = playlists
        var unresolved = 0
        if !metadata.isEmpty {
            (resolved, unresolved) = BackupSongResolver(library: library).resolve(playlists: playlists, songMetadata: metadata)
        }
        var covers: [String: [UInt8]] = [:]
        if let coverImages = backup.coverImages, !coverImages.isEmpty {
            for playlist in resolved {
                guard let entry = coverImages[playlist.id], let base64 = entry, let bytes = BackupBase64.decode(base64) else { continue }
                covers[playlist.id] = bytes
            }
        }
        resolved = resolved.map { var p = $0; p.coverImageUri = nil; return p }
        var modes: [String: String] = [:]
        for entry in (backup.playlistSongOrderModes?.entries ?? []) { if let v = entry.value { modes[entry.key] = v } }
        return PlaylistsRestore(playlists: resolved, playlistSongOrderModes: modes,
                                playlistsSortOption: backup.playlistsSortOption ?? SortOption.playlistNameAZ.storageKey,
                                coverImages: covers, unresolvedCount: unresolved,
                                pendingPayload: unresolved > 0 ? payload : nil, songMetadata: metadata)
    }

    /// `resolvePendingPlaylists`: after a library scan, re-resolve the pending payload and grow any current
    /// playlist that now has more songs. Returns the updated playlists (nil when nothing changed) and whether the
    /// pending payload can be deleted.
    public static func resolvePending(payload: String, current: [Playlist], library: [BackupSongSummary])
        -> (updated: [Playlist]?, done: Bool) {
        guard let value = try? Gson.parse(payload),
              let parsed = try? AndroidBackup.PlaylistsBackupPayload.gsonDecode(value) else { return (nil, false) }
        guard let metadata = parsed.songMetadata, !metadata.isEmpty else { return (nil, true) }
        let backupPlaylists = (parsed.playlists ?? []).compactMap { $0?.playlist }
        let (resolved, unresolved) = BackupSongResolver(library: library).resolve(playlists: backupPlaylists, songMetadata: metadata)
        var changed = false
        let updated = current.map { playlist -> Playlist in
            guard backupPlaylists.contains(where: { KotlinText.equals($0.id, playlist.id) }),
                  let match = resolved.first(where: { KotlinText.equals($0.id, playlist.id) }),
                  playlist.songIds.count < match.songIds.count else { return playlist }
            changed = true
            var copy = playlist
            copy.songIds = match.songIds
            return copy
        }
        return (changed ? updated : nil, unresolved == 0)
    }

    /// The legacy (v1/v2) array of preference entries: playlists JSON, order modes JSON and the sort option.
    static func restoreLegacy(payload: String) throws(BackupError) -> PlaylistsRestore {
        let entries = try PreferencesModule.decode(payload: payload)
        func value(_ key: String) -> String? {
            entries.first { $0.key.map { KotlinText.equals($0, key) } ?? false }?.stringValue
        }
        var playlists: [Playlist] = []
        if let raw = value(legacyUserPlaylistsKey), let decoded = try? AndroidBackup.PlaylistRecord.decodeList(raw) {
            playlists = decoded.compactMap { $0?.playlist }
        }
        var modes: [String: String] = [:]
        if let raw = value(legacyPlaylistOrderModesKey), let parsed = try? Gson.parse(raw),
           let map = try? GsonRead.map(parsed, GsonRead.string) {
            for entry in map.entries { if let v = entry.value { modes[entry.key] = v } }
        }
        playlists = playlists.map { var p = $0; p.coverImageUri = nil; return p }
        return PlaylistsRestore(playlists: playlists, playlistSongOrderModes: modes,
                                playlistsSortOption: value(legacyPlaylistSortOptionKey) ?? SortOption.playlistNameAZ.storageKey,
                                coverImages: [:], unresolvedCount: 0, pendingPayload: nil, songMetadata: GsonMap())
    }

    /// `export()`: local and AI playlists only, streaming songs removed, metadata for every remaining song (plus
    /// `extraSongIds`, the songs the other modules reference) and Base64 covers.
    public static func export(playlists: [Playlist], library: [BackupSongSummary], playlistSongOrderModes: [(String, String)],
                              playlistsSortOption: String, extraSongIds: [String] = [],
                              coverImage: (Playlist) -> [UInt8]? = { _ in nil }) -> String {
        var byId: [KotlinKey: BackupSongSummary] = [:]
        for song in library { byId[KotlinKey(song.id)] = song }
        var metadata = GsonMap<AndroidBackup.SongMetadataEntry>()
        func addMetadata(_ id: String) {
            if !metadata.contains(id), let song = byId[KotlinKey(id)] { metadata.put(id, song.metadata) }
        }
        let filtered = playlists.filter { localSources.contains($0.source) }.map { playlist -> Playlist in
            var copy = playlist
            copy.songIds = playlist.songIds.filter { !BackupSongIds.isCloudSong($0) }
            copy.songIds.forEach(addMetadata)
            return copy
        }
        extraSongIds.filter { !BackupSongIds.isCloudSong($0) }.forEach(addMetadata)
        var covers = GsonMap<String>()
        for playlist in filtered {
            if let bytes = coverImage(playlist), !bytes.isEmpty { covers.put(playlist.id, BackupBase64.encode(bytes)) }
        }
        let payload = AndroidBackup.PlaylistsBackupPayload(
            playlists: filtered.map { AndroidBackup.PlaylistRecord($0) },
            playlistSongOrderModes: GsonMap(playlistSongOrderModes.map { ($0.0, Optional($0.1)) }),
            playlistsSortOption: playlistsSortOption,
            songMetadata: metadata.isEmpty ? nil : metadata,
            coverImages: covers.isEmpty ? nil : covers)
        return GsonWriter.backup(payload.gsonTree)
    }

    /// `snapshot()`: every playlist as-is, no metadata (for rollback).
    public static func snapshot(playlists: [Playlist], playlistSongOrderModes: [(String, String)], playlistsSortOption: String) -> String {
        let payload = AndroidBackup.PlaylistsBackupPayload(
            playlists: playlists.map { AndroidBackup.PlaylistRecord($0) },
            playlistSongOrderModes: GsonMap(playlistSongOrderModes.map { ($0.0, Optional($0.1)) }),
            playlistsSortOption: playlistsSortOption)
        return GsonWriter.backup(payload.gsonTree)
    }
}

/// Base64 as `android.util.Base64` with `NO_WRAP` decodes and encodes it: standard alphabet, padding optional on
/// input, whitespace skipped, anything else rejected.
public enum BackupBase64 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    public static func encode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var i = 0
        while i + 3 <= bytes.count {
            let n = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
            out += [alphabet[Int(n >> 18)], alphabet[Int((n >> 12) & 63)], alphabet[Int((n >> 6) & 63)], alphabet[Int(n & 63)]]
            i += 3
        }
        let rest = bytes.count - i
        if rest == 1 {
            let n = UInt32(bytes[i]) << 16
            out += [alphabet[Int(n >> 18)], alphabet[Int((n >> 12) & 63)], UInt8(ascii: "="), UInt8(ascii: "=")]
        } else if rest == 2 {
            let n = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8
            out += [alphabet[Int(n >> 18)], alphabet[Int((n >> 12) & 63)], alphabet[Int((n >> 6) & 63)], UInt8(ascii: "=")]
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ text: String) -> [UInt8]? {
        var values: [UInt8] = []
        var padding = 0
        for c in text.utf8 {
            switch c {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): guard padding == 0 else { return nil }; values.append(c - 65)
            case UInt8(ascii: "a")...UInt8(ascii: "z"): guard padding == 0 else { return nil }; values.append(c - 71)
            case UInt8(ascii: "0")...UInt8(ascii: "9"): guard padding == 0 else { return nil }; values.append(c + 4)
            case UInt8(ascii: "+"): guard padding == 0 else { return nil }; values.append(62)
            case UInt8(ascii: "/"): guard padding == 0 else { return nil }; values.append(63)
            case UInt8(ascii: "="): padding += 1
            case 0x20, 0x09, 0x0A, 0x0D: continue
            default: return nil
            }
        }
        if padding > 2 || values.count % 4 == 1 { return nil }
        if padding > 0 && (values.count + padding) % 4 != 0 { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(values.count * 3 / 4)
        var i = 0
        while i + 4 <= values.count {
            let n = UInt32(values[i]) << 18 | UInt32(values[i + 1]) << 12 | UInt32(values[i + 2]) << 6 | UInt32(values[i + 3])
            out += [UInt8(n >> 16), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            i += 4
        }
        let rest = values.count - i
        if rest == 2 {
            out.append(values[i] << 2 | values[i + 1] >> 4)
        } else if rest == 3 {
            out.append(values[i] << 2 | values[i + 1] >> 4)
            out.append((values[i + 1] & 0x0F) << 4 | values[i + 2] >> 2)
        }
        return out
    }
}
