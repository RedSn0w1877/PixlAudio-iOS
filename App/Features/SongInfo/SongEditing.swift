import Foundation
import PixlModel
import PixlTags
import SwiftUI

/// The song editor's fields (Android `EditSongContent` state), filled from the library and — for songs from the
/// user's folders — the file's own tags (composer, ReplayGain, lyrics), read off the main thread.
nonisolated struct SongEditForm: Equatable, Sendable {
    nonisolated enum Cover: Equatable, Sendable {
        case unchanged
        /// JPEG bytes of the cropped image.
        case replaced(Data)
        case deleted
    }

    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var composer = ""
    var genre: String
    var lyrics: String
    /// Only an edit made in the lyrics field may overwrite stored lyrics (Android `lyricsEdited`).
    var lyricsEdited = false
    var trackNumber: String
    var discNumber: String
    var replayGainTrack = ""
    var replayGainAlbum = ""
    var cover: Cover = .unchanged

    init(song: Song) {
        title = song.title
        artist = song.displayArtist
        album = song.album
        albumArtist = song.albumArtist ?? ""
        genre = song.genre ?? ""
        lyrics = song.lyrics ?? ""
        trackNumber = String(song.trackNumber)
        discNumber = song.discNumber.map(String.init) ?? ""
    }

    /// Android `formatReplayGainForInput`: two decimals, US locale.
    static func replayGainText(_ value: Float?) -> String {
        guard let value else { return "" }
        return String(format: "%.2f", locale: Locale(identifier: "en_US"), Double(value))
    }

    /// The file's tags the library doesn't keep (composer, ReplayGain, embedded lyrics), for folder songs only.
    static func embeddedMetadata(for song: Song) async -> TagMetadata? {
        guard song.id.hasPrefix(LibraryIdentity.filePrefix), let url = URL(string: song.contentUriString),
              url.isFileURL else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return try? AudioMetadataMapper.read(data, readArtwork: false)
        }.value
    }
}

/// Saves an edit (Android `onEditSong` → `editSongMetadata`): the library shows it at once, then the tag override is
/// stored — and, for songs from the user's folders, written into the file (MP3 / FLAC / M4A) — and the library
/// reloads. Songs from the device music library can only be overridden; streamed songs aren't editable.
@MainActor
struct SongTagEditor {
    let env: AppEnvironment

    /// Android shows the edit button only for songs it can edit (local files; the demo library in UI tests).
    static func isEditable(_ song: Song) -> Bool {
        LibraryIdentity.isManaged(song.id) || song.id.hasPrefix("demo:")
    }

    /// Writes a replaced cover's JPEG off the main thread (nil for no new cover, or when the write failed).
    static func writeCover(_ cover: SongEditForm.Cover, songId: String, temporary: Bool) async -> URL? {
        guard case .replaced(let data) = cover else { return nil }
        return await Task.detached(priority: .userInitiated) {
            SongCoverStore.save(data, songId: songId, temporary: temporary)
        }.value
    }

    /// `coverURL`: the replaced cover's file, already written by `writeCover` (nil writes it here).
    func save(_ form: SongEditForm, for song: Song, coverURL: URL? = nil) {
        let artworkUri: String?
        var coverUpdate: CoverArtUpdate?
        switch form.cover {
        case .unchanged:
            artworkUri = nil
        case .deleted:
            artworkUri = ""
            coverUpdate = CoverArtUpdate(isDeletion: true)
        case .replaced(let data):
            artworkUri = (coverURL ?? SongCoverStore.save(data, songId: song.id, temporary: env.launch.isUITest))?
                .absoluteString
            coverUpdate = CoverArtUpdate(bytes: data, mimeType: "image/jpeg")
        }
        let trimmed = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let fields = TagOverrideFields(
            title: trimmed(form.title), artist: trimmed(form.artist), album: trimmed(form.album),
            albumArtist: trimmed(form.albumArtist), genre: trimmed(form.genre),
            trackNumber: Int(trimmed(form.trackNumber)) ?? song.trackNumber,
            discNumber: Int(trimmed(form.discNumber)), artworkUri: artworkUri)
        let extras = TagWriteExtras(composer: trimmed(form.composer),
                                    lyrics: form.lyricsEdited ? form.lyrics : nil,
                                    replayGainTrackGainDb: trimmed(form.replayGainTrack),
                                    replayGainAlbumGainDb: trimmed(form.replayGainAlbum),
                                    coverArt: coverUpdate)
        applyToSnapshot(fields, lyrics: extras.lyrics, songId: song.id)

        guard let importer = env.libraryImporter else { return }
        let library = env.library
        let writesFile = song.id.hasPrefix(LibraryIdentity.filePrefix)
        Task {
            do {
                try await importer.editTags(songId: song.id, fields: fields, writeToFile: writesFile, extras: extras)
                try await library.refresh()
            } catch {
                LibraryToast.shared.show(error.localizedDescription)
            }
        }
    }

    /// The edit, visible straight away (the next scan re-splits artists and regroups albums properly).
    private func applyToSnapshot(_ fields: TagOverrideFields, lyrics: String?, songId: String) {
        var snapshot = env.library.snapshot
        guard let index = snapshot.songs.firstIndex(where: { $0.id == songId }) else { return }
        var song = snapshot.songs[index]
        if let title = fields.title, !title.isEmpty { song.title = title }
        if let artist = fields.artist, !artist.isEmpty, artist != song.displayArtist {
            song.artist = artist
            song.artists = [ArtistRef(id: song.artistId, name: artist, isPrimary: true)]
        }
        if let album = fields.album, !album.isEmpty { song.album = album }
        if let albumArtist = fields.albumArtist { song.albumArtist = albumArtist.isEmpty ? nil : albumArtist }
        if let genre = fields.genre { song.genre = genre.isEmpty ? nil : genre }
        if let track = fields.trackNumber { song.trackNumber = track }
        song.discNumber = fields.discNumber
        if let artwork = fields.artworkUri { song.albumArtUriString = artwork.isEmpty ? nil : artwork }
        if let lyrics { song.lyrics = lyrics.isEmpty ? nil : lyrics }
        snapshot.songs[index] = song
        // One song changed: patch the store's lookups instead of comparing and re-indexing the whole library.
        env.library.applyEdit(snapshot, changedSongs: [song])
    }
}

/// Covers chosen in the song editor, kept in Application Support/SongCovers (Caches for UI tests).
nonisolated enum SongCoverStore {
    static func save(_ data: Data, songId: String, temporary: Bool) -> URL? {
        let base = temporary ? FileManager.default.temporaryDirectory
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let folder = base?.appendingPathComponent("SongCovers", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A fresh name per edit, so the artwork caches never serve the previous cover.
        let url = folder.appendingPathComponent("\(UUID().uuidString).jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
