// "Your sound" (docs/brain-spec.md, 8.6): the figures the screen shows, from the listener's own plays. Pure: the app hands
// over plain rows (plays in time order, who belongs to which island, tags and years by recording) and gets counts back. A
// section with nothing to say comes back empty, and the screen shows only sections that have data. No name, no sentence and
// no guess is made here: names come from the atlas and the islands in the app, and a genre or an island that is unknown is
// simply absent. A transliteration of the Android `:brain` module's `YourSound.kt`.
//
// Shares are in permille (integers), so two platforms print the same number.

/// The figures of Your sound.
public enum YourSound {
    /// "Right now": the islands of the last 28 days.
    public static let rightNowDays = 28
    public static let maxMonths = 24

    /// The eras section needs a year for at least this share of the plays (permille).
    public static let erasMinCoveragePermille = 600

    /// One counted play. `first` is true for the listener's first play of that recording (computed by `withFirsts`).
    public struct Play: Sendable {
        public let rid: Int64
        public let aid: Int64
        public let startedAtMs: Int64
        public let tzOffsetMin: Int32
        public let first: Bool

        public init(rid: Int64, aid: Int64, startedAtMs: Int64, tzOffsetMin: Int32, first: Bool) {
            self.rid = rid
            self.aid = aid
            self.startedAtMs = startedAtMs
            self.tzOffsetMin = tzOffsetMin
            self.first = first
        }
    }

    public struct IslandShare: Sendable {
        public let islandId: Int
        public let permille: Int
        public let plays: Int
        public let topAids: [Int64]
        public let topRids: [Int64]
    }

    public struct Daypart: Sendable {
        public let daypart: Int
        public let plays: Int
        public let leadingIslandId: Int
    }

    public struct IslandPermille: Sendable, Equatable {
        public let islandId: Int
        public let permille: Int
    }

    public struct Month: Sendable {
        public let month: Int
        public let plays: Int
        public let islandPermille: [IslandPermille]
    }

    public struct Decade: Sendable, Equatable {
        public let decade: Int
        public let permille: Int
    }

    public struct GenreShare: Sendable, Equatable {
        public let atlasId: Int
        public let permille: Int
    }

    public struct Novelty: Sendable {
        public let plays: Int
        public let novel: Int

        public init(plays: Int, novel: Int) {
            self.plays = plays
            self.novel = novel
        }

        /// Permille of the plays that were new to the listener; 0 with no plays.
        public var permille: Int {
            plays == 0 ? 0 : Int(BrainMath.floorToLong(Double(novel) * 1000.0 / Double(plays) + 0.5))
        }
    }

    private static func permille(_ part: Int, _ whole: Int) -> Int {
        whole <= 0 ? 0 : Int(BrainMath.floorToLong(Double(part) * 1000.0 / Double(whole) + 0.5))
    }

    /// Marks each play's first of its recording. The plays must be in time order; plays of `knownBefore` count as heard already.
    public static func withFirsts(rids: [Int64], aids: [Int64], startedAtMs: [Int64], tzOffsetMin: [Int32],
                                  knownBefore: Set<Int64> = []) -> [Play] {
        var seen = knownBefore
        var out: [Play] = []
        out.reserveCapacity(rids.count)
        for i in rids.indices {
            out.append(Play(rid: rids[i], aid: aids[i], startedAtMs: startedAtMs[i], tzOffsetMin: tzOffsetMin[i],
                            first: seen.insert(rids[i]).inserted))
        }
        return out
    }

    /// Keys of `counts` by count, largest first, ties by the smaller key.
    private static func byCountDesc<K: Comparable & Hashable>(_ counts: [K: Int]) -> [K] {
        counts.keys.sorted { a, b in
            let ca = counts[a] ?? 0
            let cb = counts[b] ?? 0
            return ca != cb ? ca > cb : a < b
        }
    }

    /// The islands of the plays that started within `rightNowDays` days before `nowMs`, largest first (ties: smaller id).
    public static func islands(_ plays: [Play], islandOf: (Int64) -> Int, nowMs: Int64, top: Int = 3) -> [IslandShare] {
        let from = nowMs &- Int64(rightNowDays) &* BrainMath.dayMs
        var counts: [Int: Int] = [:]
        var byArtist: [Int: [Int64: Int]] = [:]
        var byTrack: [Int: [Int64: Int]] = [:]
        var total = 0
        for p in plays {
            if p.startedAtMs < from || p.startedAtMs > nowMs { continue }
            let id = islandOf(p.rid)
            if id < 0 { continue }
            total += 1
            counts[id, default: 0] += 1
            if p.aid != 0 { byArtist[id, default: [:]][p.aid, default: 0] += 1 }
            byTrack[id, default: [:]][p.rid, default: 0] += 1
        }
        return byCountDesc(counts).map { id in
            let n = counts[id] ?? 0
            return IslandShare(islandId: id, permille: permille(n, total), plays: n, topAids: topKeys(byArtist[id], top),
                               topRids: topKeys(byTrack[id], top))
        }
    }

    private static func topKeys(_ m: [Int64: Int]?, _ n: Int) -> [Int64] {
        guard let m else { return [] }
        return Array(byCountDesc(m).prefix(n))
    }

    /// For each of the four dayparts: how many plays, and the island that led it (-1 when none of its plays belong to an island).
    public static func dayparts(_ plays: [Play], islandOf: (Int64) -> Int) -> [Daypart] {
        var counts = [Int](repeating: 0, count: 4)
        var perIsland = [[Int: Int]](repeating: [:], count: 4)
        for p in plays {
            let d = Int(HomePlanner.daypart(nowMs: p.startedAtMs,
                                            tzOffsetMin: p.tzOffsetMin == PlayEvent.tzUnknown ? 0 : p.tzOffsetMin))
            counts[d] += 1
            let id = islandOf(p.rid)
            if id >= 0 { perIsland[d][id, default: 0] += 1 }
        }
        return (0..<4).map { d in Daypart(daypart: d, plays: counts[d], leadingIslandId: byCountDesc(perIsland[d]).first ?? -1) }
    }

    /// `year * 12 + month0` of a UTC day, by integer arithmetic (the proleptic Gregorian calendar).
    public static func monthOfDay(_ day: Int64) -> Int {
        let z = day &+ 719_468
        let era = BrainMath.floorDiv(z, 146_097)
        let doe = z &- era &* 146_097
        let yoe = (doe &- doe / 1460 &+ doe / 36_524 &- doe / 146_096) / 365
        let y = yoe &+ era &* 400
        let doy = doe &- (365 &* yoe &+ yoe / 4 &- yoe / 100)
        let mp = (5 &* doy &+ 2) / 153
        let m = mp < 10 ? mp &+ 3 : mp &- 9
        let year = m <= 2 ? y &+ 1 : y
        return Int(year &* 12 &+ (m &- 1))
    }

    /// The last `maxMonths` months with plays, oldest first: each month's island shares (permille), largest first.
    public static func months(_ plays: [Play], islandOf: (Int64) -> Int) -> [Month] {
        var perMonth: [Int: [Int: Int]] = [:]
        var totals: [Int: Int] = [:]
        for p in plays {
            let month = monthOfDay(BrainMath.localDay(p.startedAtMs,
                                                       tzOffsetMin: p.tzOffsetMin == PlayEvent.tzUnknown ? 0 : p.tzOffsetMin))
            totals[month, default: 0] += 1
            let id = islandOf(p.rid)
            if id >= 0 { perMonth[month, default: [:]][id, default: 0] += 1 }
        }
        let all = totals.keys.sorted()
        let kept = all.count > maxMonths ? Array(all[(all.count - maxMonths)...]) : all
        return kept.map { month in
            let m = perMonth[month] ?? [:]
            let total = totals[month] ?? 0
            return Month(month: month, plays: total,
                         islandPermille: byCountDesc(m).map { IslandPermille(islandId: $0, permille: permille(m[$0] ?? 0, total)) })
        }
    }

    /// New to the listener: the plays of the last 7 days that were their first of the recording.
    public static func novelty(_ plays: [Play], nowMs: Int64) -> Novelty {
        let from = nowMs &- 7 &* BrainMath.dayMs
        var n = 0
        var novel = 0
        for p in plays {
            if p.startedAtMs < from || p.startedAtMs > nowMs { continue }
            n += 1
            if p.first { novel += 1 }
        }
        return Novelty(plays: n, novel: novel)
    }

    /// The decades of the plays whose year is known (`yearOf` gives 0 for unknown), by decade. Empty until a year is
    /// known for `erasMinCoveragePermille` of the plays.
    public static func decades(_ plays: [Play], yearOf: (Int64) -> Int) -> [Decade] {
        var counts: [Int: Int] = [:]
        var known = 0
        for p in plays {
            let y = yearOf(p.rid)
            if y < 1900 || y > 2100 { continue }
            known += 1
            counts[(y / 10) * 10, default: 0] += 1
        }
        if plays.isEmpty || permille(known, plays.count) < erasMinCoveragePermille { return [] }
        return counts.keys.sorted().map { Decade(decade: $0, permille: permille(counts[$0] ?? 0, known)) }
    }

    /// The genres of the plays, heaviest first: each play gives its track's top tag one count (unknown genres are absent).
    public static func genres(_ plays: [Play], top: Int = 8, topTagOf: (Int64) -> Int) -> [GenreShare] {
        var counts: [Int: Int] = [:]
        var known = 0
        for p in plays {
            let t = topTagOf(p.rid)
            if t == GenreAtlas.none { continue }
            known += 1
            counts[t, default: 0] += 1
        }
        return byCountDesc(counts).prefix(top).map { GenreShare(atlasId: $0, permille: permille(counts[$0] ?? 0, known)) }
    }
}

/// What "Your sound" may say about the model, a function of the model's real state and nothing else (honesty rule of stage 3).
///
/// - `gettingToKnow`: fewer than `Gate.minPlays` graded plays. Shows how many there are. No figure.
/// - `standardRecipe`: enough plays, but the gate has the prior on (the learned weights have not beaten it two weeks
///   running, or lost). Shows the prior's own accuracy, computed from the same graded plays.
/// - `learning`: the learned weights are in use. Shows how many plays moved them, the accuracy now, a month ago when there
///   is one, and the standard recipe's for comparison.
///
/// Every percentage is `floor(share * 100 + 0.5)` of the graded plays (a finish or a skip) in the gate's window: no other source.
public enum ModelVoice {
    public static let gettingToKnow = 0
    public static let standardRecipe = 1
    public static let learning = 2

    public struct State: Sendable, Equatable {
        public let kind: Int
        /// Graded plays so far (shown by `gettingToKnow`).
        public let gradedPlays: Int
        /// Plays that moved the weights since the model was last at its prior (shown by `learning`).
        public let learnedFrom: Int64
        public let accNowPercent: Int?
        public let accBeforePercent: Int?
        public let accPriorPercent: Int?
    }

    private static func percent(_ share: Double) -> Int { Int(BrainMath.floorToLong(share * 100.0 + 0.5)) }

    public static func of(_ summary: Gate.Summary?, useLearned: Bool, modelUpdates: Int64) -> State {
        let graded = summary?.playsTotal ?? 0
        guard let summary, graded >= Gate.minPlays else {
            return State(kind: gettingToKnow, gradedPlays: graded, learnedFrom: 0, accNowPercent: nil, accBeforePercent: nil,
                         accPriorPercent: nil)
        }
        if !useLearned {
            return State(kind: standardRecipe, gradedPlays: graded, learnedFrom: 0, accNowPercent: nil, accBeforePercent: nil,
                         accPriorPercent: percent(summary.accPrior))
        }
        return State(kind: learning, gradedPlays: graded, learnedFrom: modelUpdates, accNowPercent: percent(summary.accLearned),
                     accBeforePercent: summary.accLearnedBefore.map(percent), accPriorPercent: percent(summary.accPrior))
    }
}
