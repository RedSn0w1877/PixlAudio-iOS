// Plans Daily Mix and Your Mix (docs/brain-spec.md, 6.2, 6.4, 8.2; stage 2a): the listener's own music and music they
// do not have yet, in one list. It needs no atlas and no islands: the pool is the library tracks the app shortlisted
// plus the cached radios of the listener's own tracks, and the order is the brain scorer (`Ranker`, weights `M0`) under
// the hard constraints of 6.4. A transliteration of the Android `:brain` module's `MixPlanner.kt`.
//
// What it adds to `StationPlanner` (which it runs, in `StationPlanner.modeMix`):
//  - the novelty share of 8.2 times the Familiar / Blend / Discover switch;
//  - the repetition budget (`Repetition`): nothing another mix of the same day holds, a penalty for what was served
//    often in the last 30 days;
//  - a fresh session: a skip a minute ago does not reshuffle a mix that was built this morning.
//
// Pure: the same affinity tables, pool and request give the same list on both platforms.

/// The mix planner.
public enum MixPlanner {
    public static let kindDaily: Int32 = 0
    public static let kindYour: Int32 = 1
    /// First Listen (6.2, stage 2b): weekly, music never played here.
    public static let kindFirstListen: Int32 = 2

    /// A Daily Mix of one island: every track must be at least this close to it (6.2).
    public static let islandFloor = 0.2

    /// The novelty share of a Daily Mix of an island: `clip(nuLong, 0.15, 0.40)` (6.2).
    public static let islandNuMin = 0.15
    public static let islandNuMax = 0.40

    /// `lambda` of 6.5 across islands.
    public static let lambdaAcross = 0.6

    /// A Daily Mix holds 30 tracks, ending on a familiar one; Your Mix starts with 60 and is endless.
    public static let dailyCount = 30
    public static let yourCount = 60

    /// The listener's novelty appetite before stage 3 learns one (5.10: 0.25 with no history).
    public static let nu0: Double = 0.25

    /// Your Mix gives new music less room than a Daily Mix does (6.2: `0.8 * nuLong`).
    public static let yourFactor: Double = 0.8

    /// The width of the jitter every candidate gets in the value of one list: `jitter * (u - 0.5)` with `u` from
    /// `splitmix64(rid xor tieSeed)`. The spec's tie-break only separates exact ties, so a mix built twice from the
    /// same state would be the same list and "Regenerate" (8.2) would do nothing. A day's list is stable (the seed is
    /// the day's); the next day, and a regenerate, draw another.
    public static let jitter: Double = 1.0

    /// The most any switch position may push the share of new music to.
    public static let nuMax: Double = 0.6

    /// An edge read back from the persisted graph (`graph_edge`): both ends are recording ids.
    public struct Edge: Sendable, Equatable {
        public var a: Int64
        public var b: Int64
        public var weight: Double

        public init(a: Int64, b: Int64, weight: Double) {
            self.a = a
            self.b = b
            self.weight = weight
        }
    }

    public struct Request: Sendable {
        public var kind: Int32
        /// The pool: library shortlist and radio rows, blocked and muted music already removed (5.11).
        public var candidates: [Candidate]
        /// The lists of the listener's own tracks the novel candidates came from, best seed first.
        public var seeds: [Retrieval.SeedList]
        public var nowMs: Int64
        public var tzOffsetMin: Int32
        /// The Familiar / Blend / Discover switch: 0.4 / 1.0 / 2.0 (5.10).
        public var nuMultiplier: Double
        /// The install's random salt: lists differ between listeners.
        public var salt: Int64
        /// 0 for the list of the day; a "Regenerate" draws a new number (8.2).
        public var regenerate: Int32
        /// Held by another mix of the same day, or ignored three times: never picked.
        public var excludedRids: Set<Int64>
        /// From the served log: how often each recording was served in a generated list in the last 30 days.
        public var servedTimes: [Int64: Int32]
        /// Persisted edges between the pool's recordings and the seeds' (3.6, `graph_edge`).
        public var edges: [Edge]
        /// 0 for the size of the kind.
        public var count: Int
        /// The width of the per-list jitter (`MixPlanner.jitter`); a different one only to measure what it costs.
        public var jitter: Double
        /// The served-log penalty at three serves or more (`Repetition.maxPenalty`).
        public var servedMax: Double
        /// Stage 2b: the listener's islands. With them the island features (5, 6, 19) are live.
        public var islands: IslandContext?
        /// A Daily Mix of one island: the index in `islands`, or -1 (the one Daily Mix of stage 2a).
        public var islandIdx: Int
        /// Stage 2b: the graph embeddings (version of `FastRp`), for the diversity term.
        public var embeddings: Embeddings?
        /// Stage 2b: tag vectors by rid, for the diversity term.
        public var tagsByRid: [Int64: Tags.Vector]
        /// Stage 3: which weights rank the list; nil is the prior `M0` (see `StationPlanner.Request.ranking`).
        public var ranking: Ranker.WeightSource?

        public init(kind: Int32, candidates: [Candidate], seeds: [Retrieval.SeedList], nowMs: Int64, tzOffsetMin: Int32,
                    nuMultiplier: Double = 1.0, salt: Int64 = 0, regenerate: Int32 = 0, excludedRids: Set<Int64> = [],
                    servedTimes: [Int64: Int32] = [:], edges: [Edge] = [], count: Int = 0,
                    jitter: Double = MixPlanner.jitter, servedMax: Double = Repetition.maxPenalty,
                    islands: IslandContext? = nil, islandIdx: Int = -1, embeddings: Embeddings? = nil,
                    tagsByRid: [Int64: Tags.Vector] = [:]) {
            self.islands = islands
            self.islandIdx = islandIdx
            self.embeddings = embeddings
            self.tagsByRid = tagsByRid
            self.kind = kind
            self.candidates = candidates
            self.seeds = seeds
            self.nowMs = nowMs
            self.tzOffsetMin = tzOffsetMin
            self.nuMultiplier = nuMultiplier
            self.salt = salt
            self.regenerate = regenerate
            self.excludedRids = excludedRids
            self.servedTimes = servedTimes
            self.edges = edges
            self.count = count
            self.jitter = jitter
            self.servedMax = servedMax
        }
    }

    public static func countOf(_ kind: Int32) -> Int { kind == kindYour ? yourCount : dailyCount }

    /// The share of the slots given to music the listener does not have (8.2, 5.10).
    public static func nuOf(_ kind: Int32, multiplier: Double) -> Double {
        let base = kind == kindYour ? nu0 * yourFactor : nu0
        return BrainMath.clip(base * multiplier, 0.0, nuMax)
    }

    /// The novelty share of one island's Daily Mix.
    public static func nuOfIsland(multiplier: Double) -> Double {
        BrainMath.clip(nu0 * multiplier, islandNuMin, islandNuMax)
    }

    /// The surface a kind of mix is logged under.
    public static func surfaceOf(_ kind: Int32) -> Int32 {
        kind == kindYour ? Surface.yourMix : (kind == kindFirstListen ? Surface.namedMix : Surface.dailyMix)
    }

    /// What breaks ties: the same on the same local day, different after "Regenerate" and between installs.
    public static func tieSeedOf(_ request: Request) -> Int64 {
        let day = Repetition.mixDay(request.nowMs, tzOffsetMin: request.tzOffsetMin)
        let island: Int64 = request.islandIdx >= 0 ? Int64(request.islandIdx + 1) &* 65536 : 0
        let inner = Int64(bitPattern: BrainHash.splitmix64(
            UInt64(bitPattern: day &* 4 &+ Int64(request.kind) &+ Int64(request.regenerate) &* 1024 &+ island)))
        return Int64(bitPattern: BrainHash.splitmix64(UInt64(bitPattern: request.salt ^ inner)))
    }

    public static func plan(_ request: Request, affinity: Affinity.State) -> StationPlanner.Plan {
        let session = SessionState()
        var builder = Graph.Builder()
        for seed in request.seeds {
            builder.addList(seed: seed.seedRid, rids: seed.rids, factor: seed.edgeFactor)
            builder.addTrack(rid: seed.seedRid, primaryAid: seed.seedAid)
        }
        for c in request.candidates { builder.addTrack(rid: c.rid, primaryAid: c.aid) }
        for e in request.edges { builder.addEdge(e.a, e.b, weight: e.weight) }
        let graph = builder.build()
        let kind = request.kind
        let islands = request.islands
        var candidates = request.candidates
        var calibration: Calibration?
        var lambda = ListBuilder.lambdaDefault
        var nu = nuOf(kind, multiplier: request.nuMultiplier)
        if let islands, !islands.islands.isEmpty {
            if request.islandIdx >= 0 && request.islandIdx < islands.islands.count {
                // A Daily Mix of one island: every track must be close to it (6.2).
                let island = islands.islands[request.islandIdx]
                var kept: [Candidate] = []
                kept.reserveCapacity(candidates.count)
                for c in candidates {
                    guard let p = c.point else { continue }
                    if Islands.similarity(island, p) >= islandFloor { kept.append(c) }
                }
                candidates = kept
                nu = nuOfIsland(multiplier: request.nuMultiplier)
            } else if kind == kindYour && islands.islands.count > 1 {
                // Your Mix: every island, kept in the listener's proportions (6.5).
                calibration = Calibration(islands.islands.map { $0.weight })
                lambda = lambdaAcross
                var placed: [Candidate] = []
                placed.reserveCapacity(candidates.count)
                for c in candidates { placed.append(c.withIsland(islands.best(c.point).index)) }
                candidates = placed
            }
        }
        var simSource: (any SimilaritySource)?
        if islands != nil && (request.embeddings != nil || !request.tagsByRid.isEmpty) {
            simSource = SimilarityIndex(graph, request.embeddings, request.tagsByRid)
        }
        let first = kind == kindFirstListen
        return StationPlanner.plan(
            StationPlanner.Request(
                mode: first ? StationPlanner.modeFirstListen : StationPlanner.modeMix,
                count: request.count > 0 ? request.count : countOf(kind),
                candidates: candidates,
                seeds: request.seeds,
                nowMs: request.nowMs,
                tzOffsetMin: request.tzOffsetMin,
                nuMultiplier: request.nuMultiplier,
                tieSeed: tieSeedOf(request),
                excludedRids: request.excludedRids,
                finite: kind == kindDaily,
                nu: first ? 1.0 : nu,
                servedTimes: request.servedTimes,
                jitter: request.jitter,
                servedMax: request.servedMax,
                islands: islands,
                calibration: calibration,
                lambda: lambda,
                simSource: simSource,
                maxPerArtist: first ? 2 : 0,
                minNewArtistShare: first ? 0.4 : 0.0,
                ranking: request.ranking
            ),
            affinity: affinity,
            session: session,
            graph: graph
        )
    }
}
