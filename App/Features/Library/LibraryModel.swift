import Foundation
import Observation
import PixlLibrary
import PixlModel
import SwiftUI

/// What the Library tabs show, derived from the snapshot and the preferences (Android `LibraryViewModel` paging
/// flows + `LibraryStateHolder` sorting): sorted and storage-filtered songs, albums, artists, playlists, liked songs
/// and the folder tree. Recomputed off the main thread when an input changes, never in `body`.
///
/// Transition performance: only the first computation of a small library runs synchronously (so the first frame
/// has content); every later one — a sort or filter change from a sheet, a rescan — runs off the main actor while
/// the previous lists stay on screen, and lands without animation. Each list is memoised by the inputs it depends
/// on, so a change reuses the other lists' arrays unchanged (their pages see identical input and skip their
/// bodies), and the folder tree is built once per library revision. Inputs compare the library by revision.
@Observable
final class LibraryModel {
    nonisolated struct Inputs: Equatable, Sendable {
        var snapshot: LibrarySnapshot
        var songSort: SortOption
        var albumSort: SortOption
        var artistSort: SortOption
        var playlistSort: SortOption
        var folderSort: SortOption
        var likedSort: SortOption
        var storageFilter: StorageFilter
        var likedAt: [String: Int64]
        /// `LibraryStore.revision` of `snapshot`: what `==` compares instead of the snapshot itself.
        var revision: Int = 0

        static func == (a: Inputs, b: Inputs) -> Bool {
            a.revision == b.revision && a.songSort == b.songSort && a.albumSort == b.albumSort
                && a.artistSort == b.artistSort && a.playlistSort == b.playlistSort && a.folderSort == b.folderSort
                && a.likedSort == b.likedSort && a.storageFilter == b.storageFilter && a.likedAt == b.likedAt
        }
    }

    nonisolated struct Lists: Sendable {
        var songs: [Song] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []
        var liked: [Song] = []
        var folders: [MusicFolder] = []
        /// Folders with songs at any depth, flattened (the folders "playlist view").
        var folderPlaylists: [MusicFolder] = []
        /// Every folder's sorted subfolders and songs by path (what the Folders page shows for an open folder).
        var folderContents: [String: FolderContents] = [:]
        /// The root folders' paths (the breadcrumbs).
        var folderRoots: [String] = []
        /// Ids of `songs` / `liked` (the locate button asks "is the current song in this list?").
        var songIds: Set<String> = []
        var likedIds: Set<String> = []

        static let empty = Lists()
    }

    /// An open folder's subfolders (sorted with `LibrarySorting.sortFolders`) and own songs (`folderSongs`).
    nonisolated struct FolderContents: Sendable {
        var subFolders: [MusicFolder]
        var songs: [Song]
    }

    /// A computation and what it was computed from (the next one reuses what still applies).
    nonisolated struct Computed: Sendable {
        var inputs: Inputs
        var lists: Lists
        /// The unsorted folder tree of `inputs.revision`.
        var tree: [MusicFolder]
    }

    private(set) var lists = Lists.empty
    /// True until the first computation finished.
    private(set) var isComputing = true

    @ObservationIgnored private var inputs: Inputs?
    @ObservationIgnored private var computed: Computed?
    @ObservationIgnored private var generation = 0

    /// Feeds new inputs; recomputes when they changed. The first computation of a small library runs synchronously
    /// so the first frame already has content; everything else on a background task.
    func update(_ newInputs: Inputs) {
        guard newInputs != inputs else { return }
        inputs = newInputs
        generation += 1
        let token = generation
        let previous = computed
        if lists.songs.isEmpty && lists.albums.isEmpty && newInputs.snapshot.songs.count < 1500 {
            let result = Self.compute(newInputs, previous: previous)
            computed = result
            lists = result.lists
            isComputing = false
            return
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.compute(newInputs, previous: previous)
            }.value
            guard let self, self.generation == token else { return }
            self.computed = result
            // Lists land without animation (a sort or filter tapped in an animated transaction would otherwise
            // animate every row of every page).
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.lists = result.lists
                self.isComputing = false
            }
        }
    }

    nonisolated static func compute(_ inputs: Inputs) -> Lists {
        compute(inputs, previous: nil).lists
    }

    nonisolated static func compute(_ inputs: Inputs, previous: Computed?) -> Computed {
        let snapshot = inputs.snapshot
        let filter = inputs.storageFilter
        // What the previous computation can still give: same library, and per list the same sort / filter.
        let old = previous.flatMap { $0.inputs.revision == inputs.revision ? $0 : nil }
        let sameFilter = old?.inputs.storageFilter == filter
        var visible: [Song]?
        func visibleSongs() -> [Song] {
            if let visible { return visible }
            let songs = filter == .all ? snapshot.songs : snapshot.songs.filter { LibrarySorting.matches($0, filter: filter) }
            visible = songs
            return songs
        }

        var lists = Lists()
        if let old, sameFilter, old.inputs.songSort == inputs.songSort {
            lists.songs = old.lists.songs
            lists.songIds = old.lists.songIds
        } else {
            lists.songs = LibrarySorting.sortSongs(visibleSongs(), by: inputs.songSort)
            lists.songIds = Set(lists.songs.map(\.id))
        }

        if let old, sameFilter, old.inputs.albumSort == inputs.albumSort {
            lists.albums = old.lists.albums
        } else {
            let albumIds = Set(visibleSongs().map(\.albumId))
            let albums = filter == .all ? snapshot.albums : snapshot.albums.filter { albumIds.contains($0.id) }
            lists.albums = LibrarySorting.sortAlbums(albums, by: inputs.albumSort)
        }

        if let old, sameFilter, old.inputs.artistSort == inputs.artistSort {
            lists.artists = old.lists.artists
        } else {
            let artistIds = Set(visibleSongs().flatMap { song in
                song.artists.isEmpty ? [song.artistId] : song.artists.map(\.id)
            })
            let artists = filter == .all ? snapshot.artists : snapshot.artists.filter { artistIds.contains($0.id) }
            lists.artists = LibrarySorting.sortArtists(artists, by: inputs.artistSort)
        }

        if let old, old.inputs.playlistSort == inputs.playlistSort {
            lists.playlists = old.lists.playlists
        } else {
            lists.playlists = LibrarySorting.sortPlaylists(snapshot.playlists, by: inputs.playlistSort)
        }

        if let old, sameFilter, old.inputs.likedSort == inputs.likedSort, old.inputs.likedAt == inputs.likedAt {
            lists.liked = old.lists.liked
            lists.likedIds = old.lists.likedIds
        } else {
            let liked = visibleSongs().filter(\.isFavorite)
            lists.liked = LibrarySorting.sortLikedSongs(liked, by: inputs.likedSort, likedAt: inputs.likedAt)
            lists.likedIds = Set(lists.liked.map(\.id))
        }

        // The tree depends on the library only; its sorted views on the folder sort.
        let tree = old?.tree ?? folderTree(snapshot.songs)
        if let old, old.inputs.folderSort == inputs.folderSort {
            lists.folders = old.lists.folders
            lists.folderPlaylists = old.lists.folderPlaylists
            lists.folderContents = old.lists.folderContents
            lists.folderRoots = old.lists.folderRoots
        } else {
            lists.folders = LibrarySorting.sortFolders(tree, by: inputs.folderSort)
            lists.folderPlaylists = LibrarySorting.sortFolders(flatten(tree), by: inputs.folderSort)
            lists.folderContents = folderContents(tree, sort: inputs.folderSort)
            lists.folderRoots = lists.folders.map(\.path)
        }
        return Computed(inputs: inputs, lists: lists, tree: tree)
    }

    /// Every folder of the tree by path, with its subfolders and own songs sorted as the Folders page shows them.
    nonisolated static func folderContents(_ tree: [MusicFolder], sort: SortOption) -> [String: FolderContents] {
        var contents: [String: FolderContents] = [:]
        func visit(_ folder: MusicFolder) {
            contents[folder.path] = FolderContents(subFolders: LibrarySorting.sortFolders(folder.subFolders, by: sort),
                                                   songs: folderSongs(folder.songs, sort: sort))
            for sub in folder.subFolders { visit(sub) }
        }
        for root in tree { visit(root) }
        return contents
    }

    /// The folder tree from each song's parent directory. Roots are the top-level directories of the song paths
    /// (stage 6 passes the real folder sources).
    nonisolated static func folderTree(_ songs: [Song]) -> [MusicFolder] {
        let rows = songs.compactMap { song -> FolderSongRow? in
            let parent = (song.path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != "/" else { return nil }
            return FolderSongRow(id: song.id, parentDirectoryPath: parent, title: song.title,
                                 albumArtUriString: song.albumArtUriString)
        }
        let roots = Set(rows.compactMap { row -> String? in
            let parts = row.parentDirectoryPath.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = parts.first else { return nil }
            return (row.parentDirectoryPath.hasPrefix("/") ? "/" : "") + first
        }).sorted()
        let tree = FolderTreeBuilder.buildFolderTreeForRoots(folderSongs: rows, selectedRootPaths: roots)
        let byId = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return tree.map { attachSongs($0, byId) }
    }

    /// `FolderTreeBuilder` keeps lightweight songs; put the library's full songs back in.
    private nonisolated static func attachSongs(_ folder: MusicFolder, _ byId: [String: Song]) -> MusicFolder {
        MusicFolder(path: folder.path, name: folder.name, songs: folder.songs.map { byId[$0.id] ?? $0 },
                    subFolders: folder.subFolders.map { attachSongs($0, byId) })
    }

    /// Android `flattenFolders`: every folder that holds songs itself, depth first.
    nonisolated static func flatten(_ folders: [MusicFolder]) -> [MusicFolder] {
        folders.flatMap { folder in (folder.songs.isEmpty ? [] : [folder]) + flatten(folder.subFolders) }
    }

    /// Android `MusicFolder.collectAllSongs`.
    nonisolated static func allSongs(_ folder: MusicFolder) -> [Song] {
        folder.songs + folder.subFolders.flatMap(allSongs)
    }

    /// Finds a folder by path anywhere in the tree.
    nonisolated static func folder(at path: String, in folders: [MusicFolder]) -> MusicFolder? {
        for folder in folders {
            if folder.path == path { return folder }
            if let hit = Self.folder(at: path, in: folder.subFolders) { return hit }
        }
        return nil
    }

    /// What Select all adds in an open folder: the folder's own songs in the tree's order (Android
    /// `currentFolder?.songs`), whatever the folder sort — not `folderContents`, the order the page shows them in.
    /// Selection order is play / queue order and the rows' badge numbers.
    nonisolated static func selectAllSongIds(inFolder path: String, of folders: [MusicFolder]) -> [String]? {
        folder(at: path, in: folders)?.songs.map(\.id)
    }

    /// Android `sortSongsForFolderView`: title (lower case), artist, id; Z-A only for "Name (Z-A)". Each song's
    /// lower-cased title and artist are computed once (not twice per comparison); the order is the same.
    nonisolated static func folderSongs(_ songs: [Song], sort: SortOption) -> [Song] {
        guard songs.count > 1 else { return songs }
        let descending = sort == .folderNameZA
        let keyed = songs.map { (title: $0.title.lowercased(), artist: $0.artist.lowercased(), song: $0) }
        return keyed.sorted { a, b in
            if a.title != b.title { return descending ? a.title > b.title : a.title < b.title }
            if a.artist != b.artist { return a.artist < b.artist }
            return a.song.id < b.song.id
        }.map(\.song)
    }

    /// The first `limit` songs of `allSongs(folder)` (a folder playlist's collage), without collecting the rest.
    nonisolated static func firstSongs(_ folder: MusicFolder, limit: Int) -> [Song] {
        var result: [Song] = []
        func visit(_ folder: MusicFolder) {
            for song in folder.songs {
                guard result.count < limit else { return }
                result.append(song)
            }
            for sub in folder.subFolders {
                guard result.count < limit else { return }
                visit(sub)
            }
        }
        visit(folder)
        return result
    }
}

// MARK: - Formatting (Android `utils/Formats.kt`, `formatSongCount`)

nonisolated enum LibraryFormat {
    /// `song_count_singular` / `song_count_plural`: "1 Song", "12 Songs".
    static func songCount(_ count: Int) -> String { count == 1 ? "1 Song" : "\(count) Songs" }

    /// `formatDuration`: mm:ss, or hh:mm:ss past an hour; "00:00" for nothing.
    static func duration(_ milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "00:00" }
        let total = milliseconds / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// `formatTotalDuration`: "1 h 05 min" / "42 min".
    static func totalDuration(_ songs: [Song]) -> String {
        let total = songs.reduce(Int64(0)) { $0 + $1.duration }
        let hours = total / 3_600_000, minutes = (total / 60_000) % 60
        return hours > 0 ? String(format: "%d h %02d min", hours, minutes) : "\(minutes) min"
    }
}
