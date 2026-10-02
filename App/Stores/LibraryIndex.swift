import Foundation
import PixlModel

/// The by-id lookups `LibraryStore` keeps for a snapshot. Built off the main actor where the snapshot is loaded
/// (`SnapshotLoader`), so applying a library from the store or a rescan costs the main actor nothing but the swap.
nonisolated struct LibraryLookups: Sendable {
    var songsById: [String: Song]
    var albumsById: [Int64: Album]
    var artistsById: [Int64: Artist]
    var playlistsById: [String: Playlist]

    init(_ snapshot: LibrarySnapshot) {
        songsById = Dictionary(snapshot.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        albumsById = Dictionary(snapshot.albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        artistsById = Dictionary(snapshot.artists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        playlistsById = Dictionary(snapshot.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// Songs per album, artist and genre for the detail pages, built off the main actor for one library revision.
/// Each list keeps the library's order, so `songs(album:)` equals `library.songs.filter { $0.albumId == id }`, and so
/// on — the pages read these instead of filtering the whole library on the main actor in a push's first frames.
nonisolated struct LibraryDetailIndex: Sendable {
    /// The `LibraryStore.revision` this index was built from; a stale index is never used.
    let revision: Int
    let songsByAlbum: [Int64: [Song]]
    /// Songs whose primary artist or any credited artist is the key.
    let songsByArtist: [Int64: [Song]]
    /// Songs by `GenreDetailIndexKey.key(_:)` ("" collects songs without a genre).
    let songsByGenre: [String: [Song]]
    /// The artwork of the first song whose primary artist is the key (the artist page's theme fallback); no entry
    /// when that song has none, like `library.songs.first { $0.artistId == id }?.albumArtUriString`.
    let firstArtworkByArtist: [Int64: String]

    static func build(_ songs: [Song], revision: Int) -> LibraryDetailIndex {
        var byAlbum: [Int64: [Song]] = [:]
        var byArtist: [Int64: [Song]] = [:]
        var byGenre: [String: [Song]] = [:]
        var firstArtwork: [Int64: String] = [:]
        var primary: Set<Int64> = []
        for song in songs {
            byAlbum[song.albumId, default: []].append(song)
            byArtist[song.artistId, default: []].append(song)
            for credit in song.artists where credit.id != song.artistId {
                // A song credits an artist once, however often the credit repeats.
                if byArtist[credit.id]?.last?.id != song.id { byArtist[credit.id, default: []].append(song) }
            }
            byGenre[GenreDetailIndexKey.key(song.genre), default: []].append(song)
            if primary.insert(song.artistId).inserted, let art = song.albumArtUriString {
                firstArtwork[song.artistId] = art
            }
        }
        return LibraryDetailIndex(revision: revision, songsByAlbum: byAlbum, songsByArtist: byArtist,
                                  songsByGenre: byGenre, firstArtworkByArtist: firstArtwork)
    }

    @concurrent
    static func buildInBackground(_ songs: [Song], revision: Int) async -> LibraryDetailIndex {
        build(songs, revision: revision)
    }
}

/// The genre key the detail index groups by: GenreGrouping's rule (trimmed, lower-cased; "" = unknown).
nonisolated enum GenreDetailIndexKey {
    static func key(_ genre: String?) -> String {
        (genre ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }
}
