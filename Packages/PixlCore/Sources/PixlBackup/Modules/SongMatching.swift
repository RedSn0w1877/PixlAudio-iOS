// Cross-device song matching, ported from `PlaylistsModuleHandler.resolvePlaylists` / `resolveSongId`. A backup
// names songs by the ids of the device that wrote it (Android MediaStore ids such as "4711"); PixlAudio's ids are
// different (`f:…`, `mp:…`), so a song is found again by the metadata stored with the playlists
// (`songMetadata`: title, artist, album, duration).
//
// The same resolver maps the ids of the other id-bearing modules (favourites, lyrics, engagement, history), using
// the playlists' metadata table — the only metadata an Android backup carries. Backups PixlAudio writes add
// metadata for every song they reference and store PixlAudio's own id next to Android's numeric field.

import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel

/// A library song as the matcher sees it (Android `SongSummary`).
public struct BackupSongSummary: Sendable, Hashable {
    public var id: String
    public var title: String
    public var artistName: String
    public var albumName: String
    /// Milliseconds.
    public var duration: Int64

    public init(id: String, title: String, artistName: String, albumName: String, duration: Int64) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
    }

    public init(_ song: Song) {
        self.init(id: song.id, title: song.title, artistName: song.artist, albumName: song.album, duration: song.duration)
    }

    /// The metadata entry Android writes for this song.
    public var metadata: AndroidBackup.SongMetadataEntry {
        AndroidBackup.SongMetadataEntry(title: title, artist: artistName, album: albumName, duration: duration)
    }
}

/// Resolves backup song ids against the current library (`resolveSongId`).
public struct BackupSongResolver: Sendable {
    public static let durationToleranceMs: Int64 = 2000

    let byId: [KotlinKey: BackupSongSummary]
    /// "title|artist" (trimmed, lower-cased) → candidates in library order.
    let index: [KotlinKey: [BackupSongSummary]]

    public init(library: [BackupSongSummary]) {
        var byId: [KotlinKey: BackupSongSummary] = [:]
        var index: [KotlinKey: [BackupSongSummary]] = [:]
        for song in library {
            byId[KotlinKey(song.id)] = song // associateBy: the last song with an id wins
            index[KotlinKey(Self.matchKey(song.title, song.artistName)), default: []].append(song)
        }
        self.byId = byId
        self.index = index
    }

    /// 1. same id and same title/artist (or no metadata) → that id; 2. otherwise by metadata: a unique
    /// title+artist match, else a unique album match among them, else a unique match within 2 s of the duration
    /// (among the album matches when there are any); 3. otherwise nil (dropped rather than risk a wrong song).
    public func resolve(_ backupSongId: String, metadata meta: AndroidBackup.SongMetadataEntry?) -> String? {
        let direct = byId[KotlinKey(backupSongId)]
        if let direct {
            guard let meta else { return backupSongId }
            if Self.metadataMatches(meta, direct) { return backupSongId }
        }
        guard let meta else { return direct != nil ? backupSongId : nil }
        guard let candidates = index[KotlinKey(Self.matchKey(meta.title ?? "", meta.artist ?? ""))] else { return nil }
        if candidates.count == 1 { return candidates[0].id }
        let album = Self.normalize(meta.album ?? "")
        let albumMatches = candidates.filter { KotlinText.equals(Self.normalize($0.albumName), album) }
        if albumMatches.count == 1 { return albumMatches[0].id }
        let durationMatches = (albumMatches.isEmpty ? candidates : albumMatches).filter {
            abs($0.duration &- meta.duration) <= Self.durationToleranceMs
        }
        if durationMatches.count == 1 { return durationMatches[0].id }
        return nil
    }

    /// `resolvePlaylists`: maps every song id (each distinct id resolved once), drops unresolved ones and counts
    /// the distinct ids that could not be resolved.
    public func resolve(playlists: [Playlist], songMetadata: GsonMap<AndroidBackup.SongMetadataEntry>) -> (playlists: [Playlist], unresolvedCount: Int) {
        var cache: [KotlinKey: String?] = [:]
        var unresolved = 0
        for playlist in playlists {
            for id in playlist.songIds where cache[KotlinKey(id)] == nil {
                let resolved = resolve(id, metadata: songMetadata[id] ?? nil)
                cache[KotlinKey(id)] = .some(resolved)
                if resolved == nil { unresolved += 1 }
            }
        }
        let mapped = playlists.map { playlist -> Playlist in
            var copy = playlist
            copy.songIds = playlist.songIds.compactMap { cache[KotlinKey($0)] ?? nil }
            return copy
        }
        return (mapped, unresolved)
    }

    static func metadataMatches(_ meta: AndroidBackup.SongMetadataEntry, _ song: BackupSongSummary) -> Bool {
        KotlinText.equals(normalize(meta.title ?? ""), normalize(song.title))
            && KotlinText.equals(normalize(meta.artist ?? ""), normalize(song.artistName))
    }

    /// `normalizeMatchKey`.
    public static func matchKey(_ title: String, _ artist: String) -> String { normalize(title) + "|" + normalize(artist) }

    /// `normalizeText`: Kotlin `trim().lowercase()`.
    public static func normalize(_ text: String) -> String { KotlinText.lowercase(text.kotlinTrimmed()) }
}

/// Numeric ids for backups PixlAudio writes. Android's favourites and lyrics rows have a numeric `songId`; PixlAudio
/// keeps its own id in the extra `pixlSongId` member (Android's Gson ignores unknown members) and writes a stable
/// positive number Android will never confuse with a MediaStore id (2⁵² … 2⁵³ − 1, from FNV-1a 64 of the id).
public enum BackupSongIds {
    public static let pixlSongIdKey = "pixlSongId"

    public static func numericId(for songId: String) -> Int64 {
        if let n = JavaNumbers.parseLong(songId), n > 0, n < (1 << 52) { return n }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in songId.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int64(1 << 52) + Int64(hash & ((1 << 52) - 1))
    }

    /// True for ids PixlAudio streams rather than plays from a file (Android excludes its cloud songs too).
    public static func isCloudSong(_ songId: String) -> Bool {
        songId.hasPrefixBytes("sp:") || songId.hasPrefixBytes("yt:")
    }
}
