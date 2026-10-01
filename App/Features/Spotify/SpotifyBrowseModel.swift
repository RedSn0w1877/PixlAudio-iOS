import Foundation
import Observation
import PixlNet

/// Port of `SpotifyBrowseViewModel`. Drill-down (search → artist → album) is state, not routes: three views of one
/// flow, so going back never re-fetches what is already on screen.
@Observable
final class SpotifyBrowseModel {
    nonisolated enum Level: Equatable, Sendable {
        case home
        case results
        case artist(SpotifyArtistFull)
        case album(SpotifyAlbumFull)
    }

    static let searchDebounce: Duration = .milliseconds(350)

    var query = ""
    private(set) var level: Level = .home
    private(set) var isLoading = false
    private(set) var tracks: [SpotifyTrack] = []
    private(set) var artists: [SpotifyArtistFull] = []
    private(set) var albums: [SpotifyAlbumFull] = []
    /// The open artist's releases (distinct from `albums`, the search's).
    private(set) var artistAlbums: [SpotifyAlbumFull] = []
    private(set) var topArtists: [SpotifyArtistFull] = []
    var message: String?
    private(set) var topReadDenied = false

    @ObservationIgnored private weak var service: SpotifyService?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    func attach(_ service: SpotifyService) {
        self.service = service
    }

    /// First appearance: the initial query (from a Search category) or the most-played home. A demo screen id opens a
    /// drill-down directly (UI tests).
    func start(initialQuery: String, demoScreen: DemoScreen?) async {
        guard !started else { return }
        started = true
        if !initialQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            onQueryChange(initialQuery)
            return
        }
        await loadHome()
        switch demoScreen {
        case .spotifyBrowseArtist:
            if let artist = topArtists.first { openArtist(artist) }
        case .spotifyBrowseAlbum:
            if let artist = topArtists.first, let service {
                let albums = await service.artistAlbums(artist.id ?? "")
                if let album = albums.first { openAlbum(album) }
            }
        default:
            break
        }
    }

    // MARK: Home: most played

    func loadHome() async {
        guard let service, service.isLoggedIn else { return }
        isLoading = true
        async let topTracks = service.myTopTracks()
        async let topArtistsList = service.myTopArtists()
        let (tracksResult, artistsResult) = await (topTracks, topArtistsList)
        isLoading = false
        if level == .home { tracks = tracksResult }
        topArtists = artistsResult
        // Spotify denies these when the session predates `user-top-read`: reconnecting fixes it.
        topReadDenied = tracksResult.isEmpty && artistsResult.isEmpty
    }

    // MARK: Search

    func onQueryChange(_ newQuery: String) {
        query = newQuery
        searchTask?.cancel()
        if newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            level = .home
            loadTask = Task { await loadHome() }
            return
        }
        searchTask = Task {
            // Without this pause every keystroke would be a request.
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled, let service else { return }
            isLoading = true
            level = .results
            let results = (try? await service.searchCatalog(newQuery)) ?? SpotifyCatalogResults()
            guard !Task.isCancelled else { return }
            isLoading = false
            tracks = results.tracks
            artists = results.artists
            albums = results.albums
            message = results.isEmpty ? "Nothing found for \"\(newQuery)\"." : nil
        }
    }

    // MARK: Drill-down

    func openArtist(_ artist: SpotifyArtistFull) {
        guard let artistId = artist.id, let service else { return }
        searchTask?.cancel()
        isLoading = true
        level = .artist(artist)
        loadTask = Task {
            async let top = service.artistTopTracks(artistId)
            async let releases = service.artistAlbums(artistId)
            let (topTracks, albums) = await (top, releases)
            guard level == .artist(artist) else { return }
            isLoading = false
            tracks = topTracks
            artistAlbums = albums
        }
    }

    func openAlbum(_ album: SpotifyAlbumFull) {
        guard let albumId = album.id, let service else { return }
        isLoading = true
        level = .album(album)
        loadTask = Task {
            let albumTracks = await service.albumTracks(albumId)
            guard level == .album(album) else { return }
            isLoading = false
            tracks = albumTracks
        }
    }

    /// Steps back inside the screen; false when already at the home level (the screen then pops).
    func goBack() -> Bool {
        switch level {
        case .album(let album):
            // From an album back to its artist when that's how the user got here, else to the search.
            if let artist = artists.first(where: { artistOwns($0, album) }) ?? topArtists.first(where: { artistOwns($0, album) }) {
                openArtist(artist)
            } else {
                restoreSearch()
            }
            return true
        case .artist:
            restoreSearch()
            return true
        case .results:
            query = ""
            level = .home
            loadTask = Task { await loadHome() }
            return true
        case .home:
            return false
        }
    }

    private func artistOwns(_ artist: SpotifyArtistFull, _ album: SpotifyAlbumFull) -> Bool {
        (album.artists ?? []).contains { $0.id != nil && $0.id == artist.id }
    }

    private func restoreSearch() {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            level = .home
            loadTask = Task { await loadHome() }
        } else {
            onQueryChange(query)
        }
    }

    // MARK: Add to library

    /// Imports the tracks and starts the audio search. Playing isn't immediate: there is nothing to play until the
    /// matcher finds the video.
    func addToLibrary(_ tracks: [SpotifyTrack], label: String) {
        guard !tracks.isEmpty, let service else { return }
        isLoading = true
        Task {
            let added = await service.addToLibrary(tracks) ?? 0
            isLoading = false
            if added == 0 {
                message = "\(label) was already in your library — finding audio now."
            } else if tracks.count == 1 {
                message = "Added \"\(label)\". Finding audio for it now."
            } else {
                message = "Added \(added) tracks from \(label). Finding audio now."
            }
        }
    }

    var title: String {
        switch level {
        case .home: "Browse Spotify"
        case .results: "Search results"
        case .artist(let artist): artist.name ?? "Artist"
        case .album(let album): album.name ?? "Album"
        }
    }
}
