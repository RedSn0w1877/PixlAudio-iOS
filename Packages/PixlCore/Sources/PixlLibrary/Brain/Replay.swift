// Rebuilding the affinity tables from the event log and the facts (docs/brain-spec.md, 4.4, 5.2; principle 2: the
// log is the only source of truth). A transliteration of the Android `:brain` module's `Replay.kt`.

/// Facts that are not events (4.4, step 4): they become pseudo-counts in the affinity tables. Everything is given by
/// id; the caller resolved names before the pure core sees it.
public struct LibraryFacts: Sendable {
    public struct TrackFact: Sendable {
        public let rid: Int64
        public let primaryAid: Int64

        public init(rid: Int64, primaryAid: Int64) {
            self.rid = rid
            self.primaryAid = primaryAid
        }
    }

    /// `range` is one of `rangeShort`, `rangeMedium`, `rangeLong`; `position` is 0 for the first entry.
    public struct TopArtist: Sendable {
        public let aid: Int64
        public let range: Int32
        public let position: Int32
        public let listSize: Int32

        public init(aid: Int64, range: Int32, position: Int32, listSize: Int32) {
            self.aid = aid
            self.range = range
            self.position = position
            self.listSize = listSize
        }
    }

    public struct TopTrack: Sendable {
        public let rid: Int64
        public let primaryAid: Int64
        public let range: Int32
        public let position: Int32
        public let listSize: Int32

        public init(rid: Int64, primaryAid: Int64, range: Int32, position: Int32, listSize: Int32) {
            self.rid = rid
            self.primaryAid = primaryAid
            self.range = range
            self.position = position
            self.listSize = listSize
        }
    }

    /// A taste adjustment "more" / "less" on a track or an artist; `strength` is 1, 2 or 3.
    public struct Adjustment: Sendable {
        public let family: Int32
        public let key: Int64
        public let more: Bool
        public let strength: Int32

        public init(family: Int32, key: Int64, more: Bool, strength: Int32) {
            self.family = family
            self.key = key
            self.more = more
            self.strength = strength
        }
    }

    public static let rangeShort: Int32 = 0
    public static let rangeMedium: Int32 = 1
    public static let rangeLong: Int32 = 2

    public static let empty = LibraryFacts()

    /// Spotify Liked Songs and in-app favourites: `(rid, primaryAid)`.
    public var liked: [TrackFact]
    public var topArtists: [TopArtist]
    public var topTracks: [TopTrack]
    /// Followed artists, by aid.
    public var followed: [Int64]
    public var adjustments: [Adjustment]

    public init(liked: [TrackFact] = [], topArtists: [TopArtist] = [], topTracks: [TopTrack] = [],
                followed: [Int64] = [], adjustments: [Adjustment] = []) {
        self.liked = liked
        self.topArtists = topArtists
        self.topTracks = topTracks
        self.followed = followed
        self.adjustments = adjustments
    }
}

/// Grades events in order, carrying what grading needs from earlier events: the run of skips directly before a play.
/// (How often each track was finished is read from the affinity state the caller passes in, which is the map the
/// Kotlin class holds a reference to.) The live recorder and `Replay` use the same type, so replaying the log gives
/// the state the live path built.
public struct GradeTracker: Sendable {
    public static let skipStreakGapMs: Int64 = 60_000

    private var streak: Int32 = 0
    private var lastSkipEndMs: Int64 = 0
    private var lastSessionId: Int64 = 0

    public init() {}

    /// The run of skips before `e` that counts for it: live plays of one session, each within 60 s of the next.
    public mutating func grade(_ e: PlayEvent, completions: [Int64: Int32]) -> Reward.Graded {
        let live = e.origin == Origin.live
        if live && e.sessionId != lastSessionId {
            streak = 0
            lastSessionId = e.sessionId
        }
        let gap = e.endedAtMs &- lastSkipEndMs
        let streakNow: Int32 = (live && streak > 0 && gap >= 0 && gap <= GradeTracker.skipStreakGapMs) ? streak : 0
        let g = Reward.grade(e, Reward.Context(pastCompletions: completions[e.rid] ?? 0, skipStreak: streakNow))
        if live {
            if g.isSkip {
                streak = streakNow + 1
                lastSkipEndMs = e.endedAtMs
            } else {
                streak = 0
            }
        }
        return g
    }
}

/// Rebuilds the affinity tables. Stage 1 rebuilds affinities only.
public enum Replay {
    /// `events` must be in ascending `eventId` (stored events and imported plays already merged, and every rid
    /// already mapped through `track_merge`). Every event time is clamped to `nowMs`, so a clock that was once set
    /// far ahead cannot pin the counters in the future.
    public static func rebuild<Events: Sequence>(_ events: Events, facts: LibraryFacts, nowMs: Int64) -> Affinity.State
        where Events.Element == PlayEvent {
        var state = Affinity.State()
        state.recordsTouched = false
        var tracker = GradeTracker()
        for e in events {
            let g = tracker.grade(e, completions: state.completions)
            Affinity.applyEvent(&state, e, g, tMs: e.startedAtMs > nowMs ? nowMs : e.startedAtMs)
        }
        applyFacts(&state, facts)
        state.recordsTouched = true
        return state
    }

    private static func rangeWeight(_ range: Int32) -> Double {
        if range == LibraryFacts.rangeShort { return 1.0 }
        if range == LibraryFacts.rangeMedium { return 0.8 }
        return 0.6
    }

    private static func rankFactor(_ range: Int32, _ position: Int32, _ listSize: Int32) -> Double {
        let size: Int32 = listSize > 0 ? listSize : 1
        let pos: Int32 = position < 0 ? 0 : (position > size ? size : position)
        return rangeWeight(range) * (1.0 - 0.7 * Double(pos) / Double(size))
    }

    /// Replaces the pseudo-counts of `state` with the ones `facts` give (the table of 4.4). Sums run in Q20
    /// integers, so the order of the facts does not matter. An artist or a track in several top ranges gets the
    /// largest of its values, not their sum.
    public static func applyFacts(_ state: inout Affinity.State, _ facts: LibraryFacts) {
        state.clearPriors()
        for f in facts.liked {
            if f.rid != 0 { state.addPrior(Family.track, f.rid, posQ: BrainMath.toQ(2.0), negQ: 0) }
            if f.primaryAid != 0 { state.addPrior(Family.artist, f.primaryAid, posQ: BrainMath.toQ(0.5), negQ: 0) }
        }
        var bestArtist: [Int64: Int64] = [:]
        for t in facts.topArtists {
            if t.aid == 0 { continue }
            let q = BrainMath.toQ(6.0 * rankFactor(t.range, t.position, t.listSize))
            if let old = bestArtist[t.aid], q <= old { continue }
            bestArtist[t.aid] = q
        }
        for aid in bestArtist.keys.sorted() {
            state.addPrior(Family.artist, aid, posQ: bestArtist[aid]!, negQ: 0)
        }
        var bestTrack: [Int64: Int64] = [:]
        var trackArtist: [Int64: Int64] = [:]
        for t in facts.topTracks {
            if t.rid == 0 { continue }
            let q = BrainMath.toQ(3.0 * rankFactor(t.range, t.position, t.listSize))
            let old = bestTrack[t.rid]
            if old == nil || q > old! { bestTrack[t.rid] = q }
            if t.primaryAid != 0 && trackArtist[t.rid] == nil { trackArtist[t.rid] = t.primaryAid }
        }
        for rid in bestTrack.keys.sorted() {
            state.addPrior(Family.track, rid, posQ: bestTrack[rid]!, negQ: 0)
            if let aid = trackArtist[rid] { state.addPrior(Family.artist, aid, posQ: BrainMath.toQ(0.5), negQ: 0) }
        }
        var followed: Set<Int64> = []
        for aid in facts.followed where aid != 0 && followed.insert(aid).inserted {
            state.addPrior(Family.artist, aid, posQ: BrainMath.toQ(2.0), negQ: 0)
        }
        for a in facts.adjustments {
            if a.key == 0 || (a.family != Family.track && a.family != Family.artist) { continue }
            let scale: Double = a.strength >= 3 ? 2.0 : (a.strength == 2 ? 1.5 : 1.0)
            let q = BrainMath.toQ(6.0 * scale)
            if a.more {
                state.addPrior(a.family, a.key, posQ: q, negQ: 0)
            } else {
                state.addPrior(a.family, a.key, posQ: 0, negQ: q)
            }
        }
    }
}
