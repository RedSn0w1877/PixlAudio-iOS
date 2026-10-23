// When the Sing button swaps the song for its instrumental: not at once, but at the next quiet moment between sung
// words (at most 600 ms away), so the crossfade hides in a gap instead of cutting through a word. Pure; the engine asks
// for a placement once the other audio is loaded and only then knows how early it can start.

import Foundation

public enum SingSwitchPlanner {
    /// The crossfade is never shorter than this, nor longer than `maxFadeMs` (the fade of a switch with no gap to use).
    public static let minFadeMs: Int64 = 300
    public static let maxFadeMs: Int64 = 700
    /// A gap must leave at least this much quiet after the start to be worth fading in.
    public static let minGapMs: Int64 = 300
    /// How long the switch may wait for a gap (playback time, so a slowed song reaches further into the lyrics).
    public static let maxWaitMs: Int64 = 600

    /// Why a placement starts where it does.
    public enum Reason: Sendable, Equatable {
        /// The earliest start is already quiet.
        case insideGap
        /// A gap begins within the wait; the switch starts there.
        case nextGap
        /// The lyrics have no word timing (or none were loaded): start as soon as possible.
        case noWordTiming
        /// No gap long enough within the wait: start as soon as possible.
        case noGapInWindow
    }

    /// Where the swap starts and how long it fades, in the player's own milliseconds.
    public struct Placement: Sendable, Equatable {
        public let startPlayerMs: Int64
        public let fadeMs: Int64
        public let reason: Reason

        public init(startPlayerMs: Int64, fadeMs: Int64, reason: Reason) {
            self.startPlayerMs = startPlayerMs
            self.fadeMs = fadeMs
            self.reason = reason
        }
    }

    /// - Parameters:
    ///   - index: the song's gaps; nil when the lyrics aren't loaded.
    ///   - earliestPlayerMs: the first player position the other audio can start at.
    ///   - offsetMs: the lyrics' sync offset; lyrics time is player time plus this.
    ///   - rate: the playback speed.
    public static func plan(index: SingGapIndex?, earliestPlayerMs: Int64, offsetMs: Int64, rate: Double) -> Placement {
        guard let index, index.hasWordTiming else {
            return Placement(startPlayerMs: earliestPlayerMs, fadeMs: maxFadeMs, reason: .noWordTiming)
        }
        let earliest = earliestPlayerMs + offsetMs
        let window = Int64((Double(maxWaitMs) * Swift.max(rate, 0.1)).rounded())
        for gap in index.gaps(from: earliest, to: earliest + window) {
            let start = Swift.max(gap.start, earliest)
            let room = gap.end - start
            guard room >= minGapMs else { continue }
            return Placement(startPlayerMs: start - offsetMs, fadeMs: Swift.min(Swift.max(room, minFadeMs), maxFadeMs),
                             reason: gap.start <= earliest ? .insideGap : .nextGap)
        }
        return Placement(startPlayerMs: earliestPlayerMs, fadeMs: maxFadeMs, reason: .noGapInWindow)
    }
}
