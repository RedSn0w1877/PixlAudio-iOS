import PixlLibrary
import PixlModel
import SwiftUI

/// Genre detail (Android `GenreDetailScreen`): themed with the genre's colour scheme (a seed from the genre colour
/// table; "unknown" is monochrome). The gradient header (200 → 58 pt, the genre colour fading out as it collapses
/// into `surfaceContainer`) over the songs grouped by artist → album (or by album, or a flat title list), the ⋮
/// options button (Android medium FAB: `tertiaryContainer`, 24 pt corners) that opens Sort & Play — with Quick Fill
/// for the unknown genre — and long-press multi-selection with the selection bar at the bottom.
struct GenreDetailView: View {
    let genreId: String

    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        let scheme = GenreTheme.cachedScheme(genreId: genreId, isDark: appTheme.isDark,
                                             style: settings.appearance.paletteStyle)
        GenreDetailContent(genreId: genreId, headerColor: GenreTheme.color(genreId: genreId, isDark: appTheme.isDark))
            .environment(\.appTheme, scheme)
            .toolbar(.hidden, for: .navigationBar)
            .accessibilityIdentifier("screen.genreDetail")
    }
}

/// How the genre screen groups its songs (Android `GenreDetailViewModel.SortOption`).
nonisolated enum GenreSort: String, Sendable, CaseIterable {
    case artist, album, title
}

/// One row of the flattened genre list (Android `GenreDetailListItem`).
nonisolated enum GenreListItem: Identifiable, Sendable {
    case artistHeader(key: String, name: String)
    case albumHeader(key: String, name: String, artUri: String?, songs: [Song], artistStyle: Bool)
    case song(key: String, song: Song, isFirst: Bool, isLast: Bool, isLastAlbumInSection: Bool, artistStyle: Bool)
    case spacer(key: String, height: CGFloat, surface: Bool)
    case divider(key: String)

    var id: String {
        switch self {
        case .artistHeader(let key, _), .albumHeader(let key, _, _, _, _), .song(let key, _, _, _, _, _),
             .spacer(let key, _, _), .divider(let key):
            key
        }
    }
}

nonisolated enum GenreGrouping {
    /// The genre key of `LibraryDetailIndex.songsByGenre` for a genre id ("" for unknown).
    static func indexKey(of genreId: String) -> String {
        GenreTheme.isUnknown(genreId) ? "" : genreId.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Songs of a genre: matching name (trimmed, case-insensitive); "unknown" collects songs without a genre.
    static func songs(of genreId: String, in library: [Song]) -> [Song] {
        let target = genreId.trimmingCharacters(in: .whitespaces).lowercased()
        if GenreTheme.isUnknown(genreId) {
            return library.filter { ($0.genre ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return library.filter { ($0.genre ?? "").trimmingCharacters(in: .whitespaces).lowercased() == target }
    }

    private static func albumOrder(_ songs: [Song]) -> [Song] { LibrarySorting.albumPlaybackOrder(songs) }

    /// Kotlin `groupBy` keeps first-seen key order.
    private static func grouped(_ songs: [Song], by key: (Song) -> String) -> [(String, [Song])] {
        var order: [String] = []
        var groups: [String: [Song]] = [:]
        for song in songs {
            let k = key(song)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(song)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// The play order for a sort (Android `sortedSongs`).
    static func sorted(_ songs: [Song], by sort: GenreSort) -> [Song] {
        switch sort {
        case .artist: songs.sorted { $0.artist < $1.artist }
        case .album: songs.sorted { $0.album < $1.album }
        case .title: songs.sorted { $0.title < $1.title }
        }
    }

    /// Android `buildDisplaySections` + `flattenSections`.
    static func items(_ songs: [Song], sort: GenreSort) -> [GenreListItem] {
        var items: [GenreListItem] = []
        switch sort {
        case .artist:
            for (artist, artistSongs) in grouped(sorted(songs, by: .artist), by: \.artist) {
                let section = "artist_\(artist)"
                items.append(.artistHeader(key: "header_\(section)", name: artist))
                let albums = grouped(artistSongs, by: \.album)
                for (albumIndex, (album, albumSongs)) in albums.enumerated() {
                    let ordered = albumOrder(albumSongs)
                    if albumIndex > 0 { items.append(.divider(key: "divider_\(section)_\(albumIndex)")) }
                    items.append(.albumHeader(key: "\(section)_album_header_\(album)", name: album,
                                              artUri: ordered.first?.albumArtUriString, songs: ordered, artistStyle: true))
                    items.append(.spacer(key: "\(section)_album_spacer_\(album)", height: 10, surface: true))
                    for (index, song) in ordered.enumerated() {
                        items.append(.song(key: "\(section)_\(album)_\(song.id)", song: song, isFirst: index == 0,
                                           isLast: index == ordered.count - 1,
                                           isLastAlbumInSection: albumIndex == albums.count - 1, artistStyle: true))
                    }
                }
                items.append(.spacer(key: "section_spacer_\(section)", height: 16, surface: false))
            }
        case .album:
            for (album, albumSongs) in grouped(sorted(songs, by: .album), by: \.album) {
                let section = "album_\(album)"
                let ordered = albumOrder(albumSongs)
                items.append(.albumHeader(key: "\(section)_album_header_\(album)", name: album,
                                          artUri: ordered.first?.albumArtUriString, songs: ordered, artistStyle: false))
                items.append(.spacer(key: "\(section)_album_spacer_\(album)", height: 10, surface: true))
                for (index, song) in ordered.enumerated() {
                    items.append(.song(key: "\(section)_\(song.id)", song: song, isFirst: index == 0,
                                       isLast: index == ordered.count - 1, isLastAlbumInSection: true, artistStyle: false))
                }
                items.append(.spacer(key: "section_spacer_\(section)", height: 16, surface: false))
            }
        case .title:
            for song in sorted(songs, by: .title) {
                items.append(.song(key: "flat_\(song.id)", song: song, isFirst: false, isLast: false,
                                   isLastAlbumInSection: false, artistStyle: false))
            }
            items.append(.spacer(key: "section_spacer_flat", height: 16, surface: false))
        }
        return items
    }
}

private struct GenreDetailContent: View {
    let genreId: String
    let headerColor: GenreTheme.Pair

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    @State private var scroll = HeaderScrollState()
    @State private var sort: GenreSort = .artist
    /// The genre's songs, list rows and play order, derived in `body` once per (library revision, sort): the first
    /// frame of the push already has them (no second pass), and nothing is sorted again on later passes.
    @State private var memo = ViewMemo<GenreContentKey, GenreContent>()
    @State private var selection = OrderedSelection<String>()
    @State private var showsSortSheet = false
    @State private var showsQuickFill = false
    @State private var showsSelectionSheet = false
    @State private var addToPlaylistIds: [String]?

    private var displayName: String {
        genreId.replacingOccurrences(of: "_", with: " ").split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    var body: some View {
        let content = self.content
        let songs = content.songs
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let metrics = CollapseMetrics(maxHeight: 200, minHeight: 58 + safeTop)
            ZStack(alignment: .top) {
                theme.background.ignoresSafeArea()
                list(content, topPadding: metrics.maxHeight - safeTop + 8)
                GenreHeader(title: displayName, scroll: scroll, metrics: metrics, safeTop: safeTop,
                            startColor: Color(argb: headerColor.container), contentColor: Color(argb: headerColor.onContainer),
                            onBack: { router.pop() })
                    .ignoresSafeArea(edges: .top)
                if selection.isActive {
                    SelectionCountPill(count: selection.count)
                        .padding(.top, metrics.minHeight - safeTop + 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .overlay(alignment: selection.isActive ? .bottom : .bottomTrailing) {
            GenreBottomControl(selection: selection, songs: songs, playOrder: content.playOrder, sort: $sort,
                               isUnknownGenre: GenreTheme.isUnknown(genreId),
                               onQuickFill: { showsQuickFill = true },
                               onSelectionOptions: { showsSelectionSheet = true })
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selection.isActive)
        .sheet(isPresented: $showsSortSheet) {
            GenreSortSheet(sort: sort, showsQuickFill: GenreTheme.isUnknown(genreId),
                           onSort: { sort = $0; showsSortSheet = false },
                           onShuffle: {
                               let ordered = self.content.playOrder
                               if let start = ordered.randomElement() { playback.play(start, in: ordered) }
                               showsSortSheet = false
                           },
                           onQuickFill: {
                               showsSortSheet = false
                               showsQuickFill = true
                           })
                .pixlSheet(detents: [.medium])
        }
        .fullScreenCover(isPresented: $showsQuickFill) {
            QuickFillSheet(songs: songs) { ids, genre in
                env.libraryEditor.setGenre(ids, genre: genre)
            }
        }
        .sheet(isPresented: $showsSelectionSheet) {
            SongMultiSelectionSheet(songs: selection.ids.compactMap { library.song(id: $0) },
                                    onAddToPlaylist: { ids in
                                        showsSelectionSheet = false
                                        addToPlaylistIds = ids
                                    },
                                    onDone: { selection.clear() })
                .pixlSheet(detents: [.medium, .large])
        }
        .sheet(item: Binding(get: { addToPlaylistIds.map(IdentifiedIds.init) }, set: { addToPlaylistIds = $0?.ids })) { item in
            AddToPlaylistSheet(songIds: item.ids)
                .pixlSheet(detents: [.large])
        }
        .libraryToast()
    }

    private var content: GenreContent {
        memo.value(for: GenreContentKey(revision: library.revision, sort: sort)) {
            let songs = library.detailIndexIfCurrent.map { $0.songsByGenre[GenreGrouping.indexKey(of: genreId)] ?? [] }
                ?? GenreGrouping.songs(of: genreId, in: library.songs)
            return GenreContent(songs: songs, items: GenreGrouping.items(songs, sort: sort),
                                playOrder: GenreGrouping.sorted(songs, by: sort))
        }
    }

    private func list(_ content: GenreContent, topPadding: CGFloat) -> some View {
        let playOrder = content.playOrder
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(content.items) { item in
                    row(item, playOrder: playOrder)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, topPadding)
            .padding(.bottom, 148 + 16)
        }
        .scrollIndicators(.hidden)
        .trackingHeaderScroll(scroll)
    }

    @ViewBuilder
    private func row(_ item: GenreListItem, playOrder: [Song]) -> some View {
        let groupFill = theme.surfaceContainerLow.opacity(0.5)
        switch item {
        case .artistHeader(_, let name):
            HStack(spacing: 12) {
                Image(systemName: "person.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(theme.primaryContainer))
                Text(name)
                    .pixlFont(.titleMedium, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                Spacer()
            }
            .padding(16)
            .background(theme.surfaceContainerHigh)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                              topTrailingRadius: 24, style: .continuous))
        case .albumHeader(_, let name, let artUri, let albumSongs, let artistStyle):
            HStack(spacing: 16) {
                ArtworkView(source: ArtworkSource(uriString: artUri), size: 48, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .pixlFont(.titleMedium, weight: .semibold)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(LibraryFormat.songCount(albumSongs.count))
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    if let first = albumSongs.first { playback.play(first, in: playOrder) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.onPrimary)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(theme.primary))
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel("Play album")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .background(UnevenRoundedRectangle(topLeadingRadius: artistStyle ? 0 : 24, bottomLeadingRadius: 0,
                                               bottomTrailingRadius: 0, topTrailingRadius: artistStyle ? 0 : 24,
                                               style: .continuous).fill(groupFill))
        case .song(_, let song, let isFirst, let isLast, let isLastAlbum, let artistStyle):
            let closes = isLast && isLastAlbum
            VStack(spacing: 0) {
                if !isFirst { Spacer().frame(height: 2) }
                PlaybackRowState(songId: song.id) { isCurrent, isPlaying in
                    SongCard(song: song, isCurrent: isCurrent, isPlaying: isPlaying,
                             onTap: { playback.play(song, in: playOrder) },
                             onMore: { router.present(AppSheet.songInfo(songId: song.id)) },
                             showsArtwork: false,
                             corners: corners(isFirst: isFirst, isLast: isLast),
                             isSelectionMode: selection.isActive, isSelected: selection.contains(song.id),
                             selectionIndex: selection.index(of: song.id),
                             onLongPress: { selection.toggle(song.id) })
                }
                if isLast { Spacer().frame(height: 8) }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, isLast && !isLastAlbum && artistStyle ? 8 : 0)
            .background(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: closes ? 24 : 0,
                                               bottomTrailingRadius: closes ? 24 : 0, topTrailingRadius: 0,
                                               style: .continuous).fill(groupFill))
        case .spacer(_, let height, let surface):
            (surface ? groupFill : Color.clear).frame(height: height)
        case .divider:
            Rectangle()
                .fill(theme.outlineVariant.opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(groupFill)
        }
    }

    /// Android `GenreSongItemWrapper` shapes: 16 pt outer, 4 pt inner corners.
    private func corners(isFirst: Bool, isLast: Bool) -> SongCardCorners {
        switch (isFirst, isLast) {
        case (true, true): SongCardCorners(top: 16, bottom: 16)
        case (true, false): SongCardCorners(top: 16, bottom: 4)
        case (false, true): SongCardCorners(top: 4, bottom: 16)
        case (false, false): SongCardCorners(top: 4, bottom: 4)
        }
    }
}

/// What GenreDetailContent derives from the library (once per key).
private struct GenreContentKey: Equatable {
    let revision: Int
    let sort: GenreSort
}

private struct GenreContent {
    let songs: [Song]
    let items: [GenreListItem]
    let playOrder: [Song]
}

/// The floating ⋮ button, or the selection bar while selecting. Its own view: it reads whether a song is loaded
/// (the mini player's clearance), so a track change re-runs this control, not the genre's whole list.
private struct GenreBottomControl: View {
    let selection: OrderedSelection<String>
    let songs: [Song]
    /// The songs in the current sort (`GenreGrouping.sorted(songs, by: sort)`, memoised by the page).
    let playOrder: [Song]
    @Binding var sort: GenreSort
    let isUnknownGenre: Bool
    let onQuickFill: () -> Void
    let onSelectionOptions: () -> Void

    @Environment(PlaybackStore.self) private var playback
    @Environment(\.appTheme) private var theme

    /// The shell's mini player floats over pushed screens; the floating controls sit above it (Android pads by
    /// `MiniPlayerHeight` while a song is loaded).
    private var miniPlayerClearance: CGFloat { playback.miniPlayerClearance }

    var body: some View {
        if selection.isActive {
            LibrarySelectionActionRow(onSelectAll: { selection.selectAll(songs.map(\.id)) },
                                      onDeselect: { selection.clear() },
                                      onOptions: onSelectionOptions)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .pixlGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                           tint: theme.surfaceContainer.opacity(GlassTint.container))
                .padding(.horizontal, 16)
                .padding(.bottom, 16 + miniPlayerClearance)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            // Sort & Play is a small system menu that morphs out of the button (owner change 2026-10-02).
            ShapedGlassMenu(systemImage: "ellipsis", accessibilityLabel: "Options",
                            shape: RoundedRectangle(cornerRadius: 24, style: .continuous), width: 80, height: 80,
                            iconSize: 24, iconWeight: .bold, iconRotation: 90,
                            tint: theme.tertiaryContainer.opacity(GlassTint.prominent),
                            foreground: theme.onTertiaryContainer) {
                sortAndPlayMenu
            }
            .padding(.trailing, 16)
            .padding(.bottom, 26 + miniPlayerClearance)
            .accessibilityIdentifier("genre.options")
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// Android's "Sort & Play" sheet as a menu: Shuffle, Quick Fill (Unknown genre only), then Sort By.
    @ViewBuilder
    private var sortAndPlayMenu: some View {
        Section {
            Button("Shuffle", systemImage: "shuffle") {
                if let start = playOrder.randomElement() { playback.play(start, in: playOrder) }
            }
            if isUnknownGenre {
                Button("Quick Fill Genre", systemImage: "wand.and.stars", action: onQuickFill)
            }
        }
        Section("Sort By") {
            Picker("Sort By", selection: $sort) {
                Label("Artist", systemImage: "person.fill").tag(GenreSort.artist)
                Label("Album", systemImage: "opticaldisc").tag(GenreSort.album)
                Label("Title", systemImage: "textformat.abc").tag(GenreSort.title)
            }
            .pickerStyle(.inline)
        }
    }
}

/// Wraps song ids for `.sheet(item:)`.
nonisolated struct IdentifiedIds: Identifiable, Hashable, Sendable {
    let ids: [String]
    var id: String { ids.joined(separator: ",") }
}

/// Android `GenreCollapsibleTopBar`.
private struct GenreHeader: View {
    let title: String
    let scroll: HeaderScrollState
    let metrics: CollapseMetrics
    let safeTop: CGFloat
    let startColor: Color
    let contentColor: Color
    let onBack: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let height = metrics.height(offset: scroll.offset)
        let fraction = metrics.fraction(offset: scroll.offset)
        let solid = min(1, fraction * 2)
        let content = mix(contentColor, theme.onSurface, solid)
        let lerp = CollapseMetrics.lerp
        let boxHeight = lerp(88, 56, fraction)
        let area = height - safeTop
        ZStack(alignment: .topLeading) {
            theme.surfaceContainer.opacity(solid)
            LinearGradient(colors: [startColor.opacity(0.8 * (1 - solid)), startColor.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
            Text(title)
                .font(.system(size: lerp(28 * 1.2, 28 * 0.8, fraction), weight: .bold))
                .foregroundStyle(content)
                .lineLimit(1)
                .frame(height: boxHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, lerp(20, 68, fraction))
                .padding(.trailing, 24)
                .offset(y: safeTop + lerp(area - boxHeight, 0, fraction))
                .accessibilityAddTraits(.isHeader)
            Button(action: onBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(content)
                    .frame(width: 40, height: 40)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .pixlGlass(in: Circle(), tint: content.opacity(0.1), interactive: true)
            .padding(.leading, 12)
            .padding(.top, safeTop + 4)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("detail.back")
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private func mix(_ a: Color, _ b: Color, _ t: CGFloat) -> Color {
        t <= 0 ? a : (t >= 1 ? b : a.mix(with: b, by: Double(t)))
    }
}

// MARK: - Genre colours (Android `GenreThemeUtils`, `ui/theme/GenreColors.kt`)

nonisolated enum GenreTheme {
    struct Pair: Sendable, Hashable {
        let container: UInt32
        let onContainer: UInt32
    }

    static let unknownSeed: UInt32 = 0xFF7C7D84
    static let unknownLight = Pair(container: 0xFFE5E5EA, onContainer: 0xFF1B1B20)
    static let unknownDark = Pair(container: 0xFF3A3B42, onContainer: 0xFFF2F1F6)

    static let dark: [Pair] = [
        Pair(container: 0xFF004A77, onContainer: 0xFFC2E7FF), Pair(container: 0xFF7D5260, onContainer: 0xFFFFD8E4),
        Pair(container: 0xFF633B48, onContainer: 0xFFFFD8EC), Pair(container: 0xFF004F58, onContainer: 0xFF88FAFF),
        Pair(container: 0xFF324F34, onContainer: 0xFFCBEFD0), Pair(container: 0xFF6E4E13, onContainer: 0xFFFFDEAC),
        Pair(container: 0xFF3F474D, onContainer: 0xFFDEE3EB), Pair(container: 0xFF4A4458, onContainer: 0xFFE8DEF8),
        Pair(container: 0xFF7D2B2B, onContainer: 0xFFFFB4AB), Pair(container: 0xFF5B6300, onContainer: 0xFFDDF669),
        Pair(container: 0xFF005047, onContainer: 0xFF8CF4E6), Pair(container: 0xFF4F378B, onContainer: 0xFFEADDFF),
        Pair(container: 0xFF8B4A62, onContainer: 0xFFFFD9E2), Pair(container: 0xFF725C00, onContainer: 0xFFFFE084),
        Pair(container: 0xFF00213B, onContainer: 0xFF99CBFF), Pair(container: 0xFF23507D, onContainer: 0xFFD1E4FF),
        Pair(container: 0xFF93000A, onContainer: 0xFFFFDAD6), Pair(container: 0xFF45464F, onContainer: 0xFFC4C6D0),
        Pair(container: 0xFF5D3F75, onContainer: 0xFFE8B6FF), Pair(container: 0xFF7A5900, onContainer: 0xFFFFDEA5),
    ]

    static let light: [Pair] = [
        Pair(container: 0xFFD7E3FF, onContainer: 0xFF005AC1), Pair(container: 0xFFFFD8E4, onContainer: 0xFF631835),
        Pair(container: 0xFFFFD8EC, onContainer: 0xFF631B4B), Pair(container: 0xFFCCE8EA, onContainer: 0xFF004F58),
        Pair(container: 0xFFCBEFD0, onContainer: 0xFF042106), Pair(container: 0xFFFFDEAC, onContainer: 0xFF281900),
        Pair(container: 0xFFEFF1F7, onContainer: 0xFF44474F), Pair(container: 0xFFE8DEF8, onContainer: 0xFF1D192B),
        Pair(container: 0xFFFFB4AB, onContainer: 0xFF690005), Pair(container: 0xFFDDF669, onContainer: 0xFF2F3300),
        Pair(container: 0xFF8CF4E6, onContainer: 0xFF00201C), Pair(container: 0xFFEADDFF, onContainer: 0xFF21005D),
        Pair(container: 0xFFFFD9E2, onContainer: 0xFF3B071D), Pair(container: 0xFFFFE084, onContainer: 0xFF231B00),
        Pair(container: 0xFF99CBFF, onContainer: 0xFF003258), Pair(container: 0xFFD1E4FF, onContainer: 0xFF051C36),
        Pair(container: 0xFFFFDAD6, onContainer: 0xFF410002), Pair(container: 0xFFE2E2E9, onContainer: 0xFF191C20),
        Pair(container: 0xFFF2DAFF, onContainer: 0xFF2C004F), Pair(container: 0xFFFFDEA5, onContainer: 0xFF261900),
    ]

    static func isUnknown(_ genreId: String) -> Bool {
        let normalized = genreId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "unknown" || normalized == "unknown genre" || normalized == "unknown_genre"
    }

    /// `getGenreThemeColor(genreId, isDark)`: `abs(hashCode) % 20` into the table.
    static func color(genreId: String, isDark: Bool) -> Pair {
        if isUnknown(genreId) { return isDark ? unknownDark : unknownLight }
        let hash = Int(KotlinText.hashCode(genreId))
        let index = abs(hash) % dark.count
        return isDark ? dark[index] : light[index]
    }

    /// `scheme(genreId:isDark:style:)` memoised: building a scheme pair (two full dynamic schemes) cost a few
    /// milliseconds on every body pass of the genre page. Same output.
    @MainActor
    static func cachedScheme(genreId: String, isDark: Bool, style: ArtworkPaletteStyle) -> ThemeColors {
        let key = SchemeKey(seed: isUnknown(genreId) ? nil : color(genreId: genreId, isDark: isDark).container,
                            isDark: isDark, style: style)
        if let hit = schemeCache[key] { return hit }
        let scheme = scheme(genreId: genreId, isDark: isDark, style: style)
        schemeCache[key] = scheme
        return scheme
    }

    private struct SchemeKey: Hashable {
        let seed: UInt32?
        let isDark: Bool
        let style: ArtworkPaletteStyle
    }

    @MainActor private static var schemeCache: [SchemeKey: ThemeColors] = [:]

    /// `getGenreDetailColorScheme`: a scheme from the genre colour (monochrome for unknown).
    static func scheme(genreId: String, isDark: Bool, style: ArtworkPaletteStyle) -> ThemeColors {
        let pair = isUnknown(genreId)
            ? ArtworkTheme.monochromePair(seed: unknownSeed)
            : ArtworkTheme.schemePair(seed: color(genreId: genreId, isDark: isDark).container, style: style)
        return ThemeColors(roles: pair.roles(dark: isDark), isDark: isDark)
    }
}
