// The top factors of a pick (docs/brain-spec.md, 9.3 `explain_track`, 8.8 "Why this song"): which named features of the vector the pick was
// served with moved its score the most, under the weights it was ranked with. A port of Android's `ServedFactors.kt`. Only the fixed names of
// `AssistantRules.factorNames` leave this file: no raw weight and no raw value. One place, so the assistant's `explain_track` and the "Why this
// song" sheet say the same thing. A pick with no stored vector has no factors: nothing is guessed.

import Foundation
import PixlModel

extension BrainEngine {
    /// The factors of `x` (a dequantised served vector). `modelVersion` is what ranked the pick (`modelLearned`, or 0 for the prior). A pick
    /// the learned weights ranked is read with the weights the engine holds NOW (they move with every play, so this is "under the current
    /// weights", and the tool says so); when the gate has switched the learned weights off since, there is nothing true to say and the
    /// answer is nil (never the prior's factors for a list the prior did not rank).
    public func servedFactors(_ x: [Double], modelVersion: Int32, nowMs: Int64) -> [AssistantRules.Factor]? {
        withState { st in
            let rankedByLearned = modelVersion == BrainEngine.modelLearned
            if rankedByLearned && !st.learner.useLearned { return nil }
            let p0 = Affinity.p0(st.affinity, nowMs: nowMs)
            return AssistantRules.topFactors(x, Ranker.weightsFor(st.learner.model, learned: rankedByLearned, p0: p0, seed: nil))
        }
    }

    /// The factors of the pick whose vector travels in the queue as `hex` (`BrainItemTag.servedX`), or nil when it holds none.
    public func servedFactors(hex: String?, modelVersion: Int, nowMs: Int64) -> [AssistantRules.Factor]? {
        guard let hex, let bytes = ServedVector.fromHex(hex), let x = ServedVector.dequantize(bytes) else { return nil }
        return servedFactors(x, modelVersion: Int32(clamping: modelVersion), nowMs: nowMs)
    }

    /// The factors of the recording `rid` from the newest played event of it that stored a vector: for the sheet of a song with no vector
    /// of its own in the queue (a played pick). Nil when the log holds none.
    public func servedFactors(rid: Int64, nowMs: Int64) -> [AssistantRules.Factor]? {
        guard rid != 0 else { return nil }
        let newest = events().filter { $0.rid == rid && $0.servedX != nil }.max { $0.startedAtMs < $1.startedAtMs }
        guard let event = newest, let x = ServedVector.dequantize(event.servedX) else { return nil }
        return servedFactors(x, modelVersion: event.modelVersion, nowMs: nowMs)
    }
}

/// How the factors read on the "Why this song" sheet: two lines at most, "What helped: ..." and "What held it back: ...", the names joined
/// with "; " (Android `WhyThisSongSheet`).
public enum ServedFactorLines {
    public static func helped(_ factors: [AssistantRules.Factor]) -> String {
        factors.filter(\.up).map(\.name).joined(separator: "; ")
    }

    public static func held(_ factors: [AssistantRules.Factor]) -> String {
        factors.filter { !$0.up }.map(\.name).joined(separator: "; ")
    }
}
