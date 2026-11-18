// Builds a list slot by slot (docs/brain-spec.md, 6.4, 6.5). Greedy: each slot has a kind (familiar, novel, or a
// special first slot), and within the kind the candidate with the best value that breaks no hard rule takes it. A
// transliteration of the Android `:brain` module's `ListBuilder.kt`.
//
// Stage 1 has the hard constraints of 6.4, the slot plan and `lambda`; no calibration, flow cost or served penalty
// yet. Ordering is by a quantised key with a total tie-break, so sort stability and floating-point noise below
// 2^-20 cannot change a list.

/// The list builder.
public enum ListBuilder {
    public static let lambdaDefault: Double = 0.75
    /// The same primary artist not within this many slots.
    public static let artistGap = 4
    /// A station's seed artist after one skip: one track in six.
    public static let thinArtistGap = 6
    /// The same album not within this many slots.
    public static let albumGap = 8
    /// Diversity looks back this many slots.
    public static let mmrWindow = 10

    public static let slotOpener: Int32 = 0
    public static let slotFamiliar: Int32 = 1
    public static let slotNovel: Int32 = 2
    /// A familiar track by a given artist, or failing that the best row of the newest anchor's radio.
    public static let slotBridge: Int32 = 3
    /// The track scheduled because the listener liked something.
    public static let slotLiked: Int32 = 4
    public static let slotCloser: Int32 = 5

    /// A candidate with its score.
    public struct Scored: Sendable {
        public var c: Candidate
        public var arm: Int32
        public var z: Double
        public var p: Double
        /// True when the listener does not have it: it competes for the novel slots.
        public var novel: Bool
        public var bestRank: Int32
        public var bestSeed: Int32
        /// Its rank in the newest anchor's list; 0 when it is not there.
        public var newestSeedRank: Int32
        /// When it was last played; 0 for never.
        public var lastMs: Int64
        /// Retrieval percentile x 1000.
        public var retrQ: Int32

        public init(c: Candidate, arm: Int32, z: Double, p: Double, novel: Bool, bestRank: Int32, bestSeed: Int32,
                    newestSeedRank: Int32, lastMs: Int64, retrQ: Int32) {
            self.c = c
            self.arm = arm
            self.z = z
            self.p = p
            self.novel = novel
            self.bestRank = bestRank
            self.bestSeed = bestSeed
            self.newestSeedRank = newestSeedRank
            self.lastMs = lastMs
            self.retrQ = retrQ
        }
    }

    /// A slot already in the list (the engine's own tail of the queue), oldest first.
    public struct Prior: Sendable {
        public var rid: Int64
        public var aid: Int64
        public var albumKey: Int64
        public var novel: Bool

        public init(rid: Int64, aid: Int64, albumKey: Int64, novel: Bool) {
            self.rid = rid
            self.aid = aid
            self.albumKey = albumKey
            self.novel = novel
        }
    }

    public struct Request: Sendable {
        public var count: Int
        public var prior: [Prior]
        /// Novelty share: the part of the slots that goes to music the listener does not have.
        public var nu: Double
        /// Seeds the tie-break, so two lists do not break ties the same way.
        public var tieSeed: Int64
        public var nowMs: Int64
        public var tzOffsetMin: Int32
        /// Non-nil: the first slot is a `slotBridge` for these artists.
        public var firstSlotAids: [Int64]?
        /// Non-zero: one slot goes to a track by this artist, or the nearest neighbour of `likedRid`.
        public var likedAid: Int64
        public var likedRid: Int64
        /// A finite list ends on a familiar track.
        public var finite: Bool
        /// This artist is spaced `thinArtistGap` apart instead of `artistGap`.
        public var thinAid: Int64
        public var lambda: Double

        public init(count: Int, prior: [Prior], nu: Double, tieSeed: Int64, nowMs: Int64, tzOffsetMin: Int32,
                    firstSlotAids: [Int64]? = nil, likedAid: Int64 = 0, likedRid: Int64 = 0, finite: Bool = false,
                    thinAid: Int64 = 0, lambda: Double = ListBuilder.lambdaDefault) {
            self.count = count
            self.prior = prior
            self.nu = nu
            self.tieSeed = tieSeed
            self.nowMs = nowMs
            self.tzOffsetMin = tzOffsetMin
            self.firstSlotAids = firstSlotAids
            self.likedAid = likedAid
            self.likedRid = likedRid
            self.finite = finite
            self.thinAid = thinAid
            self.lambda = lambda
        }
    }

    public struct Pick: Sendable {
        public let scored: Scored
        public let kind: Int32
        /// The quantised key it won its slot with.
        public let key: Int64
    }

    public static func build(_ request: Request, scored: [Scored], graph: Graph) -> [Pick] {
        var picks: [Pick] = []
        if request.count <= 0 || scored.isEmpty { return picks }
        picks.reserveCapacity(request.count)
        var list = request.prior
        list.reserveCapacity(request.prior.count + request.count)
        var used: Set<Int64> = []
        var novelSoFar = 0
        for p in list {
            used.insert(p.rid)
            if p.novel { novelSoFar += 1 }
        }
        let today = BrainMath.localDay(request.nowMs, tzOffsetMin: request.tzOffsetMin)
        var likedPending = request.likedAid != 0 || request.likedRid != 0

        for i in 0..<request.count {
            let slotNo = list.count + 1
            var kind: Int32
            if i == 0 && request.firstSlotAids != nil {
                kind = slotBridge
            } else if likedPending {
                kind = slotLiked
            } else if slotNo == 1 {
                kind = slotOpener
            } else if slotNo == 2 {
                kind = slotFamiliar
            } else if request.finite && i == request.count - 1 {
                kind = slotCloser
            } else if Double(novelSoFar) < request.nu * Double(slotNo - 2) && !list[list.count - 1].novel {
                // The first two slots are the familiar openers; the novelty share counts from the third.
                kind = slotNovel
            } else {
                kind = slotFamiliar
            }
            var chosen: Scored?
            var chosenKey: Int64 = 0

            if kind == slotBridge {
                let aids = request.firstSlotAids!
                var best: Scored?
                var bestKey: Int64 = 0
                for s in scored {
                    if s.novel || used.contains(s.c.rid) || !contains(aids, s.c.aid) || !fits(list, s.c, thinAid: request.thinAid) {
                        continue
                    }
                    let key = BrainMath.orderKey(s.p)
                    if best == nil || better(key, s.c.rid, bestKey, best!.c.rid, request.tieSeed) {
                        best = s
                        bestKey = key
                    }
                }
                if best == nil {
                    // The best radio row of the newest anchor.
                    for s in scored {
                        if s.newestSeedRank <= 0 || used.contains(s.c.rid) || !fits(list, s.c, thinAid: request.thinAid) {
                            continue
                        }
                        let key = -Int64(s.newestSeedRank)
                        if best == nil || better(key, s.c.rid, bestKey, best!.c.rid, request.tieSeed) {
                            best = s
                            bestKey = key
                        }
                    }
                }
                chosen = best
                chosenKey = bestKey
                if chosen == nil { kind = slotNo <= 2 ? slotFamiliar : slotNovel }
            }

            if kind == slotLiked {
                likedPending = false
                var best: Scored?
                var bestKey: Int64 = 0
                if request.likedAid != 0 {
                    for s in scored {
                        if s.c.aid != request.likedAid || used.contains(s.c.rid) || !fits(list, s.c, thinAid: request.thinAid) {
                            continue
                        }
                        let key = BrainMath.orderKey(value(s, list, graph, request.lambda))
                        if best == nil || better(key, s.c.rid, bestKey, best!.c.rid, request.tieSeed) {
                            best = s
                            bestKey = key
                        }
                    }
                }
                if best == nil && request.likedRid != 0 {
                    for s in scored {
                        if used.contains(s.c.rid) || !fits(list, s.c, thinAid: request.thinAid) { continue }
                        let sim = Similarity.sim(graph, s.c.rid, s.c.aid, request.likedRid, request.likedAid)
                        if sim <= 0.0 { continue }
                        let key = BrainMath.orderKey(sim)
                        if best == nil || better(key, s.c.rid, bestKey, best!.c.rid, request.tieSeed) {
                            best = s
                            bestKey = key
                        }
                    }
                }
                chosen = best
                chosenKey = bestKey
                if chosen == nil {
                    if slotNo <= 2 {
                        kind = slotFamiliar
                    } else if Double(novelSoFar) < request.nu * Double(slotNo - 2) && !list[list.count - 1].novel {
                        kind = slotNovel
                    } else {
                        kind = slotFamiliar
                    }
                }
            }

            if chosen == nil && kind == slotOpener {
                // The trust opener: familiar, highest p, not played today.
                for s in scored {
                    if s.novel || used.contains(s.c.rid) || !fits(list, s.c, thinAid: request.thinAid) { continue }
                    if s.lastMs != 0 && BrainMath.localDay(s.lastMs, tzOffsetMin: request.tzOffsetMin) == today { continue }
                    let key = BrainMath.orderKey(s.p)
                    if chosen == nil || better(key, s.c.rid, chosenKey, chosen!.c.rid, request.tieSeed) {
                        chosen = s
                        chosenKey = key
                    }
                }
                if chosen == nil { kind = slotFamiliar }
            }

            if chosen == nil && kind == slotCloser {
                for s in scored {
                    if s.novel || used.contains(s.c.rid) || !fits(list, s.c, thinAid: request.thinAid) { continue }
                    let key = BrainMath.orderKey(s.p)
                    if chosen == nil || better(key, s.c.rid, chosenKey, chosen!.c.rid, request.tieSeed) {
                        chosen = s
                        chosenKey = key
                    }
                }
                if chosen == nil { kind = slotNovel }
            }

            if chosen == nil {
                // A familiar or a novel slot; when its own kind has nobody, the other kind takes it (staying on
                // topic beats the quota).
                var wantNovel = kind == slotNovel
                var pass = 0
                while pass < 2 && chosen == nil {
                    for s in scored {
                        if s.novel != wantNovel || used.contains(s.c.rid) || !fits(list, s.c, thinAid: request.thinAid) {
                            continue
                        }
                        let key = BrainMath.orderKey(value(s, list, graph, request.lambda))
                        if chosen == nil || better(key, s.c.rid, chosenKey, chosen!.c.rid, request.tieSeed) {
                            chosen = s
                            chosenKey = key
                        }
                    }
                    if chosen == nil { wantNovel = !wantNovel }
                    pass += 1
                }
                if let chosen { kind = chosen.novel ? slotNovel : slotFamiliar }
            }

            guard let pick = chosen else { break }
            picks.append(Pick(scored: pick, kind: kind, key: chosenKey))
            used.insert(pick.c.rid)
            if pick.novel { novelSoFar += 1 }
            list.append(Prior(rid: pick.c.rid, aid: pick.c.aid, albumKey: pick.c.albumKey, novel: pick.novel))
        }
        return picks
    }

    /// `lambda * z - (1 - lambda) * max over the last slots j of sim(i, j)`.
    private static func value(_ s: Scored, _ list: [Prior], _ graph: Graph, _ lambda: Double) -> Double {
        var maxSim = 0.0
        var back = 1
        while back <= mmrWindow && list.count - back >= 0 {
            let p = list[list.count - back]
            let sim = Similarity.sim(graph, s.c.rid, s.c.aid, p.rid, p.aid)
            if sim > maxSim { maxSim = sim }
            back += 1
        }
        return lambda * s.z - (1.0 - lambda) * maxSim
    }

    /// Order: the key descending, then `splitmix64(rid xor seed)` ascending (unsigned), then rid ascending.
    private static func better(_ key: Int64, _ rid: Int64, _ otherKey: Int64, _ otherRid: Int64, _ tieSeed: Int64) -> Bool {
        if key != otherKey { return key > otherKey }
        let mine = BrainHash.splitmix64(UInt64(bitPattern: rid ^ tieSeed))
        let theirs = BrainHash.splitmix64(UInt64(bitPattern: otherRid ^ tieSeed))
        if mine != theirs { return mine < theirs }
        return rid < otherRid
    }

    private static func contains(_ ids: [Int64], _ id: Int64) -> Bool {
        if id == 0 { return false }
        for v in ids where v == id { return true }
        return false
    }

    /// The spacing rules of 6.4 for the slot after `list`: the same primary artist not within `artistGap` slots and
    /// at most 2 per 20 and 3 per 50; the same album not within `albumGap`.
    public static func fits(_ list: [Prior], _ c: Candidate, thinAid: Int64) -> Bool {
        let size = list.count
        if c.aid != 0 {
            let gap = c.aid == thinAid ? thinArtistGap : artistGap
            var within20 = 0
            var within50 = 0
            var back = 1
            while back <= 49 && size - back >= 0 {
                if list[size - back].aid == c.aid {
                    if back <= gap { return false }
                    if back <= 19 { within20 += 1 }
                    within50 += 1
                }
                back += 1
            }
            if within20 >= 2 || within50 >= 3 { return false }
        }
        if c.albumKey != 0 {
            var back = 1
            while back <= albumGap && size - back >= 0 {
                if list[size - back].albumKey == c.albumKey { return false }
                back += 1
            }
        }
        return true
    }
}
