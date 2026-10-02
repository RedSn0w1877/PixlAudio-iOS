import PixlLibrary
import PixlModel
import SwiftUI

/// Playlist detail (Android `PlaylistDetailScreen`), also used for folder playlists (`folder_playlist:<path>`):
/// - the top bar: back circle, the name (`headlineMedium`) over "N Songs • duration" (`labelMedium`), the sort and ⋮
///   circles (no ⋮ for folders);
/// - the play row (56 pt): "Play it" (`primary`, 60 / 14 pt corners) and Shuffle (`secondaryContainer`, 14 / 60 pt);
/// - for real playlists the edit row (42 pt): Add (`tertiaryContainer` capsule), then Remove and Reorder sharing the
///   rest (12 pt corners, 24 pt and `tertiary` while active);
/// - the lyric-sync progress card, then the songs in a `surfaceContainerHigh` panel (32 pt top corners) as
///   `PlaylistSongRow`s, 8 pt apart; drag handles in reorder mode, remove buttons in remove mode;
/// - sheets: Add songs (`SongPickerSheet`), Sort Songs, Playlist options (edit, delete, default transition, export,
///   download / sync lyrics / instrumentalize all).
struct PlaylistDetailView: View {
    let playlistId: String

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var songs: [Song] = []
    @State private var sortOption: SortOption = .songDefaultOrder
    @State private var isReorderMode = false
    @State private var isRemoveMode = false
    @State private var showsAddSongs = false
    @State private var showsSort = false
    @State private var showsOptions = false
    @State private var confirmsDelete = false
    /// The playlist written as M3U for the options menu's Export (rewritten when the playlist changes).
    @State private var exportURL: URL?
    /// Stage 14: the playlist's lyric-sync run, from TAIS Studio's job states.
    private var lyricSync: PlaylistLyricSyncState { env.tais.studio.lyricSyncState(playlistId: playlistId) }
    @State private var didApplyLaunchState = false

    private var prefs: LibraryPreferences { LibraryPreferences.shared(isUITest: env.launch.isUITest) }
    /// The song picker's starting storage filter (Android: offline when the library has cloud songs, else all).
    private var songPickerFilter: StorageFilter {
        library.songs.contains(where: LibrarySorting.isOnline) ? .offline : .all
    }
    private var folderPath: String? { FolderPlaylist.path(from: playlistId) }
    private var isFolder: Bool { folderPath != nil }

    /// The folder as a read-only pseudo playlist (Android `loadPlaylistDetails`), built when the library changes.
    @State private var folderPlaylist: Playlist?
    @State private var didResolveFolder = false

    /// The playlist (or the folder's pseudo playlist).
    private var playlist: Playlist? { isFolder ? folderPlaylist : library.playlist(id: playlistId) }

    private func resolveFolder() {
        guard let folderPath else { return }
        // The library's folder tree is built off the main actor with the detail index.
        let folder = LibraryModel.folder(at: folderPath, in: library.folderTree)
        folderPlaylist = folder.map { Playlist(id: playlistId, name: $0.name, songIds: LibraryModel.allSongs($0).map(\.id)) }
        didResolveFolder = true
    }

    nonisolated private struct Inputs: Equatable {
        var songIds: [String]
        var librarySongCount: Int
        var sort: SortOption
    }

    var body: some View {
        let playlist = self.playlist
        VStack(spacing: 0) {
            DetailTopBar(title: playlist?.name ?? "Playlist",
                         subtitle: "\(LibraryFormat.songCount(songs.count)) • \(LibraryFormat.totalDuration(songs))",
                         onBack: { router.pop() }) {
                // Small menus morph out of their buttons (owner change 2026-10-02).
                GlassCircleMenu(systemImage: "line.3.horizontal.decrease", accessibilityLabel: "Sort Songs") {
                    SortMenuSections(options: SortOption.songs, selected: sortOption) { option in
                        withAnimation(PixlMotion.state) { sortOption = option }
                        prefs.setSongOrder(option, forPlaylist: playlistId)
                    }
                }
                .accessibilityIdentifier("playlist.sort")
                if !isFolder {
                    GlassCircleMenu(systemImage: "ellipsis", accessibilityLabel: "More options") {
                        optionsMenu
                    }
                        .accessibilityIdentifier("playlist.more")
                }
            }
            if isFolder && !didResolveFolder {
                Spacer()
            } else if playlist == nil {
                LibraryEmptyState(systemImage: "music.note.list", title: "Playlist not found.", subtitle: "")
            } else {
                playRow
                if !isFolder { editRow }
                PlaylistLyricSyncCard(state: lyricSync,
                                      onCancel: { env.tais.studio.cancelLyricBatch(playlistId: playlistId) },
                                      onRetry: { env.tais.studio.retryLyricBatch(playlistId: playlistId, songs: songs) })
                    .padding(.horizontal, 16)
                    .padding(.vertical, lyricSync.total > 0 ? 8 : 0)
                if songs.isEmpty {
                    emptyState
                } else {
                    songList
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: Inputs(songIds: playlist?.songIds ?? [], librarySongCount: library.songs.count, sort: sortOption),
                  initial: true) { _, inputs in
            songs = orderedSongs(inputs)
        }
        .onAppear {
            applyLaunchState()
            if !isFolder { SongPickerDefaults.warm(library: library, filter: songPickerFilter) }
        }
        // The M3U is built and written off the main actor (`PlaylistExport.writeM3U`).
        .task(id: playlist?.songIds) {
            guard let playlist, !isFolder else { return }
            exportURL = await PlaylistExport.writeTemporaryM3U(playlist, library: library)
        }
        .onChange(of: library.songs.count, initial: true) { _, _ in resolveFolder() }
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
        .accessibilityIdentifier("screen.playlistDetail")
    }

    // MARK: Ordering

    private func orderedSongs(_ inputs: Inputs) -> [Song] {
        let resolved = inputs.songIds.compactMap { library.song(id: $0) }
        if isFolder {
            // Folder playlists are always sorted (Android: `Sorted(currentPlaylistSongsSortOption)`, title A-Z first).
            let option = inputs.sort == .songDefaultOrder ? SortOption.songTitleAZ : inputs.sort
            return LibrarySorting.sortPlaylistSongs(resolved, by: option)
        }
        return inputs.sort == .songDefaultOrder ? resolved : LibrarySorting.sortPlaylistSongs(resolved, by: inputs.sort)
    }

    // MARK: Rows

    /// Android: a 62 pt row (20 pt sides, 6 pt bottom; 8 pt for folders) of two 76 pt buttons clipped to it.
    private var playRow: some View {
        let enabled = !songs.isEmpty
        // The two buttons render together (spacing below their 8 pt gap).
        return GlassEffectContainer(spacing: 4) {
            HStack(spacing: 8) {
                SegmentedGlassButton(title: "Play it", systemImage: "play.fill", accessibilityLabel: "Play",
                                     leading: 60, trailing: 14, height: 56, horizontalPadding: 10,
                                     tint: theme.primary.opacity(GlassTint.prominent), foreground: theme.onPrimary,
                                     fillsWidth: true) {
                    guard let first = songs.first else { return }
                    if playback.isShuffleEnabled { playback.setShuffleEnabled(false) }
                    playback.play(first, in: songs)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("playlist.play")
                SegmentedGlassButton(title: "Shuffle", systemImage: "shuffle", accessibilityLabel: "Shuffle",
                                     leading: 14, trailing: 60, height: 56, horizontalPadding: 10,
                                     tint: theme.secondaryContainer.opacity(GlassTint.prominent),
                                     foreground: theme.onSecondaryContainer, fillsWidth: true) {
                    playback.playShuffled(songs)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("playlist.shuffle")
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .padding(.horizontal, 20)
        .padding(.bottom, isFolder ? 8 : 6)
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
                    withAnimation(PixlMotion.state) { isRemoveMode.toggle() }
                }
                .accessibilityIdentifier("playlist.remove")
                modeButton("Reorder", systemImage: "arrow.up.arrow.down", isOn: isReorderMode) {
                    withAnimation(PixlMotion.state) { isReorderMode.toggle() }
                }
                .accessibilityIdentifier("playlist.reorder")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private func modeButton(_ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        let radius: CGFloat = isOn ? 24 : 12
        return SegmentedGlassButton(title: title, systemImage: systemImage, accessibilityLabel: title, leading: radius,
                                    trailing: radius, height: 42, horizontalPadding: 8, iconSize: 18,
                                    tint: (isOn ? theme.tertiary : theme.surfaceContainerHigh)
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
            Text(isFolder ? "This folder doesn't contain songs." : "Tap on 'Add Songs' to begin.")
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var songList: some View {
        let panel = UnevenRoundedRectangle(topLeadingRadius: 32, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                           topTrailingRadius: 32, style: .continuous)
        return ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(songs) { song in
                    PlaybackRowState(songId: song.id) { isCurrent, isPlaying in
                        PlaylistSongRow(song: song, isCurrent: isCurrent, isPlaying: isPlaying,
                                        showsDragHandle: isReorderMode && !isFolder,
                                        showsRemove: isRemoveMode && !isFolder,
                                        onTap: { playback.play(song, in: songs) },
                                        onMore: { router.present(AppSheet.songInfo(songId: song.id)) },
                                        onRemove: { env.libraryEditor.removeSong(song.id, fromPlaylist: playlistId) })
                    }
                    .dropDestination(for: String.self) { items, _ in
                        move(items.first, onto: song.id)
                    }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 16 + playback.miniPlayerClearance)
        }
        .scrollIndicators(.hidden)
        .background(panel.fill(theme.surfaceContainerHigh))
        .clipShape(panel)
        .ignoresSafeArea(edges: .bottom)
    }

    /// Drop of a dragged song onto another row (Android `ReorderableItem` → `savePlaylistSongOrder`). The playlist
    /// switches to its manual order, like Android.
    private func move(_ sourceId: String?, onto targetId: String) -> Bool {
        guard isReorderMode, !isFolder, let sourceId, sourceId != targetId,
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

    /// Android's playlist options as a menu: edit, transition, export, batch actions, then delete.
    @ViewBuilder
    private var optionsMenu: some View {
        Section {
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
                                                     : "Downloading (queued) songs")
            }
            Button("Sync lyrics for all songs", systemImage: "text.quote") {
                env.tais.studio.syncLyrics(playlistId: playlistId, songs: songs)
            }
            Button("Instrumentalize all songs", systemImage: "sparkles") {
                let queued = env.tais.studio.renderInstrumentals(songs)
                LibraryToast.shared.show(queued == 0 ? "Every song here already has an instrumental."
                                                     : "Rendering instrumentals for \(queued) songs")
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
                                                                      : "Downloading (queued) songs")
                             },
                             onSyncLyricsAll: {
                                 showsOptions = false
                                 // Stage 14: one lyric-sync job per song through TAIS Studio's lane.
                                 env.tais.studio.syncLyrics(playlistId: playlistId, songs: songs)
                             },
                             onInstrumentalizeAll: {
                                 showsOptions = false
                                 let queued = env.tais.studio.renderInstrumentals(songs)
                                 LibraryToast.shared.show(queued == 0 ? "Every song here already has an instrumental."
                                                                      : "Rendering instrumentals for \(queued) songs")
                             })
    }

    private func applyLaunchState() {
        guard !didApplyLaunchState else { return }
        didApplyLaunchState = true
        sortOption = prefs.songOrder(forPlaylist: playlistId)
        switch env.launch.screen {
        case .playlistAddSongs?: showsAddSongs = true
        case .playlistOptions?: showsOptions = true
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
    let onSyncLyricsAll: () -> Void
    let onInstrumentalizeAll: () -> Void

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
                action("Sync lyrics for all songs", "text.quote", onSyncLyricsAll)
                action("Instrumentalize all songs", "sparkles", onInstrumentalizeAll)
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

    private func action(_ title: String, _ systemImage: String, _ onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            PlaylistActionRow(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .playlistActionTile(theme)
    }
}
