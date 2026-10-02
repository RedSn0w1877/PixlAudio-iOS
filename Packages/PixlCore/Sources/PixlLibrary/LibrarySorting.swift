// Sorting for every SortOption, ported from where Android applies it:
// - songs and liked songs: the `ORDER BY` of `MusicDao.getSongIdsSorted` / `getFavoriteSongIdsSorted` (SQLite NOCASE
//   collation, NULLs first, then `title COLLATE NOCASE, id`);
// - albums, artists, folders: `LibraryStateHolder.sortAlbumsList` / `sortArtistsList` / `sortFoldersList`;
// - playlists and songs inside a playlist: `PlaylistViewModel.sortPlaylistsList` / `sortSongsList`;
// - album playback order: `QueueStateHolder.playAlbum`; drag merges: `data/playlist/PlaylistOrder.kt`.

import Foundation
import PixlFoundation
import PixlModel

public enum LibrarySorting {
    // MARK: Songs (SQL)

    /// A value of one `CASE WHEN … END` sort term; `nil` is SQL NULL (sorts first ascending).
    private enum Term {
        case none
        case int(Int64)
        /// Text under SQLite `NOCASE`, stored as its folded UTF-8 bytes (`noCaseKey`).
        case folded([UInt8])

        /// A text term, folded once (comparing the folded bytes is `KotlinText.compareNoCase`).
        static func text(_ s: String) -> Term { .folded(noCaseKey(s)) }

        static func compare(_ a: Term, _ b: Term) -> Int {
            switch (a, b) {
            case (.none, .none): return 0
            case (.none, _): return -1
            case (_, .none): return 1
            case let (.int(x), .int(y)): return cmp(x, y)
            case let (.folded(x), .folded(y)): return compareBytes(x, y)
            case (.int, .folded): return -1
            case (.folded, .int): return 1
            }
        }
    }

    /// SQLite `NOCASE`'s sort key: the UTF-8 bytes with ASCII capitals folded to lower case. Comparing two keys
    /// byte by byte (shorter first on a common prefix) is exactly `KotlinText.compareNoCase` of the strings.
    static func noCaseKey(_ s: String) -> [UInt8] {
        s.utf8.map { ($0 >= 0x41 && $0 <= 0x5A) ? $0 + 0x20 : $0 }
    }

    /// memcmp order, a shorter key first when it is a prefix of the other.
    static func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let count = min(a.count, b.count)
        var i = 0
        while i < count {
            let x = a[i], y = b[i]
            if x != y { return x < y ? -1 : 1 }
            i += 1
        }
        return cmp(a.count, b.count)
    }

    /// A song id for `compareIds`, parsed once.
    private struct IdKey {
        let raw: String
        let number: Int64?

        init(_ id: String) {
            raw = id
            number = Int64(id)
        }

        static func compare(_ a: IdKey, _ b: IdKey) -> Int {
            if let x = a.number, let y = b.number { return cmp(x, y) }
            return KotlinText.compareBinary(a.raw, b.raw)
        }
    }

    /// The SQL-side order of the Songs tab: the option's key (`song_default_order` = track number), then title
    /// (NOCASE) and id. Options of other tabs sort by title and id only, as the SQL does.
    public static func sortSongs(_ songs: [Song], by option: SortOption) -> [Song] {
        sqlSort(songs, terms: songTerms(option))
    }

    /// The Liked tab order. `likedAt` holds each song's favourite timestamp (`favorites.timestamp`).
    public static func sortLikedSongs(_ songs: [Song], by option: SortOption, likedAt: [String: Int64]) -> [Song] {
        let liked = likedAt.reduce(into: [KotlinKey: Int64]()) { $0[KotlinKey($1.key)] = $1.value }
        let terms: [(term: (Song) -> Term, descending: Bool)]
        switch option {
        case .likedSongTitleAZ: terms = [({ .text($0.title) }, false)]
        case .likedSongTitleZA: terms = [({ .text($0.title) }, true)]
        case .likedSongArtist: terms = [({ .text($0.artist) }, false)]
        case .likedSongArtistDesc: terms = [({ .text($0.artist) }, true)]
        case .likedSongAlbum: terms = [({ .text($0.album) }, false)]
        case .likedSongAlbumDesc: terms = [({ .text($0.album) }, true)]
        case .likedSongDateLiked: terms = [({ liked[KotlinKey($0.id)].map(Term.int) ?? .none }, true)]
        case .likedSongDateLikedAsc: terms = [({ liked[KotlinKey($0.id)].map(Term.int) ?? .none }, false)]
        default: terms = []
        }
        return sqlSort(songs, terms: terms)
    }

    private static func songTerms(_ option: SortOption) -> [(term: (Song) -> Term, descending: Bool)] {
        switch option {
        case .songDefaultOrder: return [({ .int(Int64($0.trackNumber)) }, false)]
        case .songTitleAZ: return [({ .text($0.title) }, false)]
        case .songTitleZA: return [({ .text($0.title) }, true)]
        case .songArtist: return [({ .text($0.artist) }, false)]
        case .songArtistDesc: return [({ .text($0.artist) }, true)]
        case .songAlbum: return [({ .text($0.album) }, false)]
        case .songAlbumDesc: return [({ .text($0.album) }, true)]
        case .songDateAdded: return [({ .int($0.dateAdded) }, true)]
        case .songDateAddedAsc: return [({ .int($0.dateAdded) }, false)]
        case .songDuration: return [({ .int($0.duration) }, true)]
        case .songDurationAsc: return [({ .int($0.duration) }, false)]
        default: return []
        }
    }

    /// Keys are computed once per song — the terms, the folded title and the parsed id — instead of per comparison
    /// (a 5,000-song sort makes ~60,000 comparisons); the order is the same.
    private static func sqlSort(_ songs: [Song], terms: [(term: (Song) -> Term, descending: Bool)]) -> [Song] {
        let keyed = songs.map { song in
            (song: song, terms: terms.map { $0.term(song) }, title: noCaseKey(song.title), id: IdKey(song.id))
        }
        return keyed.kotlinSorted { a, b in
            for index in terms.indices {
                let c = Term.compare(a.terms[index], b.terms[index])
                if c != 0 { return terms[index].descending ? -c : c }
            }
            let title = compareBytes(a.title, b.title)
            return title != 0 ? title : IdKey.compare(a.id, b.id)
        }.map(\.song)
    }

    /// `id ASC`: Android ids are integers; iOS ids are strings, compared numerically when both are integers.
    static func compareIds(_ a: String, _ b: String) -> Int {
        if let x = Int64(a), let y = Int64(b) { return cmp(x, y) }
        return KotlinText.compareBinary(a, b)
    }

    // MARK: Albums, artists, folders (LibraryStateHolder)

    /// Sorts with keys computed once per element (Kotlin evaluates `lowercase()` per comparison; same order).
    private static func sorted<E, K>(_ items: [E], key: (E) -> K, _ comparator: (K, K) -> Int) -> [E] {
        items.map { ($0, key($0)) }.kotlinSorted { comparator($0.1, $1.1) }.map(\.0)
    }

    private static func lower(_ s: String) -> String { KotlinText.lowercase(s) }
    private static func text(_ a: String, _ b: String) -> Int { KotlinText.compare(a, b) }

    public static func sortAlbums(_ albums: [Album], by option: SortOption) -> [Album] {
        typealias K = (title: String, artist: String, album: Album)
        let key: (Album) -> K = { (lower($0.title), lower($0.artist), $0) }
        let comparator: ((K, K) -> Int)?
        switch option {
        case .albumTitleAZ: comparator = { chain(text($0.title, $1.title), text($0.artist, $1.artist), cmp($0.album.id, $1.album.id)) }
        case .albumTitleZA: comparator = { chain(text($1.title, $0.title), text($0.artist, $1.artist), cmp($0.album.id, $1.album.id)) }
        case .albumArtist: comparator = { chain(text($0.artist, $1.artist), text($0.title, $1.title), cmp($0.album.id, $1.album.id)) }
        case .albumArtistDesc: comparator = { chain(text($1.artist, $0.artist), text($0.title, $1.title), cmp($0.album.id, $1.album.id)) }
        case .albumReleaseYear:
            comparator = { chain(cmp($1.album.year, $0.album.year), text($0.title, $1.title), cmp($0.album.id, $1.album.id)) }
        case .albumReleaseYearAsc:
            comparator = { chain(cmp($0.album.year, $1.album.year), text($0.title, $1.title), cmp($0.album.id, $1.album.id)) }
        case .albumDateAdded:
            comparator = { chain(cmp($1.album.dateAdded, $0.album.dateAdded), text($0.title, $1.title), cmp($0.album.id, $1.album.id)) }
        case .albumSizeAsc:
            comparator = { chain(cmp($0.album.songCount, $1.album.songCount), text($0.title, $1.title), cmp($0.album.id, $1.album.id)) }
        case .albumSizeDesc:
            comparator = { chain(cmp($1.album.songCount, $0.album.songCount), text($0.title, $1.title), cmp($0.album.id, $1.album.id)) }
        default: comparator = nil
        }
        guard let comparator else { return albums }
        return sorted(albums, key: key, comparator)
    }

    public static func sortArtists(_ artists: [Artist], by option: SortOption) -> [Artist] {
        typealias K = (name: String, artist: Artist)
        let comparator: ((K, K) -> Int)?
        switch option {
        case .artistNameAZ: comparator = { chain(text($0.name, $1.name), cmp($0.artist.id, $1.artist.id)) }
        case .artistNameZA: comparator = { chain(text($1.name, $0.name), cmp($0.artist.id, $1.artist.id)) }
        case .artistNumSongsDesc:
            comparator = { chain(cmp($1.artist.songCount, $0.artist.songCount), text($0.name, $1.name), cmp($0.artist.id, $1.artist.id)) }
        case .artistNumSongsAsc:
            comparator = { chain(cmp($0.artist.songCount, $1.artist.songCount), text($0.name, $1.name), cmp($0.artist.id, $1.artist.id)) }
        default: comparator = nil
        }
        guard let comparator else { return artists }
        return sorted(artists, key: { (lower($0.name), $0) }, comparator)
    }

    public static func sortFolders(_ folders: [MusicFolder], by option: SortOption) -> [MusicFolder] {
        typealias K = (name: String, songs: Int, subFolders: Int, path: String)
        let comparator: ((K, K) -> Int)?
        switch option {
        case .folderNameAZ: comparator = { chain(text($0.name, $1.name), text($0.path, $1.path)) }
        case .folderNameZA: comparator = { chain(text($1.name, $0.name), text($0.path, $1.path)) }
        case .folderSongCountAsc: comparator = { chain(cmp($0.songs, $1.songs), text($0.name, $1.name), text($0.path, $1.path)) }
        case .folderSongCountDesc: comparator = { chain(cmp($1.songs, $0.songs), text($0.name, $1.name), text($0.path, $1.path)) }
        case .folderSubdirCountAsc:
            comparator = { chain(cmp($0.subFolders, $1.subFolders), text($0.name, $1.name), text($0.path, $1.path)) }
        case .folderSubdirCountDesc:
            comparator = { chain(cmp($1.subFolders, $0.subFolders), text($0.name, $1.name), text($0.path, $1.path)) }
        default: comparator = nil
        }
        guard let comparator else { return folders }
        return sorted(folders, key: { (lower($0.name), $0.totalSongCount, $0.totalSubFolderCount, $0.path) }, comparator)
    }

    // MARK: Playlists (PlaylistViewModel)

    /// The Playlists tab order; options of other tabs fall back to name A–Z.
    public static func sortPlaylists(_ playlists: [Playlist], by option: SortOption) -> [Playlist] {
        typealias K = (name: String, playlist: Playlist)
        let comparator: (K, K) -> Int
        switch option {
        case .playlistCustomOrder:
            comparator = { chain(cmp($0.playlist.sortOrder, $1.playlist.sortOrder), text($0.name, $1.name), text($0.playlist.id, $1.playlist.id)) }
        case .playlistNameZA:
            comparator = { chain(text($1.name, $0.name), cmp($1.playlist.lastModified, $0.playlist.lastModified), text($0.playlist.id, $1.playlist.id)) }
        case .playlistDateCreated:
            comparator = { chain(cmp($1.playlist.lastModified, $0.playlist.lastModified), text($0.name, $1.name), text($0.playlist.id, $1.playlist.id)) }
        case .playlistDateCreatedAsc:
            comparator = { chain(cmp($0.playlist.lastModified, $1.playlist.lastModified), text($0.name, $1.name), text($0.playlist.id, $1.playlist.id)) }
        default:
            comparator = { chain(text($0.name, $1.name), cmp($1.playlist.lastModified, $0.playlist.lastModified), text($0.playlist.id, $1.playlist.id)) }
        }
        return sorted(playlists, key: { (lower($0.name), $0) }, comparator)
    }

    /// Songs inside a playlist in "Sorted" mode (`sortSongsList`); unsupported options keep the order.
    public static func sortPlaylistSongs(_ songs: [Song], by option: SortOption) -> [Song] {
        typealias K = (title: String, artist: String, album: String, song: Song)
        let id: (K, K) -> Int = { text($0.song.id, $1.song.id) }
        let comparator: ((K, K) -> Int)?
        switch option {
        case .songTitleAZ: comparator = { chain(text($0.title, $1.title), text($0.artist, $1.artist), id($0, $1)) }
        case .songTitleZA: comparator = { chain(text($1.title, $0.title), text($0.artist, $1.artist), id($0, $1)) }
        case .songArtist: comparator = { chain(text($0.artist, $1.artist), text($0.title, $1.title), id($0, $1)) }
        case .songArtistDesc: comparator = { chain(text($1.artist, $0.artist), text($0.title, $1.title), id($0, $1)) }
        case .songAlbum: comparator = { chain(text($0.album, $1.album), text($0.title, $1.title), id($0, $1)) }
        case .songAlbumDesc: comparator = { chain(text($1.album, $0.album), text($0.title, $1.title), id($0, $1)) }
        case .songDuration: comparator = { chain(cmp($1.song.duration, $0.song.duration), text($0.title, $1.title), id($0, $1)) }
        case .songDurationAsc: comparator = { chain(cmp($0.song.duration, $1.song.duration), text($0.title, $1.title), id($0, $1)) }
        case .songDateAdded: comparator = { chain(cmp($1.song.dateAdded, $0.song.dateAdded), text($0.title, $1.title), id($0, $1)) }
        case .songDateAddedAsc: comparator = { chain(cmp($0.song.dateAdded, $1.song.dateAdded), text($0.title, $1.title), id($0, $1)) }
        default: comparator = nil
        }
        guard let comparator else { return songs }
        return sorted(songs, key: { (lower($0.title), lower($0.artist), lower($0.album), $0) }, comparator)
    }

    // MARK: Album playback and playlist drags

    /// `QueueStateHolder.playAlbum` order: disc (missing = 1), track (0 = last), lower-cased title.
    public static func albumPlaybackOrder(_ songs: [Song]) -> [Song] {
        songs.kotlinSorted { a, b in
            chain(cmp(a.discNumber ?? 1, b.discNumber ?? 1),
                  cmp(a.trackNumber > 0 ? a.trackNumber : Int(Int32.max), b.trackNumber > 0 ? b.trackNumber : Int(Int32.max)),
                  KotlinText.compare(KotlinText.lowercase(a.title), KotlinText.lowercase(b.title)))
        }
    }

    /// `mergePlaylistOrder`: applies a visible drag order without dropping unavailable or concurrently added
    /// entries, deleted songs or duplicates.
    public static func mergePlaylistOrder(currentIds: [String], requestedIds: [String]) -> [String] {
        let current = Set(currentIds.map(KotlinKey.init))
        let requested = requestedIds.filter { current.contains(KotlinKey($0)) }.kotlinDistinct()
        let requestedSet = Set(requested.map(KotlinKey.init))
        return requested + currentIds.filter { !requestedSet.contains(KotlinKey($0)) }.kotlinDistinct()
    }

    // MARK: Storage filter

    /// Whether a song is a streamed (Spotify/YouTube) item rather than a local file (Android `source_type != 0`).
    /// iOS ids carry the source: `yt:` and `sp:` are streamed.
    public static func isOnline(_ song: Song) -> Bool {
        song.id.utf8.starts(with: "yt:".utf8) || song.id.utf8.starts(with: "sp:".utf8)
    }

    /// The `filterMode` clause of the song queries.
    public static func matches(_ song: Song, filter: StorageFilter) -> Bool {
        switch filter {
        case .all: true
        case .offline: !isOnline(song)
        case .online: isOnline(song)
        }
    }
}
