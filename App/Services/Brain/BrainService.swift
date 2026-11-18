import Foundation
import Observation
import PixlLibrary
import PixlModel
import PixlNet

/// What the queue shows on the Autoplay line (docs/brain-spec.md, 8.4). The switch itself is
/// `SettingsStore.ai.musicDiscoveryEnabled`.
@Observable
final class AutoplayState {
    /// The queue ended and picks are being looked for (the backstop window).
    var finding = false
    /// The picks come from the library alone (offline, or the YouTube source is off or had nothing).
    var fromLibrary = false
    /// Where the Autoplay line is drawn: the queue index of the first entry Autoplay added that is still to come.
    /// Nil while there is none (the line then closes the queue).
    var lineIndex: Int?
}

/// The app's side of the music brain in stage 1a (docs/brain-spec.md, 2.1): it owns the brain's files through
/// `BrainRepository` (PixlLibrary, where every decision and all storage live) and knows the tracks from outside
/// the library that the engine put in a queue, so the app can show them (Recently Played, the song sheet) and save
/// them (Like, "Add to playlist").
///
/// Nothing here runs at app start: the files under `Application Support/Brain/` are read on first use.
final class BrainService {
    /// Reached by `LibraryEditor`, which is built in several places: Like and "Add to playlist" ask it whether an
    /// id that is not in the library is a track the engine played.
    static weak var shared: BrainService?

    let autoplay = AutoplayState()
    /// Nil in UI tests: no files, no network.
    let repository: BrainRepository?

    /// Tracks from outside the library known in this run: what Autoplay queued, and what the files hold.
    private var tracks: [String: EngineTrack] = [:]
    private var storedTracksTask: Task<Void, Never>?

    init(radioSource: (any RadioSource)?, isEnabled: Bool) {
        if isEnabled, let directory = Self.defaultDirectory() {
            repository = BrainRepository(directory: directory, radioSource: radioSource)
        } else {
            repository = nil
        }
    }

    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Brain", isDirectory: true)
    }

    // MARK: Engine tracks

    /// The song a track from outside the library plays as: `yt:<videoId>` through `pixlstream://<videoId>`, with the
    /// artist and album ids of the YouTube Music importer's scheme.
    nonisolated static func queueSong(for track: EngineTrack, nowMs: Int64 = currentTimeMillis()) -> Song {
        track.song(artistId: { SpotifyLibrary.unifiedArtistId("yt-artist:\($0.lowercased())") },
                   albumId: { album, artist in
                       SpotifyLibrary.unifiedAlbumId("yt-album:\(album.lowercased())|\(artist.lowercased())")
                   },
                   nowMs: nowMs)
    }

    /// Remembers tracks that are about to be queued and stores them, so they are still known after a restart.
    func register(_ newTracks: [EngineTrack]) {
        guard !newTracks.isEmpty else { return }
        for track in newTracks { tracks[track.songId] = track }
        guard let repository else { return }
        Task.detached(priority: .utility) { await repository.registerPlayable(newTracks) }
    }

    /// The track that plays under `songId`, when the engine queued it in this run or the files were read.
    func track(songId: String) -> EngineTrack? { tracks[songId] }

    /// The queue's song for an id the library does not have (the song sheet of an engine item).
    func song(id: String) -> Song? { tracks[id].map { Self.queueSong(for: $0) } }

    /// The library rows a saved engine track gets: exactly what the YouTube Music importer writes for the same
    /// video, so the id (`yt:<videoId>`) and the rows agree whichever way the track came in.
    func libraryRows(songId: String, nowMs: Int64) -> (song: Song, album: Album, artist: Artist)? {
        guard let track = tracks[songId] else { return nil }
        let song = YouTubeSongFactory.song(
            YouTubeMusicTrack(videoId: track.videoId, title: track.title, artist: track.artistDisplay, album: track.album,
                              thumbnailUrl: track.artUrl, durationMs: track.durationMs),
            now: nowMs)
        return (song, YouTubeSongFactory.album(for: song, now: nowMs), YouTubeSongFactory.artist(for: song))
    }

    /// Reads the stored tracks once (a small file, off the main actor) and returns every known engine track as a
    /// song by id: Recently Played resolves ids the library does not have through this.
    func engineSongs() async -> [String: Song] {
        guard let repository else { return [:] }
        if storedTracksTask == nil {
            storedTracksTask = Task { [weak self] in
                let stored = await repository.engineTracks()
                guard let self else { return }
                for track in stored where self.tracks[track.songId] == nil { self.tracks[track.songId] = track }
            }
        }
        await storedTracksTask?.value
        let known = Array(tracks.values)
        if known.isEmpty { return [:] }
        return await Task.detached(priority: .utility) {
            let now = currentTimeMillis()
            var songs: [String: Song] = [:]
            songs.reserveCapacity(known.count)
            for track in known { songs[track.songId] = BrainService.queueSong(for: track, nowMs: now) }
            return songs
        }.value
    }
}
