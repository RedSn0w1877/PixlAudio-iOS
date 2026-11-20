// Context (docs/brain-spec.md, 5.10): four dayparts (05-11, 11-17, 17-22, 22-05 local) times weekday and weekend make eight
// buckets `b`; the keys are the listener's islands. A transliteration of the Android `:brain` module's `ContextLift.kt`;
// `context.jsonl` pins it bit for bit.
//
// ```
// n[k][b] += c * r, decayed with H = 120 days ;  N[b] = sum_k n[k][b] ;  P(k) = sum_b n[k][b] / sum_b N[b]
// lift(k | b) = clip( ln( (n[k][b] + 20 * P(k)) / (N[b] + 20) ) - ln P(k), -1.5, 1.5 )   ;  0 unless the bucket has at least 50 plays
// ```
//
// The table is a pure function of the plays and of now: `Builder` reads the log once, so nothing here needs its own
// persistence. An imported play has no timezone; its hour is read with the device's offset now (the caller resolves it).
//
// The dayparts here are the spec's. The Home plan's own daypart (`HomePlanner.daypart`, stage 2) cuts morning at 12, not 11;
// the two agree except for the hour 11, and each is used only for what it was written for (Android deviation 194).

/// Context lift.
public enum ContextLift {
    public static let buckets = 8

    /// Half-life of the counts, in days.
    public static let halfLifeDays = 120.0

    /// The smoothing mass of the lift formula.
    public static let smooth = 20.0

    public static let liftClip = 1.5

    /// A bucket with fewer plays than this has no lift: 0 for every island.
    public static let minPlays = 50

    public static let morning = 0
    public static let day = 1
    public static let evening = 2
    public static let night = 3

    /// 05-11 morning, 11-17 day, 17-22 evening, 22-05 night, by the local hour.
    public static func daypart(_ startedAtMs: Int64, tzOffsetMin: Int32) -> Int {
        let hour = Int(BrainMath.floorMod(BrainMath.floorDiv(startedAtMs &+ Int64(tzOffsetMin) &* 60_000, 3_600_000), 24))
        if hour >= 5 && hour < 11 { return morning }
        if hour >= 11 && hour < 17 { return day }
        if hour >= 17 && hour < 22 { return evening }
        return night
    }

    /// `daypart + 4 * weekend`: 0..7.
    public static func bucket(_ startedAtMs: Int64, tzOffsetMin: Int32) -> Int {
        daypart(startedAtMs, tzOffsetMin: tzOffsetMin) + (BrainMath.isWeekend(startedAtMs, tzOffsetMin: tzOffsetMin) ? 4 : 0)
    }

    public static func isWeekendBucket(_ bucket: Int) -> Bool { bucket >= 4 }

    public static func daypartOfBucket(_ bucket: Int) -> Int { bucket % 4 }

    /// The counts of every island in every bucket, and what the lift reads from them.
    public struct Table: Sendable {
        /// Island ids, ascending.
        public let islandIds: [Int]
        /// `n[k][b]` by index in `islandIds`.
        private let n: [[Double]]
        /// `N[b]`.
        private let total: [Double]
        /// How many plays each bucket holds (not decayed).
        public let plays: [Int]
        private let grand: Double

        init(islandIds: [Int], n: [[Double]], total: [Double], plays: [Int]) {
            self.islandIds = islandIds
            self.n = n
            self.total = total
            self.plays = plays
            var s = 0.0
            for b in 0..<ContextLift.buckets { s += total[b] }
            grand = s
        }

        public func indexOf(_ islandId: Int) -> Int {
            var lo = 0
            var hi = islandIds.count - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let v = islandIds[mid]
                if v == islandId { return mid }
                if v < islandId { lo = mid + 1 } else { hi = mid - 1 }
            }
            return -1
        }

        /// True when the bucket has enough plays for a lift to mean anything.
        public func hasLift(_ bucket: Int) -> Bool { bucket >= 0 && bucket < ContextLift.buckets && plays[bucket] >= ContextLift.minPlays }

        /// `lift(k | b)`: 0 for an island the table does not know, a bucket under `minPlays` plays, or an island with no
        /// counts at all.
        public func lift(_ islandId: Int, _ bucket: Int) -> Double {
            if !hasLift(bucket) { return 0.0 }
            let k = indexOf(islandId)
            if k < 0 || grand <= 0.0 { return 0.0 }
            var row = 0.0
            for b in 0..<ContextLift.buckets { row += n[k][b] }
            let pk = row / grand
            if !(pk > 0.0) { return 0.0 }
            let v = BrainMath.ln((n[k][bucket] + ContextLift.smooth * pk) / (total[bucket] + ContextLift.smooth)) - BrainMath.ln(pk)
            return BrainMath.clip(v, -ContextLift.liftClip, ContextLift.liftClip)
        }

        /// The island with the largest `W_c * exp(lift)` in `bucket` (6.2, the daypart mix), among `candidates` (island id and
        /// its weight `W_c`); ties to the lower id. -1 when `candidates` is empty or the bucket has no lift yet.
        public func leader(_ bucket: Int, _ candidates: [(id: Int, weight: Double)]) -> Int {
            if !hasLift(bucket) { return -1 }
            var best = -1
            var bestScore = 0.0
            for c in candidates.sorted(by: { $0.id < $1.id }) {
                let score = c.weight * BrainMath.exp(lift(c.id, bucket))
                if best < 0 || score > bestScore {
                    best = c.id
                    bestScore = score
                }
            }
            return best
        }
    }

    /// Collects plays, then makes the `Table`. Deterministic: islands are summed in ascending id order.
    public struct Builder: Sendable {
        private let nowMs: Int64
        private var rows: [Int: [Double]] = [:]
        private var plays = [Int](repeating: 0, count: ContextLift.buckets)

        public init(nowMs: Int64) { self.nowMs = nowMs }

        /// One graded play of an island, with its trust `c` and reward `r`; `tzOffsetMin` is the offset to read its hour with.
        /// A play in the future counts as now. A play with no island, or no trust, is not counted (the bucket's play count is
        /// plays that have an island).
        public mutating func add(islandId: Int, startedAtMs: Int64, tzOffsetMin: Int32, c: Double, r: Double) {
            if islandId < 0 || !(c > 0.0) || !BrainMath.isFinite(c) || !BrainMath.isFinite(r) { return }
            let b = ContextLift.bucket(startedAtMs, tzOffsetMin: tzOffsetMin)
            plays[b] += 1
            let weight = c * BrainMath.clip(r, 0.0, 1.0)
            if !(weight > 0.0) { return }
            let t = startedAtMs > nowMs ? nowMs : startedAtMs
            let w = weight * Affinity.decay(nowMs - t, ContextLift.halfLifeDays * Double(BrainMath.dayMs))
            var row = rows[islandId] ?? [Double](repeating: 0.0, count: ContextLift.buckets)
            row[b] += w
            rows[islandId] = row
        }

        public func build() -> Table {
            let ids = rows.keys.sorted()
            let n = ids.map { rows[$0] ?? [Double](repeating: 0.0, count: ContextLift.buckets) }
            var total = [Double](repeating: 0.0, count: ContextLift.buckets)
            for k in ids.indices { for b in 0..<ContextLift.buckets { total[b] += n[k][b] } }
            return Table(islandIds: ids, n: n, total: total, plays: plays)
        }
    }
}
