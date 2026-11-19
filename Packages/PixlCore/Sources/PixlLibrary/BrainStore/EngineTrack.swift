// A track from outside the library, in the form the player needs (docs/brain-spec.md, 7.2), and the library by
// name. Ports of Android's `EngineTrack.kt` and `LibraryIndex.kt`.

import Foundation
import PixlModel

/// A track from outside the library. It has no library row. It plays as `yt:<videoId>` through
/// `pixlstream://<videoId>`, the id and URL the YouTube Music importer gives the same track, so when the listener
/// saves it the queue item, the history entry and the library row already agree.
public struct EngineTrack: Sendable, Hashable {
    public static let songIdPrefix = "yt:"
    public static let contentUriPrefix = "pixlstream://"
    public static let unknownArtist = "Unknown Artist"
    public static let unknownAlbum = "Unknown Album"

    public var songId: String
    public var rid: Int64
    public var videoId: String
    public var title: String
    /// Credited artists, primary first; never a joined display string.
    public var artists: [RadioArtistRef]
    public var album: String?
    public var durationMs: Int64
    public var artUrl: String?

    public init(row: RadioRow, rid: Int64) {
        songId = Self.songId(videoId: row.videoId)
        self.rid = rid
        videoId = row.videoId
        title = row.title
        artists = row.artists
        album = row.album
        durationMs = Int64(row.durationSec) * 1000
        artUrl = row.thumbnailUrl
    }

    public init(record: PlayableRecord) {
        songId = record.songId
        rid = record.rid
        videoId = record.videoId
        title = record.title
        artists = record.artists
        album = record.album
        durationMs = record.durationMs
        artUrl = record.artUrl
    }

    /// The track a queue's own `yt:` song stands for, read back from that song: what the app knows about a pick
    /// right after a restart, before the brain's files are read (the restored queue still holds the song). Nil
    /// for a song that is not `yt:<videoId>`. `rid` is 0: the stored row, once read, takes its place.
    public init?(queueSong song: Song) {
        guard let videoId = TrackCatalog.videoId(ofSongId: song.id) else { return nil }
        songId = song.id
        rid = 0
        self.videoId = videoId
        title = song.title
        let ordered = song.artists.filter(\.isPrimary) + song.artists.filter { !$0.isPrimary }
        var refs: [RadioArtistRef] = []
        for artist in ordered where !BrainText.isBlank(artist.name) {
            if !refs.contains(where: { BrainKey.sameBytes($0.name, artist.name) }) {
                refs.append(RadioArtistRef(name: artist.name, channelId: nil))
            }
        }
        if refs.isEmpty, !BrainText.isBlank(song.artist), !BrainKey.sameBytes(song.artist, Self.unknownArtist) {
            refs.append(RadioArtistRef(name: song.artist, channelId: nil))
        }
        artists = refs
        album = BrainText.isBlank(song.album) || BrainKey.sameBytes(song.album, Self.unknownAlbum) ? nil : song.album
        durationMs = song.duration
        artUrl = song.albumArtUriString
    }

    public static func songId(videoId: String) -> String { songIdPrefix + videoId }

    /// The parsed row this track came from, rebuilt for a saved plan (it carries what a card and the player need).
    public func toRadioRow() -> RadioRow {
        RadioRow(videoId: videoId, title: title, artists: artists, album: album, durationSec: Int(durationMs / 1000),
                 thumbnailUrl: artUrl, kind: .atv)
    }

    public var artistDisplay: String {
        let joined = artists.map(\.name).joined(separator: ", ")
        return BrainText.isBlank(joined) ? Self.unknownArtist : joined
    }

    public var contentUri: String { Self.contentUriPrefix + videoId }

    public func record(nowMs: Int64) -> PlayableRecord {
        PlayableRecord(songId: songId, rid: rid, videoId: videoId, title: title, artists: artists, album: album,
                       durationMs: durationMs, artUrl: artUrl, lastUsedAt: nowMs)
    }

    /// The in-memory song the queue, the player and the lock screen show. The app's artist and album ids come from
    /// its own id scheme (`artistId` gets one artist's name; `albumId` the album and the artist display string);
    /// without them the ids are -1, "no artist".
    public func song(artistId: (String) -> Int64 = { _ in -1 }, albumId: (String, String) -> Int64 = { _, _ in -1 },
                     nowMs: Int64 = 0) -> Song {
        let display = artistDisplay
        let refs = artists.enumerated().map { index, artist in
            ArtistRef(id: artistId(artist.name), name: artist.name, isPrimary: index == 0)
        }
        var albumName = Self.unknownAlbum
        if let album, !BrainText.isBlank(album) { albumName = album }
        return Song(id: songId, title: title, artist: display, artistId: refs.first?.id ?? -1, artists: refs,
                    album: albumName, albumId: albumId(albumName, display), path: "", contentUriString: contentUri,
                    albumArtUriString: artUrl, duration: durationMs, dateAdded: nowMs, dateModified: nowMs,
                    mimeType: "audio/mp4", bitrate: nil, sampleRate: nil)
    }
}

/// Where "Go to artist" and "Go to album" lead for a track from outside the library.
///
/// Such a track's song carries the artist and album ids the YouTube Music importer would give it, so that the rows
/// agree once it is saved. Until then the library has no artist or album under those ids, and the pages opened
/// with them are empty, although the listener often has that very artist: the library's own artists come from
/// Spotify, under another id made from the same name. This points the song at what the library does have.
public enum EngineSongLinks {
    public static let noAlbum: Int64 = -1

    /// `song` with every credited artist the library has under `libraryArtistId(name)` pointed there, and no album
    /// (`noAlbum`, which hides "Go to album") when the library has none under its album id. Ids the library
    /// already knows are kept. A handful of dictionary lookups: fine on the main actor.
    public static func link(_ song: Song, hasArtist: (Int64) -> Bool, hasAlbum: (Int64) -> Bool,
                            libraryArtistId: (String) -> Int64) -> Song {
        var linked = song
        func resolved(_ id: Int64, _ name: String) -> Int64 {
            if hasArtist(id) || BrainText.isBlank(name) { return id }
            let byName = libraryArtistId(name)
            return hasArtist(byName) ? byName : id
        }
        linked.artists = song.artists.map { ArtistRef(id: resolved($0.id, $0.name), name: $0.name, isPrimary: $0.isPrimary) }
        if let primary = linked.artists.first(where: \.isPrimary) ?? linked.artists.first {
            linked.artistId = primary.id
        } else {
            linked.artistId = resolved(song.artistId, song.artist)
        }
        if !hasAlbum(song.albumId) { linked.albumId = noAlbum }
        return linked
    }
}

/// What the brain may do in the app's first seconds (docs/brain-spec.md, 12.1 "App start"): nothing but show what
/// is already in memory.
public enum BrainStartup {
    /// Home's first refresh does not wait for the brain's stored tracks: they are read this long after launch.
    public static let storedTracksDelayMs: Int64 = 4_000

    /// How long to wait before the stored tracks may be read, `sinceLaunchMs` after the app started; 0 for "now".
    public static func storedTracksWaitMs(sinceLaunchMs: Int64) -> Int64 {
        if sinceLaunchMs < 0 { return storedTracksDelayMs }
        return max(storedTracksDelayMs - sinceLaunchMs, 0)
    }
}

/// The library by name (docs/brain-spec.md, 3.1 "Stage 1 joins artists by name"): tells whether a radio row is a
/// recording the listener already has, and lists a library artist's tracks.
///
/// Built off the main actor, once per library change, from the songs alone: nothing is written. The match is the
/// names-only step of `Ids.resolveTrack`: same folded primary artist, same cleaned title and version flags, and a
/// length within 3 seconds when both lengths are known.
public struct BrainLibraryIndex: Sendable {
    private var byNameKey: [BrainKey: [Song]] = [:]
    private var byArtistKey: [BrainKey: [Song]] = [:]
    public let size: Int

    public init(songs: [Song]) {
        size = songs.count
        byNameKey.reserveCapacity(songs.count)
        for song in songs {
            let primary = Self.primaryArtistName(song)
            let artistKey = BrainText.fold(primary)
            if !artistKey.isEmpty { byArtistKey[BrainKey(artistKey), default: []].append(song) }
            guard let key = Ids.nameKey(primaryArtist: primary, rawTitle: song.title) else { continue }
            byNameKey[BrainKey(key), default: []].append(song)
        }
    }

    /// The library song that is the same recording as `row`, or nil.
    public func match(_ row: RadioRow) -> Song? {
        guard let primary = row.artists.first?.name,
              let key = Ids.nameKey(primaryArtist: primary, rawTitle: row.title),
              let candidates = byNameKey[BrainKey(key)] else { return nil }
        let rowMs = Int64(row.durationSec) * 1000
        for song in candidates {
            if rowMs <= 0 || song.duration <= 0 { return song }
            let delta = rowMs > song.duration ? rowMs - song.duration : song.duration - rowMs
            if delta <= Int64(Ids.nameMatchMaxDurationDeltaMs) { return song }
        }
        return nil
    }

    /// Every folded primary-artist name of the library, in ascending UTF-8 byte order (a fixed order: nothing here
    /// may depend on a dictionary's).
    public func artistKeys() -> [String] {
        byArtistKey.keys.map(\.text).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// Library songs whose primary artist folds to `artistKey`, in library order.
    public func byPrimaryArtist(_ artistKey: String) -> [Song] { byArtistKey[BrainKey(artistKey)] ?? [] }

    /// The primary artist of a library track: the first entry of the library's own split artist list, falling back
    /// to the legacy field. `Song.artist` can be a ", "-joined display string ("Tyler, The Creator" would break),
    /// so it is only the fallback and is never split here.
    public static func primaryArtistName(_ song: Song) -> String {
        if let name = (song.artists.first(where: \.isPrimary) ?? song.artists.first)?.name, !BrainText.isBlank(name) {
            return name
        }
        return song.artist
    }

    public static func artistKey(of song: Song) -> String { BrainText.fold(primaryArtistName(song)) }

    /// The folded album name; nil when the album is unknown.
    public static func albumKey(of album: String) -> String? {
        let key = BrainText.fold(album)
        return key.isEmpty || BrainKey.sameBytes(key, "unknown album") ? nil : key
    }

    /// The folded primary artist of a radio row; "" when the row names nobody.
    public static func artistKey(of row: RadioRow) -> String { row.artists.first.map { BrainText.fold($0.name) } ?? "" }
}
