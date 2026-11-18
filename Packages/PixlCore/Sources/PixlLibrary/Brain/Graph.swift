// The similarity graph (docs/brain-spec.md, 3.6): one sparse undirected weighted graph over recording ids and
// artist ids. Stage 1 builds it in memory, when a pool is built, from the radio lists of the session's seeds plus
// one edge from every track to its primary artist. Nothing is persisted. A transliteration of the Android `:brain`
// module's `Graph.kt`.
//
// Each node keeps its `maxEdges` heaviest edges (ties: the smaller neighbour id). When one pair gets edges of
// several kinds, the weight is the largest.

/// The in-memory similarity graph.
public struct Graph: Sendable {
    public static let maxEdges = 64

    /// Radio seed to a row of its list.
    public static let radio: Double = 1.0
    /// Related-tab "You might also like".
    public static let related: Double = 0.8
    /// A tuning-chip radio row (stage 2).
    public static let chip: Double = 0.6
    public static let trackArtist: Double = 0.5

    public static let empty = Builder().build()

    private let neighbours: [Int64: [Int64]]
    private let weights: [Int64: [Double]]
    private let primaryArtist: [Int64: Int64]

    fileprivate init(neighbours: [Int64: [Int64]], weights: [Int64: [Double]], primaryArtist: [Int64: Int64]) {
        self.neighbours = neighbours
        self.weights = weights
        self.primaryArtist = primaryArtist
    }

    /// The primary artist of a track node; 0 when unknown.
    public func artistOf(_ rid: Int64) -> Int64 { primaryArtist[rid] ?? 0 }

    public var nodeCount: Int { neighbours.count }

    /// Neighbour ids of `node`, ascending. Empty when the node is unknown.
    public func neighboursOf(_ node: Int64) -> [Int64] { neighbours[node] ?? [] }

    public func weightsOf(_ node: Int64) -> [Double] { weights[node] ?? [] }

    private func weightIn(_ node: Int64, _ other: Int64) -> Double {
        guard let ids = neighbours[node] else { return 0.0 }
        var lo = 0
        var hi = ids.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let v = ids[mid]
            if v == other { return weights[node]![mid] }
            if v < other { lo = mid + 1 } else { hi = mid - 1 }
        }
        return 0.0
    }

    /// The weight of the edge between `a` and `b`: kept by either end. 0 when there is none.
    public func edgeWeight(_ a: Int64, _ b: Int64) -> Double { BrainMath.max(weightIn(a, b), weightIn(b, a)) }

    /// `0.5 * max over common neighbours n of min(w(a, n), w(b, n))`, over the edges each end kept.
    public func viaCommonNeighbour(_ a: Int64, _ b: Int64) -> Double {
        guard let na = neighbours[a], let nb = neighbours[b] else { return 0.0 }
        let wa = weights[a]!
        let wb = weights[b]!
        var best = 0.0
        var i = 0
        var j = 0
        while i < na.count && j < nb.count {
            let x = na[i]
            let y = nb[j]
            if x == y {
                let m = BrainMath.min(wa[i], wb[j])
                if m > best { best = m }
                i += 1
                j += 1
            } else if x < y {
                i += 1
            } else {
                j += 1
            }
        }
        return 0.5 * best
    }

    public struct Builder: Sendable {
        private var edges: [Int64: [Int64: Double]] = [:]
        private var primaryArtist: [Int64: Int64] = [:]

        public init() {}

        private mutating func put(_ a: Int64, _ b: Int64, _ w: Double) {
            if a == b || a == 0 || b == 0 { return }
            let old = edges[a]?[b]
            if old == nil || w > old! { edges[a, default: [:]][b] = w }
            let oldB = edges[b]?[a]
            if oldB == nil || w > oldB! { edges[b, default: [:]][a] = w }
        }

        /// One list: `seed` to the row at rank k (k = 1 for the first row of `rids`) with weight
        /// `factor / log2(2 + k)`. `factor` is `Graph.radio`, `related` or `chip`.
        public mutating func addList(seed: Int64, rids: [Int64], factor: Double) {
            for i in rids.indices { put(seed, rids[i], factor / BrainMath.log2(2.0 + Double(i + 1))) }
        }

        /// One stored edge (the `graph_edge` table of 3.8, read back): the pair gets `weight`, the largest when it
        /// already has one. Used for the lists the radios of earlier days left behind.
        public mutating func addEdge(_ a: Int64, _ b: Int64, weight: Double) {
            put(a, b, weight)
        }

        /// A track and its primary artist: an edge of weight `trackArtist`, and what "same artist" reads.
        public mutating func addTrack(rid: Int64, primaryAid: Int64) {
            if rid == 0 || primaryAid == 0 { return }
            if primaryArtist[rid] == nil { primaryArtist[rid] = primaryAid }
            put(rid, primaryAid, Graph.trackArtist)
        }

        public func build() -> Graph {
            var neighbours: [Int64: [Int64]] = [:]
            var weights: [Int64: [Double]] = [:]
            neighbours.reserveCapacity(edges.count)
            weights.reserveCapacity(edges.count)
            for (node, map) in edges {
                var ids = map.keys.sorted()
                if ids.count > Graph.maxEdges {
                    // Keep the heaviest; ties go to the smaller neighbour id. Order by a quantised key.
                    let order = ids.sorted { x, y in
                        let kx = BrainMath.orderKey(map[x]!)
                        let ky = BrainMath.orderKey(map[y]!)
                        if kx != ky { return kx > ky }
                        return x < y
                    }
                    ids = Array(order[0..<Graph.maxEdges])
                    ids.sort()
                }
                neighbours[node] = ids
                weights[node] = ids.map { map[$0]! }
            }
            return Graph(neighbours: neighbours, weights: weights, primaryArtist: primaryArtist)
        }
    }
}

/// How alike two tracks are, in 0...1 (docs/brain-spec.md, 5.3). Stage 1 has no embeddings and no tags, so this is
/// the `adj` branch alone: 0.8 for the same primary artist, the edge weight between the two, or half the weakest
/// link through a common neighbour.
///
/// Scale to remember: 0.8 same artist; 0.63 a seed and the first row of its radio; 0.30 its 8th row; at most 0.25
/// between two rows of one radio. So a threshold of 0.5 or 0.6 means "same primary artist", and 0.3 means "same
/// artist, or among the first 8 rows of a seed's radio".
public enum Similarity {
    public static let sameArtist: Double = 0.8

    public static func sim(_ graph: Graph, _ a: Int64, _ aArtist: Int64, _ b: Int64, _ bArtist: Int64) -> Double {
        if a == b { return 1.0 }
        var best: Double = (aArtist != 0 && aArtist == bArtist) ? sameArtist : 0.0
        let direct = BrainMath.min(1.0, graph.edgeWeight(a, b))
        if direct > best { best = direct }
        let via = graph.viaCommonNeighbour(a, b)
        if via > best { best = via }
        return best
    }

    /// `sim` with each track's primary artist read from the graph.
    public static func sim(_ graph: Graph, _ a: Int64, _ b: Int64) -> Double {
        sim(graph, a, graph.artistOf(a), b, graph.artistOf(b))
    }
}
