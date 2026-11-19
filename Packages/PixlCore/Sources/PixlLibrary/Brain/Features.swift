// The feature vector of docs/brain-spec.md, 5.8 (D = 51). A transliteration of the Android `:brain` module's
// `Features.kt`. Stage 1 computes features 0, 1, 2, 3, 8, 12-18, 22, 23, 25, 26, 36, 37 and 38; every other entry
// is exactly 0, because its input does not exist yet or its prior weight is 0. A feature whose input is unknown is
// exactly 0. Stage 2b adds features 4 and 24 when the candidate carries a tag vector (3.4).

/// One track a list could contain, by id (the core never sees a `Song`).
public struct Candidate: Sendable {
    public var rid: Int64
    /// Primary artist; 0 when unknown.
    public var aid: Int64
    /// A hash of the folded album name; 0 when unknown.
    public var albumKey: Int64
    /// True when the recording is in the listener's library (it plays from the library row).
    public var inLibrary: Bool
    /// Favourite or Spotify Liked Songs.
    public var liked: Bool
    /// True when the row came from an artist radio rather than a song radio.
    public var fromArtistRadio: Bool
    /// The listener's boost / reduce adjustments for it (5.11): `ln(product)`, 0 for none.
    public var boostLn: Double
    /// True when the row came from the top songs of an artist close to the seed's (arm SIM, 6.1).
    public var fromSimilarArtist: Bool
    /// Feature 10, `clip((B + 4) / 6, 0, 1)` of `RepeatActivation`; 0 for a track never played or an unknown history.
    public var actr: Double
    /// The track's tag vector (3.4); nil or empty when its genres are unknown (features 4 and 24 are then exactly 0).
    public var tags: Tags.Vector?
    /// The graph embedding of the track (5.3); nil when it has none.
    public var emb: [UInt8]?
    /// `popPermille` of its DNA, 0..1000; -1 unknown (feature 20 is then 0).
    public var popPermille: Int
    /// First seen as a new release in the last 28 days (feature 39; arm NEW).
    public var fresh: Bool
    /// A forgotten favourite (arm BACK, 6.1).
    public var back: Bool
    /// From an adjacent genre (arm EDGE, 6.1).
    public var edge: Bool
    /// The index of its island in the request's `Calibration`; -1 when it is in none.
    public var islandIdx: Int
    /// True when its artist is one the listener never played (First Listen's 40% rule, 6.2).
    public var artistNew: Bool

    /// The point of the track in island space (5.4); nil when it has neither an embedding nor a tag. Computed on
    /// demand (a struct cannot cache it); it is a few hundred multiplications.
    public var point: [Double]? { Islands.point(emb, tags) }

    public init(rid: Int64, aid: Int64, albumKey: Int64 = 0, inLibrary: Bool = false, liked: Bool = false,
                fromArtistRadio: Bool = false, boostLn: Double = 0.0, fromSimilarArtist: Bool = false,
                actr: Double = 0.0, tags: Tags.Vector? = nil, emb: [UInt8]? = nil, popPermille: Int = -1,
                fresh: Bool = false, back: Bool = false, edge: Bool = false, islandIdx: Int = -1,
                artistNew: Bool = false) {
        self.emb = emb
        self.popPermille = popPermille
        self.fresh = fresh
        self.back = back
        self.edge = edge
        self.islandIdx = islandIdx
        self.artistNew = artistNew
        self.tags = tags
        self.fromSimilarArtist = fromSimilarArtist
        self.actr = actr
        self.rid = rid
        self.aid = aid
        self.albumKey = albumKey
        self.inLibrary = inLibrary
        self.liked = liked
        self.fromArtistRadio = fromArtistRadio
        self.boostLn = boostLn
    }

    /// The same candidate with what the DNA and the embeddings know about it (stage 2b).
    public func withDna(emb: [UInt8]?, tags: Tags.Vector?, popPermille: Int) -> Candidate {
        var c = self
        if let tags { c.tags = tags }
        if let emb { c.emb = emb }
        if popPermille >= 0 { c.popPermille = popPermille }
        return c
    }

    /// The same candidate with the arm flags of 6.1 and the First Listen artist flag set.
    public func withFlags(fresh: Bool? = nil, back: Bool? = nil, edge: Bool? = nil, artistNew: Bool? = nil) -> Candidate {
        var c = self
        if let fresh { c.fresh = fresh }
        if let back { c.back = back }
        if let edge { c.edge = edge }
        if let artistNew { c.artistNew = artistNew }
        return c
    }

    /// The same candidate placed in island `index` of a `Calibration`.
    public func withIsland(_ index: Int) -> Candidate {
        var c = self
        c.islandIdx = index
        return c
    }
}

/// The listener's islands as the scorer reads them (5.8 features 5, 6 and 19): the best island for a track is the one
/// whose centroid is closest to its point.
public struct IslandContext: Sendable {
    public let islands: [Islands.Island]
    private let totalWeight: Double

    public init(_ islands: [Islands.Island]) {
        self.islands = islands
        var t = 0.0
        for i in islands { t += i.weight }
        totalWeight = t
    }

    public struct Best: Sendable {
        public let index: Int
        public let sim: Double
    }

    private static let none = Best(index: -1, sim: 0.0)

    /// The closest island and its similarity; index -1 for a track with no point.
    public func best(_ point: [Double]?) -> Best {
        guard let point, !islands.isEmpty else { return Self.none }
        var best = -1
        var bestSim = 0.0
        for i in 0..<islands.count {
            let s = Islands.similarity(islands[i], point)
            if best < 0 || s > bestSim { best = i; bestSim = s }
        }
        return Best(index: best, sim: bestSim)
    }

    /// `sqrt(W_c share)` of island `index`.
    public func weightFeature(_ index: Int) -> Double {
        if index < 0 || totalWeight <= 0.0 { return 0.0 }
        return BrainMath.sqrt(islands[index].weight / totalWeight)
    }
}

/// The 51 features.
public enum Features {
    public static let d = Ranker.d

    public static let bias = 0
    public static let trackAff = 1
    public static let artistAff = 2
    public static let artistAffRecent = 3
    public static let tagAff = 4
    public static let islandSim = 5
    public static let islandWeight = 6
    public static let noveltyDist = 19
    public static let pop = 20
    public static let fresh = 39
    public static let liked = 8
    public static let actr = 10
    public static let actrSq = 11
    public static let sinceLast = 12
    public static let unheardTrack = 17
    public static let unheardArtist = 18
    public static let sessPosSim = 22
    public static let sessNegSim = 23
    public static let sessTagPen = 24
    public static let prevCompleted = 25
    public static let skipRun = 26
    public static let armAff = 36
    public static let retrieval = 37
    public static let radioRank = 38

    static let hourMs: Int64 = 3_600_000

    /// Fills `out` (length `d`) for one candidate. `arm` is the arm it is served under, `retrieval` its percentile
    /// within that arm (feature 37), `bestRank` its best radio rank or 0. With `allNovel` (lists that hold only
    /// unheard music, 5.12 rule 6) features 1 and 8 are zeroed.
    public static func compute(_ c: Candidate, arm: Int32, retrieval: Double, bestRank: Int32,
                               affinity: Affinity.State, session: SessionState, graph: Graph, nowMs: Int64,
                               p0: Double, allNovel: Bool, out: inout [Double], islands: IslandContext? = nil) {
        for i in 0..<d { out[i] = 0.0 }
        out[bias] = 1.0
        if !allNovel {
            out[trackAff] = Affinity.aff(affinity, family: Family.track, key: c.rid, nowMs: nowMs, p0: p0) / 3.0
            if c.liked { out[liked] = 1.0 }
            // Repeat activation (5.6): where the listener's own point of fatigue sits (features 10 and 11).
            out[Features.actr] = c.actr
            out[actrSq] = c.actr * c.actr
        }
        if c.aid != 0 {
            out[artistAff] = Affinity.aff(affinity, family: Family.artist, key: c.aid, nowMs: nowMs, p0: p0) / 3.0
            out[artistAffRecent] = Affinity.affRecent(affinity, family: Family.artist, key: c.aid, nowMs: nowMs, p0: p0) / 3.0
        }
        if Affinity.isHeard(affinity, family: Family.track, key: c.rid) {
            let last = Affinity.lastMs(affinity, family: Family.track, key: c.rid)
            let dt: Int64 = nowMs > last ? nowMs &- last : 0
            let bucket: Int
            if dt < 2 * hourMs {
                bucket = 0
            } else if dt < 24 * hourMs {
                bucket = 1
            } else if dt < 168 * hourMs {
                bucket = 2
            } else if dt < 720 * hourMs {
                bucket = 3
            } else {
                bucket = 4
            }
            out[sinceLast + bucket] = 1.0
        } else {
            out[unheardTrack] = 1.0
        }
        if c.aid != 0 && !Affinity.isHeard(affinity, family: Family.artist, key: c.aid) { out[unheardArtist] = 1.0 }

        if let tags = c.tags, !tags.isEmpty {
            out[Features.tagAff] = tagAff(tags, affinity, nowMs: nowMs, p0: p0)
            out[Features.sessTagPen] = sessTagPen(tags, session)
        }

        out[sessPosSim] = sessPosSim(c, session, graph)
        out[sessNegSim] = sessNegSim(c, session, graph)
        if session.prevCompleted { out[prevCompleted] = 1.0 }
        out[skipRun] = BrainMath.min(1.0, Double(session.skipRun) / 3.0)
        if arm != Arm.none {
            out[armAff] = Affinity.aff(affinity, family: Family.arm, key: Int64(arm), nowMs: nowMs, p0: p0) / 3.0
        }
        out[Features.retrieval] = retrieval
        if c.popPermille >= 0 { out[pop] = Double(c.popPermille) / 1000.0 - 0.5 }
        if c.fresh { out[Features.fresh] = 1.0 }
        if let islands {
            let best = islands.best(c.point)
            if best.index >= 0 {
                out[islandSim] = best.sim
                out[islandWeight] = islands.weightFeature(best.index)
                // Novelty distance: how far an unheard track sits from every island the listener has (5.8 feature 19).
                if !Affinity.isHeard(affinity, family: Family.track, key: c.rid) { out[noveltyDist] = 1.0 - best.sim }
            }
        }
        if bestRank > 0 { out[radioRank] = 1.0 / BrainMath.log2(2.0 + Double(bestRank)) }
    }

    /// Feature 4: `sum over tags of (w / 255) * aff(tag) / 3`, summed in the tag vector's order.
    public static func tagAff(_ tags: Tags.Vector, _ affinity: Affinity.State, nowMs: Int64, p0: Double) -> Double {
        var sum = 0.0
        for t in tags.tags {
            sum += (Double(t.q) / 255.0) * (Affinity.aff(affinity, family: Family.tag, key: Int64(t.atlasId), nowMs: nowMs, p0: p0) / 3.0)
        }
        return sum
    }

    /// Feature 24: `min(1, sum over tags of (w / 255) * tagPen[tag])`.
    public static func sessTagPen(_ tags: Tags.Vector, _ session: SessionState) -> Double {
        if session.tagPen.isEmpty { return 0.0 }
        var sum = 0.0
        for t in tags.tags {
            guard let pen = session.tagPen[t.atlasId] else { continue }
            sum += (Double(t.q) / 255.0) * pen
        }
        return BrainMath.min(1.0, sum)
    }

    /// Feature 22: `max over j of 0.7^j * sim(i, pos_j)`.
    public static func sessPosSim(_ c: Candidate, _ session: SessionState, _ graph: Graph) -> Double {
        var best = 0.0
        var w = 1.0
        for j in 0..<session.posCount {
            let v = w * Similarity.sim(graph, c.rid, c.aid, session.recentPos[j], session.recentPosAid[j])
            if v > best { best = v }
            w *= 0.7
        }
        return best
    }

    /// Feature 23: `max over j of h_j * 0.8^j * sim(i, neg_j)`.
    public static func sessNegSim(_ c: Candidate, _ session: SessionState, _ graph: Graph) -> Double {
        var best = 0.0
        var w = 1.0
        for j in 0..<session.negCount {
            let s = Similarity.sim(graph, c.rid, c.aid, session.recentNeg[j], session.recentNegAid[j])
            let v = session.recentNegH[j] * w * s
            if v > best { best = v }
            w *= 0.8
        }
        return best
    }
}
