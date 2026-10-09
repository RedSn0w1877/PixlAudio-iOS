import Foundation
import PixlModel

nonisolated enum LibraryImportMode: Sendable, Equatable {
    /// Diff against the stored library (foreground, pull to refresh).
    case incremental
    /// Re-read everything (settings › rescan, delimiter changes).
    case full
}

/// Progress of a scan, for the jobs sheet and the library's sync bar (Android `SyncProgressBar`).
nonisolated struct LibraryImportProgress: Sendable, Equatable {
    var phase: String
    var completed: Int
    var total: Int

    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

nonisolated struct LibraryImportSummary: Sendable, Equatable {
    var added: Int
    var updated: Int
    var removed: Int
    /// Album, artist and artist-link rows written or removed (songs are counted above).
    var relatedChanges = 0

    /// Nothing was written: the store still holds exactly what it held before the scan.
    var isNoOp: Bool { added == 0 && updated == 0 && removed == 0 && relatedChanges == 0 }
}

/// The seam for building the library. Stage 6 implements it (folder bookmarks, the Documents folder, the device
/// music library) and writes through `PersistenceActor`; `LibraryStore.reload()` then picks up the new snapshot.
nonisolated protocol LibraryImporting: Sendable {
    func importLibrary(mode: LibraryImportMode,
                       progress: @escaping @Sendable (LibraryImportProgress) -> Void) async throws -> LibraryImportSummary
}

/// Writes the demo library into the store (UI tests, previews, and first launches before stage 6 lands).
nonisolated struct DemoLibraryImporter: LibraryImporting {
    let persistence: PersistenceActor

    func importLibrary(mode: LibraryImportMode,
                       progress: @escaping @Sendable (LibraryImportProgress) -> Void) async throws -> LibraryImportSummary {
        let snapshot = DemoLibrary.snapshot
        progress(LibraryImportProgress(phase: "Demo", completed: 0, total: snapshot.songs.count))
        try await persistence.replaceLibrary(with: snapshot)
        progress(LibraryImportProgress(phase: "Demo", completed: snapshot.songs.count, total: snapshot.songs.count))
        return LibraryImportSummary(added: snapshot.songs.count, updated: 0, removed: 0)
    }
}
