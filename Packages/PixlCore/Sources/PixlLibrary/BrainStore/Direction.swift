// Which way the engine is turned (docs/brain-spec.md, 7.3 "Third skip in a row"). A port of Android's `Direction.kt`.
//
// Three engine picks skipped hard in a row turn the engine to another anchor of the session, and when there is
// none, to the library. That turn is a detour, not the new normal:
//
//  - Only skips of the ENGINE's picks count. A listener skipping through their own playlist to reach a song is
//    choosing, not rejecting what Autoplay offered.
//  - The turn ends the moment the listener plays a track of their own. From then on the engine seeds from the
//    normal anchors again, led by what they chose.
//  - While it lasts the engine follows the one anchor it turned to, plus any pick the listener liked since (a like
//    is a new anchor, and it belongs to the new direction).
//  - A station stays on its seed: skips there thin out what was skipped, they do not turn it.
//
// The pure core's `SessionState.reseedCount` only ever grows and counts every hard skip; it is not read for this.
// Session-scoped: a new session starts with a fresh one. A value inside `BrainEngine.Loaded`, changed on its actor.

/// Which way three skipped picks turned the engine, for one session.
public struct Direction: Sendable, Equatable {
    static let skipsToTurn = 3

    private var engineSkipRun = 0
    private var turnRid: Int64 = 0
    private var tried: [Int64] = []
    private var baseline: Set<Int64> = []
    private var turns = 0

    /// 0 while the engine follows the normal anchors; otherwise the number of the turn, counting up.
    public private(set) var turn = 0

    public init() {}

    /// One graded play. `anchors` is the session's anchors, newest first, AFTER the play was applied. True when
    /// this play turned the engine.
    ///
    /// `hardSkip`: a skip with `h >= 0.6` that counts (`c > 0`). `positive`: a completion or a like.
    public mutating func onEvent(enginePick: Bool, station: Bool, hardSkip: Bool, positive: Bool, anchors: [Int64]) -> Bool {
        if !enginePick {
            // The listener's own track, however it ended: they are steering.
            engineSkipRun = 0
            turn = 0
            turnRid = 0
            tried.removeAll()
            baseline.removeAll()
            return false
        }
        if station { return false }
        if positive {
            engineSkipRun = 0
            return false
        }
        if !hardSkip { return false }
        engineSkipRun += 1
        if engineSkipRun < Self.skipsToTurn { return false }
        engineSkipRun = 0
        if turn == 0 {
            // The newest anchor led the pool that was just skipped out of.
            tried.removeAll()
            if let first = anchors.first { tried.append(first) }
        }
        var next: Int64 = 0
        for rid in anchors where !tried.contains(rid) {
            next = rid
            break
        }
        turnRid = next
        if next != 0 { tried.append(next) }
        baseline = Set(anchors)
        turns += 1
        turn = turns
        return true
    }

    /// The anchors the engine seeds from while turned, best first: picks liked since the turn, then the anchor it
    /// turned to. Empty while turned means "nothing of the session is left to turn to": the caller seeds from the
    /// library instead. Not turned: `anchors` as they are.
    public func follow(_ anchors: [Int64]) -> [Int64] {
        if turn == 0 { return anchors }
        var out: [Int64] = []
        for rid in anchors where !baseline.contains(rid) { out.append(rid) }
        if turnRid != 0, anchors.contains(turnRid) { out.append(turnRid) }
        return out
    }
}
