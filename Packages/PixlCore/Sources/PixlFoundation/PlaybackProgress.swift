// The arithmetic behind the progress bars (full player and lyrics), shared so both draw the same position for the same
// song: which duration to trust, and the fraction.
//
// There is deliberately no "hold the committed seek for a few seconds" rule: the engine answers `currentPositionMs()`
// with the seek target the moment a seek is issued (and a remote output updates its position optimistically), so a bar
// reading the live position already shows the target. A hold only ever showed a stale point: a restart within five
// seconds of a scrub kept the old thumb, and a paused bar never redrew once the hold ran out.

import Foundation

public enum PlaybackProgress {
    /// The duration a progress bar shows: the player's when it agrees with the library's (±1.5 s), else the shorter of
    /// the two (Android `displayDurationValue`). A player duration that disagrees with the song's is usually the
    /// stream's estimate, not the song, and a bar drawn against it never reaches the end (or stops at the middle).
    public static func displayDuration(reportedMs: Int64, hintMs: Int64) -> Int64 {
        let reported = max(reportedMs, 0)
        let hint = max(hintMs, 0)
        if reported <= 0 && hint <= 0 { return 0 }
        if reported <= 0 { return hint }
        if hint <= 0 { return reported }
        if abs(reported - hint) <= 1500 { return reported }
        return min(reported, hint)
    }

    /// `positionMs / durationMs` clamped to 0...1 (0 while the duration is unknown).
    public static func fraction(positionMs: Int64, durationMs: Int64) -> Double {
        guard durationMs > 0 else { return 0 }
        return min(max(Double(positionMs) / Double(durationMs), 0), 1)
    }
}
