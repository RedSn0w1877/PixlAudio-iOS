import PixlFoundation
import PixlModel
import SwiftUI

/// Search — the port of PixlAudio's `SearchScreen.kt` (default, non-glass-mode layout):
/// - top row (24 pt sides, 12 pt below the status bar, 12 pt gap): the docked search field (56 pt, 28 pt corners,
///   `primaryContainer` 30 %; `primary` search icon and placeholder; a clear button once there is text) and the
///   settings button (40 pt, `primaryContainer`) — as a glass capsule and a glass circle;
/// - empty query: the browse grid (catalogue categories + library genres, `GenreBrowseView`);
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
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var router = router
        let showsGenres = router.searchText.isKotlinBlank
        VStack(spacing: 0) {
            topRow(query: $router.searchText)
            ZStack(alignment: .top) {
                if showsGenres {
                    genreBrowse
                        .padding(.top, 12)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -56)),
                                                removal: .opacity.combined(with: .offset(y: -46))))
                } else {
                    results
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 56)),
                                                removal: .opacity.combined(with: .offset(y: 46))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeOut(duration: 0.3), value: showsGenres)
        }
        .background(theme.background.ignoresSafeArea())
        .background { LibraryIndexFeeder(model: model, prepare: prepare) }
        .onChange(of: router.searchText, initial: true) { _, query in
            prepare()
            model.performSearch(query)
        }
        .onChange(of: model.filter) { _, _ in model.performSearch(router.searchText) }
        .onChange(of: settings.library.minTracksPerAlbum) { _, value in model.minTracksChanged(value) }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.search")
    }

    private func prepare() {
        model.attach(providers: environment.searchProviders, persistence: environment.persistence)
    }

    // MARK: Top row

    private func topRow(query: Binding<String>) -> some View {
        // Field and button are separate glass shapes 12 pt apart: one container, spacing below the gap.
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 12) {
                searchField(query: query)
                GlassCircleButton(systemImage: "gearshape", accessibilityLabel: "Settings",
                                  tint: theme.primaryContainer.opacity(GlassTint.container),
                                  foreground: theme.onPrimaryContainer) {
                    router.push(.settings)
                }
                .padding(.bottom, 2)
                .accessibilityIdentifier("search.settings")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    /// Android `DockedSearchBar` + `SearchBarDefaults.InputField`: the 48 pt icon slots sit 4 pt in from the ends,
    /// the text starts 4 pt after the leading slot.
    private func searchField(query: Binding<String>) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.primary)
                .frame(width: 48, height: 48)
                .padding(.leading, 4)
                .accessibilityLabel("Search")
            TextField("", text: query, prompt: Text("Search…").foregroundStyle(theme.primary))
                .pixlFont(.bodyLarge)
                .foregroundStyle(isFieldFocused ? theme.onSurface : theme.onSurface.opacity(0.8))
                .tint(theme.primary)
                .focused($isFieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { model.submit(query.wrappedValue) }
                .padding(.horizontal, 4)
                .accessibilityIdentifier("search.field")
            if !query.wrappedValue.isKotlinBlank {
                Button {
                    query.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.primary)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(theme.primaryContainer.opacity(0.2)))
                        .contentShape(.circle)
                }
                .buttonStyle(PressScaleButtonStyle())
                .padding(.trailing, 4)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("search.clear")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .pixlGlass(in: Capsule(), tint: theme.primaryContainer.opacity(0.3))
        .animation(PixlMotion.state, value: query.wrappedValue.isKotlinBlank)
    }

    // MARK: Browse

    private var genreBrowse: some View {
        @Bindable var librarySettings = settings.library
        return GenreBrowseView(genres: model.genres, isGridView: $librarySettings.isGenreGridView,
                               onGenre: { genre in router.push(.genreDetail(genreId: genre.id)) },
                               onCategory: { category in router.push(.spotifyBrowse(query: category.query)) })
    }

    // MARK: Results

    private var results: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            SearchFilterChips(selection: $model.filter)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            ZStack(alignment: .top) {
                if model.showsEmptyState {
                    EmptySearchResultsView(query: router.searchText)
                        .transition(.opacity)
                } else {
                    resultsList
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeInOut(duration: 0.19), value: model.showsEmptyState)
        }
        .padding(.horizontal, 16)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.sections) { section in
                    SearchResultSectionHeader(title: section.title)
                    ForEach(section.rows) { row in
                        resultRow(row.item)
                            .padding(.bottom, SearchMetrics.rowSpacing)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                          topTrailingRadius: 28, style: .continuous))
        .accessibilityIdentifier("search.results")
    }

    @ViewBuilder
    private func resultRow(_ item: SearchResultItem) -> some View {
        switch item {
        case .song(let song):
            SongCard(song: song, isCurrent: playback.current?.id == song.id, isPlaying: playback.isPlaying,
                     onTap: { playSong(song) },
                     onMore: { router.present(AppSheet.songInfo(songId: song.id)) })
        case .album(let album):
            SearchResultAlbumRow(album: album,
                                 onOpen: { router.push(.albumDetail(albumId: album.id)); itemSelected() },
                                 onPlay: { playAlbum(album); itemSelected() })
        case .artist(let artist):
            SearchResultArtistRow(artist: artist,
                                  onOpen: { router.push(.artistDetail(artistId: artist.id)); itemSelected() },
                                  onPlay: { playArtist(artist); itemSelected() })
        case .playlist(let playlist):
            SearchResultPlaylistRow(playlist: playlist,
                                    songs: playlist.songIds.prefix(4).compactMap { library.song(id: $0) },
                                    onOpen: { router.push(.playlistDetail(playlistId: playlist.id)); itemSelected() },
                                    onPlay: { playPlaylist(playlist); itemSelected() })
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

    /// Android `onItemSelected`: opening or playing a result records the query in the history.
    private func itemSelected() {
        if !router.searchText.isKotlinBlank { model.submit(router.searchText) }
    }

    private func playSong(_ song: Song) {
        let queue = model.songResults
        playback.play(song, in: queue.contains { $0.id == song.id } ? queue : [song])
        itemSelected()
    }

    private func playAlbum(_ album: Album) {
        let songs = library.songs.filter { $0.albumId == album.id }
            .sorted { ($0.discNumber ?? 0, $0.trackNumber) < ($1.discNumber ?? 0, $1.trackNumber) }
        guard !songs.isEmpty else { return }
        playback.play(songs)
    }

    private func playArtist(_ artist: Artist) {
        let songs = library.songs.filter { song in
            song.artistId == artist.id || song.artists.contains { $0.id == artist.id }
        }
        guard !songs.isEmpty else { return }
        playback.play(songs)
    }

    private func playPlaylist(_ playlist: Playlist) {
        let songs = playlist.songIds.compactMap { library.song(id: $0) }
        guard !songs.isEmpty else { return }
        playback.play(songs)
        if playback.isShuffleEnabled { playback.setShuffleEnabled(false) }
    }

    private func importRemote(_ item: SearchResultItem, play: Bool) {
        Task {
            if let song = await model.importRemote(item, play: play), play {
                playback.play(song)
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
            .onChange(of: library.snapshot, initial: true) { _, snapshot in
                prepare()
                model.libraryChanged(snapshot, minTracksPerAlbum: settings.library.minTracksPerAlbum)
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
