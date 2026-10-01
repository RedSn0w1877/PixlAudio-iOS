import Foundation
import Synchronization

/// Keeps the security scope of every resolved music folder open for the life of the process, so playback,
/// artwork and tag reads of its files work at any time (architecture §2: "keep security scope open per root").
/// One entry per folder source; `release` closes it when the user removes the folder.
nonisolated final class FolderAccessRegistry: Sendable {
    static let shared = FolderAccessRegistry()

    private nonisolated struct Entry {
        var url: URL
        var isScoped: Bool
    }

    private let entries = Mutex<[String: Entry]>([:])

    /// Opens (once) the scope of `url` for source `id`; reopens it when the bookmark now resolves elsewhere.
    @discardableResult
    func open(id: String, url: URL) -> Bool {
        entries.withLock { entries in
            if let existing = entries[id] {
                if existing.url == url { return existing.isScoped }
                if existing.isScoped { existing.url.stopAccessingSecurityScopedResource() }
            }
            let scoped = url.startAccessingSecurityScopedResource()
            entries[id] = Entry(url: url, isScoped: scoped)
            return scoped
        }
    }

    func release(id: String) {
        entries.withLock { entries in
            if let entry = entries.removeValue(forKey: id), entry.isScoped {
                entry.url.stopAccessingSecurityScopedResource()
            }
        }
    }

    func url(for id: String) -> URL? { entries.withLock { $0[id]?.url } }
}

/// Security-scoped bookmarks of user-picked folders ("Providing access to directories",
/// developer.apple.com/documentation/uikit/providing-access-to-directories). iOS bookmarks carry the scope
/// implicitly (`.minimalBookmark`; there is no `.withSecurityScope` on iOS).
nonisolated enum FolderBookmarks {
    nonisolated struct Resolved: Sendable {
        var url: URL
        /// A refreshed bookmark when the stored one was stale (save it).
        var refreshedBookmark: Data?
    }

    /// Creates a bookmark for a folder returned by `fileImporter` (the scope must be open while bookmarking).
    static func makeBookmark(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a stored bookmark; when it is stale, re-creates it from the resolved URL (with the scope open).
    static func resolve(_ bookmark: Data) throws -> Resolved {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        guard isStale else { return Resolved(url: url, refreshedBookmark: nil) }
        let refreshed = try? makeBookmark(for: url)
        return Resolved(url: url, refreshedBookmark: refreshed)
    }
}
