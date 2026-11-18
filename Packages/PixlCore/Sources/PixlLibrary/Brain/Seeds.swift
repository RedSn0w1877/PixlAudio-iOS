// Which tracks the background refresh asks YouTube Music for a radio of (docs/brain-spec.md, 3.6, "Stage 2 before
// islands exist"; 5.12 rule 10). Pure: the caller hands over the four groups, already ranked, and gets the seeds back.
// A transliteration of the Android `:brain` module's `Seeds.kt`.
//
// At most 24 seeds a day, in four groups, with at most 2 seeds per primary artist (two seeds by one artist share 28 to
// 31 of their 50 rows [L]):
//  - `recent`: the 8 newest distinct tracks the listener chose and finished in the last 14 days;
//  - `top`: the 8 top tracks by decayed engagement;
//  - `saved`: 4 tracks liked or saved in the last 30 days;
//  - `random`: 4 pseudo-random library tracks with non-negative affinity.
//
// A track the engine picked is never a seed unless the listener liked, saved or replayed it: the callers only put
// tracks they know the listener chose into the groups, and `pseudoRandomOrder` is the only thing here that is not
// already the listener's own ranking.

/// The refresh's seeds.
public enum Seeds {
    public static let recent = 0
    public static let top = 1
    public static let saved = 2
    public static let random = 3

    public static let recentQuota = 8
    public static let topQuota = 8
    public static let savedQuota = 4
    public static let randomQuota = 4

    /// A day's seeds, whatever the quotas add up to.
    public static let maxPerDay = 24
    public static let maxPerArtist = 2

    /// How far back "finished" and "liked or saved" look.
    public static let recentWindowMs: Int64 = 14 * 86_400_000
    public static let savedWindowMs: Int64 = 30 * 86_400_000

    /// One track that may be a seed. `aid` 0 is "unknown artist": it has no per-artist cap.
    public struct Seed: Sendable, Equatable {
        public var rid: Int64
        public var aid: Int64
        public var group: Int

        public init(rid: Int64, aid: Int64, group: Int) {
            self.rid = rid
            self.aid = aid
            self.group = group
        }
    }

    static func quotaOf(_ group: Int) -> Int {
        switch group {
        case recent: return recentQuota
        case top: return topQuota
        case saved: return savedQuota
        default: return randomQuota
        }
    }

    /// Walks the groups in order, each best first, and takes from each up to its quota, skipping a recording that is
    /// already a seed and an artist that already has `maxPerArtist`. `skip` holds recordings that may not be seeds at
    /// all (blocked, muted, "not for me").
    public static func select(_ groups: [[Seed]], skip: Set<Int64> = [], perArtist: Int = maxPerArtist) -> [Seed] {
        var out: [Seed] = []
        var taken: Set<Int64> = []
        var perArtistCount: [Int64: Int] = [:]
        for g in groups.indices {
            var got = 0
            let quota = quotaOf(g)
            for s in groups[g] {
                if got >= quota || out.count >= maxPerDay { break }
                if s.rid == 0 || skip.contains(s.rid) || taken.contains(s.rid) { continue }
                if s.aid != 0 {
                    let n = perArtistCount[s.aid] ?? 0
                    if n >= perArtist { continue }
                    perArtistCount[s.aid] = n + 1
                }
                taken.insert(s.rid)
                out.append(Seed(rid: s.rid, aid: s.aid, group: g))
                got += 1
            }
        }
        return out
    }

    /// The order of the `random` group: recordings by `splitmix64(rid xor salt xor day)`, unsigned, smallest first
    /// (ties by rid). The same day gives the same order; the next day another.
    public static func pseudoRandomOrder(_ rids: [Int64], salt: Int64, day: Int64) -> [Int64] {
        let dayMix = Int64(bitPattern: BrainHash.splitmix64(UInt64(bitPattern: day)))
        let key: [Int64] = rids.map { Int64(bitPattern: BrainHash.splitmix64(UInt64(bitPattern: $0 ^ salt ^ dayMix))) }
        let order = rids.indices.sorted { a, b in
            let c = BrainMath.compareUnsigned(key[a], key[b])
            if c != 0 { return c < 0 }
            return rids[a] < rids[b]
        }
        return order.map { rids[$0] }
    }
}
