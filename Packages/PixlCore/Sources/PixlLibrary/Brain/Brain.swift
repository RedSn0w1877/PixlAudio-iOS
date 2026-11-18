// The step from a play to changed state (docs/brain-spec.md, 2.3, steps 3 to 5): grade the event, update the
// affinity tables, update the session. The live recorder calls this once per finished play; `Replay.rebuild` does
// the first two steps for every event of the log. A transliteration of the Android `:brain` module's `Brain.kt`.

/// The live step of the brain.
public enum Brain {
    /// Bumped whenever the pure logic changes its output: new golden files, and a rebuild on first use.
    public static let specVersion: Int32 = 1

    @discardableResult
    public static func onEvent(affinity: inout Affinity.State, tracker: inout GradeTracker, session: inout SessionState,
                               event e: PlayEvent) -> Reward.Graded {
        let novel = !Affinity.isHeard(affinity, family: Family.track, key: e.rid)
        let g = tracker.grade(e, completions: affinity.completions)
        Affinity.applyEvent(&affinity, e, g, tMs: e.startedAtMs)
        Session.apply(&session, e, g, novel: novel)
        return g
    }
}
