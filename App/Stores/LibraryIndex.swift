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
    /// `LibraryModel.folderTree(songs)` (folder playlists and the folder explorer resolve their folder in it).
    let folderTree: [MusicFolder]

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
                                  songsByGenre: byGenre, firstArtworkByArtist: firstArtwork,
                                  folderTree: LibraryModel.folderTree(songs))
    }

    /// The same index for a library whose songs did not change (an artist-picture update), under its new revision.
    func restamped(revision: Int) -> LibraryDetailIndex {
        LibraryDetailIndex(revision: revision, songsByAlbum: songsByAlbum, songsByArtist: songsByArtist,
                           songsByGenre: songsByGenre, firstArtworkByArtist: firstArtworkByArtist,
                           folderTree: folderTree)
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

extension LibraryStore {
    /// `songs.filter { $0.albumId == id }`, from the detail index when it is current.
    func songs(ofAlbum id: Int64) -> [Song] {
        if let index = detailIndexIfCurrent { return index.songsByAlbum[id] ?? [] }
        return songs.filter { $0.albumId == id }
    }

    /// The songs whose primary or credited artist is `id`, in library order.
    func songs(ofArtist id: Int64) -> [Song] {
        if let index = detailIndexIfCurrent { return index.songsByArtist[id] ?? [] }
        return songs.filter { song in song.artistId == id || song.artists.contains { $0.id == id } }
    }

    /// The artwork of the artist's first song (primary artist), the artist page's theme fallback.
    func firstArtwork(ofArtist id: Int64) -> String? {
        if let index = detailIndexIfCurrent { return index.firstArtworkByArtist[id] }
        return songs.first { $0.artistId == id }?.albumArtUriString
    }

    /// The folder tree of the library (`LibraryModel.folderTree`), from the detail index when it is current.
    var folderTree: [MusicFolder] {
        detailIndexIfCurrent?.folderTree ?? LibraryModel.folderTree(songs)
    }
}

/// A value a view derives in `body` and keeps until its key changes — no SwiftUI state change, no second pass.
/// Keep it in `@State` (a reference that lives as long as the view).
final class ViewMemo<Key: Equatable, Value> {
    private var entry: (key: Key, value: Value)?

    func value(for key: Key, _ make: () -> Value) -> Value {
        if let entry, entry.key == key { return entry.value }
        let value = make()
        entry = (key, value)
        return value
    }
}
