// From a play to a reward `r` in 0..1 and a trust weight `c` (docs/brain-spec.md, 4.3). A transliteration of the
// Android `:brain` module's `Reward.kt`.
//
// Pure and replayable: the event log stores raw facts, and this file is the only place that says what they are
// worth. A change here is a replay, not a migration.

/// Grading a play.
public enum Reward {
    public static let completionR: Double = 0.8
    public static let maxC: Double = 4.5

    /// What grading needs beyond the event itself.
    public struct Context: Sendable {
        /// Past plays of this track with `r >= 0.8`.
        public var pastCompletions: Int32
        /// Skips directly before this play, each within 60 s of the next (this play not counted).
        public var skipStreak: Int32

        public init(pastCompletions: Int32 = 0, skipStreak: Int32 = 0) {
            self.pastCompletions = pastCompletions
            self.skipStreak = skipStreak
        }
    }

    public struct Graded: Sendable {
        public let r: Double
        /// Trust for the track's own key.
        public let c: Double
        /// Trust for every other key (artist, arm, all): lower when a well-loved track was skipped.
        public let cOther: Double
        /// Which of the nine `r` rules fired, 1...9.
        public let rule: Int32
        public let isSkip: Bool
        /// Skip strength for the session: 1.0 under 10 s, 0.6 under 30 s, 0.2 under half; 0 when not a skip.
        public let h: Double

        public var isCompletion: Bool { r >= Reward.completionR }
    }

    /// A skip (4.3): ended by next, pickedOther or queueEdit before half the track (30 s when the length is unknown).
    public static func isSkip(_ e: PlayEvent) -> Bool {
        if e.endReason != EndReason.next && e.endReason != EndReason.pickedOther && e.endReason != EndReason.queueEdit {
            return false
        }
        if e.playedMs < 0 { return false }
        return e.durationMs > 0 ? Int64(e.playedMs) * 2 < Int64(e.durationMs) : e.playedMs < 30_000
    }

    /// The session strength `h` of a skip (5.5, 7.3); 0 when `e` is not a skip.
    public static func skipStrength(_ e: PlayEvent, pastCompletions: Int32) -> Double {
        if !isSkip(e) { return 0.0 }
        let h: Double = e.playedMs < 10_000 ? 1.0 : (e.playedMs < 30_000 ? 0.6 : 0.2)
        return pastCompletions >= 3 && h > 0.3 ? 0.3 : h
    }

    public static func isEngineSurface(_ surface: Int32) -> Bool {
        surface == Surface.homeShelf || surface == Surface.dailyMix || surface == Surface.yourMix
            || surface == Surface.namedMix || surface == Surface.station || surface == Surface.autoplay
            || surface == Surface.assistant
    }

    public static func grade(_ e: PlayEvent, _ ctx: Context) -> Graded {
        // r: the first rule that matches wins.
        let explicitPositive = EventFlags.likedDuring | EventFlags.savedDuring | EventFlags.addedToPlaylist
            | EventFlags.replayed
        let r: Double
        let rule: Int32
        if e.has(EventFlags.notForMe) {
            r = 0.0; rule = 1
        } else if e.flags & explicitPositive != 0 {
            r = 1.0; rule = 2
        } else if e.playedMs == -1 {
            r = 0.75; rule = 3
        } else if e.endReason == EndReason.trackDone {
            r = 1.0; rule = 4
        } else if e.durationMs > 0 && Double(e.playedMs) >= 0.8 * Double(e.durationMs) {
            r = 1.0; rule = 5
        } else if e.playedMs < 10_000 {
            r = 0.0; rule = 6
        } else if e.playedMs < 30_000 {
            r = 0.1; rule = 7
        } else if e.durationMs > 0 {
            let fraction = (Double(e.playedMs) / Double(e.durationMs)) / 0.8
            r = 0.3 + 0.7 * BrainMath.min(1.0, fraction)
            rule = 8
        } else {
            r = 0.6; rule = 9
        }

        let skip = isSkip(e)
        let live = e.origin == Origin.live

        // c: one base value times every factor that applies.
        var c: Double
        if e.origin == Origin.migratedHistory {
            c = 0.8
        } else if e.origin == Origin.importSpotify {
            c = 0.5 * 1.0
        } else if e.origin == Origin.importYtm {
            c = 0.5 * 0.35
        } else if isEngineSurface(e.surface) {
            c = r >= 0.5 ? 0.6 : 1.0
        } else {
            c = r >= 0.5 ? 1.0 : 0.6
        }
        if rule == 1 || rule == 2 { c *= 3.0 }
        if e.has(EventFlags.seekBack) && rule != 2 { c *= 1.5 }
        if live && e.playedMs < 30_000
            && (e.endReason == EndReason.stopped || e.endReason == EndReason.killed
                || e.endReason == EndReason.error || e.endReason == EndReason.unknown) {
            c *= 0.0
        }
        if e.endReason == EndReason.prev { c *= 0.3 }
        if skip && ctx.skipStreak + 1 >= 3 { c *= 0.3 }
        if skip && e.playedMs < 2_000 && ctx.skipStreak >= 1 { c *= 0.3 }
        if r >= completionR {
            if e.passiveRun >= 12 { c *= 0.25 } else if e.passiveRun >= 6 { c *= 0.5 }
        }
        if e.has(EventFlags.exploreSlot) { c *= 1.5 }
        if e.has(EventFlags.neverAudible) { c *= 0.0 }
        if e.has(EventFlags.learnExcluded) { c *= 0.0 }
        if c > maxC { c = maxC }

        // Skipping a track they have finished three times says "not now", not "I dislike this artist".
        let cOther = skip && ctx.pastCompletions >= 3 ? c * 0.3 : c
        return Graded(r: r, c: c, cOther: cOther, rule: rule, isSkip: skip,
                      h: skipStrength(e, pastCompletions: ctx.pastCompletions))
    }
}
