// The feature vector of docs/brain-spec.md, 5.8 (D = 51). A transliteration of the Android `:brain` module's
// `Features.kt`. Stage 1 computes features 0, 1, 2, 3, 8, 12-18, 22, 23, 25, 26, 36, 37 and 38; every other entry
// is exactly 0, because its input does not exist yet or its prior weight is 0. A feature whose input is unknown is
// exactly 0.

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

    public init(rid: Int64, aid: Int64, albumKey: Int64 = 0, inLibrary: Bool = false, liked: Bool = false,
                fromArtistRadio: Bool = false, boostLn: Double = 0.0, fromSimilarArtist: Bool = false,
                actr: Double = 0.0) {
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
}

/// The 51 features.
public enum Features {
    public static let d = Ranker.d

    public static let bias = 0
    public static let trackAff = 1
    public static let artistAff = 2
    public static let artistAffRecent = 3
    public static let liked = 8
    public static let actr = 10
    public static let actrSq = 11
    public static let sinceLast = 12
    public static let unheardTrack = 17
    public static let unheardArtist = 18
    public static let sessPosSim = 22
    public static let sessNegSim = 23
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
                               p0: Double, allNovel: Bool, out: inout [Double]) {
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

        out[sessPosSim] = sessPosSim(c, session, graph)
        out[sessNegSim] = sessNegSim(c, session, graph)
        if session.prevCompleted { out[prevCompleted] = 1.0 }
        out[skipRun] = BrainMath.min(1.0, Double(session.skipRun) / 3.0)
        if arm != Arm.none {
            out[armAff] = Affinity.aff(affinity, family: Family.arm, key: Int64(arm), nowMs: nowMs, p0: p0) / 3.0
        }
        out[Features.retrieval] = retrieval
        if bestRank > 0 { out[radioRank] = 1.0 / BrainMath.log2(2.0 + Double(bestRank)) }
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
