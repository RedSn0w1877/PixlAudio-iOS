import Foundation
import PixlModel

/// Where a search runs (Android Search's source chips: library, Spotify catalogue, YouTube Music).
nonisolated enum SearchSource: String, Sendable, CaseIterable, Identifiable {
    case library
    case spotify
    case youtubeMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .spotify: "Spotify"
        case .youtubeMusic: "YouTube Music"
        }
    }
}

/// The seam for search. Stage 7c builds the screen and the library provider on PixlLibrary's `SearchIndex`;
/// stages 11/12 provide the YouTube Music and Spotify providers. Providers are `Sendable` and do their work off
/// the main thread.
nonisolated protocol SearchProviding: Sendable {
    var source: SearchSource { get }
    func search(_ query: String, filter: SearchFilterType, limit: Int) async throws -> [SearchResultItem]
}

/// Placeholder library search: case- and diacritic-insensitive substring match over the snapshot. Stage 7c replaces
/// it with the `SearchIndex`-backed provider (FTS-equivalent ranking).
nonisolated struct LocalSearchProvider: SearchProviding {
    let snapshot: LibrarySnapshot
    var source: SearchSource { .library }

    func search(_ query: String, filter: SearchFilterType, limit: Int) async throws -> [SearchResultItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func matches(_ s: String) -> Bool { s.range(of: q, options: options) != nil }
        var out: [SearchResultItem] = []
        if filter == .all || filter == .songs {
            out += snapshot.songs.filter { matches($0.title) || matches($0.artist) || matches($0.album) }.map { .song($0) }
        }
        if filter == .all || filter == .albums {
            out += snapshot.albums.filter { matches($0.title) || matches($0.artist) }.map { .album($0) }
        }
        if filter == .all || filter == .artists {
            out += snapshot.artists.filter { matches($0.name) }.map { .artist($0) }
        }
        if filter == .all || filter == .playlists {
            out += snapshot.playlists.filter { matches($0.name) }.map { .playlist($0) }
        }
        return Array(out.prefix(limit))
    }
}

/// A provider for a source that isn't available yet (not signed in, or its stage hasn't landed): no results.
nonisolated struct UnavailableSearchProvider: SearchProviding {
    let source: SearchSource

    func search(_ query: String, filter: SearchFilterType, limit: Int) async throws -> [SearchResultItem] { [] }
}
