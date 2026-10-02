import PixlLibrary
import PixlModel
import SwiftUI
import UniformTypeIdentifiers

/// PixlAudio's Library (Android `LibraryScreen`, default tabs navigation), ported with Liquid Glass:
/// - the screen background gradient (dark: `primaryContainer` 50 % → clear; light: `onPrimaryContainer` 20 % → clear)
///   and the header band tinted `primaryContainer` 40 % holding the "Library" title (40 pt heavy, `primary`) with
///   its settings circle, and the category tab row (glass capsules, gliding `primary` selection, an Edit capsule
///   that opens the reorder sheet);
/// - the content panel (`surface`, 34 pt top corners) with the action row (Shuffle / New + Import, locate, storage
///   filter, instrumental filter, sort — or the folder breadcrumbs, or the selection row) and the swipeable tab
///   pages (Songs, Albums grid/list, Artists, Playlists, Folders, Liked);
/// - long press multi-selection for songs, albums (max 6) and playlists, with the floating count pill and the
///   selection sheets; the sort sheet, the reorder sheet, the playlist creation flow and M3U import.
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme

    @State private var model = LibraryModel()
    @State private var selectedTab: LibraryTab?
    @State private var songSelection = OrderedSelection<String>()
    @State private var albumSelection = OrderedSelection<Int64>()
    @State private var playlistSelection = OrderedSelection<String>()
    @State private var folderPath: String?
    @State private var sheet: LibrarySheet?
    @State private var likedAt: [String: Int64] = [:]
    @State private var instrumentalizedOnly = false
    @State private var showsM3UImporter = false
    @State private var mergeName = ""
    @State private var showsMergeDialog = false
    /// Locate taps per page (only the tapped page scrolls).
    @State private var locateRequests: [LibraryTab: Int] = [:]
    @State private var actions = LibraryActions()
    @State private var didApplyLaunchState = false

    private var prefs: LibraryPreferences { LibraryPreferences.shared(isUITest: env.launch.isUITest) }
    private var tab: LibraryTab { selectedTab ?? prefs.tabOrder.first ?? .songs }
    private var isSelecting: Bool {
        switch tab {
        case .playlists: playlistSelection.isActive
        case .albums: albumSelection.isActive
        case .artists: false
        case .songs, .liked, .folders: songSelection.isActive
        }
    }

    var body: some View {
        let prefs = self.prefs
        VStack(spacing: 0) {
            header(prefs)
            contentPanel(prefs)
        }
        .background(background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            configureActions()
            applyLaunchState(prefs)
            actions.visibleTab = tab
        }
        .onChange(of: inputs(prefs), initial: true) { _, new in model.update(new) }
        .onChange(of: tab) { _, newTab in
            settings.library.lastLibraryTabIndex = prefs.tabOrder.firstIndex(of: newTab) ?? 0
            actions.pageChanged(to: newTab)
            clearSelections()
        }
        .task { likedAt = await env.libraryEditor.favoriteTimestamps() }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet, prefs: prefs)
        }
        .fileImporter(isPresented: $showsM3UImporter, allowedContentTypes: [.m3uPlaylist, .plainText]) { result in
            importM3U(result)
        }
        .alert("Merge Playlists", isPresented: $showsMergeDialog) {
            TextField("Merged Playlist", text: $mergeName)
            Button("Merge") {
                guard !mergeName.isEmpty else { return }
                env.libraryEditor.mergePlaylists(playlistSelection.ids, name: mergeName)
                playlistSelection.clear()
                mergeName = ""
            }
            Button("Cancel", role: .cancel) { mergeName = "" }
        } message: {
            Text("Enter a name for the merged playlist. This will merge \(playlistSelection.count) selected playlists into one.")
        }
        .libraryToast()
        .accessibilityIdentifier("screen.library")
    }

    // MARK: Background and header

    private var background: some View {
        ZStack {
            theme.background
            LinearGradient(colors: [theme.isDark ? theme.primaryContainer.opacity(0.5) : theme.onPrimaryContainer.opacity(0.2),
                                    .clear],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    /// Settings › Library Navigation (Android `LibraryNavigationMode`): the "Library" title over the tab row, or
    /// (`compact_pill`) the current tab's pill — which opens the tab menu — over the pager dots.
    private func header(_ prefs: LibraryPreferences) -> some View {
        let isCompact = settings.appearance.libraryNavigationMode == LibraryNavigationMode.compactPill
        return VStack(spacing: 0) {
            if isCompact {
                HStack(spacing: 0) {
                    LibraryNavigationPill(tab: tab, tabs: prefs.tabOrder,
                                          onSelect: { newTab in withAnimation(PixlMotion.state) { selectedTab = newTab } },
                                          onReorder: { sheet = .reorderTabs })
                    Spacer(minLength: Tokens.Spacing.s)
                    settingsButton
                }
                .padding(.leading, LibraryNavigationPill.leadingInset)
                .padding(.trailing, Tokens.TopBar.actionTrailing)
                .frame(height: Tokens.TopBar.height)
                CompactLibraryPagerIndicator(currentIndex: prefs.tabOrder.firstIndex(of: tab) ?? 0,
                                             pageCount: prefs.tabOrder.count)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            } else {
                LargeHeader("Library") { settingsButton }
                GlassPillRow(items: prefs.tabOrder.map { GlassPillRow<LibraryTab>.Item(id: $0, title: $0.tabTitle) },
                             selection: Binding(get: { tab }, set: { newTab in selectedTab = newTab }),
                             accessibilityIdentifierPrefix: "library.tab",
                             accessory: GlassPillRow<LibraryTab>.Accessory(systemImage: "pencil",
                                                                           accessibilityLabel: "Reorder tabs",
                                                                           action: { sheet = .reorderTabs }))
            }
        }
        .background(theme.primaryContainer.opacity(0.4).ignoresSafeArea(edges: .top))
    }

    private var settingsButton: some View {
        GlassCircleButton(systemImage: "gearshape.fill", accessibilityLabel: "Settings",
                          tint: theme.primaryContainer.opacity(GlassTint.prominent),
                          foreground: theme.onPrimaryContainer) {
            router.push(.settings)
        }
        .accessibilityIdentifier("library.settings")
    }

    // MARK: Content panel

    private func contentPanel(_ prefs: LibraryPreferences) -> some View {
        let panelShape = UnevenRoundedRectangle(topLeadingRadius: Tokens.Radius.contentPanel, bottomLeadingRadius: 0,
                                                bottomTrailingRadius: 0, topTrailingRadius: Tokens.Radius.contentPanel,
                                                style: .continuous)
        return VStack(spacing: 0) {
            actionRow(prefs)
                .padding(.top, 6)
                .padding(.horizontal, 10)
                .frame(minHeight: 56)
            ZStack(alignment: .top) {
                pager(prefs)
                if isSelecting {
                    SelectionCountPill(count: selectionCount)
                        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.8)))
                }
            }
            .overlay(alignment: .leading) { folderBackEdge }
            .padding(.top, 8)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isSelecting)
        }
        .background(panelShape.fill(theme.surface).ignoresSafeArea(edges: .bottom))
        .background(theme.primaryContainer.opacity(0.4).ignoresSafeArea(edges: .bottom))
    }

    /// Settings › Behavior › Back gesture controls folders (Android `folderBackGestureNavigation`: the system back
    /// gesture goes up one folder in the Folders tab): a swipe in from the leading edge, while a folder is open. With
    /// the setting off the edge belongs to the pager, as before.
    @ViewBuilder
    private var folderBackEdge: some View {
        if settings.behavior.folderBackGestureNavigation, tab == .folders, folderPath != nil {
            Color.clear
                .frame(width: 20)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onEnded { value in
                            if value.translation.width > 60 || value.predictedEndTranslation.width > 120 {
                                navigateFolderBack()
                            }
                        }
                )
                .accessibilityHidden(true)
        }
    }

    private var selectionCount: Int {
        switch tab {
        case .playlists: playlistSelection.count
        case .albums: albumSelection.count
        default: songSelection.count
        }
    }

    @ViewBuilder
    private func actionRow(_ prefs: LibraryPreferences) -> some View {
        ZStack {
            if isSelecting {
                LibrarySelectionActionRow(onSelectAll: selectAll, onDeselect: clearSelections,
                                          onOptions: openSelectionSheet)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                let tab = self.tab
                LibraryLocateState(tab: tab, isInstrumentalizedOnly: instrumentalizedOnly, folderPath: folderPath,
                                   model: model, actions: actions) { showsLocate in
                    LibraryActionRow(tab: tab,
                                     isFoldersBreadcrumbs: tab == .folders
                                         && (!prefs.isFoldersPlaylistView || folderPath != nil),
                                     folderPath: folderPath,
                                     folderRoots: model.lists.folderRoots,
                                     showsLocate: showsLocate,
                                     storageFilter: prefs.storageFilter,
                                     isInstrumentalizedOnly: instrumentalizedOnly,
                                     onMainAction: mainAction,
                                     onImport: { showsM3UImporter = true },
                                     onLocate: { locateRequests[tab, default: 0] += 1 },
                                     onStorageFilter: { withAnimation(PixlMotion.state) { prefs.cycleStorageFilter() } },
                                     onInstrumentalFilter: { instrumentalizedOnly.toggle() },
                                     prefs: prefs,
                                     onFolder: { path in withAnimation(PixlMotion.state) { folderPath = path } },
                                     onFolderBack: navigateFolderBack)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: isSelecting)
    }


    // MARK: Pager

    private func pager(_ prefs: LibraryPreferences) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(prefs.tabOrder, id: \.self) { pageTab in
                        page(pageTab, prefs: prefs)
                            .containerRelativeFrame(.horizontal)
                            .id(pageTab)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selectedTab)
            .scrollIndicators(.hidden)
            .onAppear {
                Task { @MainActor in proxy.scrollTo(tab) }
            }
            .onChange(of: didApplyLaunchState) { _, _ in
                Task { @MainActor in proxy.scrollTo(tab) }
            }
            .onChange(of: prefs.tabOrder) { _, _ in proxy.scrollTo(tab) }
        }
    }

    /// One page. Its inputs are plain values plus stable references (`selection`, `actions`): a page whose lists
    /// did not change skips its body when LibraryView re-renders.
    @ViewBuilder
    private func page(_ pageTab: LibraryTab, prefs: LibraryPreferences) -> some View {
        let context = LibraryPageContext(page: pageTab, showsScrollbarGap: settings.appearance.showScrollbar,
                                         locateRequest: locateRequests[pageTab] ?? 0)
        switch pageTab {
        case .songs:
            LibrarySongsPage(songs: instrumentalizedOnly ? [] : model.lists.songs, context: context,
                             selection: songSelection, emptyFilter: prefs.storageFilter, isLiked: false,
                             isLoading: library.isLoading, actions: actions)
        case .liked:
            LibrarySongsPage(songs: model.lists.liked, context: context, selection: songSelection,
                             emptyFilter: prefs.storageFilter, isLiked: true, isLoading: library.isLoading,
                             actions: actions)
        case .albums:
            LibraryAlbumsPage(albums: model.lists.albums, isListView: settings.library.isAlbumsListView,
                              selection: albumSelection, emptyFilter: prefs.storageFilter,
                              showsScrollbarGap: settings.appearance.showScrollbar, actions: actions)
        case .artists:
            LibraryArtistsPage(artists: model.lists.artists, emptyFilter: prefs.storageFilter,
                               showsScrollbarGap: settings.appearance.showScrollbar, actions: actions)
        case .playlists:
            LibraryPlaylistsPage(playlists: model.lists.playlists, selection: playlistSelection,
                                 showsScrollbarGap: settings.appearance.showScrollbar, actions: actions)
        case .folders:
            LibraryFoldersPage(folders: model.lists.folders, folderPlaylists: model.lists.folderPlaylists,
                               folderContents: model.lists.folderContents, folderPath: folderPath,
                               isPlaylistView: prefs.isFoldersPlaylistView, context: context,
                               selection: songSelection, actions: actions)
        }
    }

    /// The pages' actions, set once (they capture this view's stores and state, which live as long as it does).
    private func configureActions() {
        let prefs = self.prefs
        actions.play = { song, list in playback.play(song, in: list) }
        actions.showSongOptions = { song in router.present(AppSheet.songInfo(songId: song.id)) }
        actions.openAlbum = { album in
            // Start decoding the header's cover now, so the page's first frames have it.
            if let source = ArtworkSource(uriString: album.albumArtUriString) {
                ArtworkPipeline.shared.prefetch(source, pixelSize: ArtworkPipeline.displayBuckets.last ?? 1320)
            }
            router.push(.albumDetail(albumId: album.id))
        }
        actions.toggleAlbum = { album in toggleAlbum(album) }
        actions.openArtist = { artist in router.push(.artistDetail(artistId: artist.id)) }
        actions.openPlaylist = { playlist in router.push(.playlistDetail(playlistId: playlist.id)) }
        actions.reorderPlaylists = { ids in
            env.libraryEditor.savePlaylistOrder(ids)
            prefs.playlistSort = .playlistCustomOrder
        }
        actions.openFolder = { path in withAnimation(PixlMotion.state) { folderPath = path } }
        actions.openFolderPlaylist = { folder in
            router.push(.playlistDetail(playlistId: FolderPlaylist.id(for: folder.path)))
        }
    }

    /// "Cloud Only" (`hide_local_media`) forces the online filter, as Android's `effectiveStorageFilter` does.
    private func inputs(_ prefs: LibraryPreferences) -> LibraryModel.Inputs {
        LibraryModel.Inputs(snapshot: library.snapshot, songSort: prefs.songSort, albumSort: prefs.albumSort,
                            artistSort: prefs.artistSort, playlistSort: prefs.playlistSort,
                            folderSort: prefs.folderSort, likedSort: prefs.likedSort,
                            storageFilter: settings.library.hideLocalMedia ? .online : prefs.storageFilter,
                            likedAt: likedAt, revision: library.revision,
                            minTracksPerAlbum: settings.library.minTracksPerAlbum)
    }

    // MARK: Actions

    /// Android `onMainActionClick`: new playlist on Playlists, else shuffle (liked songs, a random album / artist,
    /// or every song).
    private func mainAction() {
        switch tab {
        case .playlists: sheet = .createPlaylist
        case .liked: playback.playShuffled(model.lists.liked)
        case .albums:
            guard let album = model.lists.albums.randomElement() else { return }
            playback.playShuffled(library.songs.filter { $0.albumId == album.id })
        case .artists:
            guard let artist = model.lists.artists.randomElement() else { return }
            playback.playShuffled(library.songs.filter { song in
                song.artistId == artist.id || song.artists.contains { $0.id == artist.id }
            })
        case .songs, .folders: playback.playShuffled(model.lists.songs)
        }
    }

    private func toggleAlbum(_ album: Album) {
        if !albumSelection.contains(album.id) && albumSelection.count >= maxAlbumMultiSelection {
            LibraryToast.shared.show("You can select up to \(maxAlbumMultiSelection) albums")
            return
        }
        albumSelection.toggle(album.id)
    }

    private func selectAll() {
        switch tab {
        case .playlists: playlistSelection.selectAll(model.lists.playlists.map(\.id))
        case .albums:
            let remaining = maxAlbumMultiSelection - albumSelection.count
            guard remaining > 0 else {
                LibraryToast.shared.show("You can select up to \(maxAlbumMultiSelection) albums")
                return
            }
            let candidates = model.lists.albums.map(\.id).filter { !albumSelection.contains($0) }
            albumSelection.selectAll(Array(candidates.prefix(remaining)))
        case .liked: songSelection.selectAll(model.lists.liked.map(\.id))
        case .folders:
            if let folderPath, let contents = model.lists.folderContents[folderPath] {
                songSelection.selectAll(contents.songs.map(\.id))
            }
        case .songs: songSelection.selectAll(model.lists.songs.map(\.id))
        case .artists: break
        }
    }

    private func clearSelections() {
        songSelection.clear()
        albumSelection.clear()
        playlistSelection.clear()
    }

    private func openSelectionSheet() {
        switch tab {
        case .playlists: sheet = .playlistSelection
        case .albums: sheet = .albumSelection
        default: sheet = .songSelection
        }
    }

    private func navigateFolderBack() {
        guard let folderPath else { return }
        let parent = (folderPath as NSString).deletingLastPathComponent
        let isRoot = model.lists.folders.contains { $0.path == folderPath }
        withAnimation(PixlMotion.state) {
            self.folderPath = isRoot || LibraryModel.folder(at: parent, in: model.lists.folders) == nil ? nil : parent
        }
    }

    private func importM3U(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let parsed = M3U.parse(utf8: Array(data), fileName: url.lastPathComponent, library: library.songs)
        env.libraryEditor.createPlaylist(name: parsed.name, songIds: parsed.songIds)
        LibraryToast.shared.show("Playlist created")
    }

    /// Restores the last tab; UI tests (`-screen libraryAlbums` …) open a tab, a sheet or a selection straight away.
    private func applyLaunchState(_ prefs: LibraryPreferences) {
        guard !didApplyLaunchState else { return }
        if selectedTab == nil {
            let index = settings.library.lastLibraryTabIndex
            selectedTab = prefs.tabOrder.indices.contains(index) ? prefs.tabOrder[index] : prefs.tabOrder.first
        }
        if let screen = env.launch.screen {
            let demo = DemoLibrary.snapshot
            switch screen {
            case .libraryAlbums:
                selectedTab = .albums
                settings.library.isAlbumsListView = false
            case .libraryAlbumsList:
                selectedTab = .albums
                settings.library.isAlbumsListView = true
            case .libraryArtists: selectedTab = .artists
            case .libraryPlaylists: selectedTab = .playlists
            case .libraryFolders: selectedTab = .folders
            case .libraryLiked: selectedTab = .liked
            case .librarySelection:
                selectedTab = .songs
                for song in LibrarySorting.sortSongs(demo.songs, by: prefs.songSort).prefix(3) { songSelection.toggle(song.id) }
            case .librarySort:
                selectedTab = .songs
                sheet = .sort
            case .libraryReorderTabs: sheet = .reorderTabs
            case .libraryMultiSelection:
                selectedTab = .songs
                for song in LibrarySorting.sortSongs(demo.songs, by: prefs.songSort).prefix(4) { songSelection.toggle(song.id) }
                sheet = .songSelection
            case .libraryCreatePlaylist:
                selectedTab = .playlists
                sheet = .createPlaylist
            case .libraryAddToPlaylist:
                selectedTab = .songs
                sheet = .addToPlaylist(songIds: demo.songs.prefix(2).map(\.id))
            default: break
            }
        }
        didApplyLaunchState = true
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: LibrarySheet, prefs: LibraryPreferences) -> some View {
        switch sheet {
        case .sort:
            LibrarySortSheet(tab: tab, prefs: prefs)
                .pixlSheet(detents: [.large])
        case .reorderTabs:
            ReorderTabsSheet(prefs: prefs)
                .pixlSheet(detents: [.large])
        case .songSelection:
            SongMultiSelectionSheet(songs: songSelection.ids.compactMap { library.song(id: $0) },
                                    onAddToPlaylist: { ids in self.sheet = .addToPlaylist(songIds: ids) },
                                    onDone: { songSelection.clear() })
                .pixlSheet(detents: [.medium, .large])
        case .albumSelection:
            AlbumMultiSelectionSheet(albums: albumSelection.ids.compactMap { library.album(id: $0) },
                                     onAddToPlaylist: { ids in self.sheet = .addToPlaylist(songIds: ids) },
                                     onDone: { albumSelection.clear() })
                .pixlSheet(detents: [.medium, .large])
        case .playlistSelection:
            PlaylistMultiSelectionSheet(playlists: playlistSelection.ids.compactMap { library.playlist(id: $0) },
                                        onMerge: {
                                            self.sheet = nil
                                            showsMergeDialog = true
                                        },
                                        onDone: { playlistSelection.clear() })
                .pixlSheet(detents: [.medium])
        case .addToPlaylist(let songIds):
            AddToPlaylistSheet(songIds: songIds)
                .pixlSheet(detents: [.large])
        case .createPlaylist:
            PlaylistCreationTypeSheet(onManual: {
                self.sheet = nil
                router.push(.playlistEditor(playlistId: nil))
            }, onSetupAI: {
                self.sheet = nil
                router.push(.settingsCategory(.ai))
            }, isAIEnabled: AIProviderStatus.isConfigured(env), onAI: {
                self.sheet = nil
                // The Lab is full screen (Android `CreateAiPlaylistDialog`); present it once this sheet has gone.
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    router.present(AppCover.aiPlaylistLab)
                }
            })
            .pixlSheet(detents: [.medium])
        }
    }
}

/// The Library's sheets (Android bottom sheets / dialogs of `LibraryScreen`).
nonisolated enum LibrarySheet: Identifiable, Hashable, Sendable {
    case sort
    case reorderTabs
    case songSelection
    case albumSelection
    case playlistSelection
    case addToPlaylist(songIds: [String])
    case createPlaylist

    var id: String {
        switch self {
        case .sort: "sort"
        case .reorderTabs: "reorderTabs"
        case .songSelection: "songSelection"
        case .albumSelection: "albumSelection"
        case .playlistSelection: "playlistSelection"
        case .addToPlaylist(let ids): "addToPlaylist.\(ids.joined(separator: ","))"
        case .createPlaylist: "createPlaylist"
        }
    }
}

/// Folder playlists (Android `PlaylistViewModel.FOLDER_PLAYLIST_PREFIX`): a folder opened as a read-only playlist.
nonisolated enum FolderPlaylist {
    static let prefix = "folder_playlist:"

    static func id(for path: String) -> String { prefix + path }

    static func path(from playlistId: String) -> String? {
        playlistId.hasPrefix(prefix) ? String(playlistId.dropFirst(prefix.count)) : nil
    }
}

extension LibraryTab {
    /// English titles (Android `library_tab_*`); localised titles arrive with the String Catalog.
    var tabTitle: String {
        switch self {
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        case .folders: "Folders"
        case .liked: "Liked"
        }
    }
}

/// Whether the action row's locate button shows: the current song is in the visible list and its row is off screen.
/// Computed here rather than in LibraryView, so the current song and its row's visibility re-run only the action row.
private struct LibraryLocateState<Content: View>: View {
    let tab: LibraryTab
    let isInstrumentalizedOnly: Bool
    let folderPath: String?
    let model: LibraryModel
    let actions: LibraryActions
    @ViewBuilder let content: (Bool) -> Content

    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        content(showsLocate)
    }

    private var showsLocate: Bool {
        guard let current = playback.currentSongId, !actions.currentSongVisible else { return false }
        switch tab {
        case .songs: return !isInstrumentalizedOnly && model.lists.songIds.contains(current)
        case .liked: return model.lists.likedIds.contains(current)
        case .folders:
            guard let folderPath, let contents = model.lists.folderContents[folderPath] else { return false }
            return contents.songs.contains { $0.id == current }
        default: return false
        }
    }
}
