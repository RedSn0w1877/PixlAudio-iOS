// The simple made-for-you lists of docs/brain-spec.md, 6.2 and 8.2 (stage 2b): On Repeat, Rediscover and Just Dropped.
// Each ranks a short list of candidates by one number and fills 30 slots greedily under the hard constraints of 6.4 (no
// recording twice, nothing another mix of the day holds, artists and albums spaced). First Listen, Daily Mix and Your
// Mix go through `StationPlanner` instead. A transliteration of the Android `:brain` module's `ListMixes.kt`.
//
// Pure: the same candidates and request give the same list on both platforms.

public enum ListMixes {
    public static let size = 30

    /// On Repeat looks at the last 30 days.
    public static let onRepeatWindowMs: Int64 = 30 * 86_400_000

    /// A track needs this much recent positive mass (about one finished play) to be "on repeat" at all.
    public static let onRepeatMinMass = 1.0

    /// Rediscover: loved (`aff > 0.5`) and not played for 90 days.
    public static let rediscoverAff = 0.5
    public static let rediscoverAgeMs: Int64 = 90 * 86_400_000

    /// One candidate with the one number its list is ranked by.
    public struct Item: Sendable {
        public let rid: Int64
        public let aid: Int64
        public let albumKey: Int64
        public let score: Double
        public let arm: Int32
        /// True for music the listener does not have (counts as novel in the list's health).
        public let novel: Bool
        /// Free for the caller to carry (an index into its own table).
        public let tag: Int

        public init(rid: Int64, aid: Int64, albumKey: Int64, score: Double, arm: Int32, novel: Bool = false, tag: Int = -1) {
            self.rid = rid; self.aid = aid; self.albumKey = albumKey; self.score = score
            self.arm = arm; self.novel = novel; self.tag = tag
        }
    }

    /// Fills up to `count` slots: at each slot the best remaining item (by the quantised score, then the jittered
    /// tie-break of 10.3) that breaks no spacing rule. `excluded` are recordings another mix of the day holds or that
    /// the listener ruled out; they are never picked.
    public static func fill(_ items: [Item], count: Int, excluded: Set<Int64>, tieSeed: Int64, maxPerArtist: Int = 0) -> [Item] {
        var out: [Item] = []
        if count <= 0 || items.isEmpty { return out }
        var used = Set<Int64>()
        var list: [ListBuilder.Prior] = []
        out.reserveCapacity(count)
        while out.count < count {
            var best: Item?
            var bestKey: Int64 = 0
            for x in items {
                if x.rid == 0 || used.contains(x.rid) || excluded.contains(x.rid) { continue }
                let c = Candidate(rid: x.rid, aid: x.aid, albumKey: x.albumKey)
                if !ListBuilder.fits(list, c, thinAid: 0) { continue }
                if maxPerArtist > 0 && x.aid != 0 {
                    var n = 0
                    for p in list where p.aid == x.aid { n += 1 }
                    if n >= maxPerArtist { continue }
                }
                let key = BrainMath.orderKey(x.score)
                if best == nil || key > bestKey || (key == bestKey && tieBreak(x.rid, best!.rid, tieSeed)) {
                    best = x
                    bestKey = key
                }
            }
            guard let pick = best else { break }
            used.insert(pick.rid)
            out.append(pick)
            list.append(ListBuilder.Prior(rid: pick.rid, aid: pick.aid, albumKey: pick.albumKey, novel: pick.novel))
        }
        return out
    }

    private static func tieBreak(_ rid: Int64, _ otherRid: Int64, _ tieSeed: Int64) -> Bool {
        let cmp = BrainMath.compareUnsigned(
            Int64(bitPattern: BrainHash.splitmix64(UInt64(bitPattern: rid ^ tieSeed))),
            Int64(bitPattern: BrainHash.splitmix64(UInt64(bitPattern: otherRid ^ tieSeed))))
        if cmp != 0 { return cmp < 0 }
        return rid < otherRid
    }

    /// On Repeat (6.2, nu 0): the tracks with the most decayed plays in the last 30 days. The score is the track's
    /// 21-day positive mass (finished plays, each decayed by age), and the track must have been played inside the
    /// window and carry at least `onRepeatMinMass`.
    public static func onRepeat(_ affinity: Affinity.State, rids: [Int64], aids: [Int64], albumKeys: [Int64], nowMs: Int64) -> [Item] {
        var out: [Item] = []
        for i in 0..<rids.count {
            guard let k = affinity.counter(Family.track, rids[i]) else { continue }
            if k.lastMs <= 0 || nowMs &- k.lastMs > onRepeatWindowMs { continue }
            let mass = Affinity.posRecent(k, nowMs: nowMs)
            if mass < onRepeatMinMass { continue }
            out.append(Item(rid: rids[i], aid: aids[i], albumKey: albumKeys[i], score: mass, arm: Arm.fav, tag: i))
        }
        return out
    }

    /// Rediscover (6.2, nu 0): loved tracks (`aff(track) > 0.5`) not played for 90 days. Ranked by affinity less the
    /// 30-day served penalty, so what the last weeks' lists showed steps aside and the list rotates.
    public static func rediscover(_ affinity: Affinity.State, rids: [Int64], aids: [Int64], albumKeys: [Int64],
                                  servedTimes: [Int64: Int32], nowMs: Int64) -> [Item] {
        var out: [Item] = []
        let p0 = Affinity.p0(affinity, nowMs: nowMs)
        for i in 0..<rids.count {
            guard let k = affinity.counter(Family.track, rids[i]) else { continue }
            if k.lastMs <= 0 || nowMs &- k.lastMs < rediscoverAgeMs { continue }
            let aff = Affinity.aff(affinity, family: Family.track, key: rids[i], nowMs: nowMs, p0: p0)
            if aff <= rediscoverAff { continue }
            let score = aff - Repetition.servedPenalty(servedTimes[rids[i]] ?? 0)
            out.append(Item(rid: rids[i], aid: aids[i], albumKey: albumKeys[i], score: score, arm: Arm.fav, tag: i))
        }
        return out
    }

    /// Just Dropped (6.2, nu 1): new releases, the artists the listener loves first. `artistAff` is the affinity of each
    /// item's artist; an artist the listener has never played scores below every loved one, and within one level the
    /// more recent card comes first (`recency` is bigger for newer cards).
    public static func justDropped(rids: [Int64], aids: [Int64], albumKeys: [Int64], artistAff: [Double],
                                   artistHeard: [Bool], recency: [Double]) -> [Item] {
        var out: [Item] = []
        out.reserveCapacity(rids.count)
        for i in 0..<rids.count {
            let loved = artistHeard[i] ? 3.0 + artistAff[i] : 0.0
            out.append(Item(rid: rids[i], aid: aids[i], albumKey: albumKeys[i], score: loved + 0.001 * recency[i],
                            arm: Arm.new, novel: true, tag: i))
        }
        return out
    }
}
