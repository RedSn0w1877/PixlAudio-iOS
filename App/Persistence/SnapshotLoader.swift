import Foundation
import PixlModel

/// The whole library as value types — what the UI works from (architecture §2: SwiftData is a store only).
nonisolated struct LibrarySnapshot: Sendable, Codable, Equatable {
    var songs: [Song]
    var albums: [Album]
    var artists: [Artist]
    var playlists: [Playlist]

    static let empty = LibrarySnapshot(songs: [], albums: [], artists: [], playlists: [])

    var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

/// Launch path for the library: read the binary-plist snapshot cache first (fast, no SwiftData), then reconcile
/// from `PersistenceActor` in the background and rewrite the cache. Nothing heavy on the main thread.
nonisolated struct SnapshotLoader: Sendable {
    let persistence: PersistenceActor
    /// `Application Support/library-snapshot.plist`; nil disables the cache (UI tests).
    let cacheURL: URL?

    static func defaultCacheURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("library-snapshot.plist")
    }

    /// The cached snapshot, if any (fast path for the first frame).
    func loadCached() -> LibrarySnapshot? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? PropertyListDecoder().decode(LibrarySnapshot.self, from: data)
    }

    /// The authoritative snapshot from SwiftData; refreshes the cache when it changed.
    func loadFromStore(previous: LibrarySnapshot?) async throws -> LibrarySnapshot {
        try await loadFromStoreInBackground(previous: previous).snapshot
    }

    /// `loadFromStore` with everything after the fetch off the main actor too: the comparison with `previous`, the
    /// cache write (a binary plist of the whole library) and the store's by-id lookups. Under approachable
    /// concurrency a plain `nonisolated async` method runs on its caller's actor, so this one is `@concurrent`.
    @concurrent
    func loadFromStoreInBackground(previous: LibrarySnapshot?) async throws -> LoadedLibrary {
        let snapshot = try await persistence.loadLibrarySnapshot()
        let changed = snapshot != previous
        if changed { writeCache(snapshot) }
        return LoadedLibrary(snapshot: snapshot, lookups: LibraryLookups(snapshot), changed: changed)
    }

    /// The cached snapshot and its lookups, built off the main actor.
    @concurrent
    func loadCachedInBackground() async -> LoadedLibrary? {
        guard let cached = loadCached() else { return nil }
        return LoadedLibrary(snapshot: cached, lookups: LibraryLookups(cached), changed: true)
    }

    func writeCache(_ snapshot: LibrarySnapshot) {
        guard let cacheURL else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

/// A snapshot loaded off the main actor with its lookups, and whether it differs from the one it was compared with.
nonisolated struct LoadedLibrary: Sendable {
    let snapshot: LibrarySnapshot
    let lookups: LibraryLookups
    let changed: Bool
}
