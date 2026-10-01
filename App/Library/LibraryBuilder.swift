import Foundation
import PixlLibrary
import PixlModel

/// One track as the scanner produced it (Android `SongEntity` before `preProcessAndDeduplicateWithMultiArtist`):
/// the raw artist string, the album name, where it lives. Built from a file's tags, from a media-library item, or
/// from the stored song of an unchanged file.
nonisolated struct ScannedTrack: Sendable, Equatable {
    var id: String
    var title: String
    /// The raw artist tag (may name several artists).
    var artist: String
    var album: String
    var albumArtist: String?
    var genre: String?
    var trackNumber: Int
    var discNumber: Int?
    var year: Int
    var durationMs: Int64
    var mimeType: String?
    var bitrate: Int?
    var sampleRate: Int?
    /// Playable URL: a `file://` URL or a media-library `ipod-library://` URL.
    var contentUri: String
    var artworkUri: String?
    /// Library path (`/<root>/<relative path>`), empty for media-library items.
    var path: String
    /// Empty for media-library items.
    var parentDirectory: String
    var dateAdded: Int64
    var dateModified: Int64
    /// Media-library items: the item's album persistent id. Files: nil (derived from the album grouping key).
    var fallbackAlbumId: Int64?

    /// Android `SyncWorker` / MediaStore normalisation of a file's tags: titles fall back to the file name,
    /// artists to "Unknown Artist", albums to the containing folder's name (MediaStore's default for untagged
    /// files), placeholder genres are dropped and the album artist goes through `resolveAlbumArtist`.
    static func file(id: String, root: FolderRoot, entry: ScannedFileEntry, metadata m: AudioFileMetadata,
                     coverImage: URL?) -> ScannedTrack {
        let path = LibraryIdentity.libraryPath(root: root, relativePath: entry.relativePath)
        let parent = LibraryIdentity.parentDirectory(ofLibraryPath: path)
        let fileName = (entry.relativePath as NSString).lastPathComponent
        let baseName = (fileName as NSString).deletingPathExtension
        let folderName = (parent as NSString).lastPathComponent
        let title = nonEmpty(MetadataText.normalize(m.title)) ?? nonEmpty(baseName) ?? "Unknown Title"
        let artist = nonEmpty(MetadataText.normalize(m.artist)) ?? "Unknown Artist"
        let album = nonEmpty(MetadataText.normalize(m.album)) ?? nonEmpty(folderName) ?? "Unknown Album"
        let artwork: String? = m.hasEmbeddedArtwork ? embeddedArtworkURI(entry.url) : coverImage?.absoluteString
        let modified = entry.modifiedMs > 0 ? entry.modifiedMs : Int64(Date().timeIntervalSince1970 * 1000)
        return ScannedTrack(
            id: id, title: title, artist: artist, album: album,
            albumArtist: AlbumGrouping.resolveAlbumArtist(rawAlbumArtist: nil, metadataAlbumArtist: m.albumArtist),
            genre: normalizeGenre(m.genre), trackNumber: m.trackNumber ?? 0,
            discNumber: m.discNumber.flatMap { $0 > 0 ? $0 : nil }, year: m.year ?? 0, durationMs: m.durationMs,
            mimeType: AudioFileTypes.mimeType(entry.url.pathExtension), bitrate: m.bitrate, sampleRate: m.sampleRate,
            contentUri: entry.url.absoluteString, artworkUri: artwork, path: path, parentDirectory: parent,
            dateAdded: modified, dateModified: modified, fallbackAlbumId: nil)
    }

    /// A stored song of an unchanged file, moved to the root's current URL (bookmarks can resolve to a new path).
    static func stored(_ song: Song, root: FolderRoot, entry: ScannedFileEntry) -> ScannedTrack {
        let path = LibraryIdentity.libraryPath(root: root, relativePath: entry.relativePath)
        var artwork = song.albumArtUriString
        if let current = artwork, current.hasPrefix("embedded://") { artwork = embeddedArtworkURI(entry.url) }
        return ScannedTrack(
            id: song.id, title: song.title, artist: song.artist, album: song.album, albumArtist: song.albumArtist,
            genre: song.genre, trackNumber: song.trackNumber, discNumber: song.discNumber, year: song.year,
            durationMs: song.duration, mimeType: song.mimeType, bitrate: song.bitrate, sampleRate: song.sampleRate,
            contentUri: entry.url.absoluteString, artworkUri: artwork, path: path,
            parentDirectory: LibraryIdentity.parentDirectory(ofLibraryPath: path), dateAdded: song.dateAdded,
            dateModified: song.dateModified, fallbackAlbumId: nil)
    }

    static func embeddedArtworkURI(_ url: URL) -> String { "embedded://" + url.absoluteString }

    /// Android `SyncWorker.normalizeGenre`: `<unknown>`, `unknown`, `unknown genre` and `null` are placeholders.
    static func normalizeGenre(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "<unknown>", "unknown", "unknown genre", "null": return nil
        default: return trimmed
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}

/// The library rows built from the scanned tracks.
nonisolated struct BuiltLibrary: Sendable {
    var songs: [Song]
    var albums: [LibraryAlbum]
    var artists: [Artist]
    var links: [SongArtistLink]
}

/// Artist splitting, artist ids, album grouping and the final song rows — the pure part of a scan, run over every
/// managed track each time (cheap; only file reading is incremental). Ported behaviour lives in PixlLibrary's
/// `LibraryAssembler` (Android `preProcessAndDeduplicateWithMultiArtist`); this adds iOS's ids and keeps the
/// user's state (favourite, lyrics, date added) from the stored songs.
nonisolated enum LibraryBuilder {
    static func build(tracks: [ScannedTrack], existing: LibrarySnapshot, options: LibraryScanOptions) -> BuiltLibrary {
        var scanned: [ScannedSong] = []
        scanned.reserveCapacity(tracks.count)
        for track in tracks {
            var song = ScannedSong(id: track.id, title: track.title, artistName: track.artist, artistId: 0,
                                   albumArtist: track.albumArtist, albumName: track.album, albumId: 0,
                                   contentUriString: track.contentUri, albumArtUriString: track.artworkUri,
                                   parentDirectoryPath: track.parentDirectory, dateAdded: track.dateAdded,
                                   year: track.year)
            if let fallback = track.fallbackAlbumId {
                song.albumId = fallback
            } else {
                let key = AlbumGrouping.groupingKey(for: song)
                song.albumId = LibraryIdentity.stableID("\(key.normalizedTitle)|\(key.identity)")
            }
            scanned.append(song)
        }

        var artistIds = OrderedStringMap<Int64>()
        var artistMetadata: [Int64: (imageUrl: String?, customImageUri: String?)] = [:]
        var maxArtistId: Int64 = 0
        for artist in existing.artists.sorted(by: { $0.id < $1.id }) {
            artistIds[artist.name] = artist.id
            artistMetadata[artist.id] = (artist.imageUrl, artist.customImageUri)
            maxArtistId = max(maxArtistId, artist.id)
        }
        let existingAlbums = existing.albums.map {
            LibraryAlbum(id: $0.id, title: $0.title, artistName: $0.artist, artistId: 0,
                         albumArtUriString: $0.albumArtUriString, songCount: $0.songCount, dateAdded: $0.dateAdded,
                         year: $0.year, albumArtist: $0.albumArtist)
        }
        let assembly = LibraryAssembler.assemble(
            songs: scanned, artistDelimiters: options.artistDelimiters, wordDelimiters: options.artistWordDelimiters,
            extractFromTitle: options.extractArtistsFromTitle, groupByAlbumArtist: options.groupByAlbumArtist,
            existingArtistMetadata: artistMetadata, existingAlbums: existingAlbums, existingArtistIds: artistIds,
            initialMaxArtistId: maxArtistId)

        var storedById: [String: Song] = [:]
        for song in existing.songs { storedById[song.id] = song }
        var songs: [Song] = []
        songs.reserveCapacity(tracks.count)
        for (track, assembled) in zip(tracks, assembly.songs) {
            let stored = storedById[track.id]
            songs.append(Song(
                id: track.id, title: track.title, artist: track.artist, artistId: assembled.song.artistId,
                artists: assembled.artists, album: track.album, albumId: assembled.song.albumId,
                albumArtist: track.albumArtist, path: track.path, contentUriString: track.contentUri,
                albumArtUriString: track.artworkUri, duration: track.durationMs, genre: track.genre,
                lyrics: stored?.lyrics, isFavorite: stored?.isFavorite ?? false, trackNumber: track.trackNumber,
                discNumber: track.discNumber, year: track.year, dateAdded: stored?.dateAdded ?? track.dateAdded,
                dateModified: track.dateModified, mimeType: track.mimeType, bitrate: track.bitrate,
                sampleRate: track.sampleRate, spotifyId: nil))
        }
        return BuiltLibrary(songs: songs, albums: assembly.albums, artists: assembly.artists.filter { $0.songCount > 0 },
                            links: assembly.links)
    }
}
