import SwiftUI

/// Minimizes the tab bar while a tab root scrolls down, and restores it on the way back up (Hoa, 2026-10-03: "an auto
/// compact version that removes the labels and shrinks the distance between the icons and makes it smaller and … a
/// bit shorter as well when the user scrolls"), like the system's `tabBarMinimizeBehavior(.onScrollDown)`.
///
/// Apply `minimizesTabBarOnScroll()` to the vertical `ScrollView` of each tab root's page. The state lives on the
/// `Router` (`isTabBarMinimized`), which clears it on a tab switch, a push or a pop.
///
/// Rules, on the scroll view's offset clamped to its content (so the bounce at either end can't flip the bar):
/// - within `topZone` of the top the bar is always full;
/// - it minimizes after `threshold` points of travel down, and restores after `threshold` points back up, measured
///   from the furthest point reached in the current direction, so small wobbles don't toggle it.
/// The action does arithmetic on one value per scroll frame and writes the router only when the state flips.
struct MinimizesTabBarOnScroll: ViewModifier {
    @Environment(Router.self) private var router
    /// The furthest offset in the current direction. A reference, so writing it every scroll frame never invalidates
    /// a view (nothing reads it in `body`).
    @State private var tracker = Tracker()

    private final class Tracker {
        var anchor: CGFloat = 0
    }

    static let topZone: CGFloat = 24
    static let threshold: CGFloat = 36

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
        let minimized = router.isTabBarMinimized
        if offset <= Self.topZone {
            tracker.anchor = offset
            if minimized { router.setTabBarMinimized(false) }
            return
        }
        if minimized {
            // Going down keeps it minimized; the anchor follows the deepest point.
            if offset > tracker.anchor {
                tracker.anchor = offset
            } else if tracker.anchor - offset > Self.threshold {
                tracker.anchor = offset
                router.setTabBarMinimized(false)
            }
        } else {
            if offset < tracker.anchor {
                tracker.anchor = offset
            } else if offset - tracker.anchor > Self.threshold {
                tracker.anchor = offset
                router.setTabBarMinimized(true)
            }
        }
    }
}

extension View {
    /// See `MinimizesTabBarOnScroll`. Apply to a tab root page's vertical scroll view.
    func minimizesTabBarOnScroll() -> some View {
        modifier(MinimizesTabBarOnScroll())
    }
}
