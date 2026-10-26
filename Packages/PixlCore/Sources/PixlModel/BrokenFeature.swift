// Features the owner found broken (2026-10-26): they stay visible, greyed out and locked, marked "Broken, fix soon",
// with their stored value forced to a safe default so nothing half-works. The fix flips `isLocked` here; nothing
// else about the feature was removed.

import Foundation

public enum BrokenFeature: String, Sendable, CaseIterable {
    /// Settings › Equalizer (and every effect on it).
    case equalizer
    /// The lyrics "Adjust sync" row (the per-song offset).
    case lyricsAdjustSync

    /// The label every locked control shows.
    public static let label = "Broken, fix soon"

    public var isLocked: Bool { true }

    /// The lyrics offset to apply: a locked "Adjust sync" ignores whatever was stored (the stored value is kept, not
    /// deleted, so a later fix finds it again).
    public static func lyricsOffsetMs(stored: Int) -> Int {
        BrokenFeature.lyricsAdjustSync.isLocked ? 0 : stored
    }
}
