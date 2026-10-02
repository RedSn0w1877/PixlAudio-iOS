import Observation
import SwiftUI

/// Shell state the pages read: whether the keyboard is up (the bars step aside while it is).
@Observable
final class ShellChrome {
    var isKeyboardVisible = false
}

extension EnvironmentValues {
    /// The tab whose `NavigationStack` a view lives in (nil outside the shell).
    @Entry var shellTab: RootTab? = nil
}

/// The room the shell's floating bars (mini player, tab bar) take at the bottom of a page, reserved by the page
/// itself as a clear bottom bar.
///
/// The bars used to sit in one `safeAreaBar` around the ZStack of all three tab stacks, so every push or pop from a
/// tab root (which hides or shows the tab bar) and the mini player's first appearance changed the bottom inset of all
/// three stacks — the two hidden ones included — and re-laid them out in the transition's first frame. Now the bars
/// are an overlay that takes no layout space, and each page reserves exactly the inset it had before:
///
/// - a tab root: the mini player (64 pt) when a song is loaded, the tab bar when it shows, 8 pt between them;
///   a root that is not on screen keeps its tab bar's room, so pushes, pops and tab switches never re-lay it out;
/// - a pushed page: the mini player only (every route hides the tab bar).
///
/// While the keyboard is up both bars step aside (0 pt) on the selected tab. The spacer is a `safeAreaBar`, so
/// scroll views keep the system's soft edge effect under the bars.
struct ShellBarSpace: ViewModifier {
    /// The tab whose root this is; nil for a pushed page.
    let rootOf: RootTab?

    @Environment(Router.self) private var router
    @Environment(PlaybackStore.self) private var playback
    @Environment(SettingsStore.self) private var settings
    @Environment(ShellChrome.self) private var chrome
    @Environment(\.shellTab) private var shellTab

    func body(content: Content) -> some View {
        content.safeAreaBar(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var height: CGFloat {
        let tab = rootOf ?? shellTab
        let isSelected = tab.map { router.selection == $0 } ?? true
        let keyboard = isSelected && chrome.isKeyboardVisible
        let showsMiniPlayer = playback.hasItem && !keyboard
        let showsBar = rootOf != nil && !keyboard && (!isSelected || router.isNavigationBarVisible)
        var height: CGFloat = 0
        if showsMiniPlayer { height += Tokens.Shell.miniPlayerHeight }
        if showsBar {
            height += settings.appearance.navBarCompactMode ? Tokens.Shell.navBarCompactHeight
                : Tokens.Shell.navBarHeight
        }
        if showsMiniPlayer && showsBar { height += Tokens.Shell.miniPlayerSpacing }
        return height
    }
}
