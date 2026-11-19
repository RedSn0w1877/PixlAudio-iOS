// List calibration across islands (docs/brain-spec.md, 6.5, 5.12 rule 7): a list that spans several islands keeps the
// mix the listener's taste has, so the biggest island cannot absorb every slot. A transliteration of the Android
// `:brain` module's `Calibration.kt`.
//
//     P(c)         = W_c^0.75 normalised over islands, floor 0.03 (then normalised again)
//     Q            = the island mix of the list so far, smoothed 0.99 Q + 0.01 P
//     calibGain(i) = KL(P || Q_without) - KL(P || Q_with_i)
//
// `value(i)` of the list builder adds `kappa * calibGain(i)` with `kappa = 0.4`.

/// The island mix of one list. A reference type: the list builder adds each pick to it as the list grows.
public final class Calibration: @unchecked Sendable {
    public static let floor = 0.03
    public static let kappa = 0.4

    private let p: [Double]
    private var counts: [Int]
    private var total = 0

    public init(_ islandWeights: [Double]) {
        var raw = [Double](repeating: 0.0, count: islandWeights.count)
        var sum = 0.0
        for c in 0..<raw.count {
            let w = islandWeights[c]
            raw[c] = w > 0.0 ? BrainMath.exp(0.75 * BrainMath.ln(w)) : 0.0
            sum += raw[c]
        }
        let n = raw.count
        for c in 0..<n { raw[c] = sum > 0.0 ? raw[c] / sum : 1.0 / Double(n) }
        var sum2 = 0.0
        for c in 0..<n {
            if raw[c] < Calibration.floor { raw[c] = Calibration.floor }
            sum2 += raw[c]
        }
        for c in 0..<n { raw[c] /= sum2 }
        p = raw
        counts = [Int](repeating: 0, count: islandWeights.count)
    }

    public var islands: Int { p.count }

    private func q(_ c: Int, _ extra: Int) -> Double {
        let t = total + (extra >= 0 ? 1 : 0)
        let share = t == 0 ? p[c] : Double(counts[c] + (c == extra ? 1 : 0)) / Double(t)
        return 0.99 * share + 0.01 * p[c]
    }

    private func kl(_ extra: Int) -> Double {
        var s = 0.0
        for c in 0..<p.count { s += p[c] * BrainMath.ln(p[c] / q(c, extra)) }
        return s
    }

    /// What adding a track of island `island` does to the list's mix: positive when it moves Q towards P.
    public func gain(_ island: Int) -> Double {
        if island < 0 || island >= p.count { return 0.0 }
        return kl(-1) - kl(island)
    }

    public func add(_ island: Int) {
        if island < 0 || island >= p.count { return }
        counts[island] += 1
        total += 1
    }

    /// `KL(P || Q)` of the list so far (test 5: at most 0.15 over a day).
    public func divergence() -> Double { kl(-1) }
}

/// How alike two tracks are, with embeddings and tags (docs/brain-spec.md, 5.3):
///
///     sim(a, b) = 1                                  if the same rid
///               = (0.6 * S + 0.4 * T) / (0.6 + 0.4 * hasT)
///     S         = cos_int8(e_a, e_b)  when both have an embedding of this version, else adj(a, b)
///     T, hasT   = tagdot(a, b), 1     when both have a tag vector, else 0, 0
///
/// `Similarity.sim` (the `adj` branch alone) is what the stage 1 and 2a lists use and stays as it is.
public struct SimilarityIndex: SimilaritySource {
    private let graph: Graph
    private let embeddings: Embeddings?
    private let tags: [Int64: Tags.Vector]

    public init(_ graph: Graph, _ embeddings: Embeddings?, _ tags: [Int64: Tags.Vector]) {
        self.graph = graph
        self.embeddings = embeddings
        self.tags = tags
    }

    public func sim(_ a: Int64, _ aAid: Int64, _ b: Int64, _ bAid: Int64) -> Double {
        if a == b { return 1.0 }
        let ia = embeddings?.indexOf(a) ?? -1
        let ib = embeddings?.indexOf(b) ?? -1
        let s: Double
        if ia >= 0 && ib >= 0, let embeddings {
            s = BrainMath.clip(embeddings.cosAt(ia, ib), 0.0, 1.0)
        } else {
            s = Similarity.sim(graph, a, aAid, b, bAid)
        }
        if let ta = tags[a], let tb = tags[b], !ta.isEmpty, !tb.isEmpty {
            let t = Tags.tagdot(ta, tb)
            return (0.6 * s + 0.4 * t) / 1.0
        }
        return (0.6 * s) / 0.6
    }
}
