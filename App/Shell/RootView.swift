import Combine
import PixlModel
import SwiftUI
import UIKit

/// The shell, in PixlAudio's layout (Android MainActivity `MainUI`): the selected tab's content full screen, and at
/// the bottom — inset 16 pt from the sides, above the home indicator — the mini player floating 8 pt above the
/// iOS-style glass tab bar (`GlassNavBar`), each its own capsule. The bar shows only at a tab's root (pushed screens
/// hide it, as on Android); the mini player stays.
/// Each tab keeps its own `NavigationStack` alive so switching tabs keeps scroll positions.
/// While the keyboard is up the bars step aside: on Android they stay at the bottom under the keyboard (edge to edge,
/// only the content gets the IME inset), so they must not ride up above it here (stage 7c, Search's field).
///
/// Transition performance (docs/performance.md): the bars are an overlay that takes no layout space, so a push, a
/// pop or the mini player's first appearance doesn't touch the three stacks' layout; the selected tab fades in on its
/// own short curve; hidden tabs don't animate album-colour changes.
struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(PlaybackStore.self) private var playback
    @Environment(ThemeStore.self) private var themeStore
    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @State private var isKeyboardVisible = false

    var body: some View {
        @Bindable var router = router
        let colors = themeStore.colors(for: colorScheme)
        ZStack {
            ZStack {
                colors.app.background.ignoresSafeArea()
                tab(.home, path: $router.homePath) { HomeView() }
                tab(.search, path: $router.searchPath) { SearchView() }
                tab(.library, path: $router.libraryPath) { LibraryView() }
            }
            // The bars float over the tabs and take no layout space. They used to be a `safeAreaBar` around the
            // three stacks, whose inset never reached the pages (each `NavigationStack` laid its pages out without it:
            // content scrolls under the bars, and pages that need room above the mini player reserve it themselves)
            // but whose every change — a push or pop showing or hiding the tab bar, the mini player appearing —
            // re-ran the safe-area layout of all three stacks. An overlay places the bars exactly where the bar did.
            .overlay(alignment: .bottom) {
                bottomBars
            }
            // Stage 8: the player sheet — the mini player resting in `MiniPlayerSlot` and expanding over everything.
            PlayerSheetHost()
        }
        .updateBanner(environment.updates)
        .environment(\.appTheme, colors.app)
        .environment(\.playerTheme, colors.player)
        .tint(colors.app.primary)
        .animation(.easeInOut(duration: 0.45), value: themeStore.albumPair)
        .sheet(item: $router.sheet) { sheet in
            SheetDestination(sheet: sheet)
                .environment(\.appTheme, colors.app)
                .environment(\.playerTheme, colors.player)
        }
        // `.nowPlaying` is not a cover: the player sheet takes it and expands in place.
        .fullScreenCover(item: Binding(get: { router.cover == .nowPlaying ? nil : router.cover },
                                       set: { router.cover = $0 })) { cover in
            CoverDestination(cover: cover)
                .environment(\.appTheme, colors.app)
                .environment(\.playerTheme, colors.player)
        }
        .task(id: playback.current?.id) {
            await themeStore.update(for: playback.current)
        }
        // The mini player steps aside with the tab bar, in the same transaction: the sheet keeps its slot and slides
        // the card down instead of dropping it and rebuilding it when the keyboard goes.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(PixlMotion.bars) {
                isKeyboardVisible = true
                environment.playerSheet.hiddenForKeyboard = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(PixlMotion.bars) {
                isKeyboardVisible = false
                environment.playerSheet.hiddenForKeyboard = false
            }
        }
    }

    private func tab<Content: View>(_ tab: RootTab, path: Binding<[AppRoute]>,
                                    @ViewBuilder root: () -> Content) -> some View {
        let isSelected = router.selection == tab
        return NavigationStack(path: path) {
            root().withAppRoutes()
        }
        // A song change animates the album colours over 0.45 s (the root `.animation` below): only on the tab that
        // is on screen. A hidden tab is at opacity 0, so snapping its colours shows nothing and costs no frames.
        .transaction(value: themeStore.albumPair) { transaction in
            if !isSelected { transaction.animation = nil }
        }
        // The cross-fade runs on its own curve — the visible part of the selection spring, ending at 0.21 s —
        // instead of the spring's 0.6 s tail, during which both full-screen, glass-heavy stacks stayed composited.
        // The tab bar's pill keeps the spring (`withAnimation(PixlMotion.selection)` below).
        .animation(PixlMotion.tabFade) { content in
            content.opacity(isSelected ? 1 : 0)
        }
        .allowsHitTesting(isSelected)
        .accessibilityHidden(!isSelected)
    }

    @ViewBuilder
    private var bottomBars: some View {
        let showsBar = router.isNavigationBarVisible && !isKeyboardVisible
        VStack(spacing: Tokens.Shell.miniPlayerSpacing) {
            if playback.current != nil, !isKeyboardVisible {
                // Stage 8: the player sheet draws the mini player here (and expands it from here).
                MiniPlayerSlot(bottomCornerRadius: Tokens.Shell.navBarCornerRadius)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showsBar {
                GlassNavBar(selection: router.selection,
                            compact: settings.appearance.navBarCompactMode,
                            onSelect: { tab in withAnimation(PixlMotion.selection) { router.select(tab) } })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Tokens.Shell.horizontalInset)
        .animation(PixlMotion.bars, value: showsBar)
        .animation(PixlMotion.bars, value: playback.hasItem)
    }
}
