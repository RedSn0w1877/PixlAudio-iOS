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
    /// Bumped with `revision` for everything except artist-picture updates (`updateArtists`): what screens that read
    /// songs, albums and playlists, but never an artist's picture, key their recomputation on (Home).
    private(set) var songsRevision = 0
    /// True until the first snapshot (cache or store) arrived.
    private(set) var isLoading = true
    private(set) var lastImportProgress: LibraryImportProgress?
    /// Why the last scan failed, until it is dismissed or a scan succeeds (Active jobs shows it as a failed row).
    private(set) var scanFailure: String?
    /// Songs per album, artist and genre for `revision`, or nil / an older revision while it is being built
    /// (callers then filter `songs` as before). Read it through `detailIndexIfCurrent`.
    private(set) var detailIndex: LibraryDetailIndex?

    @ObservationIgnored private(set) var songsById: [String: Song] = [:]
    @ObservationIgnored private(set) var albumsById: [Int64: Album] = [:]
    @ObservationIgnored private(set) var artistsById: [Int64: Artist] = [:]
    @ObservationIgnored private(set) var playlistsById: [String: Playlist] = [:]
    @ObservationIgnored private var detailIndexTask: Task<Void, Never>?
    /// Launch: the cache decode (`beginCachedLoad`) and the snapshot it installed (what the store is compared with).
    @ObservationIgnored private var cachedLoad: Task<LoadedLibrary?, Never>?
    @ObservationIgnored private var cachedAtLaunch: LibrarySnapshot?
    /// The scans that are running (several callers can ask at once), by a number only this store knows: what
    /// "Cancel" cancels, and what decides whether a late progress report still means anything.
    @ObservationIgnored private var scanTasks: [Int: Task<Void, any Error>] = [:]
    @ObservationIgnored private var nextScanToken = 0
    /// A cancelled scan is still unwinding: its late progress reports are dropped.
    @ObservationIgnored private var dropsScanProgress = false

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
        await installCached()
        await reconcileWithStore()
    }

    /// Launch, first half: starts decoding the snapshot cache off the main actor right away (`installCached` awaits it),
    /// so it runs alongside the services that start on the main actor.
    func beginCachedLoad() {
        guard cachedLoad == nil, let loader else { return }
        cachedLoad = Task.detached(priority: .userInitiated) { await loader.loadCachedInBackground() }
    }

    /// Launch, first half: installs the cached snapshot (nothing heavy: a plist decode off the main actor). Returns
    /// whether there was one; `reconcileWithStore()` completes the load. With a cache the library is on screen, and the
    /// restored queue can be built from it, before the store's full read.
    @discardableResult
    func installCached() async -> Bool {
        guard loader != nil else { return false }
        beginCachedLoad()
        let cached = await cachedLoad?.value
        cachedLoad = nil
        cachedAtLaunch = cached?.snapshot
        if let cached { install(cached.snapshot, lookups: cached.lookups) }
        return cached != nil
    }

    /// Launch, second half: reads the store (off the main actor) and applies it when it differs from the cache.
    func reconcileWithStore() async {
        let cachedSnapshot = cachedAtLaunch
        cachedAtLaunch = nil
        guard let loader else { isLoading = false; return }
        if let fresh = try? await loader.loadFromStoreInBackground(previous: cachedSnapshot) {
            // The store's snapshot equals the cached one on most launches: nothing to apply then.
            if fresh.changed || cachedSnapshot == nil { install(fresh.snapshot, lookups: fresh.lookups) }
        }
        isLoading = false
    }

    /// Runs the importer, then reloads from the store — unless the scan wrote nothing (the usual launch and foreground
    /// rescan), when the store still holds what the snapshot shows. A scan that is running when the app is switched
    /// away gets iOS's extra ~30 seconds to finish (`BackgroundGrace`); a longer one is suspended and carries on when
    /// the app returns (the scan writes its result once at the end, so nothing is half-saved).
    ///
    /// However it ends — done, failed or cancelled — the scan's progress is cleared (a scan that threw used to leave
    /// "40 %" behind, so Home's jobs button stayed lit for ever), a failure is kept as `scanFailure` with a short reason,
    /// and `cancelScans()` stops the work for real.
    func refresh(mode: LibraryImportMode = .incremental) async throws {
        guard importer != nil, loader != nil else { return }
        nextScanToken += 1
        let token = nextScanToken
        dropsScanProgress = false
        let work = Task { try await self.runScan(mode: mode) }
        scanTasks[token] = work
        defer {
            scanTasks[token] = nil
            if scanTasks.isEmpty {
                lastImportProgress = nil
                dropsScanProgress = false
            }
        }
        do {
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            scanFailure = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let code = (error as? URLError)?.code.rawValue
            scanFailure = JobFailureText.describe(error.localizedDescription, urlErrorCode: code)
            throw error
        }
    }

    private func runScan(mode: LibraryImportMode) async throws {
        guard let importer, let loader else { return }
        try await BackgroundGrace.run("Library scan") {
            let summary = try await importer.importLibrary(mode: mode) { progress in
                Task { @MainActor [weak self] in
                    guard let self, !self.scanTasks.isEmpty, !self.dropsScanProgress,
                          self.lastImportProgress != progress else { return }
                    self.lastImportProgress = progress
                }
            }
            if summary.isNoOp, !isLoading { return }
            let base = snapshot
            apply(try await loader.loadFromStoreInBackground(previous: base), base: base)
        }
    }

    /// A scan is running (what Active jobs shows as "Library sync").
    var isScanning: Bool { !scanTasks.isEmpty }

    /// "Cancel": every running scan is cancelled (the importer checks between files), and its progress goes at once.
    func cancelScans() {
        for task in scanTasks.values { task.cancel() }
        dropsScanProgress = !scanTasks.isEmpty
        lastImportProgress = nil
    }

    /// "Dismiss" on a failed scan.
    func dismissScanFailure() {
        scanFailure = nil
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
    /// `addedAlbums` / `addedArtists`: rows the edit appended to the snapshot (a streamed song's album and artist).
    func applyEdit(_ newSnapshot: LibrarySnapshot, changedSongs: [Song] = [], removedSongIds: Set<String> = [],
                   addedAlbums: [Album] = [], addedArtists: [Artist] = []) {
        // A heart tap changes one field of a few songs: the detail index is patched, not rebuilt.
        let favoritesOnly = removedSongIds.isEmpty && !changedSongs.isEmpty
            && newSnapshot.songs.count == snapshot.songs.count
            && changedSongs.allSatisfy { song in
                guard var before = songsById[song.id] else { return false }
                before.isFavorite = song.isFavorite
                return before == song
            }
        let previousRevision = revision
        for song in changedSongs { songsById[song.id] = song }
        for id in removedSongIds { songsById[id] = nil }
        for album in addedAlbums { albumsById[album.id] = album }
        for artist in addedArtists { artistsById[artist.id] = artist }
        if newSnapshot.playlists != snapshot.playlists {
            playlistsById = Dictionary(newSnapshot.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        snapshot = newSnapshot
        revision &+= 1
        songsRevision &+= 1
        if favoritesOnly, let base = detailIndex, base.revision == previousRevision {
            patchDetailIndex(base, changed: Dictionary(changedSongs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }))
        } else {
            rebuildDetailIndex()
        }
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
        let previousRevision = revision
        revision &+= 1
        // The songs did not change, so a current index stays valid: it is re-stamped, not rebuilt.
        if let index = detailIndex, index.revision == previousRevision {
            detailIndex = index.restamped(revision: revision)
        } else {
            rebuildDetailIndex()
        }
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

    private func patchDetailIndex(_ base: LibraryDetailIndex, changed: [String: Song]) {
        detailIndexTask?.cancel()
        let revision = self.revision
        detailIndexTask = Task { [weak self] in
            let index = await LibraryDetailIndex.patchedInBackground(base, changed: changed, revision: revision)
            guard let self, !Task.isCancelled, self.revision == revision else { return }
            self.detailIndex = index
        }
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
