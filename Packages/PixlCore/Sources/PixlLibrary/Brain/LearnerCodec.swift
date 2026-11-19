// The learner's persisted state (docs/brain-spec.md, 5.13): `m` and `q` as IEEE bit patterns, the forgetting anchor, the
// watermark of the last play applied, the gate's state and the figures Your sound reads. One canonical JSON object (see
// `BrainJson`), written atomically by the caller together with the event row it follows. A transliteration of the
// Android `:brain` module's `LearnerCodec.kt`.
//
// A reader is strict: a wrong format, a wrong length, a value that is not finite, a precision not above 0 or a mean
// outside its box gives nil, and the caller starts again from the prior and schedules a replay. Nothing here ever
// throws on bad input.

/// The learner's saved state.
public enum LearnerCodec {
    public static let format = "brain-learner-v1"

    /// What is saved beside the model.
    public struct Saved: Sendable {
        public var model: RankerModel
        public var gate: Gate.State
        /// `LearnReplay.version` the model was built under.
        public var learnVersion: Int
        public var summary: Gate.Summary?
        /// When the last full replay finished; 0 for never.
        public var rebuiltAtMs: Int64

        public init(model: RankerModel, gate: Gate.State, learnVersion: Int, summary: Gate.Summary?, rebuiltAtMs: Int64) {
            self.model = model
            self.gate = gate
            self.learnVersion = learnVersion
            self.summary = summary
            self.rebuiltAtMs = rebuiltAtMs
        }
    }

    public static func encode(_ saved: Saved) -> String {
        let model = saved.model
        var w = BrainJson.Writer()
        w.beginObject()
        w.string("format", format)
        w.int("learnVersion", saved.learnVersion)
        w.int("featureVersion", Ranker.d)
        w.beginArray("m")
        for i in 0..<Ranker.d { w.doubleItem(model.m[i]) }
        w.endArray()
        w.beginArray("q")
        for i in 0..<Ranker.d { w.doubleItem(model.q[i]) }
        w.endArray()
        w.long("anchorDay", model.anchorDay)
        w.int("forgetDone", model.forgetDone)
        w.long("updates", model.updates)
        w.long("lastEventId", model.lastEventId)
        w.int("resets", model.resets)
        w.bool("useLearned", saved.gate.useLearned)
        w.int("winStreak", saved.gate.winStreak)
        w.long("gateAtMs", saved.gate.atMs)
        w.long("rebuiltAtMs", saved.rebuiltAtMs)
        if let s = saved.summary {
            w.beginObject("summary")
            w.int("plays", s.plays)
            w.int("playsTotal", s.playsTotal)
            w.double("llLearned", s.logLossLearned)
            w.double("llPrior", s.logLossPrior)
            w.double("accLearned", s.accLearned)
            w.double("accPrior", s.accPrior)
            if let v = s.accLearnedBefore { w.double("accLearnedBefore", v) } else { w.nullValue("accLearnedBefore") }
            if let v = s.accPriorBefore { w.double("accPriorBefore", v) } else { w.nullValue("accPriorBefore") }
            w.endObject()
        } else {
            w.nullValue("summary")
        }
        w.endObject()
        return w.text
    }

    /// The saved state, or nil when `text` is not a valid one (any bad shape: a missing key, a wrong type, a bad number or hex).
    public static func decode(_ text: String) -> Saved? {
        guard let o = try? BrainJson.parse(text) else { return nil }
        guard o.stringValue == nil, o["format"]?.stringValue == format else { return nil }
        guard o["featureVersion"]?.bareLong == Int64(Ranker.d) else { return nil }
        guard let m = doubles(o["m"]), let q = doubles(o["q"]) else { return nil }
        guard let anchorDay = decimal(o["anchorDay"]), let updates = decimal(o["updates"]),
              let lastEventId = decimal(o["lastEventId"]), let gateAtMs = decimal(o["gateAtMs"]),
              let rebuiltAtMs = decimal(o["rebuiltAtMs"]),
              let forgetDone = o["forgetDone"]?.bareLong, let resets = o["resets"]?.bareLong,
              let useLearned = o["useLearned"]?.boolValue, let winStreak = o["winStreak"]?.bareLong,
              let learnVersion = o["learnVersion"]?.bareLong else { return nil }
        let prior = Ranker.newModel(today: 0)
        let model = RankerModel(m: m, q: q, m0: prior.m0, anchorDay: anchorDay, updates: updates, lastEventId: lastEventId,
                                forgetDone: Int(forgetDone), resets: Int(resets))
        if !model.isValid() { return nil }
        if model.forgetDone < 0 || model.forgetDone > Ranker.maxForgetRuns { return nil }
        var summary: Gate.Summary?
        if let so = o["summary"], !so.isNull {
            guard let plays = so["plays"]?.bareLong, let total = so["playsTotal"]?.bareLong,
                  let llL = so["llLearned"]?.doubleValue, let llP = so["llPrior"]?.doubleValue,
                  let accL = so["accLearned"]?.doubleValue, let accP = so["accPrior"]?.doubleValue else { return nil }
            var beforeL: Double?
            var beforeP: Double?
            if let v = so["accLearnedBefore"], !v.isNull {
                guard let d = v.doubleValue else { return nil }
                beforeL = d
            }
            if let v = so["accPriorBefore"], !v.isNull {
                guard let d = v.doubleValue else { return nil }
                beforeP = d
            }
            summary = Gate.Summary(plays: Int(plays), playsTotal: Int(total), logLossLearned: llL, logLossPrior: llP,
                                   accLearned: accL, accPrior: accP, accLearnedBefore: beforeL, accPriorBefore: beforeP)
        }
        return Saved(model: model, gate: Gate.State(useLearned: useLearned, winStreak: Int(winStreak), atMs: gateAtMs),
                     learnVersion: Int(learnVersion), summary: summary, rebuiltAtMs: rebuiltAtMs)
    }

    /// An Int64 written as a decimal string (the canonical form): a bare integer is not accepted.
    private static func decimal(_ v: BrainJson.Value?) -> Int64? {
        guard let s = v?.stringValue else { return nil }
        return Int64(s)
    }

    private static func doubles(_ v: BrainJson.Value?) -> [Double]? {
        guard let list = v?.arrayValue, list.count == Ranker.d else { return nil }
        var out = [Double](repeating: 0.0, count: Ranker.d)
        for i in 0..<Ranker.d {
            guard let d = list[i].doubleValue, BrainMath.isFinite(d) else { return nil }
            out[i] = d
        }
        return out
    }
}
