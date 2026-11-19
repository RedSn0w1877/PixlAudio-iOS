// Graph embeddings (docs/brain-spec.md, 5.3): one Int8[64] vector per node, found by FastRP over the similarity graph.
// The vectors of one `version` can be compared with each other and with nothing else. Similarity is an exact integer
// dot product over precomputed integer norms, so both platforms get the same number from the same bytes. A
// transliteration of the Android `:brain` module's `Embeddings.kt`. A vector is 64 bytes, each one a signed Int8
// stored as its UInt8 bit pattern (so the same hex as Android's).

/// A table of embeddings: ids ascending, `ids.count * dim` bytes.
public struct Embeddings: Sendable {
    public static let dim = 64

    public let version: Int
    private let ids: [Int64]
    private let data: [UInt8]
    private let norms2: [Int32]

    public init(version: Int, ids: [Int64], data: [UInt8]) {
        precondition(data.count == ids.count * Embeddings.dim, "embedding table size")
        self.version = version
        self.ids = ids
        self.data = data
        var norms = [Int32](repeating: 0, count: ids.count)
        for i in 0..<ids.count {
            var s: Int32 = 0
            for j in 0..<Embeddings.dim {
                let v = Int32(Int8(bitPattern: data[i * Embeddings.dim + j]))
                s += v * v
            }
            norms[i] = s
        }
        self.norms2 = norms
    }

    /// The same embedding table, read back from storage. `ids` must be ascending.
    public static func of(version: Int, ids: [Int64], data: [UInt8]) -> Embeddings {
        Embeddings(version: version, ids: ids, data: data)
    }

    public var size: Int { ids.count }

    public func idAt(_ index: Int) -> Int64 { ids[index] }

    public func indexOf(_ id: Int64) -> Int {
        var lo = 0
        var hi = ids.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let v = ids[mid]
            if v == id { return mid }
            if v < id { lo = mid + 1 } else { hi = mid - 1 }
        }
        return -1
    }

    public func has(_ id: Int64) -> Bool { indexOf(id) >= 0 }

    /// The 64 bytes of `id`, or nil when it has none (or its vector is all zero).
    public func vector(_ id: Int64) -> [UInt8]? {
        let i = indexOf(id)
        if i < 0 || norms2[i] == 0 { return nil }
        return Array(data[(i * Embeddings.dim)..<(i * Embeddings.dim + Embeddings.dim)])
    }

    /// `cos_int8`: the exact integer dot product over the integer norms; 0 when either has no direction.
    public func cos(_ a: Int64, _ b: Int64) -> Double {
        let i = indexOf(a)
        let j = indexOf(b)
        if i < 0 || j < 0 { return 0.0 }
        return cosAt(i, j)
    }

    public func cosAt(_ i: Int, _ j: Int) -> Double {
        if norms2[i] == 0 || norms2[j] == 0 { return 0.0 }
        var dot: Int32 = 0
        for k in 0..<Embeddings.dim {
            dot += Int32(Int8(bitPattern: data[i * Embeddings.dim + k])) * Int32(Int8(bitPattern: data[j * Embeddings.dim + k]))
        }
        return Double(dot) / (BrainMath.sqrt(Double(norms2[i])) * BrainMath.sqrt(Double(norms2[j])))
    }

    /// The raw table, for storage: ids ascending and the bytes in the same order.
    public func idsCopy() -> [Int64] { ids }

    public func dataCopy() -> [UInt8] { data }

    /// `cos_int8` of two stored vectors.
    public static func cos(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var dot: Int32 = 0
        var na: Int32 = 0
        var nb: Int32 = 0
        for k in 0..<dim {
            let x = Int32(Int8(bitPattern: a[k]))
            let y = Int32(Int8(bitPattern: b[k]))
            dot += x * y
            na += x * x
            nb += y * y
        }
        if na == 0 || nb == 0 { return 0.0 }
        return Double(dot) / (BrainMath.sqrt(Double(na)) * BrainMath.sqrt(Double(nb)))
    }
}

/// FastRP over the similarity graph (5.3). No training loop and no randomness beyond a hash:
///
///     R[v][j] in { +sqrt(3), 0, -sqrt(3) }:  h = splitmix64(fnv1a64(nodeId) xor j);  h mod 6 == 0 -> +,  == 1 -> -,  else 0
///     A~ = D^-1 A (row-normalised, neighbours in ascending id order)
///     N1 = A~ R;  N2 = A~ N1;  N3 = A~ N2;   each row L2-normalised after each pass
///     E  = N2 + N3;   e = round_half_up(127 * E / ||E||)  as Int8
///
/// `fnv1a64(nodeId)` is the hash of the node id's 8 bytes, little endian. A node whose neighbours are all invisible to
/// it (a row of zeros) ends with the zero vector, which compares as "no embedding".
public enum FastRp {
    public static let version = 1
    private static let sqrt3 = BrainMath.sqrt(3.0)

    /// The sparse projection entry `R[node][j]`.
    public static func projection(_ nodeHash: UInt64, _ j: Int) -> Double {
        let h = BrainHash.splitmix64(nodeHash ^ UInt64(j))
        let m = Int(h % 6)
        return m == 0 ? sqrt3 : (m == 1 ? -sqrt3 : 0.0)
    }

    public static func nodeHash(_ id: Int64) -> UInt64 {
        let u = UInt64(bitPattern: id)
        var b = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 { b[i] = UInt8(truncatingIfNeeded: u >> UInt64(8 * i)) }
        return BrainHash.fnv1a64(bytes: b)
    }

    public static func embed(_ graph: Graph) -> Embeddings {
        let ids = graph.nodeIds()
        let n = ids.count
        let d = Embeddings.dim
        if n == 0 { return Embeddings.of(version: version, ids: ids, data: []) }
        var index: [Int64: Int] = [:]
        index.reserveCapacity(n * 2)
        for i in 0..<n { index[ids[i]] = i }
        // Neighbour indices and row-normalised weights, once.
        var nbr = [[Int]](repeating: [], count: n)
        var wts = [[Double]](repeating: [], count: n)
        for i in 0..<n {
            let nb = graph.neighboursOf(ids[i])
            let w = graph.weightsOf(ids[i])
            var total = 0.0
            for k in 0..<nb.count { total += w[k] }
            var keptN: [Int] = []
            var keptW: [Double] = []
            keptN.reserveCapacity(nb.count)
            keptW.reserveCapacity(nb.count)
            for k in 0..<nb.count {
                guard let idx = index[nb[k]] else { continue }
                keptN.append(idx)
                keptW.append(total > 0.0 ? w[k] / total : 0.0)
            }
            nbr[i] = keptN
            wts[i] = keptW
        }
        var cur = [Double](repeating: 0.0, count: n * d)
        for i in 0..<n {
            let h = nodeHash(ids[i])
            for j in 0..<d { cur[i * d + j] = projection(h, j) }
        }
        var sum = [Double](repeating: 0.0, count: n * d)
        for pass in 1...3 {
            var next = [Double](repeating: 0.0, count: n * d)
            for i in 0..<n {
                let nb = nbr[i]
                let w = wts[i]
                for k in 0..<nb.count {
                    let base = nb[k] * d
                    let wk = w[k]
                    for j in 0..<d { next[i * d + j] += wk * cur[base + j] }
                }
                var norm = 0.0
                for j in 0..<d { norm += next[i * d + j] * next[i * d + j] }
                if norm > 0.0 {
                    let inv = 1.0 / BrainMath.sqrt(norm)
                    for j in 0..<d { next[i * d + j] *= inv }
                }
            }
            cur = next
            if pass >= 2 { for x in 0..<(n * d) { sum[x] += cur[x] } }
        }
        var out = [UInt8](repeating: 0, count: n * d)
        for i in 0..<n {
            var norm = 0.0
            for j in 0..<d { norm += sum[i * d + j] * sum[i * d + j] }
            if norm <= 0.0 { continue }
            let inv = 127.0 / BrainMath.sqrt(norm)
            for j in 0..<d {
                var q = BrainMath.floorToLong(sum[i * d + j] * inv + 0.5)
                if q > 127 { q = 127 }
                if q < -127 { q = -127 }
                out[i * d + j] = UInt8(bitPattern: Int8(q))
            }
        }
        return Embeddings.of(version: version, ids: ids, data: out)
    }
}
