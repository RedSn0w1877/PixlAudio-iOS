import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel
import PixlNet

/// What the receiver's rules (`SongTapReceiver`, PixlCore) need from this app's library: the same importer Search's Save
/// uses (`YouTubeLibraryImporter.importTrack`, which writes a `yt:<videoId>` row that plays through the streaming loader at
/// once), the library's own lookups, and the app's title / artist / duration YouTube search with `TrackMatcher`'s scoring
/// for a song that came without a video. Nothing here reaches the brain, the listening history or Spotify's account.
@MainActor
final class AppSongTapLibrary: SongTapLibrary {
    private let library: LibraryStore
    private let persistence: PersistenceActor?
    private let importer: YouTubeLibraryImporter
    private let editor: () -> LibraryEditor
    private let search: any YouTubeMusicSearching

    /// How long a song without a video waits for its match (the same limit as a catalogue tap).
    static let matchTimeoutSeconds: Double = 25

    init(library: LibraryStore, persistence: PersistenceActor?, importer: YouTubeLibraryImporter,
         editor: @escaping () -> LibraryEditor, search: any YouTubeMusicSearching) {
        self.library = library
        self.persistence = persistence
        self.importer = importer
        self.editor = editor
        self.search = search
    }

    private func rowId(_ videoId: String) -> String { "yt:\(videoId)" }

    func hasVideo(_ videoId: String) async -> Bool {
        if library.song(id: rowId(videoId)) != nil { return true }
        // A song synced from the listener's own Spotify sits under its Spotify id, with the video it plays from matched to it.
        guard let persistence else { return false }
        return ((try? await persistence.allSongs()) ?? []).contains { $0.matchedVideoId == videoId }
    }

    func hasSpotifyId(_ spotifyId: String) async -> Bool {
        library.song(id: SpotifyUnifiedLibrary.songId(spotifyId)) != nil
    }

    func findVideo(title: String, artist: String, durationMs: Int64, isrc: String?, spotifyId: String?) async throws -> String? {
        let matcher = TrackMatcher(search: search)
        let track = MatchableTrack(title: title, artist: artist, album: "", durationMs: durationMs)
        let found = try await withTimeout(seconds: Self.matchTimeoutSeconds) { try await matcher.findMatchFanOut(track) }
        guard let outer = found, let match = outer else { return nil }
        return match.videoId
    }

    func importSong(videoId: String, title: String, artist: String, durationMs: Int64, artUrl: String?) async throws -> Bool {
        let existed = library.song(id: rowId(videoId)) != nil
        let track = YouTubeMusicTrack(videoId: videoId, title: title, artist: artist, album: nil, thumbnailUrl: artUrl,
                                      durationMs: durationMs)
        guard await importer.importTrack(track, favorite: false) != nil else { throw SongTapLibraryError.notImported }
        return !existed
    }

    /// Takes the song back out (`LibraryEditor.removeSongs`: the row, its links, favourite and playlist entries). It is the
    /// song Song Tap added a few seconds ago, so a song the listener has since put in a playlist loses that entry too.
    func remove(videoId: String) async throws -> Bool {
        let id = rowId(videoId)
        guard library.song(id: id) != nil else { return false }
        editor().removeSongs([id])
        return true
    }

    func songId(videoId: String) async -> String {
        // A song already synced from the listener's Spotify sits under its real id; one imported from a video under `yt:`.
        if library.song(id: rowId(videoId)) != nil { return rowId(videoId) }
        if let persistence, let record = ((try? await persistence.allSongs()) ?? []).first(where: { $0.matchedVideoId == videoId }) {
            return SpotifyUnifiedLibrary.songId(record.spotifyId)
        }
        return rowId(videoId)
    }

    func songId(spotifyId: String) async -> String { SpotifyUnifiedLibrary.songId(spotifyId) }
}

nonisolated enum SongTapLibraryError: Error {
    case notImported
}

/// The ids the sender's library knows for a song (`SongTapSender`'s port): the video a YouTube song plays from, or the one a
/// Spotify song was matched to, and the recording code Spotify gave it.
nonisolated struct AppSongTapSongIds: SongTapSongIds {
    let persistence: PersistenceActor?

    func videoId(for song: Song) async -> String? {
        if let own = YouTubeSongIdentity.videoId(for: song) { return own }
        guard let spotifyId = song.spotifyId, let persistence else { return nil }
        guard let matched = (try? await persistence.matchedVideoId(spotifyId: spotifyId)) ?? nil else { return nil }
        return SongTapPayloads.isVideoId(matched) ? matched : nil
    }

    func isrc(forSpotifyId spotifyId: String) async -> String? {
        guard let persistence, let record = (try? await persistence.spotifySong(spotifyId: spotifyId)) ?? nil else { return nil }
        return record.isrc.flatMap { $0.isEmpty ? nil : $0 }
    }

    func isSyntheticId(_ spotifyId: String, forVideo videoId: String) -> Bool {
        SpotifyLibrary.youTubeMusicSyntheticId(videoId, sha256: SpotifyPlatform.sha256) == spotifyId
    }
}
