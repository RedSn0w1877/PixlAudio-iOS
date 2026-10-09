import Foundation
import Observation
import PixlFoundation
import PixlModel

/// One section of the results list (Android `SearchResultsList` groups results by type, in `sectionOrder`).
nonisolated struct SearchResultSection: Identifiable, Sendable, Equatable {
    /// A row with Android's stable key (`song_<id>`, `album_<id>`, …; playlists add their index).
    nonisolated struct Row: Identifiable, Sendable, Equatable {
        let id: String
        let item: SearchResultItem
    }

    let kind: SearchFilterType
    let rows: [Row]

    var id: SearchFilterType { kind }

    /// Android's section titles.
    var title: String {
        switch kind {
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        case .catalog: "More on Spotify"
        case .youtubeMusic: "From YouTube Music"
        case .all: "Results"
        }
    }

    static let order: [SearchFilterType] = [.songs, .albums, .artists, .playlists, .catalog, .youtubeMusic]

    static func kind(of item: SearchResultItem) -> SearchFilterType {
        switch item {
        case .song: .songs
        case .album: .albums
        case .artist: .artists
        case .playlist: .playlists
        case .catalog: .catalog
        case .youtubeMusic: .youtubeMusic
        }
    }

    static func key(_ item: SearchResultItem, index: Int) -> String {
        switch item {
        case .song(let song): "song_\(song.id)"
        case .album(let album): "album_\(album.id)"
        case .artist(let artist): "artist_\(artist.id)"
        case .playlist(let playlist): "playlist_\(playlist.id)_\(index)"
        case .catalog(let track): "catalog_\(track.spotifyId)"
        case .youtubeMusic(let track): "ytmusic_\(track.videoId)"
        }
    }

    /// Groups `results` (library first, then catalogue, then YouTube Music) into non-empty sections in order.
    static func group(_ results: [SearchResultItem]) -> [SearchResultSection] {
        var buckets: [SearchFilterType: [SearchResultItem]] = [:]
        for item in results { buckets[kind(of: item), default: []].append(item) }
        return order.compactMap { kind in
            guard let items = buckets[kind], !items.isEmpty else { return nil }
            let rows = items.enumerated().map { index, item in Row(id: key(item, index: index), item: item) }
            return SearchResultSection(kind: kind, rows: rows)
        }
    }
}

/// Search's state holder — the port of Android's `SearchStateHolder`: three independent searches on every query
/// change (the library after 160 ms, the Spotify catalogue and YouTube Music after 420 ms and only from two
/// characters, at most 20 results each), the selected filter, and search history. The Search tab's stack stays
/// alive, so this lives as long as the app (like Android's singleton).
@Observable
final class SearchModel {
    // Android SearchStateHolder constants.
    static let searchDebounce: Duration = .milliseconds(160)
    static let catalogDebounce: Duration = .milliseconds(420)
    static let youtubeMusicDebounce: Duration = .milliseconds(420)
    static let minRemoteQueryLength = 2
    static let remoteResultLimit = 20

    /// The selected filter chip (`selectedSearchFilter`).
    var filter: SearchFilterType = .all
    @ObservationIgnored private var libraryResults: [SearchResultItem] = []
    @ObservationIgnored private var catalogResults: [SearchResultItem] = []
    @ObservationIgnored private var youtubeMusicResults: [SearchResultItem] = []
    private(set) var isCatalogSearching = false
    private(set) var isYoutubeMusicSearching = false
    /// Results grouped for the list (rebuilt only when a result list changes, never in `body`).
    private(set) var sections: [SearchResultSection] = []
    /// The library's genres for the browse grid.
    private(set) var genres: [Genre] = []
    /// Remote rows being imported (spinner on the row).
    private(set) var busyItems: Set<String> = []

    @ObservationIgnored private var providers: [SearchSource: any SearchProviding] = [:]
    @ObservationIgnored private var persistence: PersistenceActor?
    @ObservationIgnored private var requestID = 0
    @ObservationIgnored private var lastQuery = ""
    @ObservationIgnored private var libraryTask: Task<Void, Never>?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var youtubeMusicTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var isAttached = false

    init(filter: SearchFilterType = .all) {
        self.filter = filter
    }

    /// Hands the model its providers and store (once, from the view).
    func attach(providers: [SearchSource: any SearchProviding], persistence: PersistenceActor?) {
        guard !isAttached else { return }
        isAttached = true
        self.providers = providers
        self.persistence = persistence
    }

    /// Results empty and nothing still on its way (Android only declares "no results" once the network searches
    /// have answered, so the screen doesn't flash the empty state).
    var showsEmptyState: Bool {
        sections.isEmpty && !isCatalogSearching && !isYoutubeMusicSearching
    }

    /// All library song results, the queue a tapped song plays in (Android `songResultsQueue`).
    var songResults: [Song] {
        libraryResults.compactMap { item -> Song? in
            guard case .song(let song) = item else { return nil }
            return song
        }
    }

    // MARK: Library index

    /// A new library snapshot: re-index off the main thread, rebuild the genre list, refresh the shown results.
    func libraryChanged(_ snapshot: LibrarySnapshot, minTracksPerAlbum: Int) {
        indexTask?.cancel()
        let provider = providers[.library] as? LibrarySearchProvider
        indexTask = Task { [weak self] in
            let genresPass = Task.detached(priority: .userInitiated) {
                LibraryGenres.genres(from: snapshot.songs)
            }
            let genres = await withTaskCancellationHandler { await genresPass.value } onCancel: { genresPass.cancel() }
            guard let self, !Task.isCancelled else { return }
            // Equal lists leave the Search screen alone (a favourite or an artist picture changes no genre).
            if self.genres != genres { self.genres = genres }
            if let provider {
                await provider.setMinTracksPerAlbum(minTracksPerAlbum)
                let rebuilt = await provider.update(snapshot: snapshot)
                if rebuilt, !Task.isCancelled, !self.lastQuery.isEmpty { self.searchLibrary(self.lastQuery, id: self.requestID) }
            }
        }
    }

    /// `min_tracks_per_album` changed: re-run the library search with it.
    func minTracksChanged(_ value: Int) {
        guard let provider = providers[.library] as? LibrarySearchProvider else { return }
        Task { [weak self] in
            await provider.setMinTracksPerAlbum(value)
            guard let self, !self.lastQuery.isEmpty else { return }
            self.searchLibrary(self.lastQuery, id: self.requestID)
        }
    }

    // MARK: Searching (Android `performSearch` + the three debounced collectors)

    func performSearch(_ rawQuery: String) {
        let query = rawQuery.kotlinTrimmed()
        requestID += 1
        let id = requestID
        lastQuery = query
        if query.isEmpty, !libraryResults.isEmpty { setLibraryResults([]) }

        libraryTask?.cancel()
        libraryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard let self, !Task.isCancelled else { return }
            self.searchLibrary(query, id: id)
        }

        catalogTask?.cancel()
        catalogTask = remoteSearch(query, id: id, source: .spotify, debounce: Self.catalogDebounce)
        youtubeMusicTask?.cancel()
        youtubeMusicTask = remoteSearch(query, id: id, source: .youtubeMusic, debounce: Self.youtubeMusicDebounce)
    }

    private func searchLibrary(_ query: String, id: Int) {
        guard !query.isKotlinBlank else {
            if !libraryResults.isEmpty { setLibraryResults([]) }
            return
        }
        guard let provider = providers[.library] else { return }
        let filter = filter
        Task { [weak self] in
            let results = (try? await provider.search(query, filter: filter, limit: .max)) ?? []
            guard let self, id == self.requestID else { return }
            if self.libraryResults != results { self.setLibraryResults(results) }
        }
    }

    private func remoteSearch(_ query: String, id: Int, source: SearchSource, debounce: Duration) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard let self, !Task.isCancelled else { return }
            guard query.utf16.count >= Self.minRemoteQueryLength, let provider = self.providers[source] else {
                self.setSearching(false, source: source)
                if !self.remoteResults(source).isEmpty { self.setRemoteResults([], source: source) }
                return
            }
            self.setSearching(true, source: source)
            do {
                let results = try await provider.search(query, filter: source == .spotify ? .catalog : .youtubeMusic,
                                                        limit: Self.remoteResultLimit)
                guard id == self.requestID, !Task.isCancelled else { return }
                self.setRemoteResults(Array(results.prefix(Self.remoteResultLimit)), source: source)
            } catch is CancellationError {
                // Superseded by a newer query.
            } catch {
                if id == self.requestID { self.setRemoteResults([], source: source) }
            }
            if id == self.requestID { self.setSearching(false, source: source) }
        }
    }

    private func remoteResults(_ source: SearchSource) -> [SearchResultItem] {
        source == .spotify ? catalogResults : youtubeMusicResults
    }

    private func setRemoteResults(_ results: [SearchResultItem], source: SearchSource) {
        if source == .spotify { catalogResults = results } else { youtubeMusicResults = results }
        regroup()
    }

    private func setSearching(_ value: Bool, source: SearchSource) {
        if source == .spotify {
            if isCatalogSearching != value { isCatalogSearching = value }
        } else if isYoutubeMusicSearching != value {
            isYoutubeMusicSearching = value
        }
    }

    private func setLibraryResults(_ results: [SearchResultItem]) {
        libraryResults = results
        regroup()
    }

    private func regroup() {
        let all = libraryResults + catalogResults + youtubeMusicResults
        let grouped = SearchResultSection.group(all)
        if grouped != sections { sections = grouped }
    }

    // MARK: Remote rows (Android `playCatalogTrack` / `likeCatalogTrack` / `playYouTubeMusicTrack`)

    static func remoteKey(_ item: SearchResultItem) -> String? {
        switch item {
        case .catalog(let track): "catalog_\(track.spotifyId)"
        case .youtubeMusic(let track): "ytmusic_\(track.videoId)"
        default: nil
        }
    }

    /// Imports a remote result (play or like); the row leaves its section afterwards either way, as on Android.
    /// Returns the playable song when there is one.
    func importRemote(_ item: SearchResultItem, play: Bool) async -> Song? {
        guard let key = Self.remoteKey(item), !busyItems.contains(key) else { return nil }
        let source: SearchSource
        switch item {
        case .catalog: source = .spotify
        default: source = .youtubeMusic
        }
        guard let provider = providers[source] else { return nil }
        busyItems.insert(key)
        defer { busyItems.remove(key) }
        var song: Song?
        if play {
            song = await provider.importAndPlay(item)
        } else {
            _ = await provider.like(item)
        }
        setRemoteResults(remoteResults(source).filter { $0 != item }, source: source)
        return song
    }

    // MARK: History (Android `onSearchQuerySubmitted`)

    func submit(_ query: String) {
        guard !query.isKotlinBlank, let persistence else { return }
        Task { try? await persistence.addSearchHistoryItem(query) }
    }
}
