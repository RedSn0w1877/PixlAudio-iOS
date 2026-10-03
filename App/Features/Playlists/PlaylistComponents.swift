import PixlLibrary
import PixlModel
import SwiftUI

// Pieces of the playlist screens: the song picker (Android `SongPickerBottomSheet` / `SongPickerSelectionPane`),
// the playlist song row (`QueuePlaylistSongItem` with `isFromPlaylist = true`), the playlist lyric-sync progress card
// (`PlaylistLyricSyncCard`), the song sort sheet (`LibrarySortBottomSheet` with the playlist's song options) and the
// options sheet rows (`PlaylistActionItem`). Material fills become tinted Liquid Glass.

// MARK: - Song picker

/// Android `SongPickerSelectionPane`: the search field (capsule, "Search or filter songs…"), the Liked filter chip and
/// the songs as check rows (`SongPickerRow`: capsule, check box, 36 pt round art). Filtering runs when an input
/// changes, never in `body`.
///
/// The whole library is filtered and sorted for it: the default list (no query, Liked off) is precomputed off the
/// main actor when the editor or the playlist page appears (`SongPickerDefaults`) and seeds the first frame; later
/// inputs (typing, the Liked chip, the storage filter) filter off the main actor while the current rows stay. Only a
/// cold first open still computes synchronously, as before.
struct SongPickerPane: View {
    @Binding var selection: Set<String>
    @Binding var storageFilter: StorageFilter
    var bottomPadding: CGFloat = 120

    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme

    @State private var query = ""
    @State private var favoritesOnly = false
    @State private var displayed: [Song]
    /// The library revision the seeded rows were computed for (nil: not seeded).
    @State private var seededRevision: Int?
    @State private var hasComputed = false
    @State private var generation = 0
    @State private var filterTask: Task<Void, Never>?

    init(selection: Binding<Set<String>>, storageFilter: Binding<StorageFilter>, bottomPadding: CGFloat = 120) {
        _selection = selection
        _storageFilter = storageFilter
        self.bottomPadding = bottomPadding
        let seed = SongPickerDefaults.latest(filter: storageFilter.wrappedValue)
        _displayed = State(initialValue: seed?.songs ?? [])
        _seededRevision = State(initialValue: seed?.revision)
    }

    nonisolated fileprivate struct Inputs: Equatable, Sendable {
        var count: Int
        var query: String
        var favoritesOnly: Bool
        var filter: StorageFilter

        var isDefault: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty && !favoritesOnly }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            HStack {
                likedChip
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            if displayed.isEmpty {
                LibraryEmptyState(systemImage: query.isEmpty ? "music.note" : "magnifyingglass",
                                  title: query.isEmpty ? LibraryEmptyCopy.title(favoritesOnly ? .liked : .songs, storageFilter)
                                                       : "No results for \"\(query)\"",
                                  subtitle: query.isEmpty ? LibraryEmptyCopy.subtitle(favoritesOnly ? .liked : .songs, storageFilter)
                                                          : "")
                    .padding(.bottom, bottomPadding)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(displayed) { song in
                            SongCheckRow(song: song, isChecked: selection.contains(song.id)) {
                                if selection.contains(song.id) { selection.remove(song.id) } else { selection.insert(song.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, bottomPadding)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .onChange(of: Inputs(count: library.songs.count, query: query, favoritesOnly: favoritesOnly, filter: storageFilter),
                  initial: true) { old, inputs in
            update(from: old, to: inputs)
        }
        .accessibilityIdentifier("songPicker")
    }

    private func update(from old: Inputs, to inputs: Inputs) {
        let isFirst = !hasComputed
        hasComputed = true
        if isFirst {
            // Seeded with this library's default list: nothing to compute.
            if inputs.isDefault, seededRevision == library.revision { return }
            // Cold first open: compute now, as before, so the first frame has its rows.
            if displayed.isEmpty {
                displayed = Self.filter(library.songs, inputs: inputs)
                if inputs.isDefault {
                    SongPickerDefaults.store(displayed, revision: library.revision, filter: inputs.filter)
                }
                return
            }
        }
        // Off the main actor; the current rows stay until the result lands (no empty-state flash, no debounce).
        filterTask?.cancel()
        generation += 1
        let token = generation
        let songs = library.songs
        // The Liked chip and the storage filter change inside their own animations, and the list change used to land
        // in that same transaction and animate with it; the late result replays the animation that triggered it.
        let animation: Animation? = if old.favoritesOnly != inputs.favoritesOnly {
            PixlMotion.state
        } else if old.filter != inputs.filter {
            PixlMotion.selection
        } else {
            nil
        }
        filterTask = Task {
            let result = await Task.detached(priority: .userInitiated) { Self.filter(songs, inputs: inputs) }.value
            guard !Task.isCancelled, token == generation else { return }
            if let animation {
                withAnimation(animation) { displayed = result }
            } else {
                displayed = result
            }
        }
    }

    fileprivate nonisolated static func filter(_ songs: [Song], inputs: Inputs) -> [Song] {
        let trimmed = inputs.query.trimmingCharacters(in: .whitespaces)
        var result = songs.filter { LibrarySorting.matches($0, filter: inputs.filter) }
        if inputs.favoritesOnly { result = result.filter(\.isFavorite) }
        if !trimmed.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(trimmed) || $0.displayArtist.localizedCaseInsensitiveContains(trimmed)
                    || $0.album.localizedCaseInsensitiveContains(trimmed)
            }
        }
        return LibrarySorting.sortSongs(result, by: inputs.favoritesOnly ? .songDateAdded : .songTitleAZ)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.onSurfaceVariant)
            TextField("Search or filter songs…", text: $query)
                .pixlFont(.bodyLarge)
                .foregroundStyle(theme.onSurface)
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.onSurfaceVariant)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .pixlGlass(in: Capsule(), tint: theme.surfaceContainerHigh.opacity(GlassTint.surface))
    }

    /// Android `FilterChip` (pill → 12 pt smooth corners when selected, `primaryContainer`).
    private var likedChip: some View {
        Button { withAnimation(PixlMotion.state) { favoritesOnly.toggle() } } label: {
            HStack(spacing: 8) {
                Image(systemName: favoritesOnly ? "heart.fill" : "heart")
                    .font(.system(size: 15, weight: .semibold))
                Text("Liked")
                    .pixlFont(.labelLarge, weight: favoritesOnly ? .bold : .medium)
            }
            .foregroundStyle(favoritesOnly ? theme.onPrimaryContainer : theme.onSurfaceVariant)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: favoritesOnly ? 12 : 16, style: .continuous),
                   tint: (favoritesOnly ? theme.primaryContainer : theme.surfaceContainerHigh)
                       .opacity(favoritesOnly ? GlassTint.prominent : GlassTint.surface),
                   interactive: true)
        .accessibilityAddTraits(favoritesOnly ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("songPicker.liked")
    }
}

/// Android `SongPickerContent`'s bottom bar: with cloud songs, the LOCAL / CLOUD tab capsule and the 56 pt check
/// button (16 pt corners, `tertiaryContainer`); without, the large "Add" button at the end (20 pt corners).
struct SongPickerBottomBar: View {
    @Binding var storageFilter: StorageFilter
    let showsCloudFilter: Bool
    var title = "Add"
    var confirmLabel = "Add selected songs"
    let onConfirm: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            if showsCloudFilter {
                // The tab bar's liquid lens (Hoa, 2026-10-03): the selection lifts off as clear glass, follows the
                // finger and magnifies LOCAL / CLOUD under it.
                LiquidTabCapsule(tabs: [
                    .init(value: StorageFilter.offline, title: "LOCAL", systemImage: "iphone", identifier: "songPicker.local"),
                    .init(value: StorageFilter.online, title: "CLOUD", systemImage: "cloud", selectedSystemImage: "cloud.fill",
                          identifier: "songPicker.cloud"),
                ], selection: $storageFilter)
                Button(action: onConfirm) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.onTertiaryContainer)
                        .frame(width: 56, height: 56)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                           tint: theme.tertiaryContainer.opacity(GlassTint.prominent), interactive: true)
                .accessibilityLabel(confirmLabel)
                .accessibilityIdentifier("songPicker.confirm")
            } else {
                Spacer()
                Button(action: onConfirm) {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark").font(.system(size: 24, weight: .semibold))
                        Text(title).pixlFont(.titleMedium, weight: .bold)
                    }
                    .foregroundStyle(theme.onTertiaryContainer)
                    .padding(.horizontal, 24)
                    .frame(height: 72)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pixlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                           tint: theme.tertiaryContainer.opacity(GlassTint.prominent), interactive: true)
                .accessibilityLabel(confirmLabel)
                .accessibilityIdentifier("songPicker.confirm")
            }
        }
        .padding(16)
    }
}

/// Android `SongPickerBottomSheet`: "Add songs" (`displaySmall`, 26 pt sides), the picker pane, the bottom bar.
/// Starts with the playlist's songs checked; confirming adds the newly checked ones. The storage filter starts at the
/// presenter's value (offline when the library has cloud songs, else all), not reassigned after the first frame
/// (which refiltered the whole library a second time while the sheet rose).
struct SongPickerSheet: View {
    let initiallySelected: Set<String>
    let onConfirm: (Set<String>) -> Void

    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme
    @State private var selection: Set<String> = []
    @State private var storageFilter: StorageFilter
    @State private var didLoad = false

    init(initiallySelected: Set<String>, initialStorageFilter: StorageFilter,
         onConfirm: @escaping (Set<String>) -> Void) {
        self.initiallySelected = initiallySelected
        self.onConfirm = onConfirm
        _storageFilter = State(initialValue: initialStorageFilter)
    }

    var body: some View {
        let hasCloud = library.songs.contains(where: LibrarySorting.isOnline) || LaunchConfiguration.current.forcesCloudFilter
        VStack(alignment: .leading, spacing: 0) {
            Text("Add songs")
                .pixlFont(.displaySmall)
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 26)
                .padding(.vertical, 8)
                .padding(.top, 16)
            SongPickerPane(selection: $selection, storageFilter: $storageFilter)
        }
        .overlay(alignment: .bottom) {
            SongPickerBottomBar(storageFilter: $storageFilter, showsCloudFilter: hasCloud) { onConfirm(selection) }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            selection = initiallySelected
        }
        .accessibilityIdentifier("sheet.songPicker")
    }
}

/// The song picker's default list (no query, Liked off) per storage filter, for one library revision: computed off
/// the main actor before the picker opens (the playlist editor's first step, the playlist page) so the picker's first
/// frame has its rows without filtering and sorting the whole library inside its transition.
enum SongPickerDefaults {
    private static var lists: [StorageFilter: (revision: Int, songs: [Song])] = [:]
    private static var warming: Set<StorageFilter> = []

    /// The latest default list for `filter` (it may be for an older revision: the picker checks).
    static func latest(filter: StorageFilter) -> (revision: Int, songs: [Song])? { lists[filter] }

    static func store(_ songs: [Song], revision: Int, filter: StorageFilter) {
        lists[filter] = (revision, songs)
    }

    /// Computes the default list for the library's current revision, unless it is there or under way.
    static func warm(library: LibraryStore, filter: StorageFilter) {
        let revision = library.revision
        guard lists[filter]?.revision != revision, !warming.contains(filter) else { return }
        warming.insert(filter)
        let songs = library.songs
        let inputs = SongPickerPane.Inputs(count: songs.count, query: "", favoritesOnly: false, filter: filter)
        Task {
            let result = await Task.detached(priority: .utility) { SongPickerPane.filter(songs, inputs: inputs) }.value
            warming.remove(filter)
            store(result, revision: revision, filter: filter)
        }
    }
}

// MARK: - Playlist song row

/// Android `QueuePlaylistSongItem` in a playlist: a 22 pt card (`surfaceContainerLowest`; the current song becomes a
/// capsule with round art and a `primary` bold title), 12 pt outer sides, 16 pt vertical padding; the drag handle
/// (reorder mode), 42 pt art, title / artist, the playing indicator, the ⋮ button (`surfaceContainerHigh`, current
/// `tertiaryContainer`) and the remove button (remove mode, `surfaceContainer`).
struct PlaylistSongRow: View {
    let song: Song
    let isCurrent: Bool
    let isPlaying: Bool
    let showsDragHandle: Bool
    let showsRemove: Bool
    let onTap: () -> Void
    let onMore: () -> Void
    let onRemove: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: isCurrent ? 37 : 22, style: .continuous)
        HStack(spacing: 0) {
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 40, height: 40)
                    .contentShape(.rect)
                    .draggable(song.id)
                    .accessibilityLabel("Reorder songs")
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Spacer().frame(width: showsDragHandle ? 6 : 12)
            // Art, title, artist and indicator read as one button that plays the song.
            HStack(spacing: 0) {
                ArtworkView(song: song, size: 42, cornerRadius: isCurrent ? 21 : 8)
                Spacer().frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(song.title)
                        .pixlFont(.bodyLarge, weight: isCurrent ? .bold : .regular)
                        .foregroundStyle(isCurrent ? theme.primary : theme.onSurface)
                        .lineLimit(1)
                    Text(song.displayArtist)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(isCurrent ? theme.primary.opacity(0.8) : theme.onSurfaceVariant)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent {
                    PlayingIndicator(isPlaying: isPlaying, color: theme.secondary)
                        .padding(.leading, 8)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onTap)
            if isCurrent {
                Spacer().frame(width: showsRemove ? 4 : 12)
            } else {
                Spacer().frame(width: 8)
            }
            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(isCurrent ? theme.onTertiaryContainer : theme.onSurface)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(isCurrent ? theme.tertiaryContainer : theme.surfaceContainerHigh))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle().inset(by: -4))
            }
            .buttonStyle(PressScaleButtonStyle())
            .padding(.trailing, 10)
            .accessibilityLabel("More options for \(song.title)")
            .accessibilityIdentifier("playlistSong.more.\(song.id)")
            if showsRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.onSurface)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(theme.surfaceContainer))
                        .frame(width: 40, height: 40)
                        .contentShape(.circle)
                }
                .buttonStyle(PressScaleButtonStyle())
                .padding(.trailing, 4)
                .accessibilityLabel("Remove from playlist")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 16)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .pixlGlass(in: shape, tint: theme.surfaceContainerLowest.opacity(GlassTint.surface), interactive: true)
        .padding(.horizontal, 12)
        .animation(PixlMotion.state, value: isCurrent)
        .animation(PixlMotion.state, value: showsDragHandle)
        .animation(PixlMotion.state, value: showsRemove)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playlistSong.\(song.id)")
    }
}

// MARK: - Lyric sync card

/// Progress of a "sync lyrics for all songs" run (Android `PlaylistLyricSyncState`), from stage 14's TAIS Studio lane
/// (`TaisStudio.lyricSyncState(playlistId:)`). Empty — and the card hidden — while no run exists, as on Android.
nonisolated struct PlaylistLyricSyncState: Sendable, Equatable {
    var total = 0
    var completed = 0
    var synced = 0
    var skipped = 0
    var failedSongIds: [String] = []
    var isRunning = false
    var detail: String?

    var progress: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    static let idle = PlaylistLyricSyncState()
}

/// Android `PlaylistLyricSyncCard`: a 28 pt `secondaryContainer` card, 20 pt padding, title, counts, progress,
/// detail and Cancel remaining / Retry unfinished songs. Hidden while no run exists.
struct PlaylistLyricSyncCard: View {
    let state: PlaylistLyricSyncState
    let onCancel: () -> Void
    let onRetry: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        if state.total > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.isRunning ? "Syncing your playlist" : "Playlist lyric sync")
                    .pixlFont(.titleMedium)
                Text("\(state.completed) of \(state.total) finished · \(state.synced) synced · \(state.skipped) skipped"
                     + (state.failedSongIds.isEmpty ? "" : " · \(state.failedSongIds.count) need a retry"))
                    .pixlFont(.bodySmall)
                if state.isRunning {
                    ProgressView(value: state.progress)
                        .tint(theme.primary)
                }
                if let detail = state.detail {
                    Text(detail).pixlFont(.bodySmall).lineLimit(2)
                }
                HStack {
                    Spacer()
                    if state.isRunning {
                        Button("Cancel remaining", action: onCancel)
                            .buttonStyle(.plain)
                            .pixlFont(.labelLarge)
                            .foregroundStyle(theme.primary)
                    } else if !state.failedSongIds.isEmpty {
                        GlassPillButton(title: "Retry unfinished songs", tint: theme.secondaryContainer.opacity(0.5),
                                        foreground: theme.onSecondaryContainer, action: onRetry)
                    }
                }
            }
            .foregroundStyle(theme.onSecondaryContainer)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                       tint: theme.secondaryContainer.opacity(GlassTint.container))
        }
    }
}

// MARK: - Song sort sheet

/// Android `LibrarySortBottomSheet` for a playlist's songs ("Sort Songs", no view toggle): the Order card, then the
/// sort methods as 8 pt tiles in a 20 pt group. "Default Order" is the playlist's own (manual) order.
struct PlaylistSongSortSheet: View {
    let selected: SortOption
    let onSelect: (SortOption) -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let methods = SortOption.songs.map { $0.methodOption() }.reduce(into: [SortOption]()) { result, option in
            if !result.contains(where: { $0.methodKey == option.methodKey }) { result.append(option) }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sort Songs")
                    .pixlFont(.headlineMedium, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .padding(.leading, 2)
                    .padding(.bottom, 16)
                SortDirectionCard(option: selected) { onSelect(selected.flipDirection()) }
                    .padding(.bottom, 12)
                VStack(spacing: 4) {
                    ForEach(methods, id: \.self) { method in
                        let isSelected = method.methodKey == selected.methodKey
                        Button {
                            onSelect(method.resolveForDirection(selected.direction))
                            dismiss()
                        } label: {
                            HStack {
                                Text(method.methodLabel)
                                    .pixlFont(.bodyLarge)
                                    .foregroundStyle(isSelected ? theme.onSecondaryContainer : theme.onSurface)
                                Spacer()
                                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 20))
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
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                Spacer().frame(height: 16)
            }
            .padding(.horizontal, Tokens.Spacing.xxl)
            .padding(.top, Tokens.Spacing.l)
        }
        .accessibilityIdentifier("sheet.playlistSort")
    }
}

// MARK: - Options sheet row

/// Android `PlaylistActionItem`: an 18 pt `surfaceContainerHigh` row (16 pt sides, 6 pt apart, 16×14 padding) with
/// the icon in a 40 pt `surfaceContainerHighest` circle (`primary`) and the label (`titleMedium`).
struct PlaylistActionRow: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.primary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(theme.surfaceContainerHighest))
            Text(title)
                .pixlFont(.titleMedium)
                .foregroundStyle(theme.onSurface)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(.rect)
    }
}

extension View {
    /// The glass tile behind a `PlaylistActionRow` (18 pt corners, `surfaceContainerHigh`).
    func playlistActionTile(_ theme: ThemeColors, interactive: Bool = true) -> some View {
        pixlGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                  tint: theme.surfaceContainerHigh.opacity(GlassTint.surface), interactive: interactive)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}
