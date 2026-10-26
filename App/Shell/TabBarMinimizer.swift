import PixlFoundation
import SwiftUI

/// Minimizes the tab bar while a tab root scrolls down, and restores it on the way back up (Hoa, 2026-10-03: "an auto
/// compact version that removes the labels and shrinks the distance between the icons and makes it smaller and … a
/// bit shorter as well when the user scrolls"), like the system's `tabBarMinimizeBehavior(.onScrollDown)`.
///
/// Apply `minimizesTabBarOnScroll()` to the vertical `ScrollView` of each tab root's page. The state lives on the
/// `Router` (`isTabBarMinimized`). It survives a tab switch, a push and a pop (Hoa, 2026-10-26: "make the minimized
/// navbar stay minimized until scrolled up even if the user clicks to go to a new menu"): only upward scrolling (or
/// re-tapping the selected tab, `Router.select`) restores it.
///
/// The rules live in `TabBarMinimizePolicy` (PixlCore, tested), fed the scroll view's offset clamped to its content
/// (so the bounce at either end can't flip the bar). The action does arithmetic on one value per scroll frame and
/// writes the router only when the state flips.
struct MinimizesTabBarOnScroll: ViewModifier {
    @Environment(Router.self) private var router
    /// The direction history (`TabBarMinimizePolicy`). A reference, so writing it every scroll frame never
    /// invalidates a view (nothing reads it in `body`).
    @State private var tracker = Tracker()

    private final class Tracker {
        var policy = TabBarMinimizePolicy()
    }

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { geometry in
            let offset = geometry.contentOffset.y + geometry.contentInsets.top
            let maxOffset = max(0, geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                - geometry.containerSize.height)
            return min(max(offset, 0), maxOffset)
        } action: { _, offset in
            update(offset: offset)
        }
    }

    private func update(offset: CGFloat) {
        if let minimized = tracker.policy.update(offset: Double(offset), minimized: router.isTabBarMinimized) {
            router.setTabBarMinimized(minimized)
        }
    }
}

extension View {
    /// See `MinimizesTabBarOnScroll`. Apply to a tab root page's vertical scroll view.
    func minimizesTabBarOnScroll() -> some View {
        modifier(MinimizesTabBarOnScroll())
    }
}
