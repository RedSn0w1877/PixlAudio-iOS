import AVFoundation
import Foundation
import PixlModel
import PixlTags

nonisolated enum TagWriteBackError: Error, Equatable, LocalizedError {
    case notAFile
    case unsupportedFormat(String)
    case editFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAFile: "Only songs from your folders can be written back to their files."
        case .unsupportedFormat(let ext): "Tags can't be written to .\(ext) files."
        case .editFailed(let message): message
        case .exportFailed(let message): "Couldn't rewrite the file: \(message)"
        }
    }
}

/// What the song editor writes into a file besides the override fields (stage 8; Android `editSongMetadata`'s
/// composer, lyrics, ReplayGain and cover parameters). nil leaves the file's value untouched.
nonisolated struct TagWriteExtras: Sendable, Equatable {
    var composer: String?
    /// nil keeps the lyrics tag; "" removes it.
    var lyrics: String?
    var replayGainTrackGainDb: String?
    var replayGainAlbumGainDb: String?
    var coverArt: CoverArtUpdate?

    init(composer: String? = nil, lyrics: String? = nil, replayGainTrackGainDb: String? = nil,
         replayGainAlbumGainDb: String? = nil, coverArt: CoverArtUpdate? = nil) {
        self.composer = composer
        self.lyrics = lyrics
        self.replayGainTrackGainDb = replayGainTrackGainDb
        self.replayGainAlbumGainDb = replayGainAlbumGainDb
        self.coverArt = coverArt
    }
}

/// Optional write-back of a tag edit into the audio file (architecture §2): MP3 and FLAC through PixlTags' port of
/// Android's `SongMetadataEditor`, M4A/M4B/AAC-in-MP4 through an `AVAssetExportSession` passthrough export (no
/// re-encode) with the edited metadata. The new file replaces the original with `FileManager.replaceItemAt`.
/// Returns the fields the format could not store (they stay as a tag override).
nonisolated enum TagWriteBack {
    static func write(_ fields: TagOverrideFields, to url: URL, current song: Song,
                      extras: TagWriteExtras = TagWriteExtras()) async throws -> TagOverrideFields {
        guard url.isFileURL else { throw TagWriteBackError.notAFile }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp3", "flac":
            try writeWithPixlTags(fields, to: url, current: song, extras: extras)
            // The editor has no year field (Android's neither); a new cover is also kept as the override so it shows
            // before the next scan reads the embedded one.
            return TagOverrideFields(year: fields.year, artworkUri: fields.artworkUri)
        case "m4a", "m4b", "mp4":
            try await writeWithExport(fields, to: url)
            return TagOverrideFields(trackNumber: fields.trackNumber, discNumber: fields.discNumber, year: fields.year,
                                     artworkUri: fields.artworkUri)
        default:
            throw TagWriteBackError.unsupportedFormat(ext)
        }
    }

    // MARK: MP3 / FLAC

    private static func writeWithPixlTags(_ fields: TagOverrideFields, to url: URL, current song: Song,
                                          extras: TagWriteExtras) throws {
        let data = try Data(contentsOf: url)
        // Keep tags the edit doesn't cover (the editor removes a missing composer).
        let existing = (try? AudioTagReader.read(data)).map {
            AudioMetadataMapper.metadata(properties: $0.properties, pictures: [], readArtwork: false)
        }
        let edit = MetadataEdit(
            title: fields.title ?? song.title, artist: fields.artist ?? song.artist, album: fields.album ?? song.album,
            albumArtist: fields.albumArtist ?? song.albumArtist, composer: extras.composer ?? existing?.composer,
            genre: fields.genre ?? song.genre ?? "", lyrics: extras.lyrics,
            trackNumber: fields.trackNumber ?? song.trackNumber, discNumber: fields.discNumber ?? song.discNumber,
            replayGainTrackGainDb: extras.replayGainTrackGainDb, replayGainAlbumGainDb: extras.replayGainAlbumGainDb,
            coverArt: extras.coverArt)
        switch SongMetadataEditor.edit(edit, fileData: data, fileExtension: url.pathExtension) {
        case .failure(let failure):
            throw TagWriteBackError.editFailed(failure.message)
        case .success(let result):
            try replace(url, with: result.data)
        }
    }

    /// Writes `data` next to the original (or in our temporary folder) and swaps it in.
    static func replace(_ url: URL, with data: Data) throws {
        let fileManager = FileManager.default
        let directory = (try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: url, create: true)) ?? fileManager.temporaryDirectory
        let temp = directory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        try data.write(to: temp)
        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? fileManager.removeItem(at: temp)
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: MP4

    private static func writeWithExport(_ fields: TagOverrideFields, to url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let existing = (try? await asset.load(.metadata)) ?? []
        var replacements: [(AVMetadataIdentifier, String?)] = []
        if let title = fields.title { replacements.append((.iTunesMetadataSongName, title)) }
        if let artist = fields.artist { replacements.append((.iTunesMetadataArtist, artist)) }
        if let album = fields.album { replacements.append((.iTunesMetadataAlbum, album)) }
        if let albumArtist = fields.albumArtist { replacements.append((.iTunesMetadataAlbumArtist, albumArtist)) }
        if let genre = fields.genre { replacements.append((.iTunesMetadataUserGenre, genre)) }
        let replaced = Set(replacements.map(\.0))
        // Common keys mirror the iTunes ones; drop both so the old values don't survive next to the new ones.
        let commonTwins: [AVMetadataIdentifier: AVMetadataIdentifier] = [
            .iTunesMetadataSongName: .commonIdentifierTitle, .iTunesMetadataArtist: .commonIdentifierArtist,
            .iTunesMetadataAlbum: .commonIdentifierAlbumName,
        ]
        let replacedCommon = Set(replaced.compactMap { commonTwins[$0] })
        var metadata = existing.filter { item in
            guard let id = item.identifier else { return true }
            return !replaced.contains(id) && !replacedCommon.contains(id)
        }
        for (identifier, value) in replacements {
            guard let value, !value.isEmpty else { continue }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            metadata.append(item)
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw TagWriteBackError.exportFailed("no passthrough export for this file")
        }
        session.metadata = metadata
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            try await session.export(to: temp, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw TagWriteBackError.exportFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        try replace(url, with: try Data(contentsOf: temp))
    }
}
