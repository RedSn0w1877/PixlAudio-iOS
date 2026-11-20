// The Home shelf bandit (docs/brain-spec.md, 5.10 "Home shelves", 8.1): a cascade bandit with one Beta posterior per (shelf
// type, daypart). A transliteration of the Android `:brain` module's `ShelfBandit.kt`; `shelfbandit.jsonl` pins it bit for bit.
//
// - Priors, pessimistic on purpose: Made for you (3, 7), On repeat (2, 8), every other shelf (1, 9).
// - Reward 1: a play of 30 s or more started from that shelf. Reward 0: the shelf was on screen for at least 1 s and the visit
//   ended, or a LOWER shelf was used. Only shelves at or above the last one seen are updated (`visit`): the listener looked
//   down the page that far.
// - The order is drawn once per daypart and then frozen (`order`); a shelf type unseen for `forceDays` days gets one forced
//   exposure.
// - With no data the fixed order of stage 2 stays: `order` answers nil until `minUpdates` shelf updates have been seen.
//
// The posteriors are a cache of the impressions: `rebuild` makes the same state from the impression rows. The learned order is
// used only while the gate has the learned weights on and is reset by "Reset what I've learned" (the caller). It has only ever
// run on synthetic data.

/// The shelf bandit.
public enum ShelfBandit {
    public static let types = 10
    public static let dayparts = 4

    /// The daypart mix shelf (stage 3); types 0..8 are `HomePlanner`'s.
    public static let daypartMix = HomePlanner.daypartMix

    /// A shelf type not seen for this many days is shown once at the top ("a forced exposure").
    public static let forceDays = 14

    /// Below this many shelf updates (all types and dayparts together) the stage 2 order stays.
    public static let minUpdates = 20

    /// A play counts as the shelf's reward from this long.
    public static let rewardPlayMs: Int64 = 30_000

    /// A shelf counts as seen after this long on screen.
    public static let seenMs: Int64 = 1_000

    public static func priorAlpha(_ type: Int32) -> Double {
        switch type {
        case HomePlanner.madeForYou: return 3.0
        case HomePlanner.onRepeat: return 2.0
        default: return 1.0
        }
    }

    public static func priorBeta(_ type: Int32) -> Double {
        switch type {
        case HomePlanner.madeForYou: return 7.0
        case HomePlanner.onRepeat: return 8.0
        default: return 9.0
        }
    }

    public struct State: Sendable {
        public var alpha: [Double]
        public var beta: [Double]
        /// The local day each type was last on screen long enough to count; `Int64.min` for never.
        public var lastSeenDay: [Int64]
        /// The `planKey` (`HomePlanner.planKey`) the frozen order was drawn for; -1 for none.
        public var frozenKey: Int64
        public var frozenOrder: [Int32]
        /// Shelf updates counted since the state was created or reset.
        public var updates: Int64

        public init(alpha: [Double], beta: [Double], lastSeenDay: [Int64], frozenKey: Int64 = -1, frozenOrder: [Int32] = [],
                    updates: Int64 = 0) {
            self.alpha = alpha
            self.beta = beta
            self.lastSeenDay = lastSeenDay
            self.frozenKey = frozenKey
            self.frozenOrder = frozenOrder
            self.updates = updates
        }

        public func isValid() -> Bool {
            let n = ShelfBandit.types * ShelfBandit.dayparts
            if alpha.count != n || beta.count != n || lastSeenDay.count != ShelfBandit.types { return false }
            for i in 0..<n {
                if !BrainMath.isFinite(alpha[i]) || !(alpha[i] > 0.0) || !BrainMath.isFinite(beta[i]) || !(beta[i] > 0.0) { return false }
            }
            for t in frozenOrder where t < 0 || Int(t) >= ShelfBandit.types { return false }
            return true
        }
    }

    private static func index(_ type: Int32, _ daypart: Int) -> Int { Int(type) * dayparts + daypart }

    public static func newState() -> State {
        let a = (0..<(types * dayparts)).map { priorAlpha(Int32($0 / dayparts)) }
        let b = (0..<(types * dayparts)).map { priorBeta(Int32($0 / dayparts)) }
        return State(alpha: a, beta: b, lastSeenDay: [Int64](repeating: Int64.min, count: types))
    }

    /// The mean of the posterior of (`type`, `daypart`).
    public static func mean(_ state: State, type: Int32, daypart: Int) -> Double {
        let i = index(type, daypart)
        return state.alpha[i] / (state.alpha[i] + state.beta[i])
    }

    /// One visit to the page, in the cascade model. `shown` are the shelf types in the order the page showed them (top first);
    /// `lastSeen` is the index of the lowest shelf that was on screen for at least `seenMs` (-1 for none); `used` the index of
    /// the shelf a play of at least `rewardPlayMs` was started from (-1 for none). Shelves from the top down to
    /// `max(lastSeen, used)` are updated: the used one with reward 1, the others with 0. Returns how many shelves were updated.
    @discardableResult
    public static func visit(_ state: inout State, daypart: Int, shown: [Int32], lastSeen: Int, used: Int, today: Int64) -> Int {
        if daypart < 0 || daypart >= dayparts { return 0 }
        let last = lastSeen > used ? lastSeen : used
        if last < 0 { return 0 }
        let end = last >= shown.count ? shown.count - 1 : last
        var n = 0
        if end < 0 { return 0 }
        for i in 0...end {
            let t = shown[i]
            if t < 0 || Int(t) >= types { continue }
            let j = index(t, daypart)
            if i == used { state.alpha[j] += 1.0 } else { state.beta[j] += 1.0 }
            state.lastSeenDay[Int(t)] = today
            state.updates += 1
            n += 1
        }
        return n
    }

    /// One draw for (`type`, `daypart`): `clip(mu + sd * gaussian12, 0, 1)` of its Beta, as in `ArmBandit.draw`.
    public static func draw(_ state: State, type: Int32, daypart: Int, _ rng: inout BrainHash.Rng) -> Double {
        let i = index(type, daypart)
        let a = state.alpha[i]
        let b = state.beta[i]
        let n = a + b
        let mu = a / n
        let sd = BrainMath.sqrt(a * b / (n * n * (n + 1.0)))
        return BrainMath.clip(mu + sd * rng.gaussian12(), 0.0, 1.0)
    }

    /// True once the posteriors hold enough evidence to reorder the page.
    public static func hasData(_ state: State) -> Bool { state.updates >= Int64(minUpdates) }

    /// The order of the shelf types `types` (given in stage 2's fixed order) for the page of `planKey`: drawn once per daypart
    /// and then frozen in `state`, so a shelf does not move while the listener is on it. Nil while there is no data (`hasData`),
    /// meaning "keep the fixed order". A type in `types` the frozen order does not know goes where it stands in the fixed
    /// order; one it holds that is not in `types` is dropped. A type last seen `forceDays` or more days ago (and seen at some
    /// time) is moved to the top once, and counted as seen from `today` so it is not forced again for another `forceDays` days.
    public static func order(_ state: inout State, planKey: Int64, daypart: Int, types shelfTypes: [Int32], seed: Int64,
                             today: Int64) -> [Int32]? {
        if !hasData(state) { return nil }
        if state.frozenKey != planKey || state.frozenOrder.isEmpty {
            var rng = BrainHash.Rng(seed: UInt64(bitPattern: seed))
            var theta = [Double](repeating: 0.0, count: shelfTypes.count)
            for i in shelfTypes.indices { theta[i] = draw(state, type: shelfTypes[i], daypart: daypart, &rng) }
            let idx = shelfTypes.indices.sorted { a, b in
                let ka = BrainMath.orderKey(theta[a])
                let kb = BrainMath.orderKey(theta[b])
                if ka != kb { return ka > kb }
                return a < b
            }
            var drawn: [Int32] = idx.map { shelfTypes[$0] }
            // One forced exposure: the type unseen the longest (and seen once), if it is 14 days or more.
            var forced: Int32 = -1
            var oldest = Int64.max
            for t in shelfTypes {
                if t < 0 || Int(t) >= types { continue }
                let seen = state.lastSeenDay[Int(t)]
                if seen == Int64.min || today - seen < Int64(forceDays) { continue }
                if seen < oldest {
                    oldest = seen
                    forced = t
                }
            }
            if forced >= 0 {
                if let at = drawn.firstIndex(of: forced) { drawn.remove(at: at) }
                drawn.insert(forced, at: 0)
                state.lastSeenDay[Int(forced)] = today
            }
            state.frozenKey = planKey
            state.frozenOrder = drawn
        }
        var out: [Int32] = []
        for t in state.frozenOrder where shelfTypes.contains(t) { out.append(t) }
        // A type the frozen order never held: at the place it has in the fixed order.
        for pos in shelfTypes.indices {
            let t = shelfTypes[pos]
            if !out.contains(t) { out.insert(t, at: pos < out.count ? pos : out.count) }
        }
        return out
    }

    /// One impression row of a visit: rows of one visit share `visitId`.
    public struct VisitRow: Sendable {
        public let visitId: Int64
        public let type: Int32
        public let daypart: Int
        public let position: Int
        public let seen: Bool
        public let used: Bool
        public let day: Int64

        public init(visitId: Int64, type: Int32, daypart: Int, position: Int, seen: Bool, used: Bool, day: Int64) {
            self.visitId = visitId
            self.type = type
            self.daypart = daypart
            self.position = position
            self.seen = seen
            self.used = used
            self.day = day
        }
    }

    /// Makes the posteriors from impression rows alone: `rows` are grouped by the visit they belong to (rows of one visit share
    /// `visitId`), oldest visit first, each visit's rows in page order. Used to rebuild the state after a reset of the saved one.
    public static func rebuild(_ rows: [VisitRow]) -> State {
        var state = newState()
        var i = 0
        while i < rows.count {
            var j = i
            while j < rows.count && rows[j].visitId == rows[i].visitId { j += 1 }
            let group = rows[i..<j].sorted { $0.position < $1.position }
            let shown = group.map { $0.type }
            var lastSeen = -1
            var used = -1
            for k in group.indices {
                if group[k].seen { lastSeen = k }
                if group[k].used { used = k }
            }
            visit(&state, daypart: group[0].daypart, shown: shown, lastSeen: lastSeen, used: used, today: group[0].day)
            i = j
        }
        return state
    }
}

/// The persisted `ShelfBandit.State`: canonical JSON, strict reader (anything wrong gives nil and the posteriors start from
/// their priors).
public enum ShelfBanditCodec {
    public static let format = "brain-shelf-bandit-v1"

    public static func encode(_ s: ShelfBandit.State) -> String {
        var w = BrainJson.Writer()
        w.beginObject()
        w.string("format", format)
        w.beginArray("alpha"); for v in s.alpha { w.doubleItem(v) }; w.endArray()
        w.beginArray("beta"); for v in s.beta { w.doubleItem(v) }; w.endArray()
        w.beginArray("lastSeenDay"); for v in s.lastSeenDay { w.longItem(v) }; w.endArray()
        w.long("frozenKey", s.frozenKey)
        w.beginArray("frozenOrder"); for t in s.frozenOrder { w.intItem(t) }; w.endArray()
        w.long("updates", s.updates)
        w.endObject()
        return w.text
    }

    public static func decode(_ text: String) -> ShelfBandit.State? {
        guard let o = try? BrainJson.parse(text), o["format"]?.stringValue == format else { return nil }
        let n = ShelfBandit.types * ShelfBandit.dayparts
        guard let alpha = doubles(o["alpha"], n), let beta = doubles(o["beta"], n),
              let seen = o["lastSeenDay"]?.arrayValue, seen.count == ShelfBandit.types,
              let frozenKey = decimal(o["frozenKey"]), let order = o["frozenOrder"]?.arrayValue,
              let updates = decimal(o["updates"]) else { return nil }
        var lastSeenDay = [Int64](repeating: Int64.min, count: ShelfBandit.types)
        for i in 0..<ShelfBandit.types {
            guard let d = decimal(seen[i]) else { return nil }
            lastSeenDay[i] = d
        }
        var frozenOrder: [Int32] = []
        for item in order {
            guard let v = item.bareLong, v >= Int64(Int32.min), v <= Int64(Int32.max) else { return nil }
            frozenOrder.append(Int32(v))
        }
        let state = ShelfBandit.State(alpha: alpha, beta: beta, lastSeenDay: lastSeenDay, frozenKey: frozenKey,
                                      frozenOrder: frozenOrder, updates: updates)
        return state.isValid() ? state : nil
    }

    private static func decimal(_ v: BrainJson.Value?) -> Int64? {
        guard let s = v?.stringValue else { return nil }
        return Int64(s)
    }

    private static func doubles(_ v: BrainJson.Value?, _ size: Int) -> [Double]? {
        guard let list = v?.arrayValue, list.count == size else { return nil }
        var out = [Double](repeating: 0.0, count: size)
        for i in 0..<size {
            guard let d = list[i].doubleValue, BrainMath.isFinite(d) else { return nil }
            out[i] = d
        }
        return out
    }
}
