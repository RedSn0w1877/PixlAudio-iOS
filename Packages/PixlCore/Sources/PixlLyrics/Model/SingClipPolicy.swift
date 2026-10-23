// Sing's preview piece on the player side (Sing step 4): a minute of the song's instrumental, made in the cloud ahead of
// the whole song, played at its own place in the song (clip time = song time − clip start) until the full instrumental
// lands. These are the decisions the player makes about it, pure so they are tested: may the clip start now, what to do
// while it plays (stay, go back to the song before it runs out, go back at once after a seek outside it, or swap to the
// full instrumental), and how the way back fits before the clip's end.

import Foundation

public enum SingClipPolicy {
    /// While the clip plays and the full instrumental is not here, the song comes back once the playhead is this close
    /// to the clip's end (at a gap between sung words, the wish to sing staying on).
    public static let endMarginMs: Int64 = 2_000
    /// A clip is only started with at least this much of it left before that point: a switch in, then straight out
    /// again, would only be heard as two fades.
    public static let minimumRunMs: Int64 = 3_000
    /// A clip that ends this close to the song's own end simply plays to it (nothing comes after to go back to).
    public static let songEndSlackMs: Int64 = 500
    /// A playhead this far outside the clip was moved there (a seek): the song comes back at once.
    public static let seekToleranceMs: Int64 = 300
    /// The clip makes way for the full instrumental with this short linear crossfade: both are the same instrumental,
    /// so there is no gap between words to wait for.
    public static let swapFadeMs: Int64 = 300
    /// The way back must be finished this long before the clip's audio ends.
    public static let fallbackSafetyMs: Int64 = 100

    /// What the player does while the clip plays.
    public enum Step: Sendable, Equatable {
        /// Keep playing the clip.
        case stay
        /// The clip is about to run out: back to the song at the next gap between words (the wish stays on).
        case leaveAtGap
        /// The playhead is outside the clip (a seek): back to the song now (the wish stays on).
        case leaveNow
        /// The full instrumental is here: swap to it at the same position.
        case swapToFull
    }

    /// The clip reaches the song's end: it plays to the end, there is no way back to plan.
    public static func reachesSongEnd(clipEndMs: Int64, songDurationMs: Int64) -> Bool {
        songDurationMs > 0 && clipEndMs >= songDurationMs - songEndSlackMs
    }

    /// May the clip start with the playhead at `positionMs` (song time)? Inside the clip, with enough of it left.
    public static func canStart(positionMs: Int64, clipStartMs: Int64, clipEndMs: Int64, songDurationMs: Int64) -> Bool {
        guard positionMs >= clipStartMs else { return false }
        let lastStart = reachesSongEnd(clipEndMs: clipEndMs, songDurationMs: songDurationMs)
            ? clipEndMs - 1_000
            : clipEndMs - endMarginMs - minimumRunMs
        return positionMs < lastStart
    }

    /// What to do now, with the clip playing and the playhead at `positionMs`.
    public static func step(positionMs: Int64, clipStartMs: Int64, clipEndMs: Int64, songDurationMs: Int64,
                            fullReady: Bool) -> Step {
        if fullReady { return .swapToFull }
        if positionMs < clipStartMs - seekToleranceMs || positionMs > clipEndMs + seekToleranceMs { return .leaveNow }
        if reachesSongEnd(clipEndMs: clipEndMs, songDurationMs: songDurationMs) { return .stay }
        if positionMs >= clipEndMs - endMarginMs { return .leaveAtGap }
        return .stay
    }

    /// The way back to the song before the clip runs out: the planner's gap placement when its fade is over in time,
    /// else as soon as possible with a fade that still fits (never under the planner's shortest).
    public static func fallbackPlacement(_ planned: SingSwitchPlanner.Placement, earliestPlayerMs: Int64,
                                         clipEndMs: Int64) -> SingSwitchPlanner.Placement {
        let deadline = clipEndMs - fallbackSafetyMs
        if planned.startPlayerMs + planned.fadeMs <= deadline { return planned }
        let fade = Swift.min(Swift.max(deadline - earliestPlayerMs, SingSwitchPlanner.minFadeMs), SingSwitchPlanner.maxFadeMs)
        return SingSwitchPlanner.Placement(startPlayerMs: earliestPlayerMs, fadeMs: fade, reason: .noGapInWindow)
    }
}
