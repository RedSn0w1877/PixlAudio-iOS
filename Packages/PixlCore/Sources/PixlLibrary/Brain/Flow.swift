// Flow ordering (docs/brain-spec.md, 6.5 `flowCost`, stage 5): the cost of putting a track after another one, from tempo, loudness
// and energy, and the energy arc a finite list follows. A transliteration of the Android `:brain` module's `Flow.kt` (`flow.jsonl`).
// It is subtracted from a slot's value in `ListBuilder`, so a list steps smoothly instead of jumping from a ballad to drum and bass;
// it never overrides a hard rule, and it is small next to the score, so taste still decides and flow breaks near-ties.
//
//   flowCost(i)  = 0.15 * max(0, tempoDist(prev, i) - 0.17) + min(0.15, 0.05 * max(0, |gainPrev - gain_i| - 4) / 4)
//                + min(0.1, 0.1 * max(0, |energyPrev - energy_i| - 32) / 64)                       (stage 5)
//                + arc(i)                                                                            (finite lists, stage 5)
//   tempoDist    = min over k in {0.5, 1, 2} of |log2(bpm_a * k / bpm_b)|
//   arc(i)       = min(0.1, 0.1 * max(0, |energy_i - target(t)| - 20) / 64),  t = slot / (count - 1)
//   target(t)    = mid + 36 * shape(t);  shape = -0.5 + t / 0.65 up to t = 0.65, then 0.5 - 0.8 (t - 0.65) / 0.35
//   mid          = the median energy of the candidates whose energy is known (the lower middle for an even count)
//
// A value that is unknown on either side costs 0. `prev` is the slot before, or `Context.lead` for the first one.

public enum Flow {
    public static let tempoW = 0.15
    public static let tempoFree = 0.17
    public static let gainW = 0.05
    public static let gainFreeDb = 4.0
    public static let gainMax = 0.15
    public static let energyW = 0.1
    public static let energyFree = 32
    public static let energyMax = 0.1
    public static let arcW = 0.1
    public static let arcFree = 20
    public static let arcAmplitude = 36.0
    public static let arcPeak = 0.65

    /// What flow reads about one track. Unknown: tempo 0, gain `TrackDna.gainUnknown`, energy -1.
    public struct Facts: Sendable, Equatable {
        public var tempoBpmX10: Int
        public var gainDbX10: Int
        public var energy: Int

        public init(tempoBpmX10: Int, gainDbX10: Int, energy: Int) {
            self.tempoBpmX10 = tempoBpmX10
            self.gainDbX10 = gainDbX10
            self.energy = energy
        }

        public static let unknown = Facts(tempoBpmX10: 0, gainDbX10: TrackDna.gainUnknown, energy: -1)
    }

    /// The facts of a list's candidates and of what plays before it. `arc` is for finite lists (mixes): the energy rises to a peak
    /// about two thirds in and settles at the end. Autoplay and stations have no end, so no arc, only smooth steps.
    public struct Context: Sendable {
        public let facts: [Int64: Facts]
        public let lead: Facts
        public let arc: Bool
        /// The middle of the arc. Computed once.
        public let mid: Int

        public init(facts: [Int64: Facts], lead: Facts = .unknown, arc: Bool = false) {
            self.facts = facts
            self.lead = lead
            self.arc = arc
            mid = Flow.median(facts)
        }

        public func of(_ rid: Int64) -> Facts { facts[rid] ?? .unknown }
    }

    /// The lower median of the known energies (sorted, so the map's order cannot reach the result); -1 for none.
    public static func median(_ facts: [Int64: Facts]) -> Int {
        var e: [Int] = []
        e.reserveCapacity(facts.count)
        for f in facts.values where f.energy >= 0 { e.append(f.energy) }
        if e.isEmpty { return -1 }
        e.sort()
        return e[(e.count - 1) / 2]
    }

    /// `min over k in {0.5, 1, 2} of |log2(a * k / b)|`; 0 when either is unknown.
    public static func tempoDist(_ aX10: Int, _ bX10: Int) -> Double {
        if aX10 <= 0 || bX10 <= 0 { return 0.0 }
        let a = Double(aX10)
        let b = Double(bX10)
        var best = BrainMath.abs(BrainMath.log2(a / b))
        let half = BrainMath.abs(BrainMath.log2(a * 0.5 / b))
        if half < best { best = half }
        let twice = BrainMath.abs(BrainMath.log2(a * 2.0 / b))
        if twice < best { best = twice }
        return best
    }

    /// The step from `prev` to `next`: tempo, loudness and energy.
    public static func step(_ prev: Facts, _ next: Facts) -> Double {
        var cost = 0.0
        let td = tempoDist(prev.tempoBpmX10, next.tempoBpmX10)
        if td > tempoFree { cost += tempoW * (td - tempoFree) }
        if prev.gainDbX10 != TrackDna.gainUnknown && next.gainDbX10 != TrackDna.gainUnknown {
            let dg = BrainMath.abs(Double(prev.gainDbX10 - next.gainDbX10) / 10.0)
            if dg > gainFreeDb { cost += BrainMath.min(gainMax, gainW * (dg - gainFreeDb) / gainFreeDb) }
        }
        if prev.energy >= 0 && next.energy >= 0 {
            let de = prev.energy > next.energy ? prev.energy - next.energy : next.energy - prev.energy
            if de > energyFree { cost += BrainMath.min(energyMax, energyW * Double(de - energyFree) / 64.0) }
        }
        return cost
    }

    /// The arc's energy at slot `slot` of `count`; -1 when there is no arc (no known energy, or one slot).
    public static func target(_ mid: Int, _ slot: Int, _ count: Int) -> Int {
        if mid < 0 || count < 2 { return -1 }
        let t = Double(slot) / Double(count - 1)
        let shape = t <= arcPeak ? -0.5 + t / arcPeak : 0.5 - 0.8 * (t - arcPeak) / (1.0 - arcPeak)
        let v = Int(BrainMath.floorToLong(Double(mid) + arcAmplitude * shape + 0.5))
        return v < 0 ? 0 : (v > 255 ? 255 : v)
    }

    /// What the arc costs a track of energy `energy` at slot `slot`.
    public static func arc(_ mid: Int, _ slot: Int, _ count: Int, _ energy: Int) -> Double {
        if energy < 0 { return 0.0 }
        let target = target(mid, slot, count)
        if target < 0 { return 0.0 }
        let d = energy > target ? energy - target : target - energy
        if d <= arcFree { return 0.0 }
        return BrainMath.min(arcW, arcW * Double(d - arcFree) / 64.0)
    }

    /// The whole flow cost of `next` in slot `slot` of a list of `count` after `prev`.
    public static func cost(_ ctx: Context, _ prev: Facts, _ next: Facts, _ slot: Int, _ count: Int) -> Double {
        var c = step(prev, next)
        if ctx.arc { c += arc(ctx.mid, slot, count, next.energy) }
        return c
    }

    /// How rough a finished order is: the sum of `step` over consecutive tracks (the golden files and the tests compare orders with
    /// it; the planner never calls it).
    public static func roughness(_ order: [Facts]) -> Double {
        var s = 0.0
        var i = 1
        while i < order.count {
            s += step(order[i - 1], order[i])
            i += 1
        }
        return s
    }
}
