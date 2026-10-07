import PixlLibrary
import PixlModel
import SwiftUI

// The Library's bottom sheets: sort (Android `LibrarySortBottomSheet`), reorder tabs (`ReorderTabsSheet`), the
// multi-selection sheets (`MultiSelectionBottomSheet`, `AlbumMultiSelectionOptionSheet`,
// `PlaylistMultiSelectionBottomSheet`) and the creation-flow chooser (`PlaylistCreationTypeDialog`). System sheets
// supply the glass and the drag handle; PixlAudio's layout sits inside.

// MARK: - Sort

/// Android `LibrarySortBottomSheet`: "Sort by" (`headlineMedium` bold), the Order card (descending =
/// `tertiaryContainer`, ascending = `primaryContainer`, an arrow that flips), the sort methods as 8 pt tiles in a
/// 20 pt group with radio marks (selected `secondaryContainer`), then per tab: Albums › View (Grid / List),
/// Folders › View (Playlist View), others › Cloud (Cloud Only).
struct LibrarySortSheet: View {
    let tab: LibraryTab
    let prefs: LibraryPreferences

    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let options = tab.menuSortOptions
        let selected = options.first { $0 == prefs.sort(for: tab) } ?? tab.defaultSort
        let methods = options.map { $0.methodOption() }.reduce(into: [SortOption]()) { result, option in
            if !result.contains(where: { $0.methodKey == option.methodKey }) { result.append(option) }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sort by")
                    .pixlFont(.headlineMedium, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .padding(.leading, 2)
                    .padding(.bottom, 16)
                if methods.contains(where: \.canFlipDirection) {
                    SortDirectionCard(option: selected) {
                        prefs.setSort(selected.flipDirection(), for: tab)
                    }
                    .padding(.bottom, 12)
                }
                // The method rows render together (spacing 0, below their 4 pt gap), inside the same 20 pt clip.
                GlassEffectContainer(spacing: 0) {
                    VStack(spacing: 4) {
                        ForEach(methods, id: \.self) { method in
                            let isSelected = method.methodKey == selected.methodKey
                            Button {
                                prefs.setSort(method.resolveForDirection(selected.direction), for: tab)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(method.methodLabel)
                                        .pixlFont(.bodyLarge)
                                        .foregroundStyle(isSelected ? theme.onSecondaryContainer : theme.onSurface)
                                    Spacer()
                                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 20, weight: .regular))
                                        .foregroundStyle(isSelected ? theme.primary : theme.onSurfaceVariant)
                                }
                                .padding(.leading, 20)
                                .padding(.trailing, 14)
                                .padding(.vertical, 14)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .pixlGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous),
                                       tint: (isSelected ? theme.secondaryContainer : theme.surfaceContainerLow)
                                           .opacity(isSelected ? GlassTint.prominent : GlassTint.surface),
                                       interactive: true)
                            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                            .accessibilityIdentifier("sort.\(method.methodKey)")
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                if tab == .albums {
                    sectionTitle("View")
                    HStack(spacing: 8) {
                        viewModeButton("Grid", systemImage: "square.grid.2x2.fill", active: !settings.library.isAlbumsListView) {
                            settings.library.isAlbumsListView = false
                        }
                        viewModeButton("List", systemImage: "list.bullet", active: settings.library.isAlbumsListView) {
                            settings.library.isAlbumsListView = true
                        }
                    }
                    .frame(height: 48)
                }
                if tab == .folders {
                    sectionTitle("View")
                    SheetToggleCard(label: "Playlist View",
                                    isOn: Binding(get: { prefs.isFoldersPlaylistView },
                                                  set: { prefs.isFoldersPlaylistView = $0 }))
                } else {
                    Spacer().frame(height: 12)
                    Text("Cloud")
                        .pixlFont(.headlineSmall, weight: .bold)
                        .foregroundStyle(theme.onSurface)
                        .padding(.leading, 2)
                        .padding(.bottom, 8)
                    SheetToggleCard(label: "Cloud Only",
                                    isOn: Binding(get: { settings.library.hideLocalMedia },
                                                  set: { settings.library.hideLocalMedia = $0 }))
                }
                Spacer().frame(height: 16)
            }
            .padding(.horizontal, Tokens.Spacing.xxl)
            .padding(.top, Tokens.Spacing.l)
        }
        .accessibilityIdentifier("sheet.sort")
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .pixlFont(.headlineSmall, weight: .bold)
            .foregroundStyle(theme.onSurface)
            .padding(.leading, 2)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }

    /// Android `ToggleSegmentButton` (active `primary`, inactive `surfaceVariant`, active corners 32 pt).
    private func viewModeButton(_ title: String, systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                Text(title).pixlFont(.labelLarge)
            }
            .foregroundStyle(active ? theme.onPrimary : theme.onSurfaceVariant)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: active ? 32 : 12, style: .continuous),
                   tint: (active ? theme.primary : theme.surfaceVariant).opacity(GlassTint.prominent), interactive: true)
        .animation(PixlMotion.state, value: active)
    }
}

/// Android `LibrarySheetSortDirectionCard`.
struct SortDirectionCard: View {
    let option: SortOption
    let onToggle: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        let enabled = option.canFlipDirection
        let descending = option.direction == .descending
        let fill = !enabled ? theme.surfaceContainerLow : (descending ? theme.tertiaryContainer : theme.primaryContainer)
        let content = !enabled ? theme.onSurfaceVariant : (descending ? theme.onTertiaryContainer : theme.onPrimaryContainer)
        let label = directionLabel
        Button(action: onToggle) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(content)
                    .rotationEffect(.degrees(descending ? 0 : 180))
                    .scaleEffect(descending ? 1 : 1.08)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(content.opacity(enabled ? 0.16 : 0.1)))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Order")
                        .pixlFont(.labelLarge)
                        .foregroundStyle(content.opacity(0.82))
                    Text(label)
                        .pixlFont(.titleMedium, weight: .semibold)
                        .foregroundStyle(content)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.72)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: fill.opacity(GlassTint.prominent),
                   interactive: enabled)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: descending)
        .accessibilityIdentifier("sort.direction")
    }

    private var directionLabel: String {
        switch option.direction {
        case .descending?: "Descending"
        case .ascending?: "Ascending"
        case nil: "Original Order"
        }
    }
}

/// Android `LibrarySheetToggleCard`: a label and a switch on a card that turns `tertiary` (18 pt corners) when on and
/// stays a capsule (`surfaceContainerLow`) when off.
struct SheetToggleCard: View {
    let label: String
    @Binding var isOn: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack {
            Text(label)
                .pixlFont(.bodyLarge)
                .foregroundStyle(isOn ? theme.onTertiary : theme.onSurface)
                .padding(.leading, 6)
                .padding(.trailing, 8)
            Spacer()
            Toggle(label, isOn: $isOn)
                .labelsHidden()
                .tint(theme.onTertiaryContainer)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .contentShape(.rect)
        .onTapGesture { isOn.toggle() }
        .pixlGlass(in: RoundedRectangle(cornerRadius: isOn ? 18 : 30, style: .continuous),
                   tint: (isOn ? theme.tertiary : theme.surfaceContainerLow).opacity(isOn ? GlassTint.prominent : GlassTint.surface))
        .animation(PixlMotion.state, value: isOn)
    }
}

// MARK: - Reorder tabs

/// Android `ReorderTabsSheet`: "Reorder library tabs" (`displaySmall`), the tabs as capsules with a drag handle,
/// and the floating toolbar (reset, Done) at the bottom.
struct ReorderTabsSheet: View {
    let prefs: LibraryPreferences

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var tabs: [LibraryTab] = []
    @State private var showsReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reorder library tabs")
                .pixlFont(.displaySmall)
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 26)
                .padding(.vertical, 8)
                .padding(.top, 16)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(tabs, id: \.self) { tab in
                        row(tab)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
        }
        .overlay(alignment: .bottom) { toolbar }
        .onAppear { tabs = prefs.tabOrder }
        .alert("Reset order", isPresented: $showsReset) {
            Button("Reset") {
                prefs.resetTabOrder()
                tabs = prefs.tabOrder
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reset tab order to the default?")
        }
        .accessibilityIdentifier("sheet.reorderTabs")
    }

    private func row(_ tab: LibraryTab) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.onSurface)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .draggable(tab.rawValue)
                .accessibilityLabel("Drag handle")
            Text(tab.tabTitle)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurface)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerLowest.opacity(GlassTint.surface))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let source = LibraryTab(rawValue: raw), source != tab,
                  let from = tabs.firstIndex(of: source), let to = tabs.firstIndex(of: tab) else { return false }
            withAnimation(PixlMotion.state) {
                tabs.remove(at: from)
                tabs.insert(source, at: to)
            }
            return true
        }
        .pixlHaptic(.selection, trigger: tabs)
        .accessibilityIdentifier("reorder.\(tab.rawValue)")
    }

    /// Android `FloatingToolBar`: a 22 pt panel (`surfaceContainerHigh`) with the reset button and the Done pill. Hoa
    /// (2026-10-07): the primary button on a floating bar is its own glass pill, so the panel's glass went (no glass on
    /// glass) and Reset is a glass circle beside Done, 10 pt apart in one container. Both keep their places (the
    /// panel's 12 pt padding is added to the bottom).
    private var toolbar: some View {
        GlassEffectContainer(spacing: 4) {
            toolbarButtons
        }
        .padding(8)
        .padding(.bottom, 8 + 12)
    }

    private var toolbarButtons: some View {
        HStack(spacing: 10) {
            Button { showsReset = true } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 48, height: 48)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .pixlGlass(in: Circle(), tint: theme.surfaceContainerHigh.opacity(GlassTint.container), interactive: true)
            .accessibilityLabel("Reset")
            Button {
                prefs.tabOrder = tabs
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold))
                    Text("Done").pixlFont(.labelLarge)
                }
                .foregroundStyle(theme.onPrimaryContainer)
                .padding(.horizontal, 20)
                .frame(height: 56)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .pixlGlass(in: Capsule(), tint: theme.primaryContainer.opacity(GlassTint.prominent), interactive: true)
            .accessibilityIdentifier("reorder.done")
        }
    }
}

// MARK: - Multi-selection

/// Android `StackedAlbumArts` / `StackedAlbumCovers`: up to four round covers overlapping by half, ringed with the
/// sheet colour.
struct StackedArtworks: View {
    let sources: [ArtworkSource?]
    var size: CGFloat = 66
    var overlap: CGFloat = 33
    @Environment(\.appTheme) private var theme

    var body: some View {
        let items = Array(sources.prefix(4).enumerated())
        ZStack(alignment: .leading) {
            ForEach(items, id: \.offset) { index, source in
                ArtworkView(source: source, size: size, cornerRadius: size / 2)
                    .padding(3)
                    .background(Circle().fill(theme.surfaceContainerLow))
                    .offset(x: CGFloat(index) * (size - overlap))
                    .zIndex(Double(items.count - index))
            }
        }
        .frame(width: items.isEmpty ? 0 : size + 6 + CGFloat(items.count - 1) * (size - overlap), height: 74,
               alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// The header of every multi-selection sheet: stacked art, "N SONGS" (`headlineSmall` bold) over "selected".
struct SelectionSheetHeader: View {
    let sources: [ArtworkSource?]
    let countText: String
    var trailing: AnyView?
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            StackedArtworks(sources: sources)
            Spacer().frame(width: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(countText)
                    .pixlFont(.headlineSmall, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                    .minimumScaleFactor(0.66)
                Text("selected")
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing { trailing }
        }
    }
}

/// Android `MultiSelectionBottomSheet`: Play all (big, `primaryContainer`), Like/Unlike all (the heart; a rounded
/// square when all are liked), Share; Add to queue + Next; Playlist + Delete all.
struct SongMultiSelectionSheet: View {
    let songs: [Song]
    let onAddToPlaylist: ([String]) -> Void
    let onDone: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false
    /// The local files to share, resolved off the main actor once the sheet is up (a URL parse per song).
    @State private var shareURLs: [URL] = []

    var body: some View {
        let allLiked = !songs.isEmpty && songs.allSatisfy(\.isFavorite)
        // Enabled from the first frame: stops at the first local file.
        let canShare = songs.contains { SongFiles.shareURL($0) != nil }
        ScrollView {
            VStack(spacing: 0) {
                // The header stacks four covers: only those are resolved.
                SelectionSheetHeader(sources: songs.prefix(4).map(ArtworkSource.init(song:)),
                                     countText: "\(songs.count) SONGS")
                Spacer().frame(height: 16)
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        ActionTile(title: "Play all", systemImage: "play.fill", tint: theme.primaryContainer,
                                   foreground: theme.onPrimaryContainer, minHeight: 80, cornerRadius: 26,
                                   titleStyle: .titleLarge) {
                            playback.play(songs)
                            finish()
                        }
                        .frame(maxWidth: .infinity)
                        HStack(spacing: 10) {
                        ActionTile(systemImage: allLiked ? "heart.slash.fill" : "heart",
                                   accessibilityLabel: allLiked ? "Remove all from favorites" : "Add all to favorites",
                                   tint: allLiked ? theme.primary : theme.surfaceVariant,
                                   foreground: allLiked ? theme.onPrimary : theme.onSurfaceVariant, minHeight: 80,
                                   cornerRadius: allLiked ? 26 : 40, iconSize: 32) {
                            env.libraryEditor.setFavorite(songs.map(\.id), !allLiked)
                            finish()
                        }
                        ShareLink(items: shareURLs) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(theme.onSecondary)
                                .frame(maxWidth: .infinity, minHeight: 80)
                                .contentShape(.circle)
                        }
                        .disabled(!canShare)
                        .pixlGlass(in: Capsule(), tint: theme.secondary.opacity(GlassTint.prominent), interactive: true)
                        .accessibilityLabel("Share all")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    HStack(spacing: 10) {
                        ActionTile(title: "Add to queue", systemImage: "text.line.last.and.arrowtriangle.forward",
                                   tint: theme.tertiaryContainer, foreground: theme.onTertiaryContainer) {
                            playback.addToQueue(songs)
                            LibraryToast.shared.show("Added to queue")
                            finish()
                        }
                        ActionTile(title: "Next", systemImage: "text.line.first.and.arrowtriangle.forward",
                                   tint: theme.tertiary, foreground: theme.onTertiary) {
                            playback.playNext(songs)
                            LibraryToast.shared.show("Playing next")
                            finish()
                        }
                    }
                    HStack(spacing: 10) {
                        ActionTile(title: "Playlist", systemImage: "text.badge.plus", tint: theme.secondaryContainer,
                                   foreground: theme.onSecondaryContainer) {
                            onAddToPlaylist(songs.map(\.id))
                        }
                        ActionTile(title: "Delete all", systemImage: "trash", tint: theme.errorContainer,
                                   foreground: theme.onErrorContainer) {
                            confirmsDelete = true
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .confirmationDialog("Delete \(songs.count) songs from your library?", isPresented: $confirmsDelete,
                            titleVisibility: .visible) {
            Button("Delete all", role: .destructive) {
                env.libraryEditor.removeSongs(songs.map(\.id))
                finish()
            }
        } message: {
            Text("Song files on this iPhone are deleted; other songs are removed from the library and won't come back when it is scanned again.")
        }
        .task { shareURLs = await SongFiles.shareURLs(contentUris: songs.map(\.contentUriString)) }
        .accessibilityIdentifier("sheet.songSelection")
    }

    private func finish() {
        onDone()
        dismiss()
    }
}

/// Android `AlbumMultiSelectionOptionSheet`: stacked covers, "N ALBUMS selected", the queue hint and limit, then
/// Play + Playlist, Next + Add to queue. Albums play in selection order, each in album order.
struct AlbumMultiSelectionSheet: View {
    let albums: [Album]
    let onAddToPlaylist: ([String]) -> Void
    let onDone: () -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var songs: [Song] {
        albums.flatMap { album in LibrarySorting.albumPlaybackOrder(library.songs.filter { $0.albumId == album.id }) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SelectionSheetHeader(sources: albums.map { ArtworkSource(uriString: $0.albumArtUriString) },
                                     countText: "\(albums.count) ALBUMS")
                Spacer().frame(height: 16)
                Text("Queue + play respects your selection order.")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                Text("Limit: \(maxAlbumMultiSelection) albums per selection.")
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                Spacer().frame(height: 16)
                HStack(spacing: 10) {
                    ActionTile(title: "Play", systemImage: "play.fill", tint: theme.primaryContainer,
                               foreground: theme.onPrimaryContainer) {
                        playback.play(songs)
                        finish()
                    }
                    ActionTile(title: "Playlist", systemImage: "text.badge.plus", tint: theme.secondaryContainer,
                               foreground: theme.onSecondaryContainer) {
                        onAddToPlaylist(songs.map(\.id))
                        onDone()
                    }
                }
                Spacer().frame(height: 10)
                HStack(spacing: 10) {
                    ActionTile(title: "Next", systemImage: "text.line.first.and.arrowtriangle.forward",
                               tint: theme.tertiary, foreground: theme.onTertiary) {
                        playback.playNext(songs)
                        finish()
                    }
                    ActionTile(title: "Add to queue", systemImage: "text.line.last.and.arrowtriangle.forward",
                               tint: theme.tertiaryContainer, foreground: theme.onTertiaryContainer) {
                        playback.addToQueue(songs)
                        finish()
                    }
                }
                Spacer().frame(height: 20)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
        }
        .accessibilityIdentifier("sheet.albumSelection")
    }

    private func finish() {
        onDone()
        dismiss()
    }
}

/// Android `PlaylistMultiSelectionBottomSheet`: stacked covers, "N PLAYLISTS selected", then Delete + Export,
/// Merge + Share.
struct PlaylistMultiSelectionSheet: View {
    let playlists: [Playlist]
    let onMerge: () -> Void
    let onDone: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var exportURLs: [URL] = []

    var body: some View {
        VStack(spacing: 0) {
            SelectionSheetHeader(sources: playlists.map { playlist in
                playlist.songIds.first.flatMap { library.song(id: $0) }.flatMap(ArtworkSource.init(song:))
            }, countText: "\(playlists.count) PLAYLISTS")
            Spacer().frame(height: 16)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ActionTile(title: "Delete", systemImage: "trash", tint: theme.errorContainer,
                               foreground: theme.onErrorContainer) {
                        env.libraryEditor.deletePlaylists(playlists.map(\.id))
                        onDone()
                        dismiss()
                    }
                    ShareLink(items: exportURLs) {
                        tileLabel("Export", systemImage: "arrow.down.doc", foreground: theme.onTertiaryContainer)
                    }
                    .pixlGlass(in: Capsule(), tint: theme.tertiaryContainer.opacity(GlassTint.prominent), interactive: true)
                }
                HStack(spacing: 10) {
                    ActionTile(title: "Merge", systemImage: "arrow.triangle.merge", tint: theme.secondaryContainer,
                               foreground: theme.onSecondaryContainer, action: onMerge)
                    ShareLink(items: exportURLs) {
                        tileLabel("Share", systemImage: "square.and.arrow.up", foreground: theme.onPrimaryContainer)
                    }
                    .pixlGlass(in: Capsule(), tint: theme.primaryContainer.opacity(GlassTint.prominent), interactive: true)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .task(id: playlists.map(\.id)) {
            var urls: [URL] = []
            for playlist in playlists {
                if let url = await PlaylistExport.writeTemporaryM3U(playlist, library: library) { urls.append(url) }
            }
            if !Task.isCancelled { exportURLs = urls }
        }
        .accessibilityIdentifier("sheet.playlistSelection")
    }

    private func tileLabel(_ title: String, systemImage: String, foreground: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 20, weight: .semibold))
            Text(title).pixlFont(.titleMedium)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, minHeight: 66)
        .contentShape(.capsule)
    }
}

/// M3U export (Android `exportPlaylistsAsM3u` / `exportM3u`).
nonisolated enum PlaylistExport {
    static func m3u(_ playlist: Playlist, songs: [Song]) -> String { M3U.generate(songs: songs) }

    /// Android `PlaylistViewModel.sanitizeFileName`.
    static func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "playlist" : cleaned
    }

    /// Writes the playlist's M3U to a temporary file for sharing. The song lookups are dictionary reads on the main
    /// actor; building the text and the atomic file write happen off it (the sheets call this while presenting).
    @MainActor
    static func writeTemporaryM3U(_ playlist: Playlist, library: LibraryStore) async -> URL? {
        let songs = playlist.songIds.compactMap { library.song(id: $0) }
        return await writeM3U(songs: songs, name: sanitizeFileName(playlist.name))
    }

    /// Under approachable concurrency a plain `nonisolated async` function would run on its caller's actor.
    @concurrent
    static func writeM3U(songs: [Song], name: String) async -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).m3u")
        guard (try? M3U.generate(songs: songs).write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
    }
}

/// Files behind songs (sharing).
nonisolated enum SongFiles {
    /// The song's file URL when it is a local file (streamed / demo songs have none).
    static func shareURL(_ song: Song) -> URL? {
        shareURL(contentUri: song.contentUriString)
    }

    static func shareURL(contentUri: String) -> URL? {
        guard let url = URL(string: contentUri), url.isFileURL else { return nil }
        return url
    }

    /// Every local file among the content URIs, resolved off the main actor (a selection can hold thousands).
    @concurrent
    static func shareURLs(contentUris: [String]) async -> [URL] {
        contentUris.compactMap { shareURL(contentUri: $0) }
    }
}

// MARK: - Creation flow

/// Android `PlaylistCreationTypeDialog`: "Create playlist" (`headlineSmall` bold, `primary`), "Choose the creation
/// flow.", the Manual card (`primaryContainer`) and the With AI card (`tertiaryContainer`, or `surfaceContainer`
/// with "Set up API key" while no AI provider is configured). iOS: while the selected on-device model can't answer,
/// the card says why and the button opens the AI settings instead of asking for a key (2026-10-07).
struct PlaylistCreationTypeSheet: View {
    let onManual: () -> Void
    let onSetupAI: () -> Void
    /// An AI provider is configured (Android `hasActiveAiProviderApiKey`).
    var isAIEnabled = false
    /// Why the selected on-device model can't answer (nil: a cloud provider, or it can).
    var onDeviceIssue: OnDeviceFailure? = nil
    /// Opens the AI Playlist Lab (stage 13).
    var onAI: () -> Void = {}

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                Text("Create playlist")
                    .pixlFont(.headlineSmall, weight: .bold)
                    .foregroundStyle(theme.primary)
                Text("Choose the creation flow.")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.primary.opacity(0.8))
            }
            .padding(.bottom, 6)
            modeCard(title: "Manual", subtitle: "Design artwork, icon, shape and pick songs yourself.",
                     systemImage: "text.badge.plus", fill: theme.primaryContainer, content: theme.onPrimaryContainer,
                     enabled: true, action: onManual)
                .accessibilityIdentifier("creation.manual")
            modeCard(title: "With AI", subtitle: aiSubtitle,
                     systemImage: isAIEnabled ? "sparkles" : (onDeviceIssue == nil ? "key.fill" : "cpu"),
                     fill: isAIEnabled ? theme.tertiaryContainer : theme.surfaceContainer,
                     content: isAIEnabled ? theme.onTertiaryContainer : theme.onSurfaceVariant,
                     enabled: isAIEnabled, action: onAI)
            if !isAIEnabled {
                Button(action: onSetupAI) {
                    HStack(spacing: 8) {
                        Image(systemName: onDeviceIssue == nil ? "key.fill" : "gearshape")
                        Text(onDeviceIssue == nil ? "Set up API key" : "Open AI settings").pixlFont(.labelLarge)
                    }
                    .foregroundStyle(theme.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: Capsule(), tint: theme.primary.opacity(GlassTint.prominent), interactive: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .padding(.top, 8)
        .accessibilityIdentifier("sheet.createPlaylist")
    }

    private var aiSubtitle: String {
        if isAIEnabled { return "Generate a curated playlist with advanced controls." }
        if let onDeviceIssue { return "Needs on-device AI · \(onDeviceIssue.title)." }
        return "Requires an AI provider key configured in settings."
    }

    /// Android `CreationModeCard`: 22 pt card, 14 pt padding, the icon in a 12/18 pt squircle, title (`titleMedium`
    /// bold) and subtitle (`bodySmall`).
    private func modeCard(title: String, subtitle: String, systemImage: String, fill: Color, content: Color,
                          enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(content)
                    .frame(width: 24, height: 24)
                    .padding(10)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 18,
                                                       bottomTrailingRadius: 12, topTrailingRadius: 18,
                                                       style: .continuous).fill(content.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).pixlFont(.titleMedium, weight: .bold)
                    Text(subtitle).pixlFont(.bodySmall).opacity(0.85)
                }
                .foregroundStyle(content)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), tint: fill.opacity(GlassTint.prominent),
                   interactive: enabled)
    }
}
