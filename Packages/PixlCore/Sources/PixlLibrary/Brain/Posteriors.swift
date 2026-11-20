// The learned state that is not the ranker's weights (docs/brain-spec.md, 5.10, 5.13): the arm bandit and the novelty appetite. One
// watermark, one entry point (`PosteriorUpdate.onPlay`) for the live path and the replay, one strict codec. A cache of the event log,
// like the ranker: a replay makes it again, and "Reset what I've learned" puts it back to its priors. A transliteration of the
// Android `:brain` module's `Posteriors.kt`; `posteriors.jsonl` pins the codec and the replay's result bit for bit.

/// The arm bandit and the novelty appetite of one listener.
public struct Posteriors: Sendable {
    public var arms: ArmBandit.State
    public var appetite: NoveltyAppetite.State
    /// The id of the newest event applied; an event at or below it is never applied again.
    public var lastEventId: Int64

    public init(arms: ArmBandit.State, appetite: NoveltyAppetite.State, lastEventId: Int64 = Int64.min) {
        self.arms = arms
        self.appetite = appetite
        self.lastEventId = lastEventId
    }

    public func isValid() -> Bool { arms.isValid() && appetite.isValid() }

    public static func newState(today: Int64) -> Posteriors {
        Posteriors(arms: ArmBandit.newState(today: today), appetite: NoveltyAppetite.newState(today: today))
    }
}

public enum PosteriorUpdate {
    /// One graded play: the arm bandit (when it came from a recommender arm on a surface the bandit knows), then the novelty
    /// appetite. `novel` is true when it was the first play of the track (computed from the tables BEFORE the play is
    /// applied). An event at or below the watermark changes nothing. Returns true when the event was applied.
    @discardableResult
    public static func onPlay(_ p: inout Posteriors, _ e: PlayEvent, _ g: Reward.Graded, novel: Bool, nowMs: Int64,
                       eventId: Int64? = nil) -> Bool {
        let id = eventId ?? e.eventId
        if id <= p.lastEventId { return false }
        let t = e.startedAtMs > nowMs ? nowMs : e.startedAtMs
        let day = LearnReplay.dayOf(e, t)
        let family = ArmBandit.familyOf(e.surface)
        let recommender = e.origin == Origin.live && family >= 0 && e.arm >= 0 && Int(e.arm) < ArmBandit.arms
        if recommender && !e.has(EventFlags.learnExcluded) && !e.has(EventFlags.neverAudible) {
            ArmBandit.update(&p.arms, family: family, arm: Int(e.arm), r: g.r, c: g.cOther,
                             explore: e.has(EventFlags.exploreSlot), day: day)
        } else {
            ArmBandit.discount(&p.arms, today: day)
            p.arms.anchorDay = day
            p.arms.forgetDone = 0
        }
        NoveltyAppetite.onPlay(&p.appetite, e, g, novel: novel, recommender: recommender, day: day)
        p.lastEventId = id
        return true
    }

    /// Brings both posteriors to local day `today`: the discount and the slow appetite's steps. Call at the end of a replay
    /// and when a list is built.
    public static func advanceTo(_ p: inout Posteriors, today: Int64) {
        ArmBandit.discount(&p.arms, today: today)
        NoveltyAppetite.advance(&p.appetite, today: today)
    }
}

/// The persisted `Posteriors`: canonical JSON (see `BrainJson`), doubles as IEEE bit patterns. A reader is strict: anything
/// wrong gives nil, and the caller starts again from the priors and schedules a replay.
public enum PosteriorCodec {
    public static let format = "brain-posteriors-v1"

    public static func encode(_ p: Posteriors) -> String {
        var w = BrainJson.Writer()
        w.beginObject()
        w.string("format", format)
        w.long("lastEventId", p.lastEventId)
        let a = p.arms
        w.beginObject("arms")
        w.beginArray("alpha"); for v in a.alpha { w.doubleItem(v) }; w.endArray()
        w.beginArray("beta"); for v in a.beta { w.doubleItem(v) }; w.endArray()
        w.beginArray("auditAlpha"); for v in a.auditAlpha { w.doubleItem(v) }; w.endArray()
        w.beginArray("auditBeta"); for v in a.auditBeta { w.doubleItem(v) }; w.endArray()
        w.long("anchorDay", a.anchorDay)
        w.int("forgetDone", a.forgetDone)
        w.long("updates", a.updates)
        w.endObject()
        let n = p.appetite
        w.beginObject("appetite")
        w.double("fAlpha", n.fAlpha); w.double("fBeta", n.fBeta); w.double("nAlpha", n.nAlpha); w.double("nBeta", n.nBeta)
        if n.nuLong != n.nuLong { w.nullValue("nuLong") } else { w.double("nuLong", n.nuLong) }
        w.long("anchorDay", n.anchorDay)
        w.int("forgetDone", n.forgetDone)
        w.long("nuDay", n.nuDay)
        w.long("updates", n.updates)
        w.beginArray("days")
        for day in n.days.keys.sorted() {
            let v = n.days[day] ?? [0, 0]
            w.beginArray(); w.longItem(day); w.intItem(v[0]); w.intItem(v[1]); w.endArray()
        }
        w.endArray()
        w.beginArray("boosts"); for t in n.boosts { w.longItem(t) }; w.endArray()
        w.endObject()
        w.endObject()
        return w.text
    }

    public static func decode(_ text: String) -> Posteriors? {
        guard let o = try? BrainJson.parse(text) else { return nil }
        guard o["format"]?.stringValue == format else { return nil }
        guard let ao = o["arms"], let no = o["appetite"] else { return nil }
        let size = ArmBandit.families * ArmBandit.arms
        guard let alpha = doubles(ao["alpha"], size), let beta = doubles(ao["beta"], size),
              let auditAlpha = doubles(ao["auditAlpha"], size), let auditBeta = doubles(ao["auditBeta"], size),
              let armsAnchor = decimal(ao["anchorDay"]), let armsForget = ao["forgetDone"]?.bareLong,
              let armsUpdates = decimal(ao["updates"]) else { return nil }
        let arms = ArmBandit.State(alpha: alpha, beta: beta, auditAlpha: auditAlpha, auditBeta: auditBeta, anchorDay: armsAnchor,
                                   forgetDone: Int(armsForget), updates: armsUpdates)
        if !arms.isValid() || arms.forgetDone < 0 || arms.forgetDone > ArmBandit.maxForgetRuns { return nil }

        var nu = Double.nan
        if let v = no["nuLong"], !v.isNull {
            guard let d = v.doubleValue else { return nil }
            nu = d
        }
        guard let rows = no["days"]?.arrayValue else { return nil }
        var days: [Int64: [Int]] = [:]
        for item in rows {
            guard let row = item.arrayValue, row.count == 3, let day = row[0].longValue, row[0].stringValue != nil,
                  let total = row[1].bareLong, let first = row[2].bareLong else { return nil }
            if total < 0 || first < 0 || first > total { return nil }
            days[day] = [Int(total), Int(first)]
        }
        guard let boostItems = no["boosts"]?.arrayValue else { return nil }
        var boosts: [Int64] = []
        for item in boostItems {
            guard let t = decimal(item) else { return nil }
            boosts.append(t)
        }
        guard let fAlpha = no["fAlpha"]?.doubleValue, let fBeta = no["fBeta"]?.doubleValue,
              let nAlpha = no["nAlpha"]?.doubleValue, let nBeta = no["nBeta"]?.doubleValue,
              let appAnchor = decimal(no["anchorDay"]), let appForget = no["forgetDone"]?.bareLong,
              let nuDay = decimal(no["nuDay"]), let appUpdates = decimal(no["updates"]),
              let lastEventId = decimal(o["lastEventId"]) else { return nil }
        let appetite = NoveltyAppetite.State(fAlpha: fAlpha, fBeta: fBeta, nAlpha: nAlpha, nBeta: nBeta, nuLong: nu,
                                             anchorDay: appAnchor, forgetDone: Int(appForget), nuDay: nuDay, days: days,
                                             boosts: boosts, updates: appUpdates)
        if !appetite.isValid() || appetite.forgetDone < 0 || appetite.forgetDone > NoveltyAppetite.maxForgetRuns { return nil }
        return Posteriors(arms: arms, appetite: appetite, lastEventId: lastEventId)
    }

    /// An Int64 written as a decimal string (the canonical form): a bare integer is not accepted.
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
