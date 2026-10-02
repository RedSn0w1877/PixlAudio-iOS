import PixlLibrary
import PixlModel
import SwiftUI

// The Library's tab pages (Android `LibrarySongsTab`, `LibraryFavoritesTab`, `LibraryAlbumsTab`, `LibraryArtistsTab`,
// `LibraryPlaylistsTab` → `PlaylistContainer`, `LibraryFoldersTab`) and their rows. Lists are lazy; every row is one
// glass layer. Content scrolls under the shell's glass bars and ends 30 pt past them (`ListExtraBottomGap`).

/// What every song page needs from the screen: plain values only, so a page whose inputs did not change skips its
/// body when LibraryView re-renders (actions go through `LibraryActions`, the current song is read per row).
struct LibraryPageContext: Equatable {
    /// The page's own tab.
    let page: LibraryTab
    /// Android reserves 22 pt on the trailing side for its scrollbar when "show scrollbar" is on.
    let showsScrollbarGap: Bool
    /// Counts the locate taps on this page (scroll the current song into view); other pages' taps don't change it.
    let locateRequest: Int

    var trailingPadding: CGFloat { showsScrollbarGap ? 22 : 12 }
}

/// The Library pages' actions, and the bit of state the current song's row reports back. One object kept by
/// LibraryView for its lifetime: pages hold it by reference instead of taking fresh closures on every LibraryView
/// pass (closures never compare equal, so every page and every visible row used to re-run on each pass — a pill tap,
/// play/pause, a track change, even with Library hidden under another tab). LibraryView sets the actions once.
@Observable
final class LibraryActions {
    /// The current song's row is on screen on the visible page (hides the locate button). Read only by the action
    /// row, not by LibraryView.
    private(set) var currentSongVisible = false
    /// The page on screen: only its rows report visibility.
    @ObservationIgnored var visibleTab: LibraryTab = .songs

    @ObservationIgnored var play: (Song, [Song]) -> Void = { _, _ in }
    @ObservationIgnored var showSongOptions: (Song) -> Void = { _ in }
    @ObservationIgnored var openAlbum: (Album) -> Void = { _ in }
    @ObservationIgnored var toggleAlbum: (Album) -> Void = { _ in }
    @ObservationIgnored var openArtist: (Artist) -> Void = { _ in }
    @ObservationIgnored var openPlaylist: (Playlist) -> Void = { _ in }
    @ObservationIgnored var reorderPlaylists: ([String]) -> Void = { _ in }
    @ObservationIgnored var openFolder: (String) -> Void = { _ in }
    @ObservationIgnored var openFolderPlaylist: (MusicFolder) -> Void = { _ in }

    func reportCurrentVisible(_ visible: Bool, page: LibraryTab) {
        guard page == visibleTab, currentSongVisible != visible else { return }
        currentSongVisible = visible
    }

    /// A new page is on screen: its current row (if any) reports again.
    func pageChanged(to tab: LibraryTab) {
        visibleTab = tab
        if currentSongVisible { currentSongVisible = false }
    }
}

/// A song row of a Library page. It reads which song is current (and, for that row only, whether it plays), so the
/// page around it doesn't; the current row keeps reporting its visibility for the locate button.
private struct LibrarySongRow: View {
    let song: Song
    let songs: [Song]
    let page: LibraryTab
    let reportsVisibility: Bool
    let selection: OrderedSelection<String>
    let actions: LibraryActions

    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        let isCurrent = playback.currentSongId == song.id
        let card = SongCard(song: song, isCurrent: isCurrent, isPlaying: isCurrent && playback.isPlaying,
                            onTap: { actions.play(song, songs) }, onMore: { actions.showSongOptions(song) },
                            isSelectionMode: selection.isActive, isSelected: selection.contains(song.id),
                            selectionIndex: selection.index(of: song.id),
                            onLongPress: { selection.toggle(song.id) })
        if isCurrent && reportsVisibility {
            card.onScrollVisibilityChange(threshold: 0.5) { visible in actions.reportCurrentVisible(visible, page: page) }
        } else {
            card
        }
    }
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
    let actions: LibraryActions

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback

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
                            LibrarySongRow(song: song, songs: songs, page: context.page, reportsVisibility: true,
                                           selection: selection, actions: actions)
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
                    guard let id = playback.currentSongId else { return }
                    withAnimation(PixlMotion.state) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .accessibilityIdentifier(isLiked ? "library.page.liked" : "library.page.songs")
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
    let actions: LibraryActions

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
            .onTapGesture { selection.isActive ? actions.toggleAlbum(album) : actions.openAlbum(album) }
            .onLongPressGesture(minimumDuration: 0.45) { actions.toggleAlbum(album) }
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
///
/// A scheme already in memory is used from the first frame (`ColorExtractor.peek`, Android `peekCachedColorScheme`):
/// album and artist pages no longer start in the brand theme and re-theme the whole page mid-push, and album cards
/// no longer flash the brand tint and animate their glass when they are (re)created. Only a real cache miss fades
/// the colours in, as before.
struct AlbumSchemeReader<Content: View>: View {
    let artUri: String?
    @ViewBuilder let content: (ThemeColors) -> Content

    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme
    @State private var pair: ColorRolesPair?

    var body: some View {
        let resolved = cachedPair ?? pair
        content(resolved.map { ThemeColors(roles: $0.roles(dark: theme.isDark), isDark: theme.isDark) } ?? theme)
            .task(id: artUri) {
                guard let source = ArtworkSource(uriString: artUri) else { pair = nil; return }
                let style = settings.appearance.paletteStyle
                let accuracy = settings.appearance.colorAccuracy
                if let hit = env.colorExtractor.peek(source, style: style, accuracyLevel: accuracy) {
                    if pair != hit { pair = hit }
                    return
                }
                let loaded = await env.colorExtractor.schemePair(for: source, style: style, accuracyLevel: accuracy)
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.25)) { pair = loaded } }
            }
    }

    private var cachedPair: ColorRolesPair? {
        guard let source = ArtworkSource(uriString: artUri) else { return nil }
        return env.colorExtractor.peek(source, style: settings.appearance.paletteStyle,
                                       accuracyLevel: settings.appearance.colorAccuracy)
    }
}

// MARK: - Artists

struct LibraryArtistsPage: View {
    let artists: [Artist]
    let emptyFilter: StorageFilter
    let showsScrollbarGap: Bool
    let actions: LibraryActions

    @Environment(LibraryStore.self) private var library

    var body: some View {
        if artists.isEmpty && !library.isLoading {
            LibraryEmptyState(systemImage: "music.mic", title: LibraryEmptyCopy.title(.artists, emptyFilter),
                              subtitle: LibraryEmptyCopy.subtitle(.artists, emptyFilter))
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(artists) { artist in
                        ArtistRow(artist: artist) { actions.openArtist(artist) }
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
    let actions: LibraryActions

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
                           onTap: { selection.isActive ? selection.toggle(playlist.id) : actions.openPlaylist(playlist) },
                           onLongPress: { selection.toggle(playlist.id) },
                           dragPayload: playlist.id)
            .dropDestination(for: String.self) { items, _ in
                guard reorderable, let source = items.first, source != playlist.id else { return false }
                var ids = playlists.map(\.id)
                guard let from = ids.firstIndex(of: source), let to = ids.firstIndex(of: playlist.id) else { return false }
                ids.remove(at: from)
                ids.insert(source, at: to)
                actions.reorderPlaylists(ids)
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
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))
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
    /// Each folder's sorted subfolders and songs (`LibraryModel`, computed off the main actor).
    let folderContents: [String: LibraryModel.FolderContents]
    let folderPath: String?
    let isPlaylistView: Bool
    let context: LibraryPageContext
    let selection: OrderedSelection<String>
    let actions: LibraryActions

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        // Precomputed: no tree walk or sort here.
        let active = folderPath.flatMap { folderContents[$0] }
        let showsPlaylistCards = isPlaylistView && active == nil
        let items: [MusicFolder] = showsPlaylistCards ? folderPlaylists : (active?.subFolders ?? folders)
        let songs = active?.songs ?? []
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
                                    FolderRow(folder: folder, asPlaylist: true) { actions.openFolderPlaylist(folder) }
                                } else {
                                    FolderRow(folder: folder, asPlaylist: false) { actions.openFolder(folder.path) }
                                }
                            }
                            ForEach(songs) { song in
                                LibrarySongRow(song: song, songs: songs, page: context.page, reportsVisibility: false,
                                               selection: selection, actions: actions)
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
                        guard let id = playback.currentSongId else { return }
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
                    ArtCollage(songs: LibraryModel.firstSongs(folder, limit: 9), size: 48)
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
