// Gestures (iOS-first, owner request 2026-10-18): the rules that keep a horizontal swipe from fighting a scroll or the
// player sheet's vertical drag. A drag decides its direction once, at the first movement past a small slop, and keeps
// that decision for the whole drag: only a clearly horizontal drag becomes a swipe, everything else is left to the
// scroll view / sheet.

import Foundation

public enum PanIntent: Sendable, Equatable {
    case undecided
    case horizontal
    case vertical
}

public enum SwipeDirection: Sendable, Equatable {
    case left
    case right
}

public enum GesturePolicy {
    /// Movement under this many points decides nothing (a tap's jitter).
    public static let slop: Double = 10
    /// A drag is horizontal when its horizontal movement is at least this many times its vertical movement.
    public static let horizontalDominance: Double = 1.7
    /// A swipe commits when released past this distance...
    public static let commitDistance: Double = 56
    /// ...or faster than this (points per second) past the shorter distance.
    public static let commitVelocity: Double = 420
    public static let commitDistanceWhenFast: Double = 24

    /// The intent of a drag that has moved by (`dx`, `dy`).
    public static func intent(dx: Double, dy: Double) -> PanIntent {
        let ax = abs(dx), ay = abs(dy)
        guard max(ax, ay) >= slop else { return .undecided }
        return ax >= ay * horizontalDominance ? .horizontal : .vertical
    }

    /// What a released horizontal drag does: the direction the finger moved, nil when it did not go far or fast
    /// enough. `velocityX` in points per second.
    public static func swipe(dx: Double, velocityX: Double) -> SwipeDirection? {
        let distance = abs(dx)
        let fast = abs(velocityX) >= commitVelocity && distance >= commitDistanceWhenFast
            && (velocityX < 0) == (dx < 0)
        guard distance >= commitDistance || fast else { return nil }
        return dx < 0 ? .left : .right
    }

    /// How far a row follows the finger for a drag of `dx`: linear to `limit`, then a stiff rubber band, so a row
    /// never leaves the screen.
    public static func rubberBand(_ dx: Double, limit: Double) -> Double {
        let magnitude = abs(dx)
        guard magnitude > limit else { return dx }
        let over = magnitude - limit
        let banded = limit + limit * 0.25 * (1 - exp(-over / limit))
        return dx < 0 ? -banded : banded
    }
}
