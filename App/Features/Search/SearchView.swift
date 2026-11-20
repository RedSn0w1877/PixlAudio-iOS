import Combine
import PixlFoundation
import PixlLibrary
import PixlModel
import SwiftUI

/// Search — the port of PixlAudio's `SearchScreen.kt` (default, non-glass-mode layout):
/// - top: the large "Search" title with the settings button (40 pt, `primaryContainer` glass circle). The search
///   field itself moved into the bottom bar (split pill, new UI 2026-11-16): on this tab the bar's big capsule is the
///   field (`GlassNavBar`), bound to `Router.searchText`; its search key bumps `Router.searchSubmission`;
/// - empty query, field not focused: the browse grid (catalogue categories + library genres, `GenreBrowseView`) under a
///   "Recent" strip when there is history;
/// - empty query, field focused: the "Recent searches" list in the grid's place (`SearchRecentList`);
/// - during a private session nothing of the history shows (one line says searches aren't saved) and nothing is saved;
/// - otherwise (16 pt sides): the filter chips (All / Songs / Albums / Artists / Playlists) as glass capsules, then
///   the results grouped Songs, Albums, Artists, Playlists, "More on Spotify", "From YouTube Music" (top corners
///   clipped at 28 pt), or the empty state;
/// - the bottom scrim (transparent → `surfaceContainerLowest`) behind the mini player and bar.
/// Library results come from `LibrarySearchProvider` (SearchIndex); the catalogue and YouTube Music from the
/// providers stages 12/11 plug into `SearchProviding` (demo providers in UI tests).
struct SearchView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme

    @State private var model = SearchModel(filter: SearchLaunchOptions.initialFilter)
    /// The browse tiles the atlas knows (docs/brain-spec.md, 8.10); nil (every tile, as before) with the legacy engine or no atlas.
    @State private var brainTiles: Set<String>?

    /// What the page shows. `browse` and `recents` are the blank query, told apart by the field's focus.
    private enum Mode: Equatable {
        case browse, recents, results
    }

    var body: some View {
        // History is hidden during a private session; the recents list takes the grid's place only when there is any.
        let hidesHistory = environment.brainActions.isPrivate
        let isBlank = router.searchText.isKotlinBlank
        let mode: Mode = !isBlank ? .results
            : (router.isSearchFieldFocused && !hidesHistory && !model.history.isEmpty ? .recents : .browse)
        VStack(spacing: 0) {
            topRow
            ZStack(alignment: .top) {
                switch mode {
                case .browse:
                    genreBrowse(hidesHistory: hidesHistory)
                        .padding(.top, 12)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -56)),
                                                removal: .opacity.combined(with: .offset(y: -46))))
                case .recents:
                    recentList
                        .padding(.top, 12)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -56)),
                                                removal: .opacity.combined(with: .offset(y: -46))))
                case .results:
                    results(hidesHistory: hidesHistory)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 56)),
                                                removal: .opacity.combined(with: .offset(y: 46))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeOut(duration: 0.3), value: mode)
        }
        .background(theme.background.ignoresSafeArea())
        .background { LibraryIndexFeeder(model: model, prepare: prepare) }
        .overlay(alignment: .bottom) {
            if let undo = model.undo {
                SearchUndoBar(undo: undo, onUndo: { withAnimation(PixlMotion.bars) { model.performUndo() } })
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(PixlMotion.bars, value: model.undo)
        .onChange(of: router.searchText, initial: true) { _, query in
            prepare()
            model.performSearch(query)
        }
        // The history is read when the Search tab is selected (not when its page is built behind the scenes at launch) and
        // after a backup restore; writes keep the model's copy current in between. At most 50 rows, never per keystroke.
        .onChange(of: router.selection == .search, initial: true) { _, isSelected in
            guard isSelected else { return }
            prepare()
            Task { await model.refreshHistory() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchHistoryRestored)) { _ in
            Task { await model.refreshHistory() }
        }
        // The browse tiles the atlas knows are asked once, not each time the grid is rebuilt by a focus change.
        .task(id: settings.ai.brainEngine) {
            if settings.ai.brainEngine == BrainEngineChoice.brain {
                brainTiles = await environment.brainActions.knownGenreTiles(SearchCategory.defaults.map { $0.name })
            } else {
                brainTiles = nil
            }
        }
        // VoiceOver: the Undo bar appears without moving focus, so say it.
        .onChange(of: model.undo) { _, undo in
            if let undo { AccessibilityNotification.Announcement(SearchHistoryStrings.undoAnnouncement(undo.message)).post() }
        }
        // The bar's field was submitted (Android `onSearch`: the query goes into the history).
        .onChange(of: router.searchSubmission) { _, _ in model.submit(router.searchText) }
        .onChange(of: model.filter) { _, _ in model.performSearch(router.searchText) }
        .onChange(of: settings.library.minTracksPerAlbum) { _, value in model.minTracksChanged(value) }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.search")
    }

    private func prepare() {
        let actions = environment.brainActions
        model.attach(providers: environment.searchProviders, persistence: environment.persistence,
                     isPrivate: { actions.isPrivate })
    }

    // MARK: Top row

    /// The page title and the settings circle (as Library's header). The field is the bottom bar's big capsule on
    /// this tab (`GlassNavBar`).
    private var topRow: some View {
        LargeHeader("Search") {
            GlassCircleButton(systemImage: "gearshape", accessibilityLabel: "Settings",
                              tint: theme.primaryContainer.opacity(GlassTint.container),
                              foreground: theme.onPrimaryContainer) {
                router.push(.settings)
            }
            .accessibilityIdentifier("search.settings")
        }
    }

    // MARK: Browse

    private func genreBrowse(hidesHistory: Bool) -> some View {
        @Bindable var librarySettings = settings.library
        let tiles = brainTiles.map { known in SearchCategory.defaults.filter { known.contains($0.name) } } ?? SearchCategory.defaults
        return GenreBrowseView(genres: model.genres, categories: tiles, isGridView: $librarySettings.isGenreGridView,
                               header: recentHeader(hidesHistory: hidesHistory),
                               onGenre: { genre in router.push(.genreDetail(genreId: genre.id)) },
                               onCategory: { category in
                                   let browse: @MainActor () -> Void = { router.push(.spotifyBrowse(query: category.query)) }
                                   // With the brain engine on a tile is a station when the atlas knows the genre and the listener
                                   // has songs under it (8.3); otherwise it is the live search it always was.
                                   if brainTiles != nil {
                                       environment.brainActions.startGenreStationByName(category.name, fallback: browse)
                                   } else {
                                       browse()
                                   }
                               })
    }

    /// Above the grid: the "Recent" strip when there is history, or the private session's one line.
    @ViewBuilder
    private func recentHeader(hidesHistory: Bool) -> some View {
        if hidesHistory {
            SearchPrivateHint()
        } else if !model.strip.isEmpty {
            SearchRecentStrip(items: model.strip, onOpen: openRecent, onRemove: { model.remove($0) })
        }
    }

    // MARK: Recent searches (the field is focused and blank)

    private var recentList: some View {
        SearchRecentList(items: model.shownHistory, onOpen: openRecent, onFill: fillField,
                         onRemove: { model.remove($0) }, onClearAll: { model.clearAll() })
    }

    /// A tap on a recent row. A result that is still in the library opens (and moves to the top again); anything else
    /// runs its text as a search.
    private func openRecent(_ item: SearchHistoryItem) {
        if !openResult(of: item) { router.searchText = item.query }
        model.record(item.query, kind: item.kind, targetId: item.targetId, targetTitle: item.targetTitle,
                     imageUrl: item.imageUrl)
        router.requestSearchBlur()
    }

    /// Opens the album, artist or playlist a row stands for when it is still in the library.
    private func openResult(of item: SearchHistoryItem) -> Bool {
        guard let id = item.targetId else { return false }
        switch item.kind {
        case .artist:
            guard let value = Int64(id), library.artist(id: value) != nil else { return false }
            router.push(.artistDetail(artistId: value))
        case .album:
            guard let value = Int64(id), library.album(id: value) != nil else { return false }
            router.push(.albumDetail(albumId: value))
        case .playlist:
            guard library.playlist(id: id) != nil else { return false }
            router.push(.playlistDetail(playlistId: id))
        case .song, .query, nil:
            return false
        }
        return true
    }

    /// The arrow: the text goes into the field (the page searches it live, as for typed text) and the keyboard stays.
    private func fillField(_ item: SearchHistoryItem) {
        router.searchText = item.query
    }

    // MARK: Results

    /// What the results area shows under the matching history rows.
    private enum ResultsState: Equatable {
        case unavailable, empty, loading, list
    }

    private var resultsState: ResultsState {
        if model.showsEmptyState { return model.remoteFailed.contains(.spotify) ? .unavailable : .empty }
        return model.showsLoadingState ? .loading : .list
    }

    private func results(hidesHistory: Bool) -> some View {
        @Bindable var model = model
        let state = resultsState
        return VStack(spacing: 0) {
            SearchFilterChips(selection: $model.filter)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            // One scroll view for every state: the matching history rows sit at its top and stay put while the loading,
            // empty and results states swap underneath them (they used to be rebuilt, and faded, with each swap).
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !hidesHistory {
                        SearchSuggestionList(items: model.suggestions, onOpen: openSuggestion, onFill: fillField)
                    }
                    switch state {
                    case .unavailable:
                        SearchUnavailableView { model.performSearch(router.searchText) }
                            .transition(.opacity)
                    case .empty:
                        EmptySearchResultsView(query: router.searchText)
                            .transition(.opacity)
                    case .loading:
                        SearchingResultsView()
                            .transition(.opacity)
                    case .list:
                        resultSections
                            .transition(.opacity)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
                .animation(.easeInOut(duration: 0.19), value: state)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .minimizesTabBarOnScroll()
            .clipShape(TopRoundedClip(radius: 28))
            .accessibilityIdentifier(state == .list ? "search.results" : "search.state")
        }
        .padding(.horizontal, 16)
    }

    /// A tap on a matching row: its text goes into the field and the search runs (the row moves to the top again).
    private func openSuggestion(_ item: SearchHistoryItem) {
        router.searchText = item.query
        model.record(item.query)
        router.requestSearchBlur()
    }

    private var resultSections: some View {
        Group {
            ForEach(model.sections) { section in
                SearchResultSectionHeader(title: section.title)
                ForEach(section.rows) { row in
                    resultRow(row.item)
                        .padding(.bottom, SearchMetrics.rowSpacing)
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ item: SearchResultItem) -> some View {
        switch item {
        case .song(let song):
            PlaybackRowState(songId: song.id) { isCurrent, isPlaying in
                SongCard(song: song, isCurrent: isCurrent, isPlaying: isPlaying,
                         onTap: { playSong(song) },
                         onMore: { router.present(AppSheet.songInfo(songId: song.id)) })
            }
        case .album(let album):
            SearchResultAlbumRow(album: album,
                                 onOpen: { router.push(.albumDetail(albumId: album.id)); itemSelected(album) },
                                 onPlay: { playAlbum(album); itemSelected(album) })
        case .artist(let artist):
            SearchResultArtistRow(artist: artist,
                                  onOpen: { router.push(.artistDetail(artistId: artist.id)); itemSelected(artist) },
                                  onPlay: { playArtist(artist); itemSelected(artist) })
        case .playlist(let playlist):
            SearchResultPlaylistRow(playlist: playlist,
                                    songs: playlist.songIds.prefix(4).compactMap { library.song(id: $0) },
                                    onOpen: { router.push(.playlistDetail(playlistId: playlist.id)); itemSelected(playlist) },
                                    onPlay: { playPlaylist(playlist); itemSelected(playlist) })
        case .catalog(let track):
            SearchResultCatalogRow(track: track, isBusy: isBusy(item),
                                   onPlay: { importRemote(item, play: true) },
                                   onLike: { importRemote(item, play: false) })
        case .youtubeMusic(let track):
            SearchResultYouTubeMusicRow(track: track, isBusy: isBusy(item),
                                        onPlay: { importRemote(item, play: true) })
        }
    }

    private func isBusy(_ item: SearchResultItem) -> Bool {
        SearchModel.remoteKey(item).map { model.busyItems.contains($0) } ?? false
    }

    // MARK: Actions (Android `onSongResultClick`, `playAlbum`, `playArtist`, playlist play, catalogue rows)

    /// Android `onItemSelected`: opening or playing a result records the typed query in the history, with what was
    /// opened (its kind, id, name and picture) so the Recent strip can show it.
    private func itemSelected(_ kind: SearchHistoryKind, id: String, title: String, imageUrl: String?) {
        guard !router.searchText.isKotlinBlank else { return }
        model.record(router.searchText, kind: kind, targetId: id, targetTitle: title, imageUrl: imageUrl)
    }

    private func itemSelected(_ song: Song) {
        itemSelected(.song, id: song.id, title: song.title, imageUrl: song.albumArtUriString)
    }

    private func itemSelected(_ album: Album) {
        itemSelected(.album, id: String(album.id), title: album.title, imageUrl: album.albumArtUriString)
    }

    private func itemSelected(_ artist: Artist) {
        itemSelected(.artist, id: String(artist.id), title: artist.name, imageUrl: artist.effectiveImageUrl)
    }

    private func itemSelected(_ playlist: Playlist) {
        itemSelected(.playlist, id: playlist.id, title: playlist.name, imageUrl: playlist.coverImageUri)
    }

    private func playSong(_ song: Song) {
        let queue = model.songResults
        playback.play(song, in: queue.contains { $0.id == song.id } ? queue : [song], source: .search)
        itemSelected(song)
    }

    private func playAlbum(_ album: Album) {
        let songs = library.songs.filter { $0.albumId == album.id }
            .sorted { ($0.discNumber ?? 0, $0.trackNumber) < ($1.discNumber ?? 0, $1.trackNumber) }
        guard !songs.isEmpty else { return }
        playback.play(songs, source: .search)
    }

    private func playArtist(_ artist: Artist) {
        let songs = library.songs.filter { song in
            song.artistId == artist.id || song.artists.contains { $0.id == artist.id }
        }
        guard !songs.isEmpty else { return }
        playback.play(songs, source: .search)
    }

    private func playPlaylist(_ playlist: Playlist) {
        let songs = playlist.songIds.compactMap { library.song(id: $0) }
        guard !songs.isEmpty else { return }
        playback.play(songs, source: .search)
        if playback.isShuffleEnabled { playback.setShuffleEnabled(false) }
    }

    private func importRemote(_ item: SearchResultItem, play: Bool) {
        guard !isBusy(item) else { return }
        Task {
            if let song = await model.importRemote(item, play: play) {
                if play {
                    playback.play(song, source: .search)
                    itemSelected(song)
                }
            } else if play {
                // The row has left its section: say why nothing plays.
                playback.notices.show("Couldn't find this song to play. Try again later.")
            }
        }
    }
}

/// Feeds library snapshots to the search index. A separate view so only snapshot changes re-run it (Search's own
/// body re-runs on every keystroke, and comparing snapshots there would cost a pass over the library each time).
private struct LibraryIndexFeeder: View {
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings
    let model: SearchModel
    let prepare: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: library.revision, initial: true) { _, _ in
                prepare()
                model.libraryChanged(library.snapshot, minTracksPerAlbum: settings.library.minTracksPerAlbum)
            }
    }
}

/// UI-test launch options of Search (`-searchFilter all|songs|albums|artists|playlists`).
nonisolated enum SearchLaunchOptions {
    static var initialFilter: SearchFilterType {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uiTest"), let index = arguments.firstIndex(of: "-searchFilter"),
              arguments.indices.contains(index + 1) else { return .all }
        return SearchFilterType(rawValue: arguments[index + 1].uppercased()) ?? .all
    }
}
