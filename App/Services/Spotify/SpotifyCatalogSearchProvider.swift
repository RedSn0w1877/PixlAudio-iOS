import Foundation
import PixlModel
import PixlNet

/// Search's "More on Spotify" section (Android `SearchStateHolder.observeCatalogRequests` / `playCatalogTrack` /
/// `likeCatalogTrack`): catalogue tracks the library doesn't have yet. Tapping imports, likes and matches the track
/// right away and plays it; the heart imports and likes it and leaves the audio to the background matcher.
nonisolated struct SpotifyCatalogSearchProvider: SearchProviding {
    let service: SpotifyService

    var source: SearchSource { .spotify }

    func search(_ query: String, filter: SearchFilterType, limit: Int) async throws -> [SearchResultItem] {
        guard await service.isLoggedIn else { return [] }
        // Tracks only: the section lists songs, and one type brings more of them within Spotify's response cap.
        let results = try await service.searchCatalog(query, types: "track", limit: limit)
        try Task.checkCancellation()
        let owned = await service.knownSpotifyIds()
        let fresh = Array(results.tracks.filter { track in
            guard let id = track.id, !id.isEmpty else { return false }
            return !owned.contains(id)
        }.prefix(limit))
        await service.rememberCatalogTracks(fresh)
        return fresh.map { SearchResultItem.catalog(Self.catalogTrack($0)) }
    }

    func importAndPlay(_ item: SearchResultItem) async -> Song? {
        guard case .catalog(let catalog) = item else { return nil }
        let track = await service.catalogTrack(id: catalog.spotifyId) ?? Self.spotifyTrack(catalog)
        return await service.importAndMatch(track, like: true)
    }

    func like(_ item: SearchResultItem) async -> Bool {
        guard case .catalog(let catalog) = item else { return false }
        let track = await service.catalogTrack(id: catalog.spotifyId) ?? Self.spotifyTrack(catalog)
        return await service.importAndLike(track)
    }

    /// `toCatalogTrack`.
    static func catalogTrack(_ track: SpotifyTrack) -> CatalogTrack {
        let artists = (track.artists ?? []).compactMap { $0.name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        return CatalogTrack(spotifyId: track.id ?? "",
                            title: track.name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "Unknown title",
                            artist: artists.isEmpty ? "Unknown Artist" : artists.joined(separator: ", "),
                            album: track.album?.name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "Unknown Album",
                            albumArtUrl: track.album?.images?.first?.url, durationMs: track.durationMs ?? 0)
    }

    /// A best-effort track when the search cache no longer holds it.
    static func spotifyTrack(_ catalog: CatalogTrack) -> SpotifyTrack {
        SpotifyTrack(id: catalog.spotifyId, name: catalog.title, durationMs: catalog.durationMs,
                     artists: [SpotifyArtistRef(id: nil, name: catalog.artist)],
                     album: SpotifyAlbumRef(id: nil, name: catalog.album, images: catalog.albumArtUrl.map { [SpotifyImage(url: $0)] }),
                     type: "track")
    }
}

extension SpotifyService {
    /// Keeps the last catalogue results by id (Android `catalogTracksById`) so an import keeps artist and album ids.
    func rememberCatalogTracks(_ tracks: [SpotifyTrack]) {
        catalogCache = [:]
        for track in tracks { if let id = track.id { catalogCache[id] = track } }
    }

    func catalogTrack(id: String) -> SpotifyTrack? { catalogCache[id] }
}
