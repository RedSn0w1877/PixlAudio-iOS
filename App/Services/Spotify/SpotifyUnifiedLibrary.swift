import Foundation
import PixlLibrary
import PixlModel
import PixlNet

/// Port of `syncUnifiedLibrarySongsFromSpotify` + `mirrorPlaylistsIntoApp`: the imported Spotify tracks as library
/// rows next to the local music. Songs are `sp:<spotifyId>` (Android used the negative unified id); albums and
/// artists use Android's negative FNV-1a ids in their own bands, so they never collide with local rows. Every
/// Spotify playlist (Liked Songs and "Saved from Spotify" included) becomes an app playlist `spotify_playlist:<id>`
/// with source `SPOTIFY`. Pure: runs anywhere, tested in AppTests.
nonisolated enum SpotifyUnifiedLibrary {
    static let songIdPrefix = "sp:"

    struct Built: Sendable, Equatable {
        var songs: [Song]
        var albums: [Album]
        var albumArtistIds: [Int64: Int64]
        var artists: [Artist]
        var links: [SongArtistLink]
        var playlists: [Playlist]
    }

    static func songId(_ spotifyId: String) -> String { songIdPrefix + spotifyId }

    static func isSpotifySongId(_ id: String) -> Bool { id.hasPrefix(songIdPrefix) }

    /// `CloudMusicUtils.parseArtistNames`: the local scan's conservative default delimiters.
    static func parseArtistNames(_ raw: String) -> [String] {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ["Unknown Artist"] }
        let parsed = ArtistParsing.split(raw, delimiters: ArtistParsing.defaultArtistDelimiters,
                                         wordDelimiters: ArtistParsing.defaultWordDelimiters)
        return parsed.isEmpty ? ["Unknown Artist"] : parsed
    }

    /// Whether an album / artist id belongs to the Spotify bands (`-(offset + x)`, x < 10^12).
    static func isSpotifyAlbumId(_ id: Int64) -> Bool { id <= -4_000_000_000_000 && id > -5_000_000_000_000 }
    static func isSpotifyArtistId(_ id: Int64) -> Bool { id <= -5_000_000_000_000 && id > -6_000_000_000_000 }

    /// Builds the unified rows from every stored Spotify row (`getDistinctSpotifySongsList` = first row per track)
    /// and the playlist headers. `existing` keeps each song's favourite flag, lyrics and date added.
    static func build(rows: [SpotifyTrackRecord], playlists: [SpotifyPlaylistRow], existing: [String: Song] = [:],
                      nowMs: Int64 = currentTimeMillis()) -> Built {
        var seen = Set<String>()
        let distinct = rows.filter { seen.insert($0.spotifyId).inserted }

        var songs: [Song] = []
        songs.reserveCapacity(distinct.count)
        var artists: [Int64: Artist] = [:]
        var artistOrder: [Int64] = []
        var albums: [Int64: Album] = [:]
        var albumOrder: [Int64] = []
        var albumArtistIds: [Int64: Int64] = [:]
        var links: [SongArtistLink] = []

        for source in distinct {
            let id = songId(source.spotifyId)
            let names = parseArtistNames(source.artist)
            let refs = names.enumerated().map { index, name -> ArtistRef in
                let artistId = SpotifyLibrary.unifiedArtistId(KotlinText.lowercase(name))
                if artists[artistId] == nil {
                    artists[artistId] = Artist(id: artistId, name: name, songCount: 0)
                    artistOrder.append(artistId)
                }
                links.append(SongArtistLink(songId: id, artistId: artistId, isPrimary: index == 0))
                return ArtistRef(id: artistId, name: name, isPrimary: index == 0)
            }
            let primary = refs.first
            let albumKey = source.albumId ?? "\(source.album)|\(source.artist)"
            let albumId = SpotifyLibrary.unifiedAlbumId(albumKey)
            if albums[albumId] == nil {
                albums[albumId] = Album(id: albumId, title: source.album, artist: primary?.name ?? source.artist, year: 0,
                                        dateAdded: source.dateAdded, albumArtUriString: source.albumArtUrl, songCount: 0)
                albumArtistIds[albumId] = primary?.id ?? 0
                albumOrder.append(albumId)
            }
            let previous = existing[id]
            songs.append(Song(id: id, title: source.title, artist: source.artist, artistId: primary?.id ?? 0, artists: refs,
                              album: source.album, albumId: albumId, path: "", contentUriString: "spotify://\(source.spotifyId)",
                              albumArtUriString: source.albumArtUrl, duration: source.durationMs, genre: source.genre,
                              lyrics: previous?.lyrics, isFavorite: previous?.isFavorite ?? false,
                              dateAdded: previous?.dateAdded ?? source.dateAdded, mimeType: nil, bitrate: nil, sampleRate: nil,
                              spotifyId: source.spotifyId))
        }

        var songsPerAlbum: [Int64: Int] = [:]
        for song in songs { songsPerAlbum[song.albumId, default: 0] += 1 }
        var tracksPerArtist: [Int64: Int] = [:]
        for link in links { tracksPerArtist[link.artistId, default: 0] += 1 }

        // Mirrored playlists: one app playlist per Spotify playlist, songs in stored order.
        var songIdsByPlaylist: [String: [String]] = [:]
        for row in rows {
            let id = songId(row.spotifyId)
            if !(songIdsByPlaylist[row.playlistId]?.contains(id) ?? false) { songIdsByPlaylist[row.playlistId, default: []].append(id) }
        }
        let mirrored = playlists.map { playlist in
            Playlist(id: SpotifyLibrary.appPlaylistId(playlist.id), name: playlist.name,
                     songIds: songIdsByPlaylist[playlist.id] ?? [], createdAt: nowMs, lastModified: nowMs,
                     coverImageUri: playlist.coverUrl, source: SpotifyLibrary.playlistSource)
        }

        return Built(songs: songs,
                     albums: albumOrder.map { id in
                         var album = albums[id]!
                         album.songCount = songsPerAlbum[id] ?? 0
                         return album
                     },
                     albumArtistIds: albumArtistIds,
                     artists: artistOrder.map { id in
                         var artist = artists[id]!
                         artist.songCount = tracksPerArtist[id] ?? 0
                         return artist
                     },
                     links: links, playlists: mirrored)
    }
}
