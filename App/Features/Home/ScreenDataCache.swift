import Foundation
import PixlLibrary
import PixlModel

/// What Stats, Recently Played and Device Capabilities computed last, kept for the app's lifetime. Each visit used
/// to start empty and swap a spinner for the whole content (Swift Charts included) when the computation landed —
/// usually mid-push. Now a revisit's first frame is the content (when it was computed from the same listening
/// history and library size), and the background reload still runs and replaces the values in place. Home's
/// computation seeds the week summary, so even the first Stats visit usually has it.
enum ScreenDataCache {
    /// What a result was computed from (the same inputs as the screens' reload keys).
    nonisolated struct Stamp: Equatable, Sendable {
        var historyRevision: Int
        var songCount: Int
    }

    private static var stats: [StatsTimeRange: (stamp: Stamp, summary: PlaybackStatsSummary)] = [:]
    private static var recentlyPlayed: [StatsTimeRange: (stamp: Stamp, groups: [HomeLogic.TimestampGroup],
                                                         queue: [Song])] = [:]
    /// The last measured device capabilities (it re-measures on every visit and route change).
    static var deviceCapabilities: DeviceCapabilitiesState?

    static func stats(_ range: StatsTimeRange, stamp: Stamp) -> PlaybackStatsSummary? {
        guard let entry = stats[range], entry.stamp == stamp else { return nil }
        return entry.summary
    }

    static func storeStats(_ summary: PlaybackStatsSummary, stamp: Stamp) {
        stats[summary.range] = (stamp, summary)
    }

    static func recentlyPlayed(_ range: StatsTimeRange,
                               stamp: Stamp) -> (groups: [HomeLogic.TimestampGroup], queue: [Song])? {
        guard let entry = recentlyPlayed[range], entry.stamp == stamp else { return nil }
        return (entry.groups, entry.queue)
    }

    static func storeRecentlyPlayed(_ range: StatsTimeRange, groups: [HomeLogic.TimestampGroup], queue: [Song],
                                    stamp: Stamp) {
        recentlyPlayed[range] = (stamp, groups, queue)
    }
}
