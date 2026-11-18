// Affinity (docs/brain-spec.md, 5.2): for every key, decayed counts of how often what played was finished (`pos`)
// and was not (`neg`), kept twice: a 120-day half-life and a 21-day "recent" copy. A transliteration of the Android
// `:brain` module's `Affinity.kt`.
//
// Counters are Q20 integers in memory as well as on disk; every update converts to double, computes, and converts
// back, so both platforms hold the same integers after every event. `aff` and `share` are rates: being played more
// cannot by itself raise them.

/// The key families of the affinity tables (5.2). Codes are stored in the `affinity` rows: never renumber.
public enum Family {
    public static let track: Int32 = 0
    public static let artist: Int32 = 1
    public static let arm: Int32 = 2
    /// One key, `allKey`: everything the listener played.
    public static let all: Int32 = 3
    // From stage 2 and 3; reserved so the codes never move.
    public static let tag: Int32 = 4
    public static let decade: Int32 = 5
    public static let island: Int32 = 6
    public static let ctx: Int32 = 7

    public static let count: Int32 = 8

    /// The single key of `all`, and the key of every family's sum row.
    public static let allKey: Int64 = 0

    /// The stored family of a family's total row (`sum:<family>`): `sumBase` + family.
    public static let sumBase: Int32 = 16
    /// The stored family of a family's pseudo-count rows (4.4): `priorBase` + family. `posQ`, `negQ` only.
    public static let priorBase: Int32 = 32
    /// The stored family of the per-track completion counts (`Affinity.State.completions`); `posQ` is the count.
    public static let completions: Int32 = 48

    /// The shrinkage weight `a` of 5.2.
    public static func shrink(_ family: Int32) -> Double {
        if family == track { return 2.0 }
        if family == tag { return 8.0 }
        return 4.0
    }
}

/// The affinity tables and their arithmetic.
public enum Affinity {
    /// 120 days in milliseconds.
    public static let halfLifeMs: Double = 10_368_000_000.0
    /// 21 days in milliseconds.
    public static let recentHalfLifeMs: Double = 1_814_400_000.0
    /// A clock more than this far behind the newest counter means the clock jumped: rebuild.
    public static let clockJumpMs: Int64 = 48 * 60 * 60 * 1000

    public struct Counter: Sendable, Equatable {
        public var posQ: Int64
        public var negQ: Int64
        public var lastMs: Int64
        public var posRQ: Int64
        public var negRQ: Int64
        public var lastRMs: Int64

        public init(posQ: Int64 = 0, negQ: Int64 = 0, lastMs: Int64 = 0, posRQ: Int64 = 0, negRQ: Int64 = 0,
                    lastRMs: Int64 = 0) {
            self.posQ = posQ
            self.negQ = negQ
            self.lastMs = lastMs
            self.posRQ = posRQ
            self.negRQ = negRQ
            self.lastRMs = lastRMs
        }
    }

    public struct Prior: Sendable, Equatable {
        public var posQ: Int64
        public var negQ: Int64

        public init(posQ: Int64 = 0, negQ: Int64 = 0) {
            self.posQ = posQ
            self.negQ = negQ
        }
    }

    /// One `(stored family, key)` pair: the address of a row.
    public struct RowRef: Sendable, Hashable {
        public let family: Int32
        public let key: Int64
    }

    /// One stored row: the stored family code (sums 16+, pseudo-counts 32+, completions 48), the key, the counter.
    public struct Row: Sendable, Equatable {
        public let family: Int32
        public let key: Int64
        public let counter: Counter

        public init(family: Int32, key: Int64, counter: Counter) {
            self.family = family
            self.key = key
            self.counter = counter
        }
    }

    /// The affinity tables. A cache: `Replay.rebuild` reproduces it from the event log and the facts.
    public struct State: Sendable {
        var tables: [[Int64: Counter]] = Array(repeating: [:], count: Int(Family.count))
        var sums: [Counter] = Array(repeating: Counter(), count: Int(Family.count))
        var priors: [[Int64: Prior]] = Array(repeating: [:], count: Int(Family.count))

        /// Past plays with `r >= 0.8`, per rid: the `pastCompletions` of `Reward.Context`.
        public internal(set) var completions: [Int64: Int32] = [:]

        /// The newest event time any counter has seen.
        public internal(set) var newestMs: Int64 = 0

        /// Rows written since `drainTouched`; the family is the stored code (sums and completions included).
        private var touchedRows: [RowRef] = []

        /// False while a rebuild folds the whole log: nobody stores those rows one by one.
        var recordsTouched = true

        public init() {}

        mutating func touched(_ family: Int32, _ key: Int64) {
            if recordsTouched { touchedRows.append(RowRef(family: family, key: key)) }
        }

        /// The rows written since the last call, in write order; then forgets them. A row can repeat.
        public mutating func drainTouched() -> [RowRef] {
            let out = touchedRows
            touchedRows.removeAll(keepingCapacity: true)
            return out
        }

        public func counter(_ family: Int32, _ key: Int64) -> Counter? { tables[Int(family)][key] }

        public func sum(_ family: Int32) -> Counter { sums[Int(family)] }

        public func prior(_ family: Int32, _ key: Int64) -> Prior? { priors[Int(family)][key] }

        public func size(_ family: Int32) -> Int { tables[Int(family)].count }

        /// Keys of `family` in ascending order (the canonical order of 10.3, rule 2).
        public func sortedKeys(_ family: Int32) -> [Int64] { tables[Int(family)].keys.sorted() }

        public func sortedPriorKeys(_ family: Int32) -> [Int64] { priors[Int(family)].keys.sorted() }

        /// Loads one stored row; `storedFamily` is the stored family code. Unknown codes are ignored.
        public mutating func load(storedFamily: Int32, key: Int64, posQ: Int64, negQ: Int64, lastMs: Int64,
                                  posRQ: Int64, negRQ: Int64, lastRMs: Int64) {
            if storedFamily >= 0 && storedFamily < Family.count {
                tables[Int(storedFamily)][key] = Counter(posQ: posQ, negQ: negQ, lastMs: lastMs, posRQ: posRQ,
                                                         negRQ: negRQ, lastRMs: lastRMs)
                if lastMs > newestMs { newestMs = lastMs }
            } else if storedFamily >= Family.sumBase && storedFamily < Family.sumBase + Family.count {
                sums[Int(storedFamily - Family.sumBase)] = Counter(posQ: posQ, negQ: negQ, lastMs: lastMs, posRQ: posRQ,
                                                                    negRQ: negRQ, lastRMs: lastRMs)
            } else if storedFamily >= Family.priorBase && storedFamily < Family.priorBase + Family.count {
                priors[Int(storedFamily - Family.priorBase)][key] = Prior(posQ: posQ, negQ: negQ)
            } else if storedFamily == Family.completions {
                completions[key] = Int32(truncatingIfNeeded: posQ)
            }
        }

        /// Every row in canonical order: the families 0-7 by key, then the sums that hold anything (16+), the
        /// pseudo-counts (32+) by key, and the completion counts (48) by rid. This is what a store writes and what
        /// the golden vectors print.
        public func rows() -> [Row] {
            var out: [Row] = []
            for f in 0..<Family.count {
                for key in sortedKeys(f) { out.append(Row(family: f, key: key, counter: tables[Int(f)][key]!)) }
            }
            for f in 0..<Family.count {
                let s = sums[Int(f)]
                if s.posQ != 0 || s.negQ != 0 || s.lastMs != 0 {
                    out.append(Row(family: Family.sumBase + f, key: Family.allKey, counter: s))
                }
            }
            for f in 0..<Family.count {
                for key in sortedPriorKeys(f) {
                    let p = priors[Int(f)][key]!
                    out.append(Row(family: Family.priorBase + f, key: key, counter: Counter(posQ: p.posQ, negQ: p.negQ)))
                }
            }
            for rid in completions.keys.sorted() {
                out.append(Row(family: Family.completions, key: rid, counter: Counter(posQ: Int64(completions[rid]!))))
            }
            return out
        }

        /// The stored form of one row, by its stored family and key; nil when the state has no such row.
        public func row(_ ref: RowRef) -> Row? {
            let f = ref.family
            if f >= 0 && f < Family.count {
                return tables[Int(f)][ref.key].map { Row(family: f, key: ref.key, counter: $0) }
            }
            if f >= Family.sumBase && f < Family.sumBase + Family.count {
                return Row(family: f, key: Family.allKey, counter: sums[Int(f - Family.sumBase)])
            }
            if f >= Family.priorBase && f < Family.priorBase + Family.count {
                return priors[Int(f - Family.priorBase)][ref.key].map {
                    Row(family: f, key: ref.key, counter: Counter(posQ: $0.posQ, negQ: $0.negQ))
                }
            }
            if f == Family.completions {
                return completions[ref.key].map { Row(family: f, key: ref.key, counter: Counter(posQ: Int64($0))) }
            }
            return nil
        }

        public mutating func clearPriors() {
            for i in priors.indices { priors[i].removeAll() }
        }

        /// Adds pseudo-counts (4.4). They do not decay; they are recomputed from the facts at every rebuild.
        public mutating func addPrior(_ family: Int32, _ key: Int64, posQ: Int64, negQ: Int64) {
            var p = priors[Int(family)][key] ?? Prior()
            p.posQ = p.posQ &+ posQ
            p.negQ = p.negQ &+ negQ
            priors[Int(family)][key] = p
        }
    }

    public static func decay(_ dtMs: Int64, _ halfLifeMs: Double) -> Double {
        BrainMath.exp(-(BrainMath.ln2 * Double(dtMs)) / halfLifeMs)
    }

    /// One update of one key and of its family's sum key (5.2 `apply`). `part` is 1, or 0.5 for a credited artist
    /// who is not the primary one. With `c = 0` this only moves `lastMs`.
    public static func apply(_ state: inout State, family: Int32, key: Int64, r: Double, c: Double, part: Double,
                             tMs: Int64) {
        var counter = state.tables[Int(family)][key] ?? Counter()
        bump(&counter, r, c, part, tMs)
        state.tables[Int(family)][key] = counter
        bump(&state.sums[Int(family)], r, c, part, tMs)
        if tMs > state.newestMs { state.newestMs = tMs }
        state.touched(family, key)
        state.touched(Family.sumBase + family, Family.allKey)
    }

    private static func bump(_ k: inout Counter, _ r: Double, _ c: Double, _ part: Double, _ tMs: Int64) {
        // The 120-day copy.
        var pos: Double
        var neg: Double
        var g: Double
        if tMs >= k.lastMs {
            let d = (k.posQ == 0 && k.negQ == 0) ? 1.0 : decay(tMs &- k.lastMs, halfLifeMs)
            pos = BrainMath.fromQ(k.posQ) * d
            neg = BrainMath.fromQ(k.negQ) * d
            g = 1.0
            k.lastMs = tMs
        } else {
            // A late event: shrink the increment, never grow the state.
            pos = BrainMath.fromQ(k.posQ)
            neg = BrainMath.fromQ(k.negQ)
            g = decay(k.lastMs &- tMs, halfLifeMs)
        }
        k.posQ = BrainMath.toQ(pos + g * c * r * part)
        k.negQ = BrainMath.toQ(neg + g * c * (1.0 - r) * part)

        // The 21-day copy.
        if tMs >= k.lastRMs {
            let d = (k.posRQ == 0 && k.negRQ == 0) ? 1.0 : decay(tMs &- k.lastRMs, recentHalfLifeMs)
            pos = BrainMath.fromQ(k.posRQ) * d
            neg = BrainMath.fromQ(k.negRQ) * d
            g = 1.0
            k.lastRMs = tMs
        } else {
            pos = BrainMath.fromQ(k.posRQ)
            neg = BrainMath.fromQ(k.negRQ)
            g = decay(k.lastRMs &- tMs, recentHalfLifeMs)
        }
        k.posRQ = BrainMath.toQ(pos + g * c * r * part)
        k.negRQ = BrainMath.toQ(neg + g * c * (1.0 - r) * part)
    }

    /// Everything one graded event does to the tables: the track, its artists (primary 1, others 0.5), its arm when
    /// the engine served it, and the key `all`. Events that were never audible or are excluded from learning touch
    /// nothing.
    public static func applyEvent(_ state: inout State, _ e: PlayEvent, _ g: Reward.Graded, tMs: Int64) {
        if e.has(EventFlags.neverAudible) || e.has(EventFlags.learnExcluded) { return }
        if e.rid != 0 { apply(&state, family: Family.track, key: e.rid, r: g.r, c: g.c, part: 1.0, tMs: tMs) }
        if e.primaryAid != 0 {
            apply(&state, family: Family.artist, key: e.primaryAid, r: g.r, c: g.cOther, part: 1.0, tMs: tMs)
        }
        for aid in e.otherAids where aid != 0 && aid != e.primaryAid {
            apply(&state, family: Family.artist, key: aid, r: g.r, c: g.cOther, part: 0.5, tMs: tMs)
        }
        if e.arm != Arm.none {
            apply(&state, family: Family.arm, key: Int64(e.arm), r: g.r, c: g.cOther, part: 1.0, tMs: tMs)
        }
        apply(&state, family: Family.all, key: Family.allKey, r: g.r, c: g.cOther, part: 1.0, tMs: tMs)
        if g.isCompletion && e.rid != 0 {
            state.completions[e.rid] = (state.completions[e.rid] ?? 0) &+ 1
            state.touched(Family.completions, e.rid)
        }
    }

    // MARK: Reads (never write)

    private static func since(_ nowMs: Int64, _ lastMs: Int64) -> Int64 { nowMs > lastMs ? nowMs &- lastMs : 0 }

    public static func pos(_ k: Counter, nowMs: Int64) -> Double {
        k.posQ == 0 ? 0.0 : BrainMath.fromQ(k.posQ) * decay(since(nowMs, k.lastMs), halfLifeMs)
    }

    public static func neg(_ k: Counter, nowMs: Int64) -> Double {
        k.negQ == 0 ? 0.0 : BrainMath.fromQ(k.negQ) * decay(since(nowMs, k.lastMs), halfLifeMs)
    }

    public static func posRecent(_ k: Counter, nowMs: Int64) -> Double {
        k.posRQ == 0 ? 0.0 : BrainMath.fromQ(k.posRQ) * decay(since(nowMs, k.lastRMs), recentHalfLifeMs)
    }

    public static func negRecent(_ k: Counter, nowMs: Int64) -> Double {
        k.negRQ == 0 ? 0.0 : BrainMath.fromQ(k.negRQ) * decay(since(nowMs, k.lastRMs), recentHalfLifeMs)
    }

    /// The listener's base completion rate, from the key `all`: 0.5 until it has one play's worth of weight.
    public static func p0(_ state: State, nowMs: Int64) -> Double {
        guard let all = state.tables[Int(Family.all)][Family.allKey] else { return 0.5 }
        let p = pos(all, nowMs: nowMs)
        let n = neg(all, nowMs: nowMs)
        if p + n < 1.0 { return 0.5 }
        return BrainMath.clip(p / (p + n), 0.2, 0.8)
    }

    /// "Do they finish it when it plays", in -3...3, relative to their base rate `p0`. Exactly 0 for a key with no
    /// plays and no pseudo-counts.
    public static func aff(_ state: State, family: Int32, key: Int64, nowMs: Int64, p0: Double) -> Double {
        let k = state.tables[Int(family)][key]
        let prior = state.priors[Int(family)][key]
        let p = k == nil ? 0.0 : pos(k!, nowMs: nowMs)
        let n = k == nil ? 0.0 : neg(k!, nowMs: nowMs)
        let pp = prior == nil ? 0.0 : BrainMath.fromQ(prior!.posQ)
        let pn = prior == nil ? 0.0 : BrainMath.fromQ(prior!.negQ)
        if p == 0.0 && n == 0.0 && pp == 0.0 && pn == 0.0 { return 0.0 }
        return rate(p + pp, n + pn, Family.shrink(family), p0)
    }

    /// `aff` over the 21-day copy. Pseudo-counts are not recent evidence and are left out.
    public static func affRecent(_ state: State, family: Int32, key: Int64, nowMs: Int64, p0: Double) -> Double {
        guard let k = state.tables[Int(family)][key] else { return 0.0 }
        let p = posRecent(k, nowMs: nowMs)
        let n = negRecent(k, nowMs: nowMs)
        if p == 0.0 && n == 0.0 { return 0.0 }
        return rate(p, n, Family.shrink(family), p0)
    }

    private static func rate(_ pos: Double, _ neg: Double, _ a: Double, _ p0: Double) -> Double {
        let top = pos + a * p0
        let bottom = neg + a * (1.0 - p0)
        let own = BrainMath.ln(top / bottom)
        let base = BrainMath.ln(p0 / (1.0 - p0))
        return BrainMath.clip(own - base, -3.0, 3.0)
    }

    /// "How much of their listening is it": the key's weight over its family's; 0 while the family has under 1.
    public static func share(_ state: State, family: Int32, key: Int64, nowMs: Int64) -> Double {
        guard let k = state.tables[Int(family)][key] else { return 0.0 }
        let s = state.sums[Int(family)]
        let total = pos(s, nowMs: nowMs) + neg(s, nowMs: nowMs)
        if total < 1.0 { return 0.0 }
        return (pos(k, nowMs: nowMs) + neg(k, nowMs: nowMs)) / total
    }

    /// The decayed weight of everything recorded for a key (`pos + neg`): roughly "how many plays".
    public static func weight(_ state: State, family: Int32, key: Int64, nowMs: Int64) -> Double {
        guard let k = state.tables[Int(family)][key] else { return 0.0 }
        return pos(k, nowMs: nowMs) + neg(k, nowMs: nowMs)
    }

    /// When the key was last played; 0 when it never was.
    public static func lastMs(_ state: State, family: Int32, key: Int64) -> Int64 {
        state.tables[Int(family)][key]?.lastMs ?? 0
    }

    public static func isHeard(_ state: State, family: Int32, key: Int64) -> Bool {
        state.tables[Int(family)][key] != nil
    }

    /// True when the clock is far behind what the state has seen (5.2): the state must be rebuilt.
    public static func clockJumpedBack(_ state: State, nowMs: Int64) -> Bool { nowMs &+ clockJumpMs < state.newestMs }
}
