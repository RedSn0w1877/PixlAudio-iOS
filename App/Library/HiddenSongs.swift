import Foundation
import PixlModel

/// Songs the user deleted that have no file of their own to delete (Android deletes the file through MediaStore, so
/// the next scan can't find it): music-library items, Spotify songs, and files the app couldn't delete. Every scan
/// skips these ids (`LocalLibraryImporter`, the Spotify library rebuild), so a deleted song stays deleted instead of
/// coming back — un-liked and out of its playlists — on the next launch.
nonisolated enum HiddenSongs {
    static let key = "hidden_song_ids_v1"

    static func ids(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func hide(_ songIds: [String], defaults: UserDefaults = .standard) {
        guard !songIds.isEmpty else { return }
        var current = ids(defaults)
        let before = current.count
        current.formUnion(songIds)
        guard current.count != before else { return }
        defaults.set(current.sorted(), forKey: key)
    }

    static func unhide(_ songIds: [String], defaults: UserDefaults = .standard) {
        var current = ids(defaults)
        let before = current.count
        current.subtract(songIds)
        guard current.count != before else { return }
        defaults.set(current.sorted(), forKey: key)
    }
}

/// Deleting the audio files of deleted songs (Android `SongRemovalStateHolder` → `createDeleteRequest`).
nonisolated enum SongFileRemoval {
    /// Whether deleting `song` deletes a file: a scanned file (Documents or a picked folder, whose security scope
    /// stays open for the process).
    static func deletesFile(_ song: Song) -> Bool {
        song.id.hasPrefix(LibraryIdentity.filePrefix) && fileURL(song) != nil
    }

    static func fileURL(_ song: Song) -> URL? {
        if let url = URL(string: song.contentUriString), url.isFileURL { return url }
        if song.contentUriString.hasPrefix("/") { return URL(fileURLWithPath: song.contentUriString) }
        return nil
    }

    /// Deletes the files (coordinated, as the Files app expects) and returns the ids whose file couldn't be deleted.
    @concurrent
    static func deleteFiles(of songs: [Song]) async -> [String] {
        var failed: [String] = []
        for song in songs {
            guard let url = fileURL(song) else {
                failed.append(song.id)
                continue
            }
            var coordinationError: NSError?
            var deleted = false
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
                deleted = (try? FileManager.default.removeItem(at: target)) != nil
            }
            if !deleted, !FileManager.default.fileExists(atPath: url.path) { deleted = true }
            if !deleted { failed.append(song.id) }
        }
        return failed
    }
}
