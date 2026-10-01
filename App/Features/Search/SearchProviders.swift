import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel

/// Library search on PixlLibrary's `SearchIndex` — the port of Android's Room/FTS `MusicRepositoryImpl.searchAll`
/// (FTS prefix query + LIKE fallback for songs, LIKE for albums/artists, contains for playlists, `min_tracks_per_album`
/// for albums). The index is rebuilt off the main thread whenever the library snapshot changes.
actor LibrarySearchProvider: SearchProviding {
    nonisolated var source: SearchSource { .library }

    private var index = SearchIndex(songs: [])
    private var indexed: LibrarySnapshot?
    private var minTracksPerAlbum = 1

    init() {}

    /// Builds a fresh index when `snapshot` differs from the indexed one. Returns whether it rebuilt.
    @discardableResult
    func update(snapshot: LibrarySnapshot) -> Bool {
        if let indexed, indexed == snapshot { return false }
        index = SearchIndex(songs: snapshot.songs, albums: snapshot.albums, artists: snapshot.artists,
                            playlists: snapshot.playlists)
        indexed = snapshot
        return true
    }

    /// Android `minTracksPerAlbumFlow`.
    func setMinTracksPerAlbum(_ value: Int) { minTracksPerAlbum = value }

    func search(_ query: String, filter: SearchFilterType, limit: Int) async throws -> [SearchResultItem] {
        try Task.checkCancellation()
        let results = index.searchAll(query, filter: filter, minTracksPerAlbum: minTracksPerAlbum)
        return limit < results.count ? Array(results.prefix(limit)) : results
    }
}

/// UI-test stand-in for the Spotify catalogue (stage 12 provides the real one): invented tracks matching the query,
/// so the "More on Spotify" section renders with demo data. No network, deterministic.
nonisolated struct DemoCatalogSearchProvider: SearchProviding {
    var source: SearchSource { .spotify }

    static let tracks: [CatalogTrack] = [
        CatalogTrack(spotifyId: "demo-sp-1", title: "Prism Avenue", artist: "Luma Vale", album: "Prism Avenue",
                     albumArtUrl: "demo-art://41", durationMs: 207_000),
        CatalogTrack(spotifyId: "demo-sp-2", title: "Harbor Lights (Acoustic)", artist: "Luma Vale",
                     album: "City of Glass (Deluxe)", albumArtUrl: "demo-art://44", durationMs: 221_000),
        CatalogTrack(spotifyId: "demo-sp-3", title: "Lumen", artist: "Sora Kline, Luma Vale", album: "Lumen",
                     albumArtUrl: "demo-art://47", durationMs: 189_000),
        CatalogTrack(spotifyId: "demo-sp-4", title: "Night Swim", artist: "Hollow Pines", album: "Drift",
                     albumArtUrl: "demo-art://50", durationMs: 244_000),
    ]

    func search(_ query: String, filter: SearchFilterType, limit: Int) async throws -> [SearchResultItem] {
        Array(Self.tracks.filter { DemoSearchMatch.matches(query, $0.title, $0.artist) }.prefix(limit))
            .map(SearchResultItem.catalog)
    }
}

/// UI-test stand-in for YouTube Music search (stage 11 provides the real one).
nonisolated struct DemoYouTubeMusicSearchProvider: SearchProviding {
    var source: SearchSource { .youtubeMusic }

    static let tracks: [YouTubeMusicTrack] = [
        YouTubeMusicTrack(videoId: "demo-yt-1", title: "Neon Harbor (Live Session)", artist: "Luma Vale",
                          album: nil, thumbnailUrl: "demo-art://53", durationMs: 236_000),
        YouTubeMusicTrack(videoId: "demo-yt-2", title: "Velvet Static (Slowed)", artist: "Luma Vale",
                          album: "City of Glass", thumbnailUrl: "demo-art://56", durationMs: 252_000),
        YouTubeMusicTrack(videoId: "demo-yt-3", title: "Midnight Transit (Night Drive Edit)", artist: "Sora Kline",
                          album: nil, thumbnailUrl: "demo-art://59", durationMs: 268_000),
    ]

    func search(_ query: String, filter: SearchFilterType, limit: Int) async throws -> [SearchResultItem] {
        Array(Self.tracks.filter { DemoSearchMatch.matches(query, $0.title, $0.artist) }.prefix(limit))
            .map(SearchResultItem.youtubeMusic)
    }
}

nonisolated enum DemoSearchMatch {
    static func matches(_ query: String, _ fields: String...) -> Bool {
        let q = query.kotlinTrimmed()
        guard !q.isEmpty else { return false }
        return fields.contains { KotlinText.contains($0, q, ignoreCase: true) }
    }
}
