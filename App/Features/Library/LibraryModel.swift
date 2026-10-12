import Foundation
import Observation
import PixlLibrary
import PixlModel
import SwiftUI

/// What the Library tabs show, derived from the snapshot and the preferences (Android `LibraryViewModel` paging
/// flows + `LibraryStateHolder` sorting): sorted songs, albums, artists, playlists and liked songs. Recomputed off
/// the main thread when an input changes, never in `body`.
///
/// Transition performance: only the first computation of a small library runs synchronously (so the first frame
/// has content); every later one — a sort or filter change from a sheet, a rescan — runs off the main actor while
/// the previous lists stay on screen, and lands without animation. Each list is memoised by the inputs it depends
/// on, so a change reuses the other lists' arrays unchanged (their pages see identical input and skip their
/// bodies). Inputs compare the library by revision.
@Observable
final class LibraryModel {
    nonisolated struct Inputs: Equatable, Sendable {
        var snapshot: LibrarySnapshot
        var songSort: SortOption
        var albumSort: SortOption
        var artistSort: SortOption
        var playlistSort: SortOption
        var likedSort: SortOption
        var storageFilter: StorageFilter
        var likedAt: [String: Int64]
        /// `LibraryStore.revision` of `snapshot`: what `==` compares instead of the snapshot itself.
        var revision: Int = 0
        /// Settings › Library › Min tracks per album (Android `getPaginatedAlbums(minTracks)`): smaller albums are
        /// left out of the Albums tab.
        var minTracksPerAlbum: Int = 1

        static func == (a: Inputs, b: Inputs) -> Bool {
            a.revision == b.revision && a.songSort == b.songSort && a.albumSort == b.albumSort
                && a.artistSort == b.artistSort && a.playlistSort == b.playlistSort
                && a.likedSort == b.likedSort && a.storageFilter == b.storageFilter && a.likedAt == b.likedAt
                && a.minTracksPerAlbum == b.minTracksPerAlbum
        }
    }

    nonisolated struct Lists: Sendable {
        var songs: [Song] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []
        var liked: [Song] = []
        /// Ids of `songs` / `liked` (the locate button asks "is the current song in this list?").
        var songIds: Set<String> = []
        var likedIds: Set<String> = []

        static let empty = Lists()
    }

    /// A computation and what it was computed from (the next one reuses what still applies).
    nonisolated struct Computed: Sendable {
        var inputs: Inputs
        var lists: Lists
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
        // What the previous computation can still give. Each list is reused when everything it is derived from is
        // equal: the same revision proves it at once; otherwise the source arrays are compared (cheap next to a sort),
        // so a playlist edit or an artist picture re-sorts only that list. A heart tap changes songs in one field
        // (`isFavorite`), which no sort reads: the sorted lists are patched by id instead of sorted again.
        let old = previous
        let sameRevision = old?.inputs.revision == inputs.revision
        let before = old?.inputs.snapshot
        let songsSame = sameRevision || (before.map { $0.songs == snapshot.songs } ?? false)
        let favoriteChanges: [String: Song]? = (songsSame || before == nil) ? nil
            : favoriteOnlyChanges(from: before!.songs, to: snapshot.songs)
        let songsUsable = songsSame || favoriteChanges != nil
        let albumsSame = sameRevision || (before.map { $0.albums == snapshot.albums } ?? false)
        let artistsSame = sameRevision || (before.map { $0.artists == snapshot.artists } ?? false)
        let playlistsSame = sameRevision || (before.map { $0.playlists == snapshot.playlists } ?? false)
        let sameFilter = old?.inputs.storageFilter == filter
        var visible: [Song]?
        func visibleSongs() -> [Song] {
            if let visible { return visible }
            let songs = filter == .all ? snapshot.songs : snapshot.songs.filter { LibrarySorting.matches($0, filter: filter) }
            visible = songs
            return songs
        }

        var lists = Lists()
        if let old, sameFilter, songsUsable, old.inputs.songSort == inputs.songSort {
            lists.songs = songsSame ? old.lists.songs : patched(old.lists.songs, favoriteChanges ?? [:])
            lists.songIds = old.lists.songIds
        } else {
            lists.songs = LibrarySorting.sortSongs(visibleSongs(), by: inputs.songSort)
            lists.songIds = Set(lists.songs.map(\.id))
        }

        // Albums and artists read songs only to filter by storage: a field change cannot move a song in or out.
        if let old, sameFilter, albumsSame, songsUsable || filter == .all, old.inputs.albumSort == inputs.albumSort,
           old.inputs.minTracksPerAlbum == inputs.minTracksPerAlbum {
            lists.albums = old.lists.albums
        } else {
            let albumIds = Set(visibleSongs().map(\.albumId))
            var albums = filter == .all ? snapshot.albums : snapshot.albums.filter { albumIds.contains($0.id) }
            let minTracks = inputs.minTracksPerAlbum
            if minTracks > 1 { albums = albums.filter { $0.songCount >= minTracks } }
            lists.albums = LibrarySorting.sortAlbums(albums, by: inputs.albumSort)
        }

        if let old, sameFilter, artistsSame, songsUsable || filter == .all, old.inputs.artistSort == inputs.artistSort {
            lists.artists = old.lists.artists
        } else {
            let artistIds = Set(visibleSongs().flatMap { song in
                song.artists.isEmpty ? [song.artistId] : song.artists.map(\.id)
            })
            let artists = filter == .all ? snapshot.artists : snapshot.artists.filter { artistIds.contains($0.id) }
            lists.artists = LibrarySorting.sortArtists(artists, by: inputs.artistSort)
        }

        if let old, playlistsSame, old.inputs.playlistSort == inputs.playlistSort {
            lists.playlists = old.lists.playlists
        } else {
            lists.playlists = LibrarySorting.sortPlaylists(snapshot.playlists, by: inputs.playlistSort)
        }

        if let old, sameFilter, songsSame, old.inputs.likedSort == inputs.likedSort, old.inputs.likedAt == inputs.likedAt {
            lists.liked = old.lists.liked
            lists.likedIds = old.lists.likedIds
        } else {
            let liked = visibleSongs().filter(\.isFavorite)
            lists.liked = LibrarySorting.sortLikedSongs(liked, by: inputs.likedSort, likedAt: inputs.likedAt)
            lists.likedIds = Set(lists.liked.map(\.id))
        }

        return Computed(inputs: inputs, lists: lists)
    }

    /// The songs of `new` that differ from `old` in `isFavorite` alone, by id; nil when anything else differs (a song
    /// added, removed, moved or edited), so the caller falls back to a full computation.
    nonisolated static func favoriteOnlyChanges(from old: [Song], to new: [Song]) -> [String: Song]? {
        guard old.count == new.count else { return nil }
        var changed: [String: Song] = [:]
        for index in old.indices {
            let before = old[index], after = new[index]
            guard before.id == after.id else { return nil }
            if before == after { continue }
            var probe = before
            probe.isFavorite = after.isFavorite
            guard probe == after else { return nil }
            changed[after.id] = after
        }
        return changed
    }

    /// `songs` with the changed songs swapped in, order unchanged.
    nonisolated static func patched(_ songs: [Song], _ changed: [String: Song]) -> [Song] {
        guard !changed.isEmpty else { return songs }
        return songs.map { changed[$0.id] ?? $0 }
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
