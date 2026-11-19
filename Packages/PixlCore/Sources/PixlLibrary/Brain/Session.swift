// What the listener is doing right now (docs/brain-spec.md, 5.5, 7.3): short lists and counters, in memory only,
// reset after 30 minutes without a play. It holds recording and artist ids, never vectors (decision D7). A
// transliteration of the Android `:brain` module's `Session.kt`.

/// The session state of 5.5.
public struct SessionState: Sendable {
    /// The surface's novelty share at the start of the session.
    public let nuStart: Double

    public var sessionId: Int64 = 0
    /// Plays started in this session so far.
    public var plays: Int32 = 0
    public var passiveRun: Int32 = 0
    /// When the last recorded play ended.
    public var lastEndMs: Int64 = 0

    /// Newest first. A liked track is pushed twice.
    public var recentPos = [Int64](repeating: 0, count: Session.recent)
    public var recentPosAid = [Int64](repeating: 0, count: Session.recent)
    public var posCount = 0

    /// Newest first, with the strength of each skip.
    public var recentNeg = [Int64](repeating: 0, count: Session.recent)
    public var recentNegAid = [Int64](repeating: 0, count: Session.recent)
    public var recentNegH = [Double](repeating: 0, count: Session.recent)
    public var negCount = 0

    /// Artists not to queue for a while: `blockLeft` tracks, or `Session.restOfSession`. Insertion order.
    public var blockAid: [Int64] = []
    public var blockLeft: [Int32] = []

    /// Hard skips (`h >= 0.6`) per artist in this session. Insertion order.
    public var skippedAid: [Int64] = []
    public var skippedCount: [Int32] = []

    public var skipRun: Int32 = 0
    public var lastCompleted: Int64 = 0
    public var lastCompletedAid: Int64 = 0
    /// The previous track was finished (feature 25).
    public var prevCompleted = false
    public var nuSession: Double

    /// The station or autoplay seed; 0 when there is none.
    public var seed: Int64 = 0
    public var seedAid: Int64 = 0
    public var seedKind: Int32 = Session.seedNone
    /// A station's own seed artist after skips: 0 no limit, 1 one track in six, 2 none; for `seedLimitLeft` tracks.
    public var seedLimit: Int32 = 0
    public var seedLimitLeft: Int32 = 0

    /// Newest first: tracks the listener chose and heard, and engine picks they liked, saved or replayed.
    public var anchors = [Int64](repeating: 0, count: Session.maxAnchors)
    public var anchorsAid = [Int64](repeating: 0, count: Session.maxAnchors)
    public var anchorCount = 0

    /// Two hard skips in a row: the next engine pick must be familiar and by `lastCompletedAid`.
    public var familiarNext = false
    /// Bumped at every third hard skip in a row: the engine changes direction (the next anchor).
    public var reseedCount: Int32 = 0

    /// A track was liked: one track by the same artist (or its nearest neighbour) goes into the next `likedWithin`
    /// slots.
    public var likedRid: Int64 = 0
    public var likedAid: Int64 = 0
    public var likedWithin: Int32 = 0

    public init(nuStart: Double = Session.nuDefault) {
        self.nuStart = nuStart
        self.nuSession = nuStart
    }

    public func isBlocked(_ aid: Int64) -> Bool {
        if aid == 0 { return false }
        for i in blockAid.indices where blockAid[i] == aid { return true }
        return false
    }

    /// Hard skips of `aid` in this session.
    public func skipsOf(_ aid: Int64) -> Int32 {
        for i in skippedAid.indices where skippedAid[i] == aid { return skippedCount[i] }
        return 0
    }

    /// One canonical JSON object: the whole state, for the golden vectors and for debugging.
    public func encode() -> String {
        var w = BrainJson.Writer()
        w.beginObject()
        w.long("sessionId", sessionId); w.int("plays", plays); w.int("passiveRun", passiveRun)
        w.long("lastEndMs", lastEndMs)
        w.longs("recentPos", Array(recentPos[0..<posCount]))
        w.longs("recentNeg", Array(recentNeg[0..<negCount]))
        w.beginArray("recentNegH")
        for i in 0..<negCount { w.doubleItem(recentNegH[i]) }
        w.endArray()
        w.longs("blockAid", blockAid); w.ints("blockLeft", blockLeft)
        w.longs("skippedAid", skippedAid); w.ints("skippedCount", skippedCount)
        w.int("skipRun", skipRun); w.long("lastCompleted", lastCompleted); w.bool("prevCompleted", prevCompleted)
        w.double("nuSession", nuSession)
        w.int("seedLimit", seedLimit); w.int("seedLimitLeft", seedLimitLeft)
        w.longs("anchors", Array(anchors[0..<anchorCount]))
        w.bool("familiarNext", familiarNext); w.int("reseedCount", reseedCount)
        w.long("likedRid", likedRid); w.int("likedWithin", likedWithin)
        w.endObject()
        return w.text
    }
}

/// The session rules of 5.5 and 7.3. Pure: state in, state out, no clock.
public enum Session {
    public static let recent = 5
    public static let maxAnchors = 3
    public static let gapMs: Int64 = 30 * 60 * 1000
    public static let nuDefault: Double = 0.25
    public static let nuFloor: Double = 0.08
    public static let nuCeiling: Double = 0.6
    public static let blockTracks: Int32 = 10
    public static let restOfSession: Int32 = -1
    public static let hardSkip: Double = 0.6
    public static let likedWithin: Int32 = 5

    public static let seedNone: Int32 = 0
    public static let seedAutoplay: Int32 = 1
    public static let seedStationSong: Int32 = 2
    public static let seedStationArtist: Int32 = 3

    /// What a play that starts now is stamped with (4.1 `sessionId`, `posInSession`, `passiveRun`).
    public struct Stamp: Sendable {
        public let sessionId: Int64
        public let posInSession: Int32
        public let passiveRun: Int32
    }

    /// True when a play starting at `startedAtMs` opens a new session.
    public static func isExpired(_ state: SessionState, startedAtMs: Int64) -> Bool {
        state.sessionId == 0 || startedAtMs &- state.lastEndMs > gapMs
    }

    /// Stamps a play that starts at `startedAtMs`. The caller replaces an expired state with a fresh one first
    /// (`isExpired`); a state that never played becomes a session here.
    public static func begin(_ state: inout SessionState, startedAtMs: Int64, startReason: Int32) -> Stamp {
        if state.sessionId == 0 { state.sessionId = startedAtMs != 0 ? startedAtMs : 1 }
        let pos = state.plays
        state.plays = pos &+ 1
        state.passiveRun = (startReason == StartReason.autoAdvance || startReason == StartReason.autoplay)
            ? state.passiveRun &+ 1 : 0
        // A play that has started keeps the session alive even before it ends.
        if startedAtMs > state.lastEndMs { state.lastEndMs = startedAtMs }
        return Stamp(sessionId: state.sessionId, posInSession: pos > 32767 ? 32767 : pos,
                     passiveRun: state.passiveRun > 32767 ? 32767 : state.passiveRun)
    }

    /// Applies one finished play. `novel` says the listener had never played the track before this play. An event
    /// with `c = 0` changes nothing except `lastCompleted` and the block countdown.
    public static func apply(_ state: inout SessionState, _ e: PlayEvent, _ g: Reward.Graded, novel: Bool) {
        if e.endedAtMs > state.lastEndMs { state.lastEndMs = e.endedAtMs }
        countDown(&state)
        let notForMe = e.has(EventFlags.notForMe)
        let positive = EventFlags.likedDuring | EventFlags.savedDuring | EventFlags.addedToPlaylist | EventFlags.replayed
        let liked = !notForMe && (e.flags & positive) != 0
        if g.c == 0.0 {
            if g.isCompletion {
                state.lastCompleted = e.rid
                state.lastCompletedAid = e.primaryAid
            }
            return
        }
        let h: Double = notForMe ? 1.0 : g.h
        if h > 0.0 {
            pushNeg(&state, e.rid, e.primaryAid, h)
            state.prevCompleted = false
            if h >= hardSkip {
                state.skipRun += 1
                if e.primaryAid != 0 { hardSkipOfArtist(&state, e.primaryAid) }
                if novel { state.nuSession = BrainMath.max(nuFloor, state.nuSession * 0.67) }
                if state.skipRun >= 3 {
                    state.reseedCount += 1
                    state.skipRun = 0
                    state.familiarNext = false
                } else if state.skipRun == 2 {
                    state.familiarNext = true
                }
            }
        } else if g.isCompletion || liked {
            pushPos(&state, e.rid, e.primaryAid)
            if liked { pushPos(&state, e.rid, e.primaryAid) }
            state.skipRun = 0
            state.familiarNext = false
            state.lastCompleted = e.rid
            state.lastCompletedAid = e.primaryAid
            state.prevCompleted = true
            if liked {
                if novel { state.nuSession = BrainMath.min(nuCeiling, state.nuSession * 1.25) }
                state.likedRid = e.rid
                state.likedAid = e.primaryAid
                state.likedWithin = likedWithin
            }
        } else {
            state.prevCompleted = false
        }
        // Anchors: only the listener's own choices, or engine picks they acted on (5.12, rule 10).
        let enginePick = e.arm != Arm.none
        if e.rid != 0 && ((!enginePick && g.r >= 0.5 && h == 0.0) || (enginePick && liked)) {
            pushAnchor(&state, e.rid, e.primaryAid)
        }
    }

    private static func countDown(_ state: inout SessionState) {
        var i = 0
        while i < state.blockAid.count {
            let left = state.blockLeft[i]
            if left == restOfSession { i += 1; continue }
            if left <= 1 {
                state.blockAid.remove(at: i)
                state.blockLeft.remove(at: i)
            } else {
                state.blockLeft[i] = left - 1
                i += 1
            }
        }
        if state.seedLimitLeft > 0 {
            state.seedLimitLeft -= 1
            if state.seedLimitLeft == 0 { state.seedLimit = 0 }
        }
    }

    private static func hardSkipOfArtist(_ state: inout SessionState, _ aid: Int64) {
        var n: Int32 = 1
        var at = -1
        for i in state.skippedAid.indices where state.skippedAid[i] == aid { at = i }
        if at >= 0 {
            n = state.skippedCount[at] + 1
            state.skippedCount[at] = n
        } else {
            state.skippedAid.append(aid)
            state.skippedCount.append(1)
        }
        let station = state.seedKind == seedStationSong || state.seedKind == seedStationArtist
        if station && aid == state.seedAid {
            // The listener asked for this artist: thin it out, never ban it for the session.
            state.seedLimit = n >= 2 ? 2 : 1
            state.seedLimitLeft = blockTracks
            return
        }
        let left: Int32 = n >= 2 ? restOfSession : blockTracks
        for i in state.blockAid.indices where state.blockAid[i] == aid {
            state.blockLeft[i] = left
            return
        }
        state.blockAid.append(aid)
        state.blockLeft.append(left)
    }

    private static func pushPos(_ state: inout SessionState, _ rid: Int64, _ aid: Int64) {
        if rid == 0 { return }
        var i = state.posCount < recent ? state.posCount : recent - 1
        while i > 0 {
            state.recentPos[i] = state.recentPos[i - 1]
            state.recentPosAid[i] = state.recentPosAid[i - 1]
            i -= 1
        }
        state.recentPos[0] = rid
        state.recentPosAid[0] = aid
        if state.posCount < recent { state.posCount += 1 }
    }

    /// The strength of a swipe on an engine row of the queue (8.4): the weakest skip of 5.5.
    public static let swipeH: Double = 0.2

    /// The listener removed an engine pick from the queue without hearing it (8.4: "swipe removes it, a weak negative,
    /// `h = 0.2`"). It only pushes the track onto `recentNeg` with that strength, so tracks like it rank lower for the
    /// rest of the session: no affinity changes, no block, no skip run.
    public static func weakNegative(_ state: inout SessionState, rid: Int64, aid: Int64) {
        pushNeg(&state, rid, aid, swipeH)
    }

    private static func pushNeg(_ state: inout SessionState, _ rid: Int64, _ aid: Int64, _ h: Double) {
        if rid == 0 { return }
        var i = state.negCount < recent ? state.negCount : recent - 1
        while i > 0 {
            state.recentNeg[i] = state.recentNeg[i - 1]
            state.recentNegAid[i] = state.recentNegAid[i - 1]
            state.recentNegH[i] = state.recentNegH[i - 1]
            i -= 1
        }
        state.recentNeg[0] = rid
        state.recentNegAid[0] = aid
        state.recentNegH[0] = h
        if state.negCount < recent { state.negCount += 1 }
    }

    private static func pushAnchor(_ state: inout SessionState, _ rid: Int64, _ aid: Int64) {
        // Already an anchor: move it to the front.
        var at = -1
        for i in 0..<state.anchorCount where state.anchors[i] == rid { at = i }
        var i = at >= 0 ? at : (state.anchorCount < maxAnchors ? state.anchorCount : maxAnchors - 1)
        while i > 0 {
            state.anchors[i] = state.anchors[i - 1]
            state.anchorsAid[i] = state.anchorsAid[i - 1]
            i -= 1
        }
        state.anchors[0] = rid
        state.anchorsAid[0] = aid
        if at < 0 && state.anchorCount < maxAnchors { state.anchorCount += 1 }
    }

    /// The session's anchors in the order the engine should seed from: newest first, turned by one place for every
    /// change of direction (7.3, third skip in a row: "the next anchor of the session").
    public static func seedOrder(_ state: SessionState) -> [Int64] {
        let n = state.anchorCount
        if n == 0 { return [] }
        let shift = Int(state.reseedCount) % n
        return (0..<n).map { state.anchors[($0 + shift) % n] }
    }

    /// Re-scores the engine-owned tail of the queue after a reaction (2.3 step 7, 7.3). `request` holds the tail's
    /// own candidates together with the pool, and asks for as many tracks as the tail has. Returns the new tail, or
    /// nil when nothing changes. The caller never passes a track that is starting or already warmed (decision D8),
    /// and applies the answer in one queue edit.
    public static func patchQueue(_ state: SessionState, tail: [Int64], request: StationPlanner.Request,
                                  affinity: Affinity.State, graph: Graph) -> StationPlanner.Plan? {
        let plan = StationPlanner.plan(request, affinity: affinity, session: state, graph: graph)
        if plan.picks.count == tail.count {
            var same = true
            for i in tail.indices where plan.picks[i].rid != tail[i] { same = false }
            if same { return nil }
        }
        return plan
    }
}
