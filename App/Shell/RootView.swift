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
    /// Tabs whose stack exists. The selected tab is always built; the other two are built after launch has settled
    /// (`prebuildHiddenTabs`) or on first selection, and a built tab keeps its stack and scroll position for life.
    @State private var builtTabs: Set<RootTab> = []

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
            // Under the settled, opaque full player nothing of the shell can be seen: it isn't drawn then.
            .modifier(ShellCoveredByPlayer())
            // Stage 8: the player sheet — the mini player resting in `MiniPlayerSlot` and expanding over everything.
            PlayerSheetHost()
        }
        // Spotify Connect's messages (skipped songs, takeovers, errors) over whatever is on screen, above the bars.
        .libraryToast(environment.spotifyConnect.toast, bottomPadding: Tokens.Shell.miniPlayerHeight + 96)
        // The Connect device's volume pop-up (the volume buttons), over the tabs and the full player; sheets and covers
        // show their own copy.
        .spotifyConnectVolumeHUD(followsPresentations: true)
        .updateBanner(environment.updates)
        .environment(\.appTheme, colors.app)
        .environment(\.playerTheme, colors.player)
        .tint(colors.app.primary)
        .animation(.easeInOut(duration: 0.45), value: themeStore.albumPair)
        // Presentations don't inherit the shell's `.tint` (it sits inside these modifiers), so each one gets the accent
        // again; without it default-tinted controls in sheets and covers fell back to the static AccentColor asset.
        .sheet(item: $router.sheet) { sheet in
            SheetDestination(sheet: sheet)
                .environment(\.appTheme, colors.app)
                .environment(\.playerTheme, colors.player)
                .tint(colors.app.primary)
        }
        // `.nowPlaying` is not a cover: the player sheet takes it and expands in place.
        .fullScreenCover(item: Binding(get: { router.cover == .nowPlaying ? nil : router.cover },
                                       set: { router.cover = $0 })) { cover in
            CoverDestination(cover: cover)
                .environment(\.appTheme, colors.app)
                .environment(\.playerTheme, colors.player)
                .tint(colors.app.primary)
        }
        .task(id: playback.current?.id) {
            await themeStore.update(for: playback.current)
        }
        .onChange(of: router.selection, initial: true) { _, tab in
            if !builtTabs.contains(tab) { builtTabs.insert(tab) }
        }
        .task { await prebuildHiddenTabs() }
        // Settings › Appearance › Accent Color: UIKit-presented controls (alerts, dialogs, menus) follow the window's
        // tint. The accent snaps (no animation: the root `.animation` is keyed to the album colours only).
        .onChange(of: themeStore.accentPair, initial: true) { _, pair in
            WindowTint.apply(pair)
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
        // A tab nobody has looked at yet is not built: its stack, lists and tasks used to run at launch under the
        // visible tab (all three tabs were built behind each other at opacity 0).
        return Group {
            if isSelected || builtTabs.contains(tab) {
                NavigationStack(path: path) {
                    root()
                        .bottomBarsClearance(.tabRoot)
                        .withAppRoutes()
                }
                // Room for the floating bars, per page (`BottomBarsClearance`): equal values don't propagate, so only
                // the mini player appearing, compact mode or the keyboard on this tab change a page's inset.
                .environment(\.bottomBarsClearance, clearance(isSelected: isSelected))
                // A song change animates the album colours over 0.45 s (the root `.animation` below): only on the tab
                // that is on screen. A hidden tab is at opacity 0, so snapping its colours shows nothing and costs no
                // frames.
                .transaction(value: themeStore.albumPair) { transaction in
                    if !isSelected { transaction.animation = nil }
                }
                // The cross-fade runs on its own curve — the visible part of the selection spring, ending at 0.21 s —
                // instead of the spring's 0.6 s tail, during which both full-screen, glass-heavy stacks stayed
                // composited. The tab bar's pill keeps the spring (`withAnimation(PixlMotion.selection)` below).
                .animation(PixlMotion.tabFade) { content in
                    content.opacity(isSelected ? 1 : 0)
                }
                .allowsHitTesting(isSelected)
                // Hidden tabs are out of the accessibility tree, and so is the selected one while the full player
                // covers it (a modal screen for VoiceOver). One `accessibilityHidden` per stack: an
                // `accessibilityHidden(false)` around the three stacks overrode the hidden tabs' `true`, so their
                // invisible rows answered accessibility hit tests over the visible tab's (UI tests found nothing
                // hittable).
                .modifier(TabAccessibilityHidden(isSelected: isSelected))
            }
        }
    }

    /// Builds the tabs that aren't selected once launch has settled, one per turn with a pause between, so a first
    /// switch only animates. Until then the selected tab has the launch to itself.
    private func prebuildHiddenTabs() async {
        let settle: Duration = environment.launch.isUITest ? .milliseconds(400) : .milliseconds(2000)
        try? await Task.sleep(for: settle)
        for tab in HiddenTabPrebuild.order(selected: router.selection, built: builtTabs) {
            guard !Task.isCancelled else { return }
            if !builtTabs.contains(tab) { builtTabs.insert(tab) }
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    /// The bars' height over a tab root and over a pushed page. The keyboard hides both bars, but only the selected
    /// tab changes for it (the hidden tabs keep their layout).
    private func clearance(isSelected: Bool) -> BottomBarsClearance {
        let keyboard = isKeyboardVisible && isSelected
        let miniPlayer: CGFloat = playback.current != nil && !keyboard
            ? Tokens.Shell.miniPlayerHeight + Tokens.Shell.miniPlayerSpacing : 0
        let bar: CGFloat = keyboard ? 0
            : settings.appearance.navBarCompactMode ? Tokens.Shell.navBarCompactHeight : Tokens.Shell.navBarHeight
        return BottomBarsClearance(tabRoot: bar + miniPlayer, pushed: miniPlayer)
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
                            minimized: router.isTabBarMinimized,
                            onSelect: { tab in withAnimation(PixlMotion.selection) { router.select(tab) } })
                    .modifier(HiddenWhilePlayerExpanded())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Tokens.Shell.horizontalInset)
        .animation(PixlMotion.bars, value: showsBar)
        .animation(PixlMotion.bars, value: playback.hasItem)
        // The minimized bar is lower: the mini player follows it down on the bars' curve (the capsule itself
        // animates in UIKit, `LiquidLensBarView.setShape`).
        .animation(PixlMotion.bars, value: router.isTabBarMinimized)
        // A tab switch, a push or a pop restores the full bar.
        .onChange(of: router.selection) { router.setTabBarMinimized(false) }
        .onChange(of: router.currentPath.count) { router.setTabBarMinimized(false) }
    }
}

/// A tab's stack leaves the accessibility tree when it isn't the selected tab, or while the full player covers it.
/// Its own small view, so the expand / collapse flips re-run this modifier and not the shell's body.
private struct TabAccessibilityHidden: ViewModifier {
    let isSelected: Bool
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        content.accessibilityHidden(!isSelected || environment.playerSheet.isExpanded)
    }
}

/// The shell (tabs and bars) is not drawn while the settled full player covers the whole screen with its opaque card
/// (`PlayerSheetController.coversShell`): the compositor stops drawing about 15–25 Liquid Glass surfaces under every
/// frame of the player (carousel swipes, scrubbing, ambient styles). Nothing is removed, so state, scroll positions
/// and the tab bar survive; the shell is back, without animation, in the update that starts any movement of the card.
/// Its own small view: the flag flips here and not in the shell's body.
private struct ShellCoveredByPlayer: ViewModifier {
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        let covered = environment.playerSheet.coversShell
        content
            .opacity(covered ? 0 : 1)
            .animation(nil, value: covered)
    }
}

/// Hides the tab bar from VoiceOver while the full player covers it (the mini player's own layer hides itself). The
/// bar's tabs are UIKit segments, which `accessibilityHidden` doesn't reach, so `GlassNavBar` also hides them itself
/// (`tabBarAccessibilityHidden`): left in the tree, they answered accessibility hit tests under the player's toggle
/// row (CI, 2026-10-07: UI tests tapped the heart at its corner, outside the round "on" segment).
private struct HiddenWhilePlayerExpanded: ViewModifier {
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        let isExpanded = environment.playerSheet.isExpanded
        content
            .environment(\.tabBarAccessibilityHidden, isExpanded)
            .accessibilityHidden(isExpanded)
    }
}

/// Which tabs to build after launch, in which order: the likelier next tab (Library) before Search.
nonisolated enum HiddenTabPrebuild {
    static func order(selected: RootTab, built: Set<RootTab>) -> [RootTab] {
        [RootTab.home, .library, .search].filter { $0 != selected && !built.contains($0) }
    }
}
