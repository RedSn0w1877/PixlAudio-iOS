// The scroll rules of the minimizing tab bar, as pure arithmetic so they can be tested (the app feeds it one clamped
// scroll offset per frame and writes the router only when the answer flips).

import Foundation

/// Decides when a tab root's scroll minimizes or restores the tab bar.
///
/// Offsets are clamped to the content by the caller, so the bounce at either end can't flip the bar. The bar stays
/// minimized until the user scrolls up: opening another tab, popping back from a pushed screen or a page loading at the
/// top never restores it by itself. Only upward travel does.
///
/// - Going down: after `threshold` points of travel from the furthest point reached upward, the bar minimizes (never
///   inside the top `topZone`, where it is full for a page at rest).
/// - Going up while minimized: it restores after `threshold` points back up from the deepest point, or, inside the top
///   zone, after `topZoneRestore` points up (so reaching the top by scrolling up always restores, but the first
///   downward drag on a page that opened at the top does not, and a small wobble doesn't).
public struct TabBarMinimizePolicy: Sendable, Equatable {
    public static let topZone: Double = 24
    public static let threshold: Double = 36
    public static let topZoneRestore: Double = 6

    /// The furthest offset reached in the current direction.
    public private(set) var anchor: Double

    public init(anchor: Double = 0) {
        self.anchor = anchor
    }

    /// Feeds one scroll offset. Returns the new minimized state when it should change, `nil` to leave it.
    public mutating func update(offset: Double, minimized: Bool) -> Bool? {
        if minimized {
            if offset >= anchor {
                // Going down (or still): keeps it minimized; the anchor follows the deepest point.
                anchor = offset
                return nil
            }
            let travelledUp = anchor - offset
            let needed = offset <= Self.topZone ? Self.topZoneRestore : Self.threshold
            if travelledUp > needed {
                anchor = offset
                return false
            }
            return nil
        }
        if offset <= Self.topZone {
            anchor = offset
            return nil
        }
        if offset < anchor {
            anchor = offset
            return nil
        }
        if offset - anchor > Self.threshold {
            anchor = offset
            return true
        }
        return nil
    }

    /// Forgets the direction history (call when the scroll view's content or identity changes).
    public mutating func reset(to offset: Double = 0) {
        anchor = offset
    }
}
