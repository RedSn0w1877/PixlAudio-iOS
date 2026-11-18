// Plans what the engine plays next (docs/brain-spec.md, 6.2, 7.1, 7.3, 8.1): an autoplay batch, a station batch, or
// the "Because you listened to" Home row. One path for all three: retrieve (`Retrieval.cooc`), score (`Features`,
// `Ranker`), build (`ListBuilder`), explain (`WhyLine`). A transliteration of the Android `:brain` module's
// `StationPlanner.kt`.
//
// Pure: the same affinity tables, session, graph and request give the same picks on both platforms.

/// The planner.
public enum StationPlanner {
    public static let modeAutoplay: Int32 = 0
    public static let modeStation: Int32 = 1
    public static let modeHomeRow: Int32 = 2

    public static let fourHoursMs: Int64 = 4 * 60 * 60 * 1000

    /// Autoplay: a library track must be this close to an anchor (same artist, or the first 8 radio rows).
    public static let familiarFloor: Double = 0.3
    /// A station without embeddings: every track must be at least this close to the seed.
    public static let stationFloor: Double = 0.15
    /// ARTIST arm: the artist's affinity and decayed play weight must both be above these.
    public static let artistArmAff: Double = 0.5
    public static let artistArmWeight: Double = 5.0

    public struct Request: Sendable {
        public var mode: Int32
        public var count: Int
        /// Everything that could be picked. Not yet in the queue; blocked and muted music already removed (5.11).
        public var candidates: [Candidate]
        /// The seeds' lists, newest anchor first. For a station or a Home row the seed is `seeds[0]`.
        public var seeds: [Retrieval.SeedList]
        /// The engine's slots already in the list, oldest first.
        public var prior: [ListBuilder.Prior]
        public var nowMs: Int64
        public var tzOffsetMin: Int32
        /// The surface factor times the listener's Familiar / Blend / Discover switch (0.4 / 1 / 2).
        public var nuMultiplier: Double
        public var tieSeed: Int64
        /// Recordings that may not be picked (already queued, ignored three times).
        public var excludedRids: Set<Int64>
        /// The first slot is the bridge of 7.1 (the first track autoplay appends to a queue).
        public var bridge: Bool
        public var finite: Bool

        public init(mode: Int32, count: Int, candidates: [Candidate], seeds: [Retrieval.SeedList],
                    prior: [ListBuilder.Prior] = [], nowMs: Int64, tzOffsetMin: Int32 = 0, nuMultiplier: Double = 1.0,
                    tieSeed: Int64 = 0, excludedRids: Set<Int64> = [], bridge: Bool = false, finite: Bool = false) {
            self.mode = mode
            self.count = count
            self.candidates = candidates
            self.seeds = seeds
            self.prior = prior
            self.nowMs = nowMs
            self.tzOffsetMin = tzOffsetMin
            self.nuMultiplier = nuMultiplier
            self.tieSeed = tieSeed
            self.excludedRids = excludedRids
            self.bridge = bridge
            self.finite = finite
        }
    }

    public struct Pick: Sendable {
        public let rid: Int64
        public let arm: Int32
        /// Position in the engine's list: `prior.count + index`.
        public let slot: Int32
        public let slotKind: Int32
        public let whyKey: Int32
        public let whyArg: Int64
        /// Retrieval percentile x 1000 (the event's `retrQ`).
        public let retrQ: Int32
        /// Best radio rank, -1 for none (the event's `radioRank`).
        public let radioRank: Int32
        /// The quantised key the pick won its slot with.
        public let key: Int64
        /// `p` x 10,000.
        public let pQ: Int32
        public let novel: Bool
    }

    public struct Plan: Sendable {
        public let picks: [Pick]
        /// The like-scheduled slot was filled: the caller clears `likedWithin`.
        public let usedLiked: Bool
        /// The "second skip in a row" slot was planned: the caller clears `familiarNext`.
        public let usedFamiliarNext: Bool
        /// How many candidates survived the filters.
        public let poolSize: Int
    }

    public static func plan(_ request: Request, affinity: Affinity.State, session: SessionState, graph: Graph) -> Plan {
        let nowMs = request.nowMs
        let p0 = Affinity.p0(affinity, nowMs: nowMs)
        let weights = Ranker.weights(p0: p0)
        let cooc = Retrieval.cooc(request.seeds, affinity: affinity, nowMs: nowMs, p0: p0)
        let homeRow = request.mode == modeHomeRow
        let station = request.mode == modeStation
        let stationSeed: Retrieval.SeedList? = ((station || homeRow) && !request.seeds.isEmpty) ? request.seeds[0] : nil
        let newest: Retrieval.SeedList? = !request.seeds.isEmpty ? request.seeds[0] : nil
        var newestRank: [Int64: Int32] = [:]
        if let newest {
            for i in newest.rids.indices where newestRank[newest.rids[i]] == nil {
                newestRank[newest.rids[i]] = Int32(i + 1)
            }
        }

        // Filter, and decide each candidate's arm.
        var kept: [Candidate] = []
        var arms: [Int32] = []
        kept.reserveCapacity(request.candidates.count)
        arms.reserveCapacity(request.candidates.count)
        var seen: Set<Int64> = []
        // A seed is what the listener is hearing: it is never its own recommendation.
        for seed in request.seeds { seen.insert(seed.seedRid) }
        for c in request.candidates {
            if c.rid == 0 || request.excludedRids.contains(c.rid) || !seen.insert(c.rid).inserted { continue }
            if session.isBlocked(c.aid) { continue }
            if session.seedLimit == 2 && c.aid != 0 && c.aid == session.seedAid { continue }
            let last = Affinity.lastMs(affinity, family: Family.track, key: c.rid)
            if last != 0 && nowMs &- last < fourHoursMs { continue }
            if homeRow && c.inLibrary { continue }
            if let stationSeed, station {
                let s = Similarity.sim(graph, c.rid, c.aid, stationSeed.seedRid, stationSeed.seedAid)
                if s < (c.inLibrary ? familiarFloor : stationFloor) { continue }
            } else if c.inLibrary {
                var close = 0.0
                for seed in request.seeds {
                    let s = Similarity.sim(graph, c.rid, c.aid, seed.seedRid, seed.seedAid)
                    if s > close { close = s }
                }
                if close < familiarFloor { continue }
            }
            let arm: Int32
            if c.inLibrary {
                arm = (affinity.completions[c.rid] ?? 0) >= 1 ? Arm.fav : Arm.deep
            } else if c.fromArtistRadio {
                arm = Arm.artist
            } else if c.aid != 0
                && Affinity.aff(affinity, family: Family.artist, key: c.aid, nowMs: nowMs, p0: p0) > artistArmAff
                && Affinity.weight(affinity, family: Family.artist, key: c.aid, nowMs: nowMs) >= artistArmWeight {
                arm = Arm.artist
            } else {
                arm = Arm.radio
            }
            kept.append(c)
            arms.append(arm)
        }

        let n = kept.count
        var scores = [Double](repeating: 0.0, count: n)
        for i in 0..<n { scores[i] = cooc[kept[i].rid]?.cooc ?? 0.0 }
        let pct = Retrieval.percentiles(arms: arms, scores: scores)
        var x = [Double](repeating: 0.0, count: Features.d)
        var scored: [ListBuilder.Scored] = []
        scored.reserveCapacity(n)
        for i in 0..<n {
            let c = kept[i]
            let entry = cooc[c.rid]
            let bestRank: Int32 = entry?.bestRank ?? 0
            Features.compute(c, arm: arms[i], retrieval: pct[i], bestRank: bestRank, affinity: affinity,
                             session: session, graph: graph, nowMs: nowMs, p0: p0, allNovel: homeRow, out: &x)
            var z = Ranker.z(weights, x)
            if let stationSeed, station {
                let s = Similarity.sim(graph, c.rid, c.aid, stationSeed.seedRid, stationSeed.seedAid)
                let blend = 0.6 * s + 0.4 * x[Features.sessPosSim]
                z += 1.2 * blend
            }
            // The listener's boost / reduce is applied after scoring, outside the model (5.11).
            z += c.boostLn
            scored.append(ListBuilder.Scored(
                c: c,
                arm: arms[i],
                z: z,
                p: Ranker.p(z, x),
                novel: !c.inLibrary,
                bestRank: bestRank,
                bestSeed: entry?.bestSeed ?? -1,
                newestSeedRank: newestRank[c.rid] ?? 0,
                lastMs: Affinity.lastMs(affinity, family: Family.track, key: c.rid),
                retrQ: Int32(truncatingIfNeeded: BrainMath.floorToLong(pct[i] * 1000.0 + 0.5))
            ))
        }

        // The special first slot: after two skips in a row a familiar track by the artist last finished; on the
        // first batch, the bridge from what was just heard.
        var firstSlotAids: [Int64]?
        let familiarNext = session.familiarNext && !homeRow
        if familiarNext {
            firstSlotAids = session.lastCompletedAid != 0 ? [session.lastCompletedAid] : []
        } else if request.bridge && !homeRow {
            var aids: [Int64] = []
            var j = 0
            while j < session.posCount && j < 3 {
                let aid = session.recentPosAid[j]
                if aid != 0 && !aids.contains(aid) { aids.append(aid) }
                j += 1
            }
            firstSlotAids = aids
        }
        let liked = session.likedWithin > 0 && !homeRow
        let nu: Double = homeRow ? 1.0 : BrainMath.clip(session.nuSession * request.nuMultiplier, 0.0, 1.0)
        let built = ListBuilder.build(
            ListBuilder.Request(
                count: request.count,
                prior: request.prior,
                nu: nu,
                tieSeed: request.tieSeed,
                nowMs: nowMs,
                tzOffsetMin: request.tzOffsetMin,
                firstSlotAids: firstSlotAids,
                likedAid: liked ? session.likedAid : 0,
                likedRid: liked ? session.likedRid : 0,
                finite: request.finite,
                thinAid: session.seedLimit == 1 ? session.seedAid : 0
            ),
            scored: scored,
            graph: graph
        )

        var usedLiked = false
        var picks: [Pick] = []
        picks.reserveCapacity(built.count)
        for i in built.indices {
            let b = built[i]
            let s = b.scored
            if b.kind == ListBuilder.slotLiked { usedLiked = true }
            let seedAid: Int64 = (s.bestSeed >= 0 && Int(s.bestSeed) < request.seeds.count)
                ? request.seeds[Int(s.bestSeed)].seedAid : 0
            let why = WhyLine.pick(
                arm: s.arm,
                slotKind: b.kind,
                homeRow: homeRow,
                candidateAid: s.c.aid,
                seedAid: seedAid,
                bestRank: s.bestRank,
                likedRid: session.likedRid,
                homeSeedRid: stationSeed?.seedRid ?? 0,
                trackAffRecent: Affinity.affRecent(affinity, family: Family.track, key: s.c.rid, nowMs: nowMs, p0: p0)
            )
            picks.append(Pick(
                rid: s.c.rid,
                arm: s.arm,
                slot: Int32(request.prior.count + i),
                slotKind: b.kind,
                whyKey: why.key,
                whyArg: why.arg,
                retrQ: s.retrQ,
                radioRank: s.bestRank > 0 ? s.bestRank : -1,
                key: b.key,
                pQ: Int32(truncatingIfNeeded: BrainMath.floorToLong(s.p * 10000.0 + 0.5)),
                novel: s.novel
            ))
        }
        return Plan(picks: picks, usedLiked: usedLiked, usedFamiliarNext: familiarNext && !picks.isEmpty, poolSize: n)
    }

    /// The in-memory graph of 3.6 for one plan: every seed's list, plus one edge from each track to its primary
    /// artist for the seeds, the candidates and the tracks the session remembers.
    public static func buildGraph(seeds: [Retrieval.SeedList], candidates: [Candidate], session: SessionState) -> Graph {
        var b = Graph.Builder()
        for seed in seeds {
            b.addList(seed: seed.seedRid, rids: seed.rids, factor: seed.edgeFactor)
            b.addTrack(rid: seed.seedRid, primaryAid: seed.seedAid)
        }
        for c in candidates { b.addTrack(rid: c.rid, primaryAid: c.aid) }
        for i in 0..<session.posCount { b.addTrack(rid: session.recentPos[i], primaryAid: session.recentPosAid[i]) }
        for i in 0..<session.negCount { b.addTrack(rid: session.recentNeg[i], primaryAid: session.recentNegAid[i]) }
        for i in 0..<session.anchorCount { b.addTrack(rid: session.anchors[i], primaryAid: session.anchorsAid[i]) }
        return b.build()
    }

    /// What the caller does to the session once a plan's picks are in the queue.
    public static func consume(_ session: inout SessionState, _ plan: Plan) {
        if plan.usedLiked { session.likedWithin = 0 }
        if plan.usedFamiliarNext { session.familiarNext = false }
    }
}
