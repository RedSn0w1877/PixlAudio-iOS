import Foundation
import PixlFoundation
import PixlModel
import PixlNet
import SwiftData

/// YouTube Music search for the Search screen (Android `SearchStateHolder.observeYoutubeMusicRequests` +
/// `playYouTubeMusicTrack`): songs and music videos interleaved, at most 20, queries shorter than two characters
/// skipped. Tapping a result brings it into the library as a `yt:<videoId>` song (no matching needed — the video
/// is known) and plays it through the streaming loader.
nonisolated struct YouTubeMusicSearchProvider: SearchProviding {
    static let minQueryLength = 2
    static let resultLimit = 20

    var source: SearchSource { .youtubeMusic }
    let service: InnerTubeService
    let importer: YouTubeLibraryImporter

    func search(_ query: String, filter: SearchFilterType, limit: Int) async throws -> [SearchResultItem] {
        guard query.count >= Self.minQueryLength else { return [] }
        let results = try await service.searchMusic(query, limit: min(limit, Self.resultLimit))
        return results.map { .youtubeMusic(Self.track($0)) }
    }

    func importAndPlay(_ item: SearchResultItem) async -> Song? {
        guard case .youtubeMusic(let track) = item else { return nil }
        return await importer.importTrack(track, favorite: false)
    }

    func like(_ item: SearchResultItem) async -> Bool {
        guard case .youtubeMusic(let track) = item else { return false }
        return await importer.importTrack(track, favorite: true) != nil
    }

    /// `toYouTubeMusicTrack()`.
    static func track(_ result: YouTubeSearchResult) -> YouTubeMusicTrack {
        YouTubeMusicTrack(videoId: result.videoId, title: result.title,
                          artist: result.artist.isKotlinBlank ? "Unknown Artist" : result.artist,
                          album: result.album, thumbnailUrl: result.thumbnailUrl,
                          durationMs: Int64(result.durationSeconds ?? 0) * 1000)
    }
}

/// Adds YouTube Music songs to the library: the snapshot updates at once, then the store (Android
/// `importYouTubeMusicTracks`, which went through the Spotify tables; iOS writes `yt:` song rows directly).
@MainActor
final class YouTubeLibraryImporter {
    private let library: LibraryStore
    private let persistence: PersistenceActor?
    private let writesCache: Bool

    init(library: LibraryStore, persistence: PersistenceActor?, writesCache: Bool) {
        self.library = library
        self.persistence = persistence
        self.writesCache = writesCache
    }

    /// The library song for `track` (imported when new; liked when `favorite`).
    func importTrack(_ track: YouTubeMusicTrack, favorite: Bool) async -> Song? {
        guard CloudStreamSecurity.validateYouTubeVideoId(track.videoId) else { return nil }
        let now = currentTimeMillis()
        var built = YouTubeSongFactory.song(track, now: now)
        var snapshot = library.snapshot
        if let index = snapshot.songs.firstIndex(where: { $0.id == built.id }) {
            guard favorite, !snapshot.songs[index].isFavorite else { return snapshot.songs[index] }
            snapshot.songs[index].isFavorite = true
            built = snapshot.songs[index]
        } else {
            built.isFavorite = favorite
            snapshot.songs.append(built)
        }
        let album = YouTubeSongFactory.album(for: built, now: now)
        let artist = YouTubeSongFactory.artist(for: built)
        if !snapshot.albums.contains(where: { $0.id == album.id }) { snapshot.albums.append(album) }
        if !snapshot.artists.contains(where: { $0.id == artist.id }) { snapshot.artists.append(artist) }
        library.apply(snapshot)
        if let persistence {
            let song = built, writesCache = self.writesCache, final = snapshot
            try? await persistence.upsertStreamSong(song, album: album, artist: artist, favoriteAt: favorite ? now : nil)
            if writesCache {
                Task.detached(priority: .utility) {
                    SnapshotLoader(persistence: persistence, cacheURL: SnapshotLoader.defaultCacheURL()).writeCache(final)
                }
            }
        }
        return built
    }
}

/// The library rows of a YouTube Music track (ids in the unified negative bands, as Android's synthetic rows).
nonisolated enum YouTubeSongFactory {
    static func song(_ track: YouTubeMusicTrack, now: Int64) -> Song {
        let artist = track.artist.isKotlinBlank ? "Unknown Artist" : track.artist
        let album = (track.album?.isKotlinBlank ?? true) ? "Unknown Album" : track.album!
        let artistId = SpotifyLibrary.unifiedArtistId("yt-artist:\(artist.lowercased())")
        return Song(id: "yt:\(track.videoId)", title: track.title, artist: artist, artistId: artistId,
                    artists: [ArtistRef(id: artistId, name: artist, isPrimary: true)],
                    album: album, albumId: SpotifyLibrary.unifiedAlbumId("yt-album:\(album.lowercased())|\(artist.lowercased())"),
                    path: "", contentUriString: "\(YouTubeSongIdentity.scheme)://\(track.videoId)",
                    albumArtUriString: track.thumbnailUrl, duration: track.durationMs, dateAdded: now, dateModified: now,
                    mimeType: "audio/mp4", bitrate: nil, sampleRate: nil)
    }

    static func album(for song: Song, now: Int64) -> Album {
        Album(id: song.albumId, title: song.album, artist: song.artist, year: 0, dateAdded: now,
              albumArtUriString: song.albumArtUriString, songCount: 1)
    }

    static func artist(for song: Song) -> Artist {
        Artist(id: song.artistId, name: song.artist, songCount: 1)
    }
}
