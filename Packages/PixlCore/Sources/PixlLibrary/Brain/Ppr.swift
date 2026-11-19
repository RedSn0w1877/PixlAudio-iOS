// Personalised PageRank retrieval (docs/brain-spec.md, 6.1, stage 2), in the deterministic power-iteration form:
//
//     seeds S = an island's top 30 tracks by w_t ;  p0[t] = w_t / sum(w)
//     repeat 4 times:  p <- 0.20 * p0 + 0.80 * (A~ transposed) p ;  truncate p to its 3,000 largest entries (ties by node id)
//     ppr(t) = p[t] / sqrt(weightedDegree(t))
//
// `A~` is the row-normalised adjacency of the similarity graph. Every sum runs in ascending node id order, so both
// platforms add the same numbers in the same order. A transliteration of the Android `:brain` module's `Ppr.kt`.

public enum Ppr {
    public static let restart = 0.20
    public static let walk = 0.80
    public static let iterations = 4
    public static let keep = 3000
    public static let seeds = 30

    /// Nodes best first, with their score `ppr(t)`.
    public struct Result: Sendable {
        public let ids: [Int64]
        public let scores: [Double]
        public var size: Int { ids.count }
    }

    /// `seedIds` and `seedWeights` are parallel; a seed with a weight of 0 or less is ignored. At most `seeds` seeds
    /// count: the heaviest, ties to the smaller id.
    public static func run(_ graph: Graph, seedIds: [Int64], seedWeights: [Double], top: Int = 300) -> Result {
        var order: [Int] = []
        for i in 0..<seedIds.count where seedWeights[i] > 0.0 && seedIds[i] != 0 { order.append(i) }
        order.sort { a, b in
            let ka = BrainMath.orderKey(seedWeights[a])
            let kb = BrainMath.orderKey(seedWeights[b])
            if ka != kb { return ka > kb }
            return seedIds[a] < seedIds[b]
        }
        if order.count > seeds { order = Array(order[0..<seeds]) }
        if order.isEmpty { return Result(ids: [], scores: []) }
        var p0: [Int64: Double] = [:]
        var total = 0.0
        for i in order { total += seedWeights[i] }
        for i in order { p0[seedIds[i]] = (p0[seedIds[i]] ?? 0.0) + seedWeights[i] / total }
        let p0Sorted = p0.keys.sorted()
        var p = p0
        for _ in 0..<iterations {
            var next: [Int64: Double] = [:]
            next.reserveCapacity(p.count * 4)
            for id in p0Sorted { next[id] = restart * p0[id]! }
            for v in p.keys.sorted() {
                let mass = p[v]!
                let nb = graph.neighboursOf(v)
                if nb.isEmpty { continue }
                let w = graph.weightsOf(v)
                var deg = 0.0
                for x in w { deg += x }
                if deg <= 0.0 { continue }
                let share = walk * mass / deg
                for k in 0..<nb.count { next[nb[k]] = (next[nb[k]] ?? 0.0) + share * w[k] }
            }
            p = truncate(next)
        }
        var scores: [Int64: Double] = [:]
        scores.reserveCapacity(p.count * 2)
        var ids = p.keys.sorted()
        for id in ids {
            let mass = p[id]!
            let deg = graph.weightedDegree(id)
            scores[id] = deg > 0.0 ? mass / BrainMath.sqrt(deg) : mass
        }
        ids.sort { a, b in
            let ka = BrainMath.orderKey(scores[a]!)
            let kb = BrainMath.orderKey(scores[b]!)
            if ka != kb { return ka > kb }
            return a < b
        }
        let n = ids.count < top ? ids.count : top
        return Result(ids: Array(ids[0..<n]), scores: (0..<n).map { scores[ids[$0]]! })
    }

    private static func truncate(_ p: [Int64: Double]) -> [Int64: Double] {
        if p.count <= keep { return p }
        let ids = p.keys.sorted { a, b in
            let ka = BrainMath.orderKey(p[a]!)
            let kb = BrainMath.orderKey(p[b]!)
            if ka != kb { return ka > kb }
            return a < b
        }
        var out: [Int64: Double] = [:]
        out.reserveCapacity(keep)
        for i in 0..<keep { out[ids[i]] = p[ids[i]]! }
        return out
    }
}
