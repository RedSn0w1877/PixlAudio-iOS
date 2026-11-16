// The split-pill navigation bar's pure decisions (`App/DesignSystem/Components/GlassNavBar.swift`): one big glass
// capsule and one small glass circle side by side at the bottom of the screen.
//
// - On Home and Library the big capsule holds the Home and Library segments and the circle is Search. The emphasized
//   segment (the selected one, or the one under a finger that is down on the capsule) takes a larger share of the
//   capsule (`emphasisWeight`, the approved mockup's flex 1.3 : 1), and the tonal selection capsule sits on it.
// - On Search the two shapes swap roles: the left shape shrinks into the Home circle and the right one grows into the
//   search field (`SplitPillNav.Mode`).
//
// The arithmetic lives here so it can be tested: segment spans, the segment under a finger (the emphasized segment is
// wider, which gives a drag natural hysteresis at a boundary), the minimized capsule's width, and when the bar shows
// over the keyboard.

import Foundation

public enum SplitPillNav {
    /// What the two shapes show.
    public enum Mode: Sendable, Equatable {
        /// Big capsule = the tab segments, small circle = Search.
        case tabs
        /// Small circle = Home, big capsule = the search field.
        case search
    }

    /// One segment's horizontal span inside the big capsule's content box, in points.
    public struct Span: Sendable, Equatable {
        public var x: Double
        public var width: Double

        public init(x: Double, width: Double) {
            self.x = x
            self.width = width
        }

        public var maxX: Double { x + width }
        public var midX: Double { x + width / 2 }
    }

    /// The emphasized segment's share against 1 for the others (mockup: `flex: 1.3` vs `flex: 1`).
    public static let emphasisWeight: Double = 1.3

    /// Flex weights for `count` segments, `emphasized` taking `emphasis` (out-of-range or `nil`: all equal).
    public static func weights(count: Int, emphasized: Int?, emphasis: Double = emphasisWeight) -> [Double] {
        guard count > 0 else { return [] }
        return (0 ..< count).map { $0 == emphasized ? max(emphasis, 0) : 1 }
    }

    /// Splits `width` between the segments by weight, `spacing` points apart, left to right from 0. Widths never go
    /// negative; a zero or negative total weight splits evenly.
    public static func spans(width: Double, weights: [Double], spacing: Double) -> [Span] {
        guard !weights.isEmpty else { return [] }
        let gaps = spacing * Double(weights.count - 1)
        let available = max(0, width - gaps)
        let total = weights.reduce(0) { $0 + max($1, 0) }
        var x = 0.0
        return weights.map { weight in
            let share = total > 0 ? max(weight, 0) / total : 1 / Double(weights.count)
            let span = Span(x: x, width: available * share)
            x += span.width + spacing
            return span
        }
    }

    /// The segment under `x`: the one containing it, the nearer one in a gap, and the first / last past the ends.
    public static func index(at x: Double, in spans: [Span]) -> Int? {
        guard let first = spans.first, let last = spans.last else { return nil }
        if x <= first.maxX { return 0 }
        if x >= last.x { return spans.count - 1 }
        for (i, span) in spans.enumerated() {
            if x < span.x {
                // In the gap before segment i: the nearer edge wins.
                let previous = spans[i - 1]
                return x - previous.maxX <= span.x - x ? i - 1 : i
            }
            if x <= span.maxX { return i }
        }
        return spans.count - 1
    }

    /// The segment under `x` while segment `emphasized` is drawn wider: what a finger moving along the capsule
    /// points at. Because the segment under the finger is the wide one, crossing back needs the finger to travel
    /// past the old boundary, so the selection doesn't flicker at an edge.
    public static func index(at x: Double, width: Double, count: Int, emphasized: Int?, spacing: Double,
                             emphasis: Double = emphasisWeight) -> Int? {
        index(at: x, in: spans(width: width, weights: weights(count: count, emphasized: emphasized, emphasis: emphasis),
                               spacing: spacing))
    }

    /// The minimized capsule's outer width: `count` segments of `segmentWidth`, `spacing` apart, inside `padding`.
    public static func minimizedWidth(count: Int, segmentWidth: Double, spacing: Double, padding: Double) -> Double {
        guard count > 0 else { return 2 * padding }
        return Double(count) * segmentWidth + spacing * Double(count - 1) + 2 * padding
    }

    /// Whether the bar shows. It shows only at a tab's root; while the keyboard is up it steps aside (Android keeps
    /// its bar under the keyboard), except on the Search tab, where the bar is the search field and rides on top of
    /// the keyboard. Keyed to the tab rather than the field's focus: focus drops a moment before the keyboard's hide
    /// notification on submit, and a focus rule would pull the bar out and put it back in that moment.
    public static func showsBar(atTabRoot: Bool, keyboardVisible: Bool, onSearchTab: Bool) -> Bool {
        guard atTabRoot else { return false }
        return !keyboardVisible || onSearchTab
    }

    /// Whether the bar rides on the keyboard (and the page under it keeps room for it).
    public static func ridesKeyboard(atTabRoot: Bool, keyboardVisible: Bool, onSearchTab: Bool) -> Bool {
        atTabRoot && keyboardVisible && onSearchTab
    }
}
