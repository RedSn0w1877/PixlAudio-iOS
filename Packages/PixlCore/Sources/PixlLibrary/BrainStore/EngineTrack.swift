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

    public static func songId(videoId: String) -> String { songIdPrefix + videoId }

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
