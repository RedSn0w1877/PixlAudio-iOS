import Foundation
import Observation
import PixlModel

/// The library as the UI sees it: the current `LibrarySnapshot` plus lookups built once per snapshot.
/// Sorting/grouping for a screen is cached by that screen's owner (stage 7a) — never computed in `body`.
@Observable
final class LibraryStore {
    private(set) var snapshot: LibrarySnapshot = .empty
    /// True until the first snapshot (cache or store) arrived.
    private(set) var isLoading = true
    private(set) var lastImportProgress: LibraryImportProgress?

    @ObservationIgnored private(set) var songsById: [String: Song] = [:]
    @ObservationIgnored private(set) var albumsById: [Int64: Album] = [:]
    @ObservationIgnored private(set) var artistsById: [Int64: Artist] = [:]
    @ObservationIgnored private(set) var playlistsById: [String: Playlist] = [:]

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
    func album(id: Int64) -> Album? { albumsById[id] }
    func artist(id: Int64) -> Artist? { artistsById[id] }
    func playlist(id: String) -> Playlist? { playlistsById[id] }

    /// Launch: show the cached snapshot immediately, then the store's (both off the main thread).
    func load() async {
        guard let loader else { isLoading = false; return }
        let cached = await Task.detached(priority: .userInitiated) { loader.loadCached() }.value
        if let cached { apply(cached) }
        if let fresh = try? await loader.loadFromStore(previous: cached) {
            apply(fresh)
        }
        isLoading = false
    }

    /// Runs the importer, then reloads from the store.
    func refresh(mode: LibraryImportMode = .incremental) async throws {
        guard let importer, let loader else { return }
        _ = try await importer.importLibrary(mode: mode) { progress in
            Task { @MainActor [weak self] in self?.lastImportProgress = progress }
        }
        apply(try await loader.loadFromStore(previous: snapshot))
    }

    /// Re-reads the store after another writer changed it (stage 12: Spotify rows merged into the library).
    func reloadFromStore() async {
        guard let loader, let fresh = try? await loader.loadFromStore(previous: snapshot) else { return }
        apply(fresh)
    }

    func apply(_ newSnapshot: LibrarySnapshot) {
        guard newSnapshot != snapshot || isLoading else { return }
        songsById = Dictionary(newSnapshot.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        albumsById = Dictionary(newSnapshot.albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        artistsById = Dictionary(newSnapshot.artists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        playlistsById = Dictionary(newSnapshot.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        snapshot = newSnapshot
    }
}
