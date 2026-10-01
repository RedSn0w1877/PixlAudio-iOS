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

/// The seam for search. Stage 7c builds the screen and the library provider (`LibrarySearchProvider`, on PixlLibrary's
/// `SearchIndex`); stages 11/12 provide the YouTube Music and Spotify providers. Providers are `Sendable` and do their
/// work off the main thread.
nonisolated protocol SearchProviding: Sendable {
    var source: SearchSource { get }
    func search(_ query: String, filter: SearchFilterType, limit: Int) async throws -> [SearchResultItem]
    /// Brings a remote result into the library and returns the playable song (Android `playCatalogTrack` /
    /// `playYouTubeMusicTrack`); nil when it couldn't be imported or matched.
    func importAndPlay(_ item: SearchResultItem) async -> Song?
    /// Imports a catalogue result as a liked song without playing it (Android `likeCatalogTrack`).
    func like(_ item: SearchResultItem) async -> Bool
}

extension SearchProviding {
    /// Library results are already playable; remote providers override this.
    nonisolated func importAndPlay(_ item: SearchResultItem) async -> Song? { nil }
    nonisolated func like(_ item: SearchResultItem) async -> Bool { false }
}

/// A provider for a source that isn't available yet (not signed in, or its stage hasn't landed): no results.
nonisolated struct UnavailableSearchProvider: SearchProviding {
    let source: SearchSource

    func search(_ query: String, filter: SearchFilterType, limit: Int) async throws -> [SearchResultItem] { [] }
}
