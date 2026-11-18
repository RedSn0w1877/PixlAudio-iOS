import PixlFoundation
import PixlLibrary
import PixlModel
import SwiftUI

/// Playlist detail, new UI (2026-11-16, mockup `iOSPlaylist`; owner decisions over the mockup), themed with the hero
/// art's scheme:
/// - The cover fills the top edge to edge, sharp at the top and progressively blurred into the page
///   (`ProgressiveBlurHero`, `HeroGradients.header`, like the artist page): the playlist's own image, else its colour
///   cover (colour + icon), else the first song's cover (`PlaylistHero.art`). Over its blurred part: the name
///   (`FitWidthTitle(.playlistHero)`: SF Pro heavy at the widest width that fits two lines, morphing narrower and
///   lighter as it scrolls under the bar, where `CollapsedBarTitle` takes over), the meta line ("Made by Taizo · N Songs
///   · duration", the owner only for generated / imported playlists), then Play (prominent glass capsule) and Shuffle
///   (clear glass capsule). No "Edit with Taizo": Ask Taizo can't be opened on a playlist yet.
/// - A pinned bar: back, the collapsed name, the Sort Songs and ⋯ menus (system menus, ungrouped glass as before).
/// - The songs on a `surfaceContainerHigh` card: the edit row first (Add, Remove, Reorder), then `PlaylistSongRow`s
///   (drag handles in reorder mode, remove buttons in remove mode, swipe to queue, ⋯ → song info).
/// - Find in playlist: pull the page down past its top (or ⋯ › Find in playlist). The field pins under the bar and the
///   page shows only the matching songs until Cancel; scrolling with nothing typed puts it away (`PullToFind`).
/// - Sheets: Add songs (`SongPickerSheet`), Sort Songs, Playlist options (UI-test launch state); the ⋯ menu has edit,
///   default transition, export, download all, process all on-device / in cloud, delete.
struct PlaylistDetailView: View {
    let playlistId: String

    @Environment(LibraryStore.self) private var library

    var body: some View {
        let art = library.playlist(id: playlistId).map { PlaylistDetailContent.heroArt($0, library: library) }
        ArtworkThemed(artUri: art?.uri) {
            PlaylistDetailContent(playlistId: playlistId)
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("screen.playlistDetail")
    }
}

private struct PlaylistDetailContent: View {
    let playlistId: String

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(BlockedArtistsStore.self) private var blocked
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var songs: [Song] = []
    /// Find in playlist: pull the page down past its top (or More options › Find in playlist).
    @State private var find = ListFindModel()
    @State private var sortOption: SortOption = .songDefaultOrder
    @State private var isReorderMode = false
    @State private var isRemoveMode = false
    @State private var showsAddSongs = false
    @State private var showsSort = false
    @State private var showsOptions = false
    @State private var confirmsDelete = false
    /// The playlist written as M3U for the options menu's Export (rewritten when the playlist changes).
    @State private var exportURL: URL?
    @State private var didApplyLaunchState = false
    /// The hero name's collapse stop: only the name and the bar title read it, so scrolling never re-renders the page.
    @State private var titleState = CollapsingTitleState()
    /// The title block's and the name's heights, measured once per text / size (they don't change while scrolling):
    /// they place the collapse window.
    @State private var overlayHeight: CGFloat = 0
    @State private var titleHeight: CGFloat = 0
    /// Width, top inset and viewport, measured on the first layout and only when they change (`HeroPageMetrics`).
    @State private var metrics: HeroPageMetrics?

    private var prefs: LibraryPreferences { LibraryPreferences.shared(isUITest: env.launch.isUITest) }
    /// The song picker always starts on all songs (every song is a Spotify song; there is no local/cloud split).
    private var songPickerFilter: StorageFilter {
        .all
    }
    private var playlist: Playlist? { library.playlist(id: playlistId) }

    nonisolated private struct Inputs: Equatable {
        var songIds: [String]
        var librarySongCount: Int
        var sort: SortOption
    }

    /// What fills the hero: the playlist's image, its colour cover, else the first song's cover in the playlist's own
    /// order (re-sorting the list never swaps the hero). Stops at the first song with a cover.
    static func heroArt(_ playlist: Playlist, library: LibraryStore) -> PlaylistHero.Art {
        PlaylistHero.art(coverImageUri: playlist.coverImageUri, hasColourCover: playlist.coverColorArgb != nil,
                         songArt: playlist.songIds.lazy.map { library.song(id: $0)?.albumArtUriString })
    }

    var body: some View {
        let playlist = self.playlist
        // Measured, not a `GeometryReader` round the page: the keyboard (Find in playlist) moves no metric here, so
        // its frames don't rebuild the hero and the rows (`HeroPageMetrics`).
        ZStack(alignment: .top) {
            theme.surface.ignoresSafeArea()
            if let metrics {
                let safeTop = metrics.safeTop
                let heroHeight = CGFloat(HeroHeader.height(width: Double(metrics.width),
                                                           viewportHeight: Double(metrics.viewport),
                                                           aspect: Double(Tokens.PageHero.aspect)))
                if let playlist {
                    page(playlist, width: metrics.width, heroHeight: heroHeight, safeTop: safeTop)
                    topChrome(playlist, safeTop: safeTop)
                } else {
                    VStack(spacing: 0) {
                        HeroTopBar(title: "", titleState: titleState, safeTop: safeTop, groupsGlass: false,
                                   onBack: { router.pop() }) {
                            EmptyView()
                        }
                        LibraryEmptyState(systemImage: "music.note.list", title: "Playlist not found.", subtitle: "")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .measuringHeroPage($metrics)
        .onChange(of: Inputs(songIds: playlist?.songIds ?? [], librarySongCount: library.songs.count, sort: sortOption),
                  initial: true) { _, inputs in
            songs = orderedSongs(inputs)
            find.setSongs(songs)
        }
        .onAppear {
            applyLaunchState()
            SongPickerDefaults.warm(library: library, filter: songPickerFilter)
        }
        // The M3U is built and written off the main actor (`PlaylistExport.writeM3U`).
        .task(id: playlist?.songIds) {
            guard let playlist else { return }
            exportURL = await PlaylistExport.writeTemporaryM3U(playlist, library: library)
        }
        .sheet(isPresented: $showsAddSongs) {
            SongPickerSheet(initiallySelected: Set(playlist?.songIds ?? []),
                            initialStorageFilter: songPickerFilter) { selected in
                env.libraryEditor.addSongs(Array(selected), toPlaylist: playlistId)
                showsAddSongs = false
            }
            .pixlSheet(detents: [.large])
        }
        .sheet(isPresented: $showsSort) {
            PlaylistSongSortSheet(selected: sortOption) { option in
                withAnimation(PixlMotion.state) { sortOption = option }
                prefs.setSongOrder(option, forPlaylist: playlistId)
            }
            .pixlSheet(detents: [.large])
        }
        .sheet(isPresented: $showsOptions) {
            optionsSheet(playlist)
                .pixlSheet(detents: [.medium, .large])
        }
        .alert("Delete playlist?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) {
                env.libraryEditor.deletePlaylists([playlistId])
                router.pop()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this playlist?")
        }
        .libraryToast()
    }

    // MARK: Ordering

    private func orderedSongs(_ inputs: Inputs) -> [Song] {
        let resolved = inputs.songIds.compactMap { library.song(id: $0) }
        return inputs.sort == .songDefaultOrder ? resolved : LibrarySorting.sortPlaylistSongs(resolved, by: inputs.sort)
    }

    // MARK: Page

    /// One scrolling page: the hero with its title block, then the song card. With Find open, the hero folds away to
    /// the pinned field's height and the card shows the matching songs (the keyboard would otherwise cover them).
    /// Both modes share one structure: the hero stays mounted (folded, transparent; its blurred copy and fitted title
    /// survive Find) and the rows are one `ForEach` over whichever list shows, so opening or closing Find keeps every
    /// row's identity instead of rebuilding the page.
    private func page(_ playlist: Playlist, width: CGFloat, heroHeight: CGFloat, safeTop: CGFloat) -> some View {
        let titleTop = HeroHeader.overlayTop(heroHeight: Double(heroHeight), overlayHeight: Double(overlayHeight))
        let window = HeroHeader.titleCollapse(titleTop: titleTop, titleHeight: Double(titleHeight),
                                              barBottom: Double(safeTop + Tokens.PageHero.barHeight))
        let isFinding = find.isOpen
        let noMatches = isFinding && find.hasNoMatches
        let rows = isFinding ? (find.results ?? songs) : songs
        let foldedHeight = safeTop + Tokens.PageHero.barHeight + Tokens.PageHero.findFieldHeight + 8
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                hero(playlist, width: width, height: heroHeight, safeTop: safeTop)
                    // Not clipped: the pull-down stretch grows the hero past its top edge.
                    .frame(height: isFinding ? foldedHeight : heroHeight, alignment: .top)
                    .opacity(isFinding ? 0 : 1)
                    .allowsHitTesting(!isFinding)
                    .accessibilityHidden(isFinding)
                if noMatches {
                    ListFindNoMatches(query: find.query)
                        .padding(.top, 32)
                } else {
                    panelTop(showsEditRow: !isFinding)
                }
                if !isFinding, songs.isEmpty {
                    emptyState
                }
                songRows(rows)
                if !noMatches {
                    panelBottom
                }
            }
            // The mini player's and the bar's room comes from the route's safe area (`BottomBarsClearance`).
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        // Pulling down past the top reveals Find in playlist; it bounces even when the page is shorter than the screen.
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollDismissesKeyboard(.interactively)
        .ignoresSafeArea(edges: .top)
        .trackingTitleCollapse(titleState, start: CGFloat(window.start), distance: CGFloat(window.distance))
        // Discrete zones: the action runs only when the page crosses a threshold, never per frame.
        .onScrollGeometryChange(for: PullToFind.Zone.self) { geometry in
            PullToFind.zone(offset: Double(geometry.contentOffset.y + geometry.contentInsets.top))
        } action: { _, zone in
            entered(zone)
        }
        .accessibilityAction(named: "Find in playlist") { withAnimation(PixlMotion.state) { find.open() } }
    }

    /// The bar, and under it the Find field while it is open (on the page colour, so the rows pass under it).
    private func topChrome(_ playlist: Playlist, safeTop: CGFloat) -> some View {
        VStack(spacing: 0) {
            HeroTopBar(title: playlist.name, titleState: titleState, safeTop: safeTop, forcesBackdrop: find.isOpen,
                       groupsGlass: false, onBack: { router.pop() }) {
                // Small menus morph out of their buttons (owner change 2026-10-02).
                GlassCircleMenu(systemImage: "line.3.horizontal.decrease", accessibilityLabel: "Sort Songs") {
                    SortMenuSections(options: SortOption.songs, selected: sortOption) { option in
                        withAnimation(PixlMotion.state) { sortOption = option }
                        prefs.setSongOrder(option, forPlaylist: playlistId)
                    }
                }
                .accessibilityIdentifier("playlist.sort")
                GlassCircleMenu(systemImage: "ellipsis", accessibilityLabel: "More options") {
                    optionsMenu
                }
                .accessibilityIdentifier("playlist.more")
            }
            if find.isOpen {
                ListFindField(model: find)
                    .background(alignment: .top) {
                        LinearGradient(stops: [.init(color: theme.surface, location: 0),
                                               .init(color: theme.surface, location: 0.78),
                                               .init(color: theme.surface.opacity(0), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .padding(.bottom, -16)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// Entering a pull / scroll zone opens or puts away Find in playlist (`PullToFind`).
    private func entered(_ zone: PullToFind.Zone) {
        let action = PullToFind.action(entering: zone, isOpen: find.isOpen, hasQuery: !find.query.isEmpty,
                                       isEditing: isReorderMode || isRemoveMode)
        switch action {
        case .open?: withAnimation(PixlMotion.state) { find.open() }
        case .close?: withAnimation(PixlMotion.state) { find.close() }
        case nil: break
        }
    }

    // MARK: Hero

    /// The cover filling the top edge to edge, sharp at the top and progressively blurred into the page under the title
    /// block (`ProgressiveBlurHero`, one pre-blurred layer). It stretches from its bottom edge when the page is pulled
    /// down and trails the page a little as it scrolls away — both in `visualEffect` (render phase).
    private func hero(_ playlist: Playlist, width: CGFloat, height: CGFloat, safeTop: CGFloat) -> some View {
        let art = Self.heroArt(playlist, library: library)
        let source = ArtworkSource(uriString: art.uri)
        return ZStack(alignment: .bottomLeading) {
            ProgressiveBlurHero(source: source, gradients: .header, veil: theme.surface,
                                topScrimHeight: safeTop + Tokens.PageHero.barHeight + 16,
                                size: CGSize(width: width, height: height)) {
                heroArt(art, source: source, playlist: playlist, width: width, height: height)
            }
            .frame(width: width, height: height)
            .visualEffect { content, proxy in
                let effect = HeroHeader.scrollEffect(minY: Double(proxy.frame(in: .scrollView).minY),
                                                     height: Double(proxy.size.height))
                return content
                    .scaleEffect(CGFloat(effect.scale), anchor: .bottom)
                    .offset(y: CGFloat(effect.offset))
            }
            heroOverlay(playlist)
                .padding(.horizontal, Tokens.PageHero.sidePadding)
                .padding(.bottom, 4)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { overlayHeight = $0 }
        }
    }

    @ViewBuilder
    private func heroArt(_ art: PlaylistHero.Art, source: ArtworkSource?, playlist: Playlist, width: CGFloat,
                         height: CGFloat) -> some View {
        if let source {
            // A square at the hero's larger side, centre-cropped to the hero (decoded once at that size).
            ArtworkView(source: source, size: max(width, height), cornerRadius: 0)
                .frame(width: width, height: height)
                .clipped()
                .accessibilityHidden(true)
        } else if art == .colour, let colour = playlist.coverColorArgb {
            // The colour cover: its colour edge to edge, its icon large in the sharp part.
            let argb = UInt32(bitPattern: colour)
            ZStack {
                Color(argb: argb)
                Image(systemName: PlaylistIcons.symbol(for: playlist.coverIconName))
                    .font(.system(size: min(width, height) * 0.34, weight: .semibold))
                    .foregroundStyle(PlaylistIcons.contentColor(onArgb: argb, theme: theme))
                    .offset(y: -height * 0.14)
            }
            .frame(width: width, height: height)
            .accessibilityHidden(true)
        } else {
            Image(systemName: "music.note.list")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant.opacity(0.2))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surfaceVariant)
                .accessibilityHidden(true)
        }
    }

    /// Over the blurred part (mockup `iOSPlaylist`): the name (SF Pro heavy at the widest width that fits two lines,
    /// morphing narrower and lighter as it scrolls under the bar), the meta line, then Play and Shuffle.
    private func heroOverlay(_ playlist: Playlist) -> some View {
        let owner = PlaylistHero.owner(isAiGenerated: playlist.isAiGenerated, source: playlist.source)
        return VStack(alignment: .leading, spacing: 0) {
            FitWidthTitle(text: playlist.name, face: .playlistHero, narrowest: .compressed, lines: 2,
                          collapse: titleState)
                .foregroundStyle(theme.onSurface)
                .shadow(color: theme.surface.opacity(0.35), radius: 7, y: 1)
                .accessibilityAddTraits(.isHeader)
                .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { titleHeight = $0 }
            HStack(spacing: 8) {
                if let owner { ownerBadge(owner) }
                Text(PlaylistHero.meta(owner: owner, songCount: songs.count,
                                       duration: LibraryFormat.totalDuration(songs)))
                    .pixlFont(.custom(size: 15, weight: .medium))
                    .foregroundStyle(theme.onSurface.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.top, 4)
            heroActions
                .padding(.top, 14)
        }
    }

    /// The mockup's 22 pt badge before the owner: Taizo's sparkles, or Spotify's disc.
    private func ownerBadge(_ owner: PlaylistHero.Owner) -> some View {
        let isTaizo = owner == .taizo
        return Image(systemName: isTaizo ? "sparkles" : "opticaldisc.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isTaizo ? theme.onTertiaryContainer : Color(argb: 0xFF1DB954))
            .frame(width: 22, height: 22)
            .background(Circle().fill(isTaizo ? theme.tertiaryContainer : theme.surfaceContainerHigh))
            .accessibilityHidden(true)
    }

    /// Play (the one prominent glass capsule) and Shuffle (a clear glass capsule), sharing one glass container.
    private var heroActions: some View {
        let enabled = !songs.isEmpty
        return GlassEffectContainer(spacing: Tokens.PageHero.actionSpacing / 2) {
            HStack(spacing: Tokens.PageHero.actionSpacing) {
                Button {
                    guard let first = songs.first else { return }
                    if playback.isShuffleEnabled { playback.setShuffleEnabled(false) }
                    playback.play(first, in: songs, source: .playlist(id: playlistId))
                } label: {
                    actionLabel("Play", systemImage: "play.fill", foreground: theme.onPrimary)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: Capsule(), tint: theme.primary.opacity(GlassTint.prominent), interactive: true)
                .accessibilityLabel("Play")
                .accessibilityIdentifier("playlist.play")
                Button {
                    playback.playShuffled(songs)
                } label: {
                    actionLabel("Shuffle", systemImage: "shuffle", foreground: theme.onSurface)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: true)
                .accessibilityLabel("Shuffle")
                .accessibilityIdentifier("playlist.shuffle")
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String, foreground: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .accessibilityHidden(true)
            Text(title)
                .pixlFont(.custom(size: 17, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: Tokens.PageHero.actionHeight)
        .contentShape(.capsule)
    }

    // MARK: Song card

    /// The card's top: rounded corners, then (outside Find) the edit row.
    private func panelTop(showsEditRow: Bool) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: Tokens.PageHero.panelCorner, bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0, topTrailingRadius: Tokens.PageHero.panelCorner,
                                           style: .continuous)
        return VStack(spacing: 0) {
            if showsEditRow { editRow }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, showsEditRow ? 14 : 12)
        .padding(.bottom, showsEditRow ? 4 : 0)
        .background(shape.fill(theme.surfaceContainerHigh))
        .padding(.horizontal, Tokens.PageHero.panelInset)
        .padding(.top, showsEditRow ? 12 : 0)
    }

    /// The card's bottom: its rounded end.
    private var panelBottom: some View {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: Tokens.PageHero.panelCorner,
                               bottomTrailingRadius: Tokens.PageHero.panelCorner, topTrailingRadius: 0,
                               style: .continuous)
            .fill(theme.surfaceContainerHigh)
            .frame(height: 16)
            .padding(.horizontal, Tokens.PageHero.panelInset)
            .accessibilityHidden(true)
    }

    /// Android: Add (capsule, `tertiaryContainer`), then Remove and Reorder stretched over the rest.
    private var editRow: some View {
        // The three buttons render together (spacing below their 8 pt gaps).
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 8) {
                SegmentedGlassButton(title: "Add", systemImage: "plus", accessibilityLabel: "Add songs", leading: 21,
                                     trailing: 21, height: 42, horizontalPadding: 12,
                                     tint: theme.tertiaryContainer.opacity(GlassTint.prominent),
                                     foreground: theme.onTertiaryContainer) { showsAddSongs = true }
                    .accessibilityIdentifier("playlist.add")
                modeButton("Remove", systemImage: "minus.circle", isOn: isRemoveMode) {
                    find.close()
                    withAnimation(PixlMotion.state) { isRemoveMode.toggle() }
                }
                .accessibilityIdentifier("playlist.remove")
                modeButton("Reorder", systemImage: "arrow.up.arrow.down", isOn: isReorderMode) {
                    find.close()
                    withAnimation(PixlMotion.state) { isReorderMode.toggle() }
                }
                .accessibilityIdentifier("playlist.reorder")
            }
        }
        .padding(.horizontal, 12)
    }

    private func modeButton(_ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        let radius: CGFloat = isOn ? 24 : 12
        return SegmentedGlassButton(title: title, systemImage: systemImage, accessibilityLabel: title, leading: radius,
                                    trailing: radius, height: 42, horizontalPadding: 8, iconSize: 18,
                                    tint: (isOn ? theme.tertiary : theme.surfaceContainerHighest)
                                        .opacity(isOn ? GlassTint.prominent : GlassTint.container),
                                    foreground: isOn ? theme.onTertiary : theme.onSurface,
                                    titleStyle: .labelMedium, fillsWidth: true, action: action)
            .frame(maxWidth: .infinity)
            .animation(PixlMotion.state, value: isOn)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(theme.onSurfaceVariant)
                .frame(width: 48, height: 48)
            Spacer().frame(height: 8)
            Text("This playlist is empty.")
                .pixlFont(.titleMedium)
                .foregroundStyle(theme.onSurface)
            Text("Tap on 'Add Songs' to begin.")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(theme.surfaceContainerHigh)
        .padding(.horizontal, Tokens.PageHero.panelInset)
    }

    /// The rows, each its own item of the page's lazy stack (laid out only when near the screen), on the card's colour
    /// (plain fills that tile into one card; the rows themselves are the glass).
    private func songRows(_ list: [Song]) -> some View {
        ForEach(list) { song in
            PlaybackRowState(songId: song.id) { isCurrent, isPlaying in
                PlaylistSongRow(song: song, isCurrent: isCurrent, isPlaying: isPlaying,
                                showsDragHandle: isReorderMode,
                                showsRemove: isRemoveMode,
                                onTap: { blocked.playTapped(song, in: list, using: playback, source: .playlist(id: playlistId)) },
                                onMore: { router.present(AppSheet.songInfo(songId: song.id)) },
                                onRemove: { env.libraryEditor.removeSong(song.id, fromPlaylist: playlistId) })
            }
            .swipeToQueue(song: song, isEnabled: !isReorderMode && !isRemoveMode)
            .dropDestination(for: String.self) { items, _ in
                move(items.first, onto: song.id)
            }
            .padding(.vertical, 4)
            .background(theme.surfaceContainerHigh)
            .padding(.horizontal, Tokens.PageHero.panelInset)
        }
    }

    /// Drop of a dragged song onto another row (Android `ReorderableItem` → `savePlaylistSongOrder`). The playlist
    /// switches to its manual order, like Android.
    private func move(_ sourceId: String?, onto targetId: String) -> Bool {
        guard isReorderMode, let sourceId, sourceId != targetId,
              let from = songs.firstIndex(where: { $0.id == sourceId }),
              let to = songs.firstIndex(where: { $0.id == targetId }) else { return false }
        var reordered = songs
        let moved = reordered.remove(at: from)
        reordered.insert(moved, at: to)
        withAnimation(PixlMotion.state) { songs = reordered }
        sortOption = .songDefaultOrder
        prefs.setSongOrder(.songDefaultOrder, forPlaylist: playlistId)
        env.libraryEditor.setSongOrder(reordered.map(\.id), inPlaylist: playlistId)
        return true
    }

    // MARK: Options menu

    /// "Process all on-device": an instrumental for every song that has none, one after another.
    private func processAllOnDevice() {
        let queued = env.tais.studio.renderInstrumentals(songs)
        LibraryToast.shared.show(queued == 0 ? "Every song here already has an instrumental."
                                             : "Making instrumentals for \(queued) \(queued == 1 ? "song" : "songs")")
    }

    /// "Process all in cloud": starts at once (no confirm sheet); the toast says how many went, or why none did.
    private func processAllInCloud() {
        let cloud = env.cloud, batch = songs, title = playlist?.name ?? "Playlist"
        Task {
            let outcome = await cloud.startNow(songs: batch, title: title)
            LibraryToast.shared.show(outcome.message(useCellular: cloud.settings.useCellular))
        }
    }

    /// Android's playlist options as a menu: edit, transition, export, batch actions, then delete.
    @ViewBuilder
    private var optionsMenu: some View {
        Section {
            Button("Find in playlist", systemImage: "magnifyingglass") { withAnimation(PixlMotion.state) { find.open() } }
            Button("Edit playlist", systemImage: "pencil") { router.push(.playlistEditor(playlistId: playlistId)) }
            Button("Set default transition", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                router.push(.editTransition(playlistId: playlistId))
            }
            if let exportURL {
                ShareLink(item: exportURL) { Label("Export Playlist", systemImage: "paperclip") }
            }
        }
        Section {
            Button("Download all songs", systemImage: "arrow.down.circle") {
                let queued = env.youtube.downloads.downloadAll(songs)
                LibraryToast.shared.show(queued == 0 ? "No streamed songs in this playlist to download."
                                                     : "Downloading \(queued) songs")
            }
            Button("Process all on-device", systemImage: "sparkles") { processAllOnDevice() }
            // Cloud Studio (iOS-first), always offered: with the cloud off it says where to turn it on. In a menu the
            // second Text is the item's subtitle.
            Button {
                processAllInCloud()
            } label: {
                Text("Process all in cloud")
                Text("Cloud yields better results but requires a Wi-Fi connection.")
                Image(systemName: "icloud.and.arrow.up")
            }
        }
        Button("Delete playlist", systemImage: "trash", role: .destructive) { confirmsDelete = true }
    }

    // MARK: Options sheet (UI-test launch state)

    private func optionsSheet(_ playlist: Playlist?) -> some View {
        PlaylistOptionsSheet(playlist: playlist,
                             onEdit: {
                                 showsOptions = false
                                 router.push(.playlistEditor(playlistId: playlistId))
                             },
                             onDelete: {
                                 showsOptions = false
                                 confirmsDelete = true
                             },
                             onTransition: {
                                 showsOptions = false
                                 router.push(.editTransition(playlistId: playlistId))
                             },
                             onDownloadAll: {
                                 showsOptions = false
                                 // Stage 11: queue every streamed song (Android `requestDownload` per song).
                                 let queued = env.youtube.downloads.downloadAll(songs)
                                 LibraryToast.shared.show(queued == 0 ? "No streamed songs in this playlist to download."
                                                                      : "Downloading \(queued) songs")
                             },
                             onProcessAllOnDevice: {
                                 showsOptions = false
                                 processAllOnDevice()
                             },
                             onProcessAllInCloud: {
                                 showsOptions = false
                                 processAllInCloud()
                             })
    }

    private func applyLaunchState() {
        guard !didApplyLaunchState else { return }
        didApplyLaunchState = true
        sortOption = prefs.songOrder(forPlaylist: playlistId)
        switch env.launch.screen {
        case .playlistAddSongs?: showsAddSongs = true
        case .playlistOptions?: showsOptions = true
        case .playlistFind?, .playlistFindEmpty?:
            // UI tests: the field open on a query ('sora' matches three songs, 'zzz' none).
            let base = songs.isEmpty ? orderedSongs(Inputs(songIds: playlist?.songIds ?? [], librarySongCount: library.songs.count, sort: sortOption)) : songs
            find.setSongs(base)
            find.open()
            find.query = env.launch.screen == .playlistFind ? "sora" : "zzz"
        case .playlistReorder?:
            isReorderMode = true
            isRemoveMode = true
        default: break
        }
    }
}

/// Android's playlist options `ModalBottomSheet`: "Playlist options" (`titleLarge`) over the name (`bodyMedium`), then
/// the action rows.
private struct PlaylistOptionsSheet: View {
    let playlist: Playlist?
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onTransition: () -> Void
    let onDownloadAll: () -> Void
    let onProcessAllOnDevice: () -> Void
    let onProcessAllInCloud: () -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme
    @State private var exportURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Playlist options")
                        .pixlFont(.titleLarge)
                        .foregroundStyle(theme.onSurface)
                    if let name = playlist?.name {
                        Text(name)
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                action("Edit playlist", "pencil", onEdit).accessibilityIdentifier("playlistOptions.edit")
                action("Delete playlist", "trash", onDelete).accessibilityIdentifier("playlistOptions.delete")
                action("Set default transition", "point.topleft.down.to.point.bottomright.curvepath", onTransition)
                if let exportURL {
                    ShareLink(item: exportURL) {
                        PlaylistActionRow("Export Playlist", systemImage: "paperclip")
                    }
                    .buttonStyle(.plain)
                    .playlistActionTile(theme)
                } else {
                    PlaylistActionRow("Export Playlist", systemImage: "paperclip")
                        .opacity(0.5)
                        .playlistActionTile(theme, interactive: false)
                }
                action("Download all songs", "arrow.down.circle", onDownloadAll)
                action("Process all on-device", "sparkles", onProcessAllOnDevice)
                action("Process all in cloud", "icloud.and.arrow.up", onProcessAllInCloud,
                       subtitle: "Cloud yields better results but requires a Wi-Fi connection.")
            }
            .padding(.vertical, 12)
            .padding(.top, 12)
        }
        .task(id: playlist?.id) {
            guard let playlist else { return }
            let url = await PlaylistExport.writeTemporaryM3U(playlist, library: library)
            if !Task.isCancelled { exportURL = url }
        }
        .accessibilityIdentifier("sheet.playlistOptions")
    }

    private func action(_ title: String, _ systemImage: String, _ onTap: @escaping () -> Void,
                        subtitle: String? = nil) -> some View {
        Button(action: onTap) {
            PlaylistActionRow(title, subtitle: subtitle, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .playlistActionTile(theme)
    }
}
