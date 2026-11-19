// The served-log repetition budget (docs/brain-spec.md, 1 promise 2, 6.4, 6.5 `servedPen`, 12.1): what a generated
// list may repeat. Pure: the caller reads the served log and hands over plain lists. A transliteration of the Android
// `:brain` module's `Repetition.kt`.
//
// Three rules live here, all of them about music the app already served in a generated list:
//  - a recording is never in two mixes built on the same local day (`takenOnDay`; the day of a daily list starts at
//    04:00, rule 12 of 10.3);
//  - a recording served often in the last 30 days costs value in the next list (`servedPenalty`);
//  - the log is kept 60 days (`retentionMs`), the longest "stays away" rule of 6.1 needs.

/// The repetition budget.
public enum Repetition {
    public static let dayMs: Int64 = 86_400_000

    /// How far back "times served" looks (6.5).
    public static let windowMs: Int64 = 30 * dayMs

    /// How long a served list is kept (3.8).
    public static let retentionMs: Int64 = 60 * dayMs

    /// The penalty at three serves or more: `maxPenalty * min(1, timesServedLast30Days / 3)` (6.5). The spec says 0.4
    /// and marks it [E]. Measured on the three synthetic listeners of the harness (30 simulated days) 0.4 gave 0.32 /
    /// 0.47 / 0.40 distinct tracks, below the 0.60 that stage 2's "done means" asks; 1.2 gives 0.67 / 0.84 / 0.72
    /// (Android's deviation 82, which holds here).
    public static let maxPenalty: Double = 1.2
    public static let fullPenaltyAt: Int32 = 3

    /// A day starts at 04:00 local: `floorDiv(ms + tz * 60_000 - 14_400_000, 86_400_000)`.
    public static func mixDay(_ ms: Int64, tzOffsetMin: Int32) -> Int64 {
        BrainMath.floorDiv(ms &+ Int64(tzOffsetMin) &* 60_000 &- 14_400_000, dayMs)
    }

    public static func servedPenalty(_ timesServedLast30Days: Int32, max: Double = maxPenalty) -> Double {
        if timesServedLast30Days <= 0 { return 0.0 }
        let share = BrainMath.min(1.0, Double(timesServedLast30Days) / Double(fullPenaltyAt))
        return max * share
    }

    /// One list the app served: the surface it was for (`Surface`), when it was built, its recordings.
    public struct Served: Sendable, Equatable {
        public var surface: Int32
        public var builtAtMs: Int64
        public var rids: [Int64]
        /// Stage 2b: which list of its surface it was (`daily:<islandId>`, `your`, ...); empty for a stage 2a row.
        public var surfaceId: String

        public init(surface: Int32, builtAtMs: Int64, rids: [Int64], surfaceId: String = "") {
            self.surface = surface
            self.builtAtMs = builtAtMs
            self.rids = rids
            self.surfaceId = surfaceId
        }
    }

    /// True for the surfaces whose lists are mixes: a recording may be in only one of them a day.
    public static func isMixSurface(_ surface: Int32) -> Bool {
        surface == Surface.dailyMix || surface == Surface.yourMix || surface == Surface.namedMix
    }

    /// How many of the lists served in the last 30 days hold each recording (a recording counts once per list). A
    /// list built in the future (a clock that was set ahead) does not count.
    public static func timesServed(_ lists: [Served], nowMs: Int64) -> [Int64: Int32] {
        var out: [Int64: Int32] = [:]
        for list in lists {
            let age = nowMs &- list.builtAtMs
            if age < 0 || age >= windowMs { continue }
            var seen: Set<Int64> = []
            for rid in list.rids where rid != 0 && seen.insert(rid).inserted { out[rid, default: 0] += 1 }
        }
        return out
    }

    /// The recordings that mixes of the same local day as `nowMs` already hold, except the lists of `exceptSurface`
    /// (a list that is being rebuilt replaces its own earlier build).
    public static func takenOnDay(_ lists: [Served], nowMs: Int64, tzOffsetMin: Int32, exceptSurface: Int32 = -1,
                                  exceptId: String? = nil) -> Set<Int64> {
        let today = mixDay(nowMs, tzOffsetMin: tzOffsetMin)
        var out: Set<Int64> = []
        for list in lists {
            if !isMixSurface(list.surface) { continue }
            // Stage 2b: with an id, only the very list being rebuilt is skipped; the other lists of its surface count.
            if let exceptId {
                if list.surface == exceptSurface && list.surfaceId == exceptId { continue }
            } else if list.surface == exceptSurface {
                continue
            }
            if mixDay(list.builtAtMs, tzOffsetMin: tzOffsetMin) != today { continue }
            for rid in list.rids where rid != 0 { out.insert(rid) }
        }
        return out
    }

    /// Lists built before this time are dropped from the log.
    public static func keepAfter(_ nowMs: Int64) -> Int64 { nowMs &- retentionMs }

    /// Health (test 5): distinct recordings over all recordings of `builds` (several days of one mix). 1.0 for none.
    public static func distinctRatio(_ builds: [[Int64]]) -> Double {
        var total = 0
        var distinct: Set<Int64> = []
        for b in builds {
            for rid in b {
                total += 1
                distinct.insert(rid)
            }
        }
        if total == 0 { return 1.0 }
        return Double(distinct.count) / Double(total)
    }

    /// Health (test 5): the most any one artist holds of a list, as a share of it.
    public static func maxArtistShare(_ aids: [Int64]) -> Double {
        if aids.isEmpty { return 0.0 }
        var counts: [Int64: Int] = [:]
        var best = 0
        for a in aids where a != 0 {
            let n = (counts[a] ?? 0) + 1
            counts[a] = n
            if n > best { best = n }
        }
        return Double(best) / Double(aids.count)
    }
}
