// Candidate retrieval for stage 1 (docs/brain-spec.md, 6.1): cross-seed co-occurrence over the radio lists of the
// session's seeds. A transliteration of the Android `:brain` module's `Retrieval.kt`.

/// Retrieval: `cooc` and the percentile of feature 37.
public enum Retrieval {
    /// One seed and its list, best row first: row `i` has rank `i + 1`.
    public struct SeedList: Sendable {
        public var seedRid: Int64
        /// The seed's primary artist; 0 when unknown.
        public var seedAid: Int64
        public var rids: [Int64]
        /// `Graph.radio` or `Graph.related`: what kind of list it is, for the graph.
        public var edgeFactor: Double

        public init(seedRid: Int64, seedAid: Int64, rids: [Int64], edgeFactor: Double = Graph.radio) {
            self.seedRid = seedRid
            self.seedAid = seedAid
            self.rids = rids
            self.edgeFactor = edgeFactor
        }
    }

    public struct Entry: Sendable {
        public var cooc: Double = 0.0
        /// The best (smallest) rank in any seed's list.
        public var bestRank: Int32 = 0
        /// The index, in the seed list order, of the seed whose list ranks it best.
        public var bestSeed: Int32 = -1
        public var firstSeedAid: Int64 = 0
        public var severalArtists = false
    }

    /// ```
    /// cooc(c) = sum over seeds s whose list contains c of  w(s) / (10 + rank_s(c))
    /// w(s)    = clip(1 + aff(primary artist of s) / 3, 0.1, 2)
    /// cooc   *= 1.25 if c appears under seeds by two or more different artists
    /// ```
    /// The sum runs in the order of `seeds`.
    public static func cooc(_ seeds: [SeedList], affinity: Affinity.State, nowMs: Int64, p0: Double) -> [Int64: Entry] {
        var out: [Int64: Entry] = [:]
        for s in seeds.indices {
            let seed = seeds[s]
            let a: Double = seed.seedAid == 0
                ? 0.0 : Affinity.aff(affinity, family: Family.artist, key: seed.seedAid, nowMs: nowMs, p0: p0)
            let w = BrainMath.clip(1.0 + a / 3.0, 0.1, 2.0)
            var seenInThisList: Set<Int64> = []
            for i in seed.rids.indices {
                let rid = seed.rids[i]
                if rid == 0 || !seenInThisList.insert(rid).inserted { continue }
                let rank = Int32(i + 1)
                var e = out[rid] ?? Entry()
                e.cooc += w / (10.0 + Double(rank))
                if e.bestRank == 0 || rank < e.bestRank {
                    e.bestRank = rank
                    e.bestSeed = Int32(s)
                }
                if e.bestSeed < 0 { e.bestSeed = Int32(s) }
                if seed.seedAid != 0 {
                    if e.firstSeedAid == 0 {
                        e.firstSeedAid = seed.seedAid
                    } else if e.firstSeedAid != seed.seedAid {
                        e.severalArtists = true
                    }
                }
                out[rid] = e
            }
        }
        for rid in Array(out.keys) where out[rid]!.severalArtists { out[rid]!.cooc *= 1.25 }
        return out
    }

    /// Feature 37: a candidate's retrieval-score percentile within its arm,
    /// `(candidates of that arm with a strictly smaller quantised score) / max(1, n - 1)`; 0 for a candidate without
    /// a retrieval score. `arms` and `scores` are parallel.
    public static func percentiles(arms: [Int32], scores: [Double]) -> [Double] {
        let n = arms.count
        var keys = [Int64](repeating: 0, count: n)
        for i in 0..<n { keys[i] = BrainMath.orderKey(scores[i]) }
        var out = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            if scores[i] <= 0.0 { continue }
            var smaller = 0
            var inArm = 0
            for j in 0..<n {
                if arms[j] != arms[i] { continue }
                inArm += 1
                if keys[j] < keys[i] { smaller += 1 }
            }
            let den = inArm - 1 > 1 ? inArm - 1 : 1
            out[i] = Double(smaller) / Double(den)
        }
        return out
    }
}
