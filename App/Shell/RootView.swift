import PixlModel
import SwiftUI

/// The shell, in PixlAudio's layout (Android MainActivity `MainUI`): the selected tab's content full screen, and at
/// the bottom — inset 16 pt from the sides, above the home indicator — the mini player floating 8 pt above the
/// bottom bar. The bar shows only at a tab's root (pushed screens hide it, as on Android); the mini player stays.
/// Each tab keeps its own `NavigationStack` alive so switching tabs keeps scroll positions.
struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(PlaybackStore.self) private var playback
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var router = router
        let colors = themeStore.colors(for: colorScheme)
        ZStack {
            colors.app.background.ignoresSafeArea()
            tab(.home, path: $router.homePath) { HomeView() }
            tab(.search, path: $router.searchPath) { SearchView() }
            tab(.library, path: $router.libraryPath) { LibraryView() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBars
        }
        .environment(\.appTheme, colors.app)
        .environment(\.playerTheme, colors.player)
        .tint(colors.app.primary)
        .animation(.easeInOut(duration: 0.45), value: themeStore.albumPair)
        .sheet(item: $router.sheet) { sheet in
            SheetDestination(sheet: sheet)
                .environment(\.appTheme, colors.app)
                .environment(\.playerTheme, colors.player)
        }
        .fullScreenCover(item: $router.cover) { cover in
            CoverDestination(cover: cover)
                .environment(\.appTheme, colors.app)
                .environment(\.playerTheme, colors.player)
        }
        .task(id: playback.current?.id) {
            await themeStore.update(for: playback.current)
        }
    }

    private func tab<Content: View>(_ tab: RootTab, path: Binding<[AppRoute]>,
                                    @ViewBuilder root: () -> Content) -> some View {
        let isSelected = router.selection == tab
        return NavigationStack(path: path) {
            root().withAppRoutes()
        }
        .opacity(isSelected ? 1 : 0)
        .allowsHitTesting(isSelected)
        .accessibilityHidden(!isSelected)
    }

    @ViewBuilder
    private var bottomBars: some View {
        let showsBar = router.isNavigationBarVisible
        VStack(spacing: Tokens.Shell.miniPlayerSpacing) {
            if let song = playback.current {
                MiniPlayerBar(song: song, isPlaying: playback.isPlaying, isPreparing: playback.isPreparing,
                              bottomCornerRadius: showsBar ? Tokens.Shell.joinCornerRadius : Tokens.Shell.navBarCornerRadius,
                              onOpen: { router.present(AppCover.nowPlaying) },
                              onPrevious: { playback.skipToPrevious() },
                              onPlayPause: { playback.togglePlayPause() },
                              onNext: { playback.skipToNext() })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showsBar {
                GlassNavBar(selection: router.selection,
                            topCornerRadius: playback.hasItem ? Tokens.Shell.joinCornerRadius : Tokens.Shell.navBarCornerRadius,
                            onSelect: { tab in withAnimation(PixlMotion.selection) { router.select(tab) } })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Tokens.Shell.horizontalInset)
        .animation(PixlMotion.bars, value: showsBar)
        .animation(PixlMotion.bars, value: playback.hasItem)
    }
}
