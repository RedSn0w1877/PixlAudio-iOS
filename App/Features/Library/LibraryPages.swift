import PixlLibrary
import PixlModel
import SwiftUI

// The Library's tab pages (Android `LibrarySongsTab`, `LibraryFavoritesTab`, `LibraryAlbumsTab`, `LibraryArtistsTab`,
// `LibraryPlaylistsTab` → `PlaylistContainer`, `LibraryFoldersTab`) and their rows. Lists are lazy; every row is one
// glass layer. Content scrolls under the shell's glass bars and ends 30 pt past them (`ListExtraBottomGap`).

/// What every song page needs from the screen.
struct LibraryPageContext {
    let currentSongId: String?
    let isPlaying: Bool
    /// Android reserves 22 pt on the trailing side for its scrollbar when "show scrollbar" is on.
    let showsScrollbarGap: Bool
    /// Changes when the locate button is tapped (scroll the current song into view).
    let locateRequest: Int
    let onCurrentVisible: (Bool) -> Void
    let onSongMore: (Song) -> Void

    var trailingPadding: CGFloat { showsScrollbarGap ? 22 : 12 }
}

/// Android `ListExtraBottomGap`.
let libraryListExtraBottomGap: CGFloat = 30

// MARK: - Songs / Liked

struct LibrarySongsPage: View {
    let songs: [Song]
    let context: LibraryPageContext
    let selection: OrderedSelection<String>
    let emptyFilter: StorageFilter
    let isLiked: Bool
    let isLoading: Bool
    let onPlay: (Song, [Song]) -> Void

    @Environment(LibraryStore.self) private var library

    var body: some View {
        if songs.isEmpty && !isLoading {
            LibraryEmptyState(systemImage: isLiked ? "heart.fill" : "music.note",
                              title: LibraryEmptyCopy.title(isLiked ? .liked : .songs, emptyFilter),
                              subtitle: LibraryEmptyCopy.subtitle(isLiked ? .liked : .songs, emptyFilter))
                .padding(.bottom, libraryListExtraBottomGap)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Tokens.SongCard.listSpacing) {
                        ForEach(songs) { song in
                            songRow(song)
                                .id(song.id)
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, context.trailingPadding)
                    .padding(.bottom, libraryListExtraBottomGap)
                }
                .scrollIndicators(context.showsScrollbarGap ? .visible : .hidden)
                .refreshable { try? await library.refresh() }
                .onChange(of: context.locateRequest) { _, _ in
                    guard let id = context.currentSongId else { return }
                    withAnimation(PixlMotion.state) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .accessibilityIdentifier(isLiked ? "library.page.liked" : "library.page.songs")
        }
    }

    @ViewBuilder
    private func songRow(_ song: Song) -> some View {
        let isCurrent = song.id == context.currentSongId
        let card = SongCard(song: song, isCurrent: isCurrent, isPlaying: isCurrent && context.isPlaying,
                            onTap: { onPlay(song, songs) }, onMore: { context.onSongMore(song) },
                            isSelectionMode: selection.isActive, isSelected: selection.contains(song.id),
                            selectionIndex: selection.index(of: song.id),
                            onLongPress: { selection.toggle(song.id) })
        if isCurrent {
            card.onScrollVisibilityChange(threshold: 0.5) { visible in context.onCurrentVisible(visible) }
        } else {
            card
        }
    }
}

// MARK: - Albums

struct LibraryAlbumsPage: View {
    let albums: [Album]
    let isListView: Bool
    let selection: OrderedSelection<Int64>
    let emptyFilter: StorageFilter
    let showsScrollbarGap: Bool
    let onOpen: (Album) -> Void
    let onToggle: (Album) -> Void

    @Environment(LibraryStore.self) private var library

    var body: some View {
        if albums.isEmpty && !library.isLoading {
            LibraryEmptyState(systemImage: "opticaldisc", title: LibraryEmptyCopy.title(.albums, emptyFilter),
                              subtitle: LibraryEmptyCopy.subtitle(.albums, emptyFilter))
        } else {
            ScrollView {
                Group {
                    if isListView {
                        LazyVStack(spacing: 8) {
                            ForEach(albums) { album in item(album, list: true) }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                  spacing: 8) {
                            ForEach(albums) { album in item(album, list: false) }
                        }
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, showsScrollbarGap ? 24 : 14)
                .padding(.bottom, libraryListExtraBottomGap + 4)
            }
            .scrollIndicators(showsScrollbarGap ? .visible : .hidden)
            .refreshable { try? await library.refresh() }
            .accessibilityIdentifier("library.page.albums")
        }
    }

    private func item(_ album: Album, list: Bool) -> some View {
        let isSelected = selection.contains(album.id)
        return AlbumCard(album: album, isList: list, isSelected: isSelected,
                         selectionIndex: selection.index(of: album.id))
            .onTapGesture { selection.isActive ? onToggle(album) : onOpen(album) }
            .onLongPressGesture(minimumDuration: 0.45) { onToggle(album) }
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("albumCard.\(album.id)")
    }
}

/// Android `AlbumGridItemRedesigned` (grid: 3:2 art fading into an 84 pt text block, 20 pt corners) and
/// `AlbumListItem` (list: 88 pt row, square art fading into the text panel, 16 pt corners), both coloured with the
/// album's own scheme (`primaryContainer` / `onPrimaryContainer`) — here a glass card tinted with it.
struct AlbumCard: View {
    let album: Album
    let isList: Bool
    var isSelected = false
    var selectionIndex: Int?

    var body: some View {
        AlbumSchemeReader(artUri: album.albumArtUriString) { scheme in
            if isList { listCard(scheme) } else { gridCard(scheme) }
        }
        .scaleEffect(isSelected ? (isList ? 0.99 : 0.985) : 1)
        .animation(.easeOut(duration: 0.22), value: isSelected)
    }

    private func gridCard(_ scheme: ThemeColors) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(3.0 / 2.0, contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        ArtworkView(source: ArtworkSource(uriString: album.albumArtUriString),
                                    size: proxy.size.width, cornerRadius: 0)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    }
                    .mask(LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(album.title)
                    .pixlFont(.titleMedium, weight: .bold)
                    .foregroundStyle(scheme.onPrimaryContainer)
                    .lineLimit(1)
                Text(album.artist)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(scheme.onPrimaryContainer.opacity(0.85))
                    .lineLimit(1)
                Text(LibraryFormat.songCount(album.songCount))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(scheme.onPrimaryContainer.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 84, alignment: .leading)
        }
        .clipShape(shape)
        .pixlGlass(in: shape, tint: scheme.primaryContainer.opacity(GlassTint.prominent), interactive: true)
        .overlay { if isSelected { shape.stroke(scheme.primary, lineWidth: 2) } }
        .overlay(alignment: .topTrailing) { badge(scheme, size: 28).padding(10) }
    }

    private func listCard(_ scheme: ThemeColors) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return HStack(spacing: 0) {
            ArtworkView(source: ArtworkSource(uriString: album.albumArtUriString), size: 88, cornerRadius: 0)
                .mask(LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing))
            VStack(alignment: .leading, spacing: 0) {
                Text(album.title)
                    .pixlFont(.custom(size: 22, weight: .bold))
                    .foregroundStyle(scheme.onPrimaryContainer)
                    .lineLimit(1)
                Spacer().frame(height: 4)
                Text(album.artist)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(scheme.onPrimaryContainer.opacity(0.85))
                    .lineLimit(1)
                Text(LibraryFormat.songCount(album.songCount))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(scheme.onPrimaryContainer.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: 88)
        .clipShape(shape)
        .pixlGlass(in: shape, tint: scheme.primaryContainer.opacity(GlassTint.prominent), interactive: true)
        .overlay { if isSelected { shape.stroke(scheme.primary, lineWidth: 2) } }
        .overlay(alignment: .topTrailing) { badge(scheme, size: 24).padding(8) }
    }

    @ViewBuilder
    private func badge(_ scheme: ThemeColors, size: CGFloat) -> some View {
        if isSelected {
            Text(selectionIndex.map(String.init) ?? "✓")
                .pixlFont(size > 24 ? .labelMedium : .labelSmall, weight: .bold)
                .foregroundStyle(scheme.onPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(scheme.primary))
        }
    }
}

/// Resolves an artwork's colour scheme (Android `getAlbumColorSchemeFlow`) and hands it to the content; the app
/// scheme until it is ready. Extraction runs off the main thread and is cached by `ColorExtractor`.
struct AlbumSchemeReader<Content: View>: View {
    let artUri: String?
    @ViewBuilder let content: (ThemeColors) -> Content

    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme
    @State private var pair: ColorRolesPair?

    var body: some View {
        content(pair.map { ThemeColors(roles: $0.roles(dark: theme.isDark), isDark: theme.isDark) } ?? theme)
            .task(id: artUri) {
                guard let source = ArtworkSource(uriString: artUri) else { pair = nil; return }
                let loaded = await env.colorExtractor.schemePair(for: source, style: settings.appearance.paletteStyle,
                                                                 accuracyLevel: settings.appearance.colorAccuracy)
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.25)) { pair = loaded } }
            }
    }
}

// MARK: - Artists

struct LibraryArtistsPage: View {
    let artists: [Artist]
    let emptyFilter: StorageFilter
    let showsScrollbarGap: Bool
    let onOpen: (Artist) -> Void

    @Environment(LibraryStore.self) private var library

    var body: some View {
        if artists.isEmpty && !library.isLoading {
            LibraryEmptyState(systemImage: "music.mic", title: LibraryEmptyCopy.title(.artists, emptyFilter),
                              subtitle: LibraryEmptyCopy.subtitle(.artists, emptyFilter))
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(artists) { artist in
                        ArtistRow(artist: artist) { onOpen(artist) }
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, showsScrollbarGap ? 22 : 12)
                .padding(.bottom, libraryListExtraBottomGap)
            }
            .scrollIndicators(showsScrollbarGap ? .visible : .hidden)
            .refreshable { try? await library.refresh() }
            .accessibilityIdentifier("library.page.artists")
        }
    }
}

/// Android `ArtistListItem`: a 16 pt card (`surfaceContainerLow`), 12 pt padding, the 48 pt round image (or the
/// artist icon on `primaryContainer`), name (`titleMedium` bold) and song count (`bodySmall`).
struct ArtistRow: View {
    let artist: Artist
    let onTap: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.medium, style: .continuous)
        Button(action: onTap) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(theme.primaryContainer)
                    if let url = artist.effectiveImageUrl, let source = ArtworkSource(uriString: url) {
                        ArtworkView(source: source, size: 48, cornerRadius: 24)
                    } else {
                        Image(systemName: "music.mic")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(theme.onPrimaryContainer)
                    }
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 0) {
                    Text(artist.name)
                        .pixlFont(.titleMedium, weight: .bold)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(LibraryFormat.songCount(artist.songCount))
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: theme.surfaceContainerLow.opacity(GlassTint.surface), interactive: true)
        .accessibilityIdentifier("artistRow.\(artist.id)")
    }
}

// MARK: - Playlists

struct LibraryPlaylistsPage: View {
    let playlists: [Playlist]
    let selection: OrderedSelection<String>
    let showsScrollbarGap: Bool
    let onOpen: (Playlist) -> Void
    let onReorder: ([String]) -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme

    var body: some View {
        if playlists.isEmpty && !library.isLoading {
            LibraryEmptyState(systemImage: "music.note.list", title: "No playlist has been created.",
                              subtitle: "Touch the 'New Playlist' button to start.")
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(playlists) { playlist in
                        row(playlist)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, showsScrollbarGap ? 22 : 12)
                .padding(.bottom, libraryListExtraBottomGap)
            }
            .scrollIndicators(showsScrollbarGap ? .visible : .hidden)
            .overlay(alignment: .top) {
                // PlaylistContainer's 10 pt fade from the panel colour.
                LinearGradient(colors: [theme.surface, theme.surface.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 10)
                    .allowsHitTesting(false)
            }
            .refreshable { try? await library.refresh() }
            .accessibilityIdentifier("library.page.playlists")
        }
    }

    private func row(_ playlist: Playlist) -> some View {
        let reorderable = !selection.isActive
        return PlaylistRow(playlist: playlist, songs: playlist.songIds.prefix(4).compactMap { library.song(id: $0) },
                           isSelectionMode: selection.isActive, isSelected: selection.contains(playlist.id),
                           selectionIndex: selection.index(of: playlist.id), showsDragHandle: reorderable,
                           onTap: { selection.isActive ? selection.toggle(playlist.id) : onOpen(playlist) },
                           onLongPress: { selection.toggle(playlist.id) },
                           dragPayload: playlist.id)
            .dropDestination(for: String.self) { items, _ in
                guard reorderable, let source = items.first, source != playlist.id else { return false }
                var ids = playlists.map(\.id)
                guard let from = ids.firstIndex(of: source), let to = ids.firstIndex(of: playlist.id) else { return false }
                ids.remove(at: from)
                ids.insert(source, at: to)
                onReorder(ids)
                return true
            }
    }
}

/// Android `PlaylistItem`: a 16 pt card (`surfaceContainerLow`; selected `secondaryContainer` with a 2.5 pt
/// `primary` border, scale 0.98), 12 pt padding, the 48 pt cover, name (`titleMedium` bold) with the AI / Spotify
/// marks, the song count, the selection number and the drag handle.
struct PlaylistRow: View {
    let playlist: Playlist
    let songs: [Song]
    var isSelectionMode = false
    var isSelected = false
    var selectionIndex: Int?
    var showsDragHandle = false
    /// Add-to-playlist mode: a check box instead of the handle.
    var isChecked: Bool?
    let onTap: () -> Void
    var onLongPress: (() -> Void)?
    var dragPayload: String?

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.medium, style: .continuous)
        HStack(spacing: 0) {
            PlaylistCoverView(playlist: playlist, songs: songs, size: 48)
            Spacer().frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(playlist.name)
                        .pixlFont(.titleMedium, weight: .bold)
                        .foregroundStyle(isSelected ? theme.onSecondaryContainer : theme.onSurface)
                        .lineLimit(1)
                    if playlist.isAiGenerated {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.tertiary)
                            .accessibilityLabel("AI Generated")
                    }
                    if playlist.source == "SPOTIFY" {
                        Image(systemName: "opticaldisc.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(argb: 0xFF1DB954))
                            .accessibilityLabel("Spotify")
                    }
                }
                .padding(.trailing, 6)
                Text(LibraryFormat.songCount(playlist.songIds.count))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected && isSelectionMode {
                Spacer().frame(width: 10)
                Text(selectionIndex.map(String.init) ?? "✓")
                    .pixlFont(.labelMedium, weight: .bold)
                    .foregroundStyle(theme.onPrimary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(theme.primary))
            }
            if let isChecked {
                Spacer().frame(width: 8)
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(isChecked ? theme.primary : theme.onSurfaceVariant)
                    .frame(width: 40, height: 40)
            }
            if showsDragHandle, let dragPayload {
                Spacer().frame(width: 4)
                Image(systemName: "circle.grid.2x3.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 40, height: 40)
                    .contentShape(.rect)
                    .draggable(dragPayload)
                    .accessibilityLabel("Drag to reorder playlist")
            }
        }
        .padding(12)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .modifier(OptionalLongPress(action: onLongPress))
        .pixlGlass(in: shape,
                   tint: (isSelected ? theme.secondaryContainer.opacity(GlassTint.container)
                                     : (isChecked != nil ? theme.surfaceContainerHigh : theme.surfaceContainerLow)
                                        .opacity(GlassTint.surface)),
                   interactive: true)
        .overlay { if isSelected && isChecked == nil { shape.stroke(theme.primary, lineWidth: 2.5) } }
        .scaleEffect(isSelected ? 0.98 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("playlistRow.\(playlist.id)")
    }
}

struct OptionalLongPress: ViewModifier {
    let action: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let action {
            content.onLongPressGesture(minimumDuration: 0.45) { action() }
        } else {
            content
        }
    }
}

// MARK: - Folders

struct LibraryFoldersPage: View {
    let folders: [MusicFolder]
    let folderPlaylists: [MusicFolder]
    let folderPath: String?
    let isPlaylistView: Bool
    let sort: SortOption
    let context: LibraryPageContext
    let selection: OrderedSelection<String>
    let onOpenFolder: (String) -> Void
    let onOpenFolderPlaylist: (MusicFolder) -> Void
    let onPlay: (Song, [Song]) -> Void

    @Environment(LibraryStore.self) private var library

    var body: some View {
        let active = folderPath.flatMap { LibraryModel.folder(at: $0, in: folders) }
        let showsPlaylistCards = isPlaylistView && active == nil
        let items: [MusicFolder] = showsPlaylistCards ? folderPlaylists
            : (active.map { LibrarySorting.sortFolders($0.subFolders, by: sort) } ?? folders)
        let songs = LibraryModel.folderSongs(active?.songs ?? [], sort: sort)
        Group {
            if items.isEmpty && songs.isEmpty {
                LibraryEmptyState(systemImage: "folder.fill", title: "No folders found",
                                  subtitle: "Folders with music will appear here.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(items, id: \.path) { folder in
                                if showsPlaylistCards {
                                    FolderRow(folder: folder, asPlaylist: true) { onOpenFolderPlaylist(folder) }
                                } else {
                                    FolderRow(folder: folder, asPlaylist: false) { onOpenFolder(folder.path) }
                                }
                            }
                            ForEach(songs) { song in
                                let isCurrent = song.id == context.currentSongId
                                SongCard(song: song, isCurrent: isCurrent, isPlaying: isCurrent && context.isPlaying,
                                         onTap: { onPlay(song, songs) }, onMore: { context.onSongMore(song) },
                                         isSelectionMode: selection.isActive, isSelected: selection.contains(song.id),
                                         selectionIndex: selection.index(of: song.id),
                                         onLongPress: { selection.toggle(song.id) })
                                    .id(song.id)
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, context.trailingPadding)
                        .padding(.bottom, libraryListExtraBottomGap)
                    }
                    .scrollIndicators(context.showsScrollbarGap ? .visible : .hidden)
                    .refreshable { try? await library.refresh() }
                    .onChange(of: context.locateRequest) { _, _ in
                        guard let id = context.currentSongId else { return }
                        withAnimation(PixlMotion.state) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .id(folderPath ?? "__root__")
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
        .accessibilityIdentifier("library.page.folders")
    }
}

/// Android `FolderListItem` (folder icon in a 48 pt `primaryContainer` circle) and `FolderPlaylistItem` (the 48 pt
/// collage of the folder's songs): a 16 pt `surfaceContainerLow` card, 12 pt padding, name + song count.
struct FolderRow: View {
    let folder: MusicFolder
    let asPlaylist: Bool
    let onTap: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.medium, style: .continuous)
        Button(action: onTap) {
            HStack(spacing: 16) {
                if asPlaylist {
                    ArtCollage(songs: Array(LibraryModel.allSongs(folder).prefix(9)), size: 48)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(theme.onPrimaryContainer)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(theme.primaryContainer))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(folder.name)
                        .pixlFont(.titleMedium, weight: .bold)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(LibraryFormat.songCount(folder.totalSongCount))
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: shape, tint: theme.surfaceContainerLow.opacity(GlassTint.surface), interactive: true)
        .accessibilityIdentifier("folderRow.\(folder.name)")
    }
}

// MARK: - Empty copy (Android `libraryEmptySpec`)

nonisolated enum LibraryEmptyCopy {
    static func title(_ tab: LibraryTab, _ filter: StorageFilter) -> String {
        switch (tab, filter) {
        case (.songs, .all): "No songs yet"
        case (.songs, .offline): "No local songs found"
        case (.songs, .online): "No cloud songs found"
        case (.albums, .all): "No albums available"
        case (.albums, .offline): "No local albums found"
        case (.albums, .online): "No cloud albums found"
        case (.artists, .all): "No artists available"
        case (.artists, .offline): "No local artists found"
        case (.artists, .online): "No cloud artists found"
        case (.liked, .all): "No liked songs yet"
        case (.liked, .offline): "No liked local songs"
        case (.liked, .online): "No liked cloud songs"
        case (.folders, _): "No folders found"
        case (.playlists, _): "No playlists yet"
        }
    }

    static func subtitle(_ tab: LibraryTab, _ filter: StorageFilter) -> String {
        switch (tab, filter) {
        case (.songs, .all): "Add music to your device or sync a cloud source to start listening."
        case (.songs, .offline): "Try another source filter or rescan your device library."
        case (.songs, .online): "Sync your cloud songs, or switch to local source."
        case (.albums, .all): "Albums will appear here as soon as your library has grouped tracks."
        case (.albums, .offline): "Local songs are required to build local album groups."
        case (.albums, .online): "Cloud songs with album data will appear here after sync."
        case (.artists, .all): "Artists are shown after songs are indexed from any source."
        case (.artists, .offline): "No artist metadata is available for local songs right now."
        case (.artists, .online): "Cloud artist entries appear when remote songs are synced."
        case (.liked, .all): "Tap the heart icon while playing a song to save it here."
        case (.liked, .offline): "Switch source filter or like songs from your device."
        case (.liked, .online): "Like cloud tracks to see them in this view."
        case (.folders, _): "Folders with music will appear here."
        case (.playlists, _): "Create your first playlist to organize your library."
        }
    }
}
