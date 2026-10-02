import SwiftUI

/// How much of the screen's bottom the shell's floating bars cover, so the pages can scroll their last rows (and
/// pin their bottom controls) above them. The bars are an overlay that takes no layout space (docs/performance.md:
/// no inset wraps the three stacks), so each page adds the room itself, inside its stack, as safe-area padding:
/// content still scrolls under the see-through bars; only the scroll extent grows (Android pads its lists by
/// `bottomBarHeight + MiniPlayerHeight`).
///
/// The values change only when the mini player appears or goes, the keyboard comes and goes on the selected tab, or
/// compact mode is switched — never on a push or pop (a page always has one kind).
nonisolated struct BottomBarsClearance: Sendable, Equatable {
    /// A tab's root: the tab bar, plus the mini player and its 8 pt gap above the bar while a song is loaded.
    var tabRoot: CGFloat = 0
    /// A pushed screen: every route hides the tab bar (`AppRoute.hidesNavigationBar`), so only the mini player.
    var pushed: CGFloat = 0
}

extension EnvironmentValues {
    /// Set by `RootView` on each tab's stack.
    @Entry var bottomBarsClearance = BottomBarsClearance()
}

/// Where a page sits in its stack.
nonisolated enum BottomBarsPlacement: Sendable {
    case tabRoot
    case pushed
}

private struct BottomBarsClearanceModifier: ViewModifier {
    let placement: BottomBarsPlacement
    @Environment(\.bottomBarsClearance) private var clearance

    func body(content: Content) -> some View {
        content.safeAreaPadding(.bottom, placement == .tabRoot ? clearance.tabRoot : clearance.pushed)
    }
}

extension View {
    /// Reserves the room the shell's bottom bars cover (see `BottomBarsClearance`). Applied by the shell to every
    /// tab root and route; pages don't add it themselves.
    func bottomBarsClearance(_ placement: BottomBarsPlacement) -> some View {
        modifier(BottomBarsClearanceModifier(placement: placement))
    }
}
