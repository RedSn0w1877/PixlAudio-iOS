import Foundation
import Observation
import PixlLibrary
import PixlModel

/// What the Library tabs show, derived from the snapshot and the preferences (Android `LibraryViewModel` paging
/// flows + `LibraryStateHolder` sorting): sorted and storage-filtered songs, albums, artists, playlists, liked songs
/// and the folder tree. Recomputed off the main thread when an input changes, never in `body`.
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

        static let empty = Lists()
    }

    private(set) var lists = Lists.empty
    /// True until the first computation finished.
    private(set) var isComputing = true

    @ObservationIgnored private var inputs: Inputs?
    @ObservationIgnored private var generation = 0

    /// Feeds new inputs; recomputes when they changed. Small libraries are computed synchronously so the first
    /// frame already has content; large ones on a background task.
    func update(_ newInputs: Inputs) {
        guard newInputs != inputs else { return }
        inputs = newInputs
        generation += 1
        let token = generation
        if newInputs.snapshot.songs.count < 1500 {
            lists = Self.compute(newInputs)
            isComputing = false
            return
        }
        Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) { Self.compute(newInputs) }.value
            guard let self, self.generation == token else { return }
            self.lists = computed
            self.isComputing = false
        }
    }

    nonisolated static func compute(_ inputs: Inputs) -> Lists {
        let snapshot = inputs.snapshot
        let filter = inputs.storageFilter
        let visibleSongs = filter == .all ? snapshot.songs : snapshot.songs.filter { LibrarySorting.matches($0, filter: filter) }
        var lists = Lists()
        lists.songs = LibrarySorting.sortSongs(visibleSongs, by: inputs.songSort)

        let albumIds = Set(visibleSongs.map(\.albumId))
        let albums = filter == .all ? snapshot.albums : snapshot.albums.filter { albumIds.contains($0.id) }
        lists.albums = LibrarySorting.sortAlbums(albums, by: inputs.albumSort)

        let artistIds = Set(visibleSongs.flatMap { song in song.artists.isEmpty ? [song.artistId] : song.artists.map(\.id) })
        let artists = filter == .all ? snapshot.artists : snapshot.artists.filter { artistIds.contains($0.id) }
        lists.artists = LibrarySorting.sortArtists(artists, by: inputs.artistSort)

        lists.playlists = LibrarySorting.sortPlaylists(snapshot.playlists, by: inputs.playlistSort)

        let liked = visibleSongs.filter(\.isFavorite)
        lists.liked = LibrarySorting.sortLikedSongs(liked, by: inputs.likedSort, likedAt: inputs.likedAt)

        let tree = folderTree(snapshot.songs)
        lists.folders = LibrarySorting.sortFolders(tree, by: inputs.folderSort)
        lists.folderPlaylists = LibrarySorting.sortFolders(flatten(tree), by: inputs.folderSort)
        return lists
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

    /// Android `sortSongsForFolderView`: title (lower case), artist, id; Z-A only for "Name (Z-A)".
    nonisolated static func folderSongs(_ songs: [Song], sort: SortOption) -> [Song] {
        let descending = sort == .folderNameZA
        return songs.sorted { a, b in
            let ta = a.title.lowercased(), tb = b.title.lowercased()
            if ta != tb { return descending ? ta > tb : ta < tb }
            let aa = a.artist.lowercased(), ab = b.artist.lowercased()
            if aa != ab { return aa < ab }
            return a.id < b.id
        }
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
