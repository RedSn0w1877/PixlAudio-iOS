// The file-tag half of Android's `SongMetadataEditor.editSongMetadata`: input validation, ReplayGain parsing,
// container routing and the TagLib property-map update (`updateFileMetadataWithTagLib`), applied to MP3 (ID3v2)
// and FLAC (Vorbis comment) files in memory. MediaStore, Room and artist-link updates are app-side.

import Foundation
import PixlFoundation

/// Android `MetadataEditError`.
public enum MetadataEditError: String, Sendable, Hashable, CaseIterable, Error {
    case fileNotFound = "FILE_NOT_FOUND"
    case noWritePermission = "NO_WRITE_PERMISSION"
    case invalidInput = "INVALID_INPUT"
    case unsupportedFormat = "UNSUPPORTED_FORMAT"
    case taglibError = "TAGLIB_ERROR"
    case timeout = "TIMEOUT"
    case fileCorrupted = "FILE_CORRUPTED"
    case ioError = "IO_ERROR"
    case unknown = "UNKNOWN"
}

/// A failed edit: the error kind and Android's message.
public struct MetadataEditFailure: Error, Sendable, Hashable {
    public var error: MetadataEditError
    public var message: String

    public init(_ error: MetadataEditError, _ message: String) {
        self.error = error
        self.message = message
    }
}

/// Android `CoverArtUpdate`: new image bytes, or a deletion.
public struct CoverArtUpdate: Sendable, Hashable {
    public var bytes: Data?
    public var mimeType: String
    public var isDeletion: Bool

    public init(bytes: Data? = nil, mimeType: String = "image/jpeg", isDeletion: Bool = false) {
        self.bytes = bytes
        self.mimeType = mimeType
        self.isDeletion = isDeletion
    }
}

/// The edit request (`editSongMetadata` parameters).
public struct MetadataEdit: Sendable, Hashable {
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String?
    public var composer: String?
    public var genre: String
    /// nil keeps the file's lyrics tag untouched; blank removes it.
    public var lyrics: String?
    public var trackNumber: Int
    public var discNumber: Int?
    /// nil keeps, blank clears, otherwise a dB value.
    public var replayGainTrackGainDb: String?
    public var replayGainAlbumGainDb: String?
    public var coverArt: CoverArtUpdate?

    public init(title: String, artist: String, album: String, albumArtist: String? = nil, composer: String? = nil,
                genre: String, lyrics: String?, trackNumber: Int, discNumber: Int?,
                replayGainTrackGainDb: String? = nil, replayGainAlbumGainDb: String? = nil,
                coverArt: CoverArtUpdate? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.composer = composer
        self.genre = genre
        self.lyrics = lyrics
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.replayGainTrackGainDb = replayGainTrackGainDb
        self.replayGainAlbumGainDb = replayGainAlbumGainDb
        self.coverArt = coverArt
    }
}

public enum SongMetadataEditor {
    /// `MetadataLimits` (lengths in UTF-16 code units, like Kotlin's `String.length`).
    public enum Limits {
        public static let maxTitleLength = 500
        public static let maxArtistLength = 500
        public static let maxAlbumLength = 500
        public static let maxAlbumArtistLength = 500
        public static let maxComposerLength = 500
        public static let maxGenreLength = 100
        public static let maxLyricsLength = 50_000
    }

    /// `validateMetadataInput`: the first problem as Android's message, or nil.
    public static func validate(title: String, artist: String, album: String, albumArtist: String?, composer: String?,
                                genre: String, lyrics: String?) -> String? {
        if title.isKotlinBlank { return "Title cannot be empty" }
        if title.kotlinLength > Limits.maxTitleLength { return "Title too long" }
        if artist.kotlinLength > Limits.maxArtistLength { return "Artist name too long" }
        if album.kotlinLength > Limits.maxAlbumLength { return "Album name too long" }
        if let albumArtist, !albumArtist.isKotlinBlank, albumArtist.kotlinLength > Limits.maxAlbumArtistLength {
            return "Album artist name too long"
        }
        if let composer, !composer.isKotlinBlank, composer.kotlinLength > Limits.maxComposerLength {
            return "Composer name too long"
        }
        if genre.kotlinLength > Limits.maxGenreLength { return "Genre too long" }
        if let lyrics, lyrics.kotlinLength > Limits.maxLyricsLength { return "Lyrics too long" }
        return nil
    }

    /// The validated, normalised parts of an edit (what `editSongMetadata` computes before touching the file).
    public struct PreparedEdit: Sendable, Hashable {
        public var edit: MetadataEdit
        /// `newLyrics?.trim()`.
        public var trimmedLyrics: String?
        /// `newGenre.trim()`.
        public var trimmedGenre: String
        public var replayGainTrack: ReplayGainUpdate
        public var replayGainAlbum: ReplayGainUpdate
    }

    /// Validation, trimming and ReplayGain parsing, in Android's order.
    public static func prepare(_ edit: MetadataEdit) -> Result<PreparedEdit, MetadataEditFailure> {
        if let message = validate(title: edit.title, artist: edit.artist, album: edit.album, albumArtist: edit.albumArtist,
                                  composer: edit.composer, genre: edit.genre, lyrics: edit.lyrics) {
            return .failure(MetadataEditFailure(.invalidInput, message))
        }
        let track: ReplayGainUpdate
        switch ReplayGainTags.parseUpdate(edit.replayGainTrackGainDb, fieldName: "Track ReplayGain") {
        case .success(let u): track = u
        case .failure(let f): return .failure(f)
        }
        let album: ReplayGainUpdate
        switch ReplayGainTags.parseUpdate(edit.replayGainAlbumGainDb, fieldName: "Album ReplayGain") {
        case .success(let u): album = u
        case .failure(let f): return .failure(f)
        }
        return .success(PreparedEdit(edit: edit, trimmedLyrics: edit.lyrics?.kotlinTrimmed(),
                                     trimmedGenre: edit.genre.kotlinTrimmed(), replayGainTrack: track,
                                     replayGainAlbum: album))
    }

    /// `updateFileMetadataWithTagLib`'s property-map changes.
    public static func applyProperties(_ p: PreparedEdit, to map: inout TagProperties) {
        let e = p.edit
        map["TITLE"] = [e.title]
        map["ARTIST"] = [e.artist]
        map["ALBUM"] = [e.album]
        if let albumArtist = e.albumArtist, !albumArtist.isKotlinBlank { map["ALBUMARTIST"] = [albumArtist] }
        upsertOrRemove(&map, "COMPOSER", e.composer)
        upsertOrRemove(&map, "GENRE", p.trimmedGenre)
        if let lyrics = p.trimmedLyrics { upsertOrRemove(&map, "LYRICS", lyrics) }
        map["TRACKNUMBER"] = [String(e.trackNumber)]
        if let disc = e.discNumber, disc > 0 { map["DISCNUMBER"] = [String(disc)] } else { map.remove("DISCNUMBER") }
        ReplayGainTags.apply(p.replayGainTrack, key: ReplayGainTags.trackGainKey, to: &map)
        ReplayGainTags.apply(p.replayGainAlbum, key: ReplayGainTags.albumGainKey, to: &map)
    }

    /// `MutableMap.upsertOrRemove`.
    static func upsertOrRemove(_ map: inout TagProperties, _ key: String, _ value: String?) {
        if KotlinText.isNullOrBlank(value) { map.remove(key) } else { map[key] = [value!] }
    }

    /// The pictures TagLib is given for a cover update (nil = leave pictures alone).
    public static func pictures(for update: CoverArtUpdate?) -> [TagPicture]? {
        guard let update else { return nil }
        if update.isDeletion { return [] }
        guard let bytes = update.bytes else { return nil }
        return [TagPicture(data: bytes, mimeType: update.mimeType, description: "Front Cover",
                           pictureType: TagPicture.type(named: "Front Cover"))]
    }

    /// Writes `edit` into a complete file (`fileData`, named with `fileExtension`) and returns the new file.
    ///
    /// Routing follows `editSongMetadata`: the container is detected from the bytes and wins over a wrong extension.
    /// MP3 and FLAC are written here; MP4/M4A (written by the app with AVFoundation), Ogg/Opus and WAV are
    /// `UNSUPPORTED_FORMAT`. Unlike Android, a FLAC stream behind an ID3v2 tag is written as FLAC (Android's magic
    /// check calls it MP3).
    public static func edit(_ edit: MetadataEdit, fileData: Data, fileExtension: String,
                            id3v2Version: UInt8? = 4) -> Result<TagWriteResult, MetadataEditFailure> {
        let prepared: PreparedEdit
        switch prepare(edit) {
        case .success(let p): prepared = p
        case .failure(let f): return .failure(f)
        }
        let detected = AudioContainer.detect(fileData)
        var effective = AudioContainer.effectiveExtension(fileExtension: fileExtension, detected: detected)
        if effective == "mp3", let tags = try? AudioTagReader.read(fileData), tags.container == .flac { effective = "flac" }
        guard effective == "mp3" || effective == "flac" else {
            return .failure(MetadataEditFailure(.unsupportedFormat, "Unsupported format: .\(effective)"))
        }
        do {
            let tags = try AudioTagReader.read(fileData)
            // `TagLib.getMetadata` → edit → `savePropertyMap`: start from the file's current property map.
            var map = tags.properties
            applyProperties(prepared, to: &map)
            let changes = TagChanges(properties: map, pictures: pictures(for: edit.coverArt), syncedLyrics: nil,
                                     id3v2Version: id3v2Version)
            return .success(try AudioTagWriter.write(changes, to: fileData))
        } catch TagError.unsupported(let what) {
            return .failure(MetadataEditFailure(.unsupportedFormat, "Unsupported format: \(what)"))
        } catch {
            return .failure(MetadataEditFailure(.taglibError, "Failed to write metadata to file"))
        }
    }
}
