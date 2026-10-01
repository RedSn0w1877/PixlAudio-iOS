import PixlModel
import SwiftUI

/// Library — placeholder until stage 7a ports PixlAudio's Library (`LibraryScreen.kt`). Trivially simple but in
/// PixlAudio's layout: the "Library" header with its settings circle, the category tabs as glass capsules with
/// the gliding selection, the action row (Shuffle + view/filter/sort circles), and the songs as glass cards.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var tab: LibraryTab = .songs

    var body: some View {
        VStack(spacing: 0) {
            LargeHeader("Library") {
                GlassCircleButton(systemImage: "gearshape", accessibilityLabel: "Open settings",
                                  tint: theme.primaryContainer.opacity(GlassTint.container),
                                  foreground: theme.onPrimaryContainer) {
                    router.push(.settings)
                }
                .accessibilityIdentifier("library.settings")
            }
            GlassPillRow(items: LibraryTab.defaultOrder.map { GlassPillRow<LibraryTab>.Item(id: $0, title: $0.tabTitle) },
                         selection: $tab, accessibilityIdentifierPrefix: "library.tab")
                .padding(.top, Tokens.Spacing.s)
                .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: Tokens.SongCard.listSpacing) {
                    actionRow
                        .padding(.bottom, Tokens.Spacing.xs)
                    LazyVStack(spacing: Tokens.SongCard.listSpacing) {
                        ForEach(library.songs) { song in
                            SongCard(song: song, isCurrent: playback.current?.id == song.id,
                                     isPlaying: playback.isPlaying,
                                     onTap: { playback.play(song, in: library.songs) },
                                     onMore: { router.present(AppSheet.songInfo(songId: song.id)) })
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, Tokens.Spacing.xxl)
            }
            .scrollIndicators(.hidden)
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("screen.library")
    }

    private var actionRow: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: Tokens.Spacing.s) {
                GlassPillButton(title: "Shuffle", systemImage: "shuffle",
                                tint: theme.secondaryContainer.opacity(GlassTint.container),
                                foreground: theme.onSecondaryContainer, style: .labelLarge.weight(.bold),
                                horizontalPadding: 18, verticalPadding: 13) {
                    playback.play(library.songs.shuffled())
                }
                Spacer()
                GlassCircleButton(systemImage: "square.grid.2x2", accessibilityLabel: "Change view", size: 44) {}
                GlassCircleButton(systemImage: "line.3.horizontal.decrease", accessibilityLabel: "Filter", size: 44) {}
                GlassCircleButton(systemImage: "arrow.up.arrow.down", accessibilityLabel: "Sort", size: 44) {}
            }
        }
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

/// Folder browser (Android `FolderExplorerScreen`) — stage 7a.
struct FolderExplorerView: View {
    let path: String?

    var body: some View {
        PlaceholderScreen(title: "Folders", systemImage: "folder", owner: "Stage 7a — Library & details",
                          screenID: "folderExplorer")
    }
}
