import Foundation
import Observation
import PixlModel

/// The library as the UI sees it: the current `LibrarySnapshot` plus lookups built once per snapshot.
/// Sorting/grouping for a screen is cached by that screen's owner (stage 7a) — never computed in `body`.
///
/// Transition performance: `revision` changes with every snapshot, so screens key their work on it instead of
/// comparing the whole library (each comparison of two 5,000-song snapshots walked every field on the main actor);
/// snapshots from the store arrive with their lookups built off the main actor; edits patch the lookups instead of
/// rebuilding them; and `detailIndex` (songs per album / artist / genre) is built off the main actor after each
/// change for the detail pages.
@Observable
final class LibraryStore {
    private(set) var snapshot: LibrarySnapshot = .empty
    /// Bumped whenever `snapshot` changes.
    private(set) var revision = 0
    /// True until the first snapshot (cache or store) arrived.
    private(set) var isLoading = true
    private(set) var lastImportProgress: LibraryImportProgress?
    /// Songs per album, artist and genre for `revision`, or nil / an older revision while it is being built
    /// (callers then filter `songs` as before). Read it through `detailIndexIfCurrent`.
    private(set) var detailIndex: LibraryDetailIndex?

    @ObservationIgnored private(set) var songsById: [String: Song] = [:]
    @ObservationIgnored private(set) var albumsById: [Int64: Album] = [:]
    @ObservationIgnored private(set) var artistsById: [Int64: Artist] = [:]
    @ObservationIgnored private(set) var playlistsById: [String: Playlist] = [:]
    @ObservationIgnored private var detailIndexTask: Task<Void, Never>?

    private let loader: SnapshotLoader?
    private let importer: (any LibraryImporting)?

    init(loader: SnapshotLoader?, importer: (any LibraryImporting)?) {
        self.loader = loader
        self.importer = importer
    }

    /// A store holding a fixed snapshot (previews, unit tests).
    convenience init(snapshot: LibrarySnapshot) {
        self.init(loader: nil, importer: nil)
        apply(snapshot)
    }

    var songs: [Song] { snapshot.songs }
    var albums: [Album] { snapshot.albums }
    var artists: [Artist] { snapshot.artists }
    var playlists: [Playlist] { snapshot.playlists }

    func song(id: String) -> Song? { songsById[id] }

    /// `song(id:)` for a view's `body`: also reads `revision`, so the view redraws after the next edit (the lookup
    /// itself is `@ObservationIgnored` and patched in place by `applyEdit`). Use it in small views that show a field an
    /// edit changes in place, such as the favourite heart; keep `song(id:)` in actions and long lists, where a
    /// dependency on every revision would redraw each visible row.
    func observedSong(id: String) -> Song? {
        _ = revision
        return songsById[id]
    }

    func album(id: Int64) -> Album? { albumsById[id] }
    func artist(id: Int64) -> Artist? { artistsById[id] }
    func playlist(id: String) -> Playlist? { playlistsById[id] }

    /// The detail index when it matches the current snapshot.
    var detailIndexIfCurrent: LibraryDetailIndex? {
        guard let detailIndex, detailIndex.revision == revision else { return nil }
        return detailIndex
    }

    /// Launch: show the cached snapshot immediately, then the store's (both off the main thread).
    func load() async {
        guard let loader else { isLoading = false; return }
        let cached = await loader.loadCachedInBackground()
        if let cached { install(cached.snapshot, lookups: cached.lookups) }
        if let fresh = try? await loader.loadFromStoreInBackground(previous: cached?.snapshot) {
            // The store's snapshot equals the cached one on most launches: nothing to apply then.
            if fresh.changed || cached == nil { install(fresh.snapshot, lookups: fresh.lookups) }
        }
        isLoading = false
    }

    /// Runs the importer, then reloads from the store.
    func refresh(mode: LibraryImportMode = .incremental) async throws {
        guard let importer, let loader else { return }
        _ = try await importer.importLibrary(mode: mode) { progress in
            Task { @MainActor [weak self] in
                guard let self, self.lastImportProgress != progress else { return }
                self.lastImportProgress = progress
            }
        }
        let base = snapshot
        apply(try await loader.loadFromStoreInBackground(previous: base), base: base)
    }

    /// Re-reads the store after another writer changed it (stage 12: Spotify rows merged into the library).
    func reloadFromStore() async {
        let base = snapshot
        guard let loader, let fresh = try? await loader.loadFromStoreInBackground(previous: base) else { return }
        apply(fresh, base: base)
    }

    /// Applies a snapshot loaded (and compared with `base`) off the main actor. When nothing replaced `base` in the
    /// meantime — an O(1) check, the arrays still share their storage — the off-main comparison decides; otherwise
    /// this falls back to `apply(_:)`'s comparison.
    private func apply(_ loaded: LoadedLibrary, base: LibrarySnapshot) {
        if snapshot == base {
            if loaded.changed { install(loaded.snapshot, lookups: loaded.lookups) }
        } else {
            apply(loaded.snapshot)
        }
    }

    func apply(_ newSnapshot: LibrarySnapshot) {
        guard newSnapshot != snapshot || isLoading else { return }
        install(newSnapshot, lookups: LibraryLookups(newSnapshot))
    }

    /// An edit of the in-memory library (favourites, playlists, tags, removals): the caller knows the snapshot
    /// changed and which songs did, so the lookups are patched instead of rebuilt and nothing is compared.
    func applyEdit(_ newSnapshot: LibrarySnapshot, changedSongs: [Song] = [], removedSongIds: Set<String> = []) {
        for song in changedSongs { songsById[song.id] = song }
        for id in removedSongIds { songsById[id] = nil }
        if newSnapshot.playlists != snapshot.playlists {
            playlistsById = Dictionary(newSnapshot.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        snapshot = newSnapshot
        revision &+= 1
        rebuildDetailIndex()
    }

    /// Replaces artists by id — their pictures (Deezer, a custom image) — patching the snapshot and the artist lookup
    /// without rebuilding the others.
    func updateArtists(_ updated: [Artist]) {
        guard !updated.isEmpty else { return }
        let byId = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var newSnapshot = snapshot
        for index in newSnapshot.artists.indices {
            if let artist = byId[newSnapshot.artists[index].id] { newSnapshot.artists[index] = artist }
        }
        for artist in updated { artistsById[artist.id] = artist }
        snapshot = newSnapshot
        revision &+= 1
        rebuildDetailIndex()
    }

    /// Rewrites the launch cache with the current snapshot, off the main actor (after an edit made outside
    /// `LibraryEditor`).
    func writeSnapshotCache() {
        guard let loader else { return }
        let snapshot = self.snapshot
        Task.detached(priority: .utility) { loader.writeCache(snapshot) }
    }

    private func install(_ newSnapshot: LibrarySnapshot, lookups: LibraryLookups) {
        songsById = lookups.songsById
        albumsById = lookups.albumsById
        artistsById = lookups.artistsById
        playlistsById = lookups.playlistsById
        snapshot = newSnapshot
        revision &+= 1
        rebuildDetailIndex()
    }

    private func rebuildDetailIndex() {
        detailIndexTask?.cancel()
        let songs = snapshot.songs, revision = self.revision
        detailIndexTask = Task { [weak self] in
            let index = await LibraryDetailIndex.buildInBackground(songs, revision: revision)
            guard let self, !Task.isCancelled, self.revision == revision else { return }
            self.detailIndex = index
        }
    }
}
