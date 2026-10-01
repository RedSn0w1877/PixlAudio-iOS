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
    @State private var lyricSync = PlaylistLyricSyncState.idle
    @State private var didApplyLaunchState = false

    private var prefs: LibraryPreferences { LibraryPreferences.shared(isUITest: env.launch.isUITest) }
    private var folderPath: String? { FolderPlaylist.path(from: playlistId) }
    private var isFolder: Bool { folderPath != nil }

    /// The folder as a read-only pseudo playlist (Android `loadPlaylistDetails`), built when the library changes.
    @State private var folderPlaylist: Playlist?
    @State private var didResolveFolder = false

    /// The playlist (or the folder's pseudo playlist).
    private var playlist: Playlist? { isFolder ? folderPlaylist : library.playlist(id: playlistId) }

    private func resolveFolder() {
        guard let folderPath else { return }
        let folder = LibraryModel.folder(at: folderPath, in: LibraryModel.folderTree(library.songs))
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
                GlassCircleButton(systemImage: "line.3.horizontal.decrease", accessibilityLabel: "Sort Songs",
                                  tint: theme.surfaceContainerHigh.opacity(GlassTint.surface),
                                  foreground: theme.onSurface) { showsSort = true }
                    .accessibilityIdentifier("playlist.sort")
                if !isFolder {
                    GlassCircleButton(systemImage: "ellipsis", accessibilityLabel: "More options",
                                      tint: theme.surfaceContainerHigh.opacity(GlassTint.container),
                                      foreground: theme.onSurface) { showsOptions = true }
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
                PlaylistLyricSyncCard(state: lyricSync, onCancel: { lyricSync = .idle }, onRetry: {})
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
        .onAppear(perform: applyLaunchState)
        .onChange(of: library.songs.count, initial: true) { _, _ in resolveFolder() }
        .sheet(isPresented: $showsAddSongs) {
            SongPickerSheet(initiallySelected: Set(playlist?.songIds ?? [])) { selected in
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
        return HStack(spacing: 8) {
            SegmentedGlassButton(title: "Play it", systemImage: "play.fill", accessibilityLabel: "Play",
                                 leading: 60, trailing: 14, height: 56, horizontalPadding: 10,
                                 tint: theme.primary.opacity(GlassTint.prominent), foreground: theme.onPrimary) {
                guard let first = songs.first else { return }
                if playback.isShuffleEnabled { playback.setShuffleEnabled(false) }
                playback.play(first, in: songs)
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("playlist.play")
            SegmentedGlassButton(title: "Shuffle", systemImage: "shuffle", accessibilityLabel: "Shuffle",
                                 leading: 14, trailing: 60, height: 56, horizontalPadding: 10,
                                 tint: theme.secondaryContainer.opacity(GlassTint.prominent),
                                 foreground: theme.onSecondaryContainer) {
                playback.playShuffled(songs)
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("playlist.shuffle")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .padding(.horizontal, 20)
        .padding(.bottom, isFolder ? 8 : 6)
    }

    /// Android: Add (capsule, `tertiaryContainer`), then Remove and Reorder stretched over the rest.
    private var editRow: some View {
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
                                    titleStyle: .labelMedium, action: action)
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
                    let isCurrent = playback.current?.id == song.id
                    PlaylistSongRow(song: song, isCurrent: isCurrent, isPlaying: isCurrent && playback.isPlaying,
                                    showsDragHandle: isReorderMode && !isFolder, showsRemove: isRemoveMode && !isFolder,
                                    onTap: { playback.play(song, in: songs) },
                                    onMore: { router.present(AppSheet.songInfo(songId: song.id)) },
                                    onRemove: { env.libraryEditor.removeSong(song.id, fromPlaylist: playlistId) })
                        .dropDestination(for: String.self) { items, _ in
                            move(items.first, onto: song.id)
                        }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(panel.fill(theme.surfaceContainerHigh).ignoresSafeArea(edges: .bottom))
        .clipShape(panel)
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

    // MARK: Options sheet

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
                                 LibraryToast.shared.show("No streamed songs in this playlist to download.")
                             },
                             onSyncLyricsAll: {
                                 showsOptions = false
                                 LibraryToast.shared.show("Word-level lyric sync arrives in a later update.")
                             },
                             onInstrumentalizeAll: {
                                 showsOptions = false
                                 LibraryToast.shared.show("Instrumentals arrive in a later update.")
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
            exportURL = PlaylistExport.writeTemporaryM3U(playlist, library: library)
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
