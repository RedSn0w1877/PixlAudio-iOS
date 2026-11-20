// The brain's in-memory state, the event recorder and the rebuild (docs/brain-spec.md, 2.3 steps 1 to 5, 4.2, 4.4,
// 5.13). An actor: everything that reads or changes the affinity tables and the session runs here, off the main
// actor, one caller at a time. Ports of Android's `BrainEngine.kt`, `BrainEventRecorder.kt` and `AppStateRebuilder`.
//
// Nothing here runs at app start. The first play that ends, or the first autoplay plan, loads the stored rows; the
// one-shot migration and every later rebuild run beside the live state, which keeps serving.

import Foundation
import PixlModel

/// A track of this session the engine may seed a radio from, with what a radio request needs.
public struct AnchorInfo: Sendable, Equatable {
    public var rid: Int64
    public var mediaId: String
    public var title: String
    /// ONE artist name.
    public var primaryArtist: String
    public var spotifyId: String?
    public var videoId: String?
    public var durationMs: Int64

    public init(rid: Int64, mediaId: String, title: String, primaryArtist: String, spotifyId: String?, videoId: String?,
                durationMs: Int64) {
        self.rid = rid
        self.mediaId = mediaId
        self.title = title
        self.primaryArtist = primaryArtist
        self.spotifyId = spotifyId
        self.videoId = videoId
        self.durationMs = durationMs
    }
}

/// How one list was ranked, fixed when it was built (5.12 point 8): `source` is nil for the prior; `control` is true when the list
/// was ranked with the prior because its session is one of the one in ten; `modelVersion` is 1 when the learned weights ranked it,
/// else 0.
public struct RankingChoice: Sendable {
    public let source: Ranker.WeightSource?
    public let control: Bool
    public let modelVersion: Int32

    public init(source: Ranker.WeightSource?, control: Bool, modelVersion: Int32) {
        self.source = source
        self.control = control
        self.modelVersion = modelVersion
    }

    /// A list nothing ranked: the prior, no control.
    public static let none = RankingChoice(source: nil, control: false, modelVersion: 0)
}

/// What a finished play did to the session, for whoever reacts at once (the autoplay tail).
public struct Reaction: Sendable {
    public let event: PlayEvent
    public let graded: Reward.Graded
    /// The title of the track that played, for "Because you liked ...".
    public let title: String
    /// The third engine pick skipped hard in a row: the engine changes direction (`Direction`).
    public let changedDirection: Bool
    /// The session's anchors, newest first: what the engine seeds from when it is not turned. Empty when the
    /// session has none yet.
    public let anchors: [AnchorInfo]
    /// 0 while the engine follows `anchors`; otherwise the number of the turn it is on. A turn lasts while the
    /// engine's own picks play: the listener's next own track ends it.
    public let turn: Int
    /// What the engine seeds from while turned, best first. Empty with `turn` set means the session has nothing
    /// left to turn to, and the pool is seeded from the library.
    public let turnAnchors: [AnchorInfo]
    /// The folded primary artist of the track that played; "" when unknown.
    public let artistKey: String
    /// That artist is not to be queued for now (a hard skip): their picks leave the engine's tail.
    public let artistBlocked: Bool
    /// The track that played, as a radio request needs it: what a station re-seeds from (6.2).
    public let played: AnchorInfo?

    public init(event: PlayEvent, graded: Reward.Graded, title: String, changedDirection: Bool, anchors: [AnchorInfo],
                turn: Int = 0, turnAnchors: [AnchorInfo] = [], artistKey: String = "", artistBlocked: Bool = false,
                played: AnchorInfo? = nil) {
        self.played = played
        self.event = event
        self.graded = graded
        self.title = title
        self.changedDirection = changedDirection
        self.anchors = anchors
        self.turn = turn
        self.turnAnchors = turnAnchors
        self.artistKey = artistKey
        self.artistBlocked = artistBlocked
    }

    /// Turned, with no anchor of the session to follow.
    public var needsOtherDirection: Bool { turn != 0 && turnAnchors.isEmpty }

    public var liked: Bool {
        let positive = EventFlags.likedDuring | EventFlags.savedDuring | EventFlags.addedToPlaylist | EventFlags.replayed
        return event.flags & positive != 0 && !event.has(EventFlags.notForMe)
    }
}

/// What one autoplay plan reads, gathered by the caller (`AutoplayPlanning.inputs`).
public struct AutoplayPlanInputs: Sendable {
    public var candidates: [Candidate]
    public var prior: [ListBuilder.Prior]
    public var excludedRids: Set<Int64>
    public var seeds: [Retrieval.SeedList]
    public var nuMultiplier: Double
    public var nowMs: Int64
    public var tzOffsetMin: Int32
    public var batch: Int64
    /// The station the plan is for (8.3); nil for plain autoplay.
    public var station: Station?
    /// An album or playlist station, or one that was re-seeded: a track must be near the closest of its seeds.
    public var closestOfSeeds: Bool
    /// The plan replaces a whole tail by other picks ("Refresh picks"): a plan with none must not empty the tail.
    public var replaceAll: Bool

    public init(candidates: [Candidate], prior: [ListBuilder.Prior], excludedRids: Set<Int64>, seeds: [Retrieval.SeedList],
                nuMultiplier: Double, nowMs: Int64, tzOffsetMin: Int32, batch: Int64, station: Station? = nil,
                closestOfSeeds: Bool = false, replaceAll: Bool = false) {
        self.closestOfSeeds = closestOfSeeds
        self.replaceAll = replaceAll
        self.candidates = candidates
        self.prior = prior
        self.excludedRids = excludedRids
        self.seeds = seeds
        self.nuMultiplier = nuMultiplier
        self.nowMs = nowMs
        self.tzOffsetMin = tzOffsetMin
        self.batch = batch
        self.station = station
    }
}

/// The brain's state behind one actor.
public actor BrainEngine {
    /// What a rebuild reads from the rest of the app. Closures: nothing is loaded until a rebuild runs.
    public struct Sources: Sendable {
        public var library: @Sendable () async -> [Song]
        /// The app's own play history (`playback_history.json`).
        public var history: @Sendable () async -> [PlaybackEvent]
        /// A cheap value that changes when the imported history does (its size and newest play).
        public var importSignature: @Sendable () async -> String
        public var imported: @Sendable () async -> (plays: [ImportedPlay], taste: ExternalTasteSnapshot)
        /// The active taste adjustments.
        public var adjustments: @Sendable () async -> [TasteAdjustment]
        /// "Use my Spotify music to shape picks" (13.1): off, Spotify's own history and its top lists and follows are left
        /// out of the picks at the next rebuild; the app's own plays stay.
        public var spotifyShapesPicks: @Sendable () -> Bool

        public init(library: @escaping @Sendable () async -> [Song],
                    history: @escaping @Sendable () async -> [PlaybackEvent],
                    importSignature: @escaping @Sendable () async -> String,
                    imported: @escaping @Sendable () async -> (plays: [ImportedPlay], taste: ExternalTasteSnapshot),
                    adjustments: @escaping @Sendable () async -> [TasteAdjustment],
                    spotifyShapesPicks: @escaping @Sendable () -> Bool = { true }) {
            self.spotifyShapesPicks = spotifyShapesPicks
            self.library = library
            self.history = history
            self.importSignature = importSignature
            self.imported = imported
            self.adjustments = adjustments
        }
    }

    static let factsRefreshMs: Int64 = 7 * 24 * 60 * 60 * 1000
    static let resolveBatch = 400

    /// The learner's state (stage 3, 5.9): the ranker's weights, the gate's state and the figures Your sound reads. Held
    /// inside `Loaded`, so it changes only under the actor, one caller at a time.
    struct Learner: Sendable {
        var model: RankerModel
        var gate = Gate.State()
        var summary: Gate.Summary?
        /// `LearnReplay.version` the model was built under; 0 when there is none yet (a rebuild is due).
        var learnVersion = 0
        var rebuiltAtMs: Int64 = 0
        /// Favourites at the last rebuild (feature 8 of a live play).
        var liked: Set<Int64> = []
        /// The arm bandit and the novelty appetite (5.10), learned from the same plays as `model`.
        var posteriors = Posteriors.newState(today: 0)

        init(model: RankerModel) { self.model = model }

        /// The learned weights rank, and the copy may say so: the gate has them on and the model is valid.
        var useLearned: Bool { gate.useLearned && learnVersion == LearnReplay.version && model.isValid() }

        var saved: LearnerCodec.Saved {
            LearnerCodec.Saved(model: model, gate: gate, learnVersion: learnVersion, summary: summary, rebuiltAtMs: rebuiltAtMs)
        }
    }

    struct Loaded {
        var affinity: Affinity.State
        var tracker = GradeTracker()
        var session = SessionState()
        var learner = Learner(model: Ranker.newModel(today: 0))
        /// Bumped by "Reset what I've learned": a rebuild that started before it must not bring the old weights back.
        var learnEpoch = 0

        /// Which weights rank a list for the session `sessionId`: nil (the prior `M0`) while the gate has the prior on, and
        /// for one session in ten (the control sessions, 5.12 point 8). With `seed` the list gets one posterior sample (5.10).
        mutating func ranking(sessionId: Int64, seed: Int64? = nil, nowMs: Int64 = currentTimeMillis()) -> Ranker.WeightSource? {
            rankingChoice(sessionId: sessionId, seed: seed, nowMs: nowMs).source
        }

        /// `ranking` together with what the plays of the list must say about it (5.12 point 8): decided ONCE, when the list is
        /// built, and carried with each queue entry, so the control completion rate is measured on what was really ranked with
        /// the prior. A control exists only while the gate has the learned weights on (before that EVERY list is ranked with the prior,
        /// so there is nothing to compare it with, and a control flag would only mix eras in the comparison).
        mutating func rankingChoice(sessionId: Int64, seed: Int64? = nil, nowMs: Int64 = currentTimeMillis()) -> RankingChoice {
            let control = learner.useLearned && Ranker.isControlSession(controlKey(sessionId, nowMs: nowMs))
            if !learner.useLearned || control { return RankingChoice(source: nil, control: control, modelVersion: 0) }
            return RankingChoice(source: Ranker.WeightSource(model: learner.model, learned: true, seed: seed), control: false,
                                 modelVersion: BrainEngine.modelLearned)
        }

        /// The arm bandit of a list (5.10), seeded by `seed`: nil while the gate has the prior on and in a control session, so
        /// a listener on the standard recipe keeps stage 2's choice of the novel candidate exactly.
        mutating func armPicker(sessionId: Int64, family: Int, seed: Int64, nowMs: Int64 = currentTimeMillis()) -> (any ArmPicker)? {
            if !learner.useLearned || Ranker.isControlSession(controlKey(sessionId, nowMs: nowMs)) { return nil }
            return ArmBandit.Sampler(learner.posteriors.arms, family: family, seed: seed)
        }

        private var pendingKey: Int64 = 0
        private var pendingFor: Int64 = -1

        /// The id a list's control draw is taken on. A session's id is the start time of its first play, so before that play (right after
        /// the process starts, or after the session has expired and before the next play) there is no live id: the stored one is 0 or
        /// the old session's. Drawing on it would make every list built then the same kind for good (id 0 is never a control). Those
        /// lists are drawn on one key per gap instead (the time the gap was first seen), so about one in ten of them is a control too.
        mutating func controlKey(_ sessionId: Int64, nowMs: Int64) -> Int64 {
            let stale = sessionId == 0 || (sessionId == session.sessionId && Session.isExpired(session, startedAtMs: nowMs))
            if !stale { return sessionId }
            if pendingFor != sessionId {
                pendingFor = sessionId
                pendingKey = nowMs
            }
            return pendingKey
        }

        /// The novelty share a new session starts at (5.5): the learned appetite while the gate has the learned weights on, else
        /// stage 2's constant.
        func sessionNu(nowMs: Int64) -> Double {
            learner.useLearned ? NoveltyAppetite.nu(learner.posteriors.appetite, nowMs: nowMs) : Session.nuDefault
        }
        /// What a radio request needs for each of the session's anchors, by rid.
        var anchors: [Int64: AnchorInfo] = [:]
        /// Which way three skipped picks turned the engine, for this session.
        var direction = Direction()

        /// Starts a new session: the old one's lists, blocks, anchors and direction are gone.
        mutating func newSession(nowMs: Int64 = currentTimeMillis()) {
            session = SessionState()
            // A new gap before the next play: its lists are drawn on a fresh key (`controlKey`), and a control draw keeps the standard
            // share of new music.
            pendingFor = -1
            session.nuSession = learner.useLearned && Ranker.isControlSession(controlKey(0, nowMs: nowMs))
                ? Session.nuDefault : sessionNu(nowMs: nowMs)
            anchors.removeAll()
            direction = Direction()
        }
    }

    let log: BrainEventLog
    let repository: BrainRepository
    let clock: @Sendable () -> Int64
    /// "Don't count this" and the private session's spans are `feedback` rows (3.8).
    let feedbackStore: FeedbackStore
    /// Private session (8.5): the spans of this process, memory only.
    var privateSpans = PrivateSpans()
    var privateRowId: Int64 = 0
    let sources: Sources?
    var loaded: Loaded?
    /// The genre atlas, for the pseudo-counts of a genre the listener asked for more or less of (set by `configureAtlas`; nil leaves
    /// genre adjustments to the ranking-time boost alone).
    private var atlasProvider: (any AtlasProvider)?
    private var rebuildTask: Task<Void, Never>?
    private var learnGeneration = 0
    /// A forced rebuild asked for while another ran: the running one read the log before the change, so one more follows.
    private var rebuildAgain = false
    private var recordedDuringRebuild: [PlayEvent]?
    private var recoveredKilledPlay = false
    /// 6.1 "ignored three times": read with the first pool or Home row that asks, then kept current.
    private var ignoreTally: IgnoreTally?

    /// How long a rebuild that the first use of the state asked for (not a forced one) waits: the listener is scrolling Home or
    /// starting a song then, and a rebuild reads the whole log. The app passes `BrainEngine.appRebuildDelayMs`; tests wait for nothing.
    public static let appRebuildDelayMs: Int64 = 15_000
    private let rebuildDelayMs: Int64
    private var rebuildDelayCut = false

    public init(directory: URL, repository: BrainRepository, sources: Sources?, rebuildDelayMs: Int64 = 0,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.rebuildDelayMs = rebuildDelayMs
        log = BrainEventLog(directory: directory)
        feedbackStore = FeedbackStore(directory: directory)
        self.repository = repository
        self.sources = sources
        self.clock = clock
    }

    /// Hands the engine the atlas a rebuild reads genre names with. Reads nothing.
    public func configureAtlas(_ provider: any AtlasProvider) { atlasProvider = provider }

    // MARK: State

    private func ensureLoaded() {
        if loaded != nil { return }
        var state = Affinity.State()
        log.loadAffinity(into: &state)
        _ = state.drainTouched()
        let storedLearner = loadLearner()
        // A saved learner that cannot be read: the replay is due again.
        if storedLearner == nil, log.value(BrainEventLog.keyLearnVersion) != nil { log.setValue(BrainEventLog.keyLearnVersion, nil) }
        if log.value(BrainEventLog.keyFirstUseMs) == nil {
            log.setValue(BrainEventLog.keyFirstUseMs, String(clock()))
        }
        var fresh = Loaded(affinity: state)
        if let storedLearner { fresh.learner = storedLearner }
        loaded = fresh
        // First use reads the cache; a rebuild runs now only when the tables themselves are missing or stale (`urgentOnly`). The replay
        // that trains the learner, the gate and the weekly refresh of the facts run in the refresh worker (`rebuildIfDue`), so a play
        // or a Home plan never starts them (5.9: no second job).
        requestRebuild(force: false, urgentOnly: true)
    }

    /// One graded play into the state and the log: the event and the affinity rows it touched. Nil when the event
    /// was already stored (nothing changes then).
    func apply(_ event: PlayEvent, to state: inout Loaded) -> Reward.Graded? {
        if log.hasEvent(event.eventId) { return nil }
        // The learner reads the state as it was before the play is applied (5.9): its step runs in the hook, on a copy
        // of the model that is put back afterwards.
        var model = state.learner.model
        var posteriors = state.learner.posteriors
        var learnStatus = Ranker.updateSkipped
        let learnerReady = state.learner.learnVersion == LearnReplay.version
        let liked = state.learner.liked.contains(event.rid)
        let nowMs = clock()
        let graded = Brain.onEvent(affinity: &state.affinity, tracker: &state.tracker, session: &state.session,
                                   event: event) { e, g, affinity, session in
            if learnerReady {
                learnStatus = LearnReplay.applyLive(&model, posteriors: &posteriors, e, g, liked: liked, affinity: affinity,
                                                    session: session, nowMs: nowMs)
            }
        }
        if learnerReady {
            state.learner.model = model
            state.learner.posteriors = posteriors
        }
        var rows: [Affinity.Row] = []
        var seen: Set<Affinity.RowRef> = []
        for ref in state.affinity.drainTouched() where seen.insert(ref).inserted {
            if let row = state.affinity.row(ref) { rows.append(row) }
        }
        // The tally of 6.1 is read BEFORE the event is stored: the first time ever it is built from the log, and
        // the event must not be in it twice.
        let countsForTally = IgnoreTally.counts(event)
        if countsForTally, ignoreTally == nil { ignoreTally = log.loadIgnoreTally(nowMs: clock()) }
        log.insert([event])
        // Where the live log begins (`LegacyMigration.cutoff`): the start of its first live play.
        if event.origin == Origin.live, log.value(BrainEventLog.keyFirstLiveStartMs) == nil {
            log.setValue(BrainEventLog.keyFirstLiveStartMs, String(event.startedAtMs))
        }
        log.upsertAffinity(rows)
        // The learner is saved right after the play it learned from: a crash between the two loses one step and never
        // applies one twice (the watermark). The files are separate here, so this is not one transaction as on Android.
        if learnerReady {
            log.setValue(BrainEventLog.keyLearner, LearnerCodec.encode(state.learner.saved))
            log.setValue(BrainEventLog.keyPosteriors, PosteriorCodec.encode(state.learner.posteriors))
        }
        if countsForTally, let row = ignoreTally?.note(event) { log.putIgnoreRow(rid: event.rid, row) }
        recordedDuringRebuild?.append(event)
        // A value that was not finite sent the model back to its prior: replay it from the log (5.12 point 2).
        if learnStatus == Ranker.updateReset || Affinity.clockJumpedBack(state.affinity, nowMs: clock()) { requestRebuild(force: true) }
        return graded
    }

    /// Takes the state out of the actor's property for one synchronous step (so its tables are changed in place,
    /// not copied) and puts it back.
    func withState<T>(_ body: (inout Loaded) -> T) -> T {
        ensureLoaded()
        var state = loaded!
        loaded = nil
        let result = body(&state)
        loaded = state
        return result
    }

    // MARK: Recording (4.2)

    /// Records one play. Nil when it could not be identified or was already stored. Plays must arrive one at a
    /// time and in order (`BrainRecorder` sees to that).
    public func record(_ play: FinishedPlay) async -> Reaction? {
        let context = play.context
        guard let facts = TrackCatalog.facts(of: context, durationMs: play.durationMs) else { return nil }
        let durationMs = Int32(clamping: max(play.durationMs > 0 ? play.durationMs : facts.durationMs, 0))
        let names = [facts.primaryArtist] + facts.otherArtists.prefix(PlayEvent.maxOtherAids)
        let resolved = await repository.resolve(keys: facts.keys, durationMs: durationMs, artistNames: names)
        let rid = resolved.rid
        if rid == 0 { return nil }
        let aids = resolved.aids
        let tag = context.tag
        var flags = play.flags
        if context.shuffle { flags |= EventFlags.shuffle }
        if context.repeatOne { flags |= EventFlags.repeatOne }
        if context.offline { flags |= EventFlags.offline }
        // A play that overlapped a private session counts for nothing in the picks; the log still has it (8.5).
        if privateSpans.overlaps(startMs: play.startedAtMs, endMs: play.startedAtMs &+ max(play.playedMs, 0)) {
            flags |= EventFlags.learnExcluded
        }

        // From here on nothing suspends: the state changes in one step.
        return withState { state -> Reaction? in
        let firstSession = state.session.sessionId == 0
        var newSession = false
        if state.session.sessionId != 0 && Session.isExpired(state.session, startedAtMs: play.startedAtMs) {
            state.newSession(nowMs: play.startedAtMs)
            newSession = true
        }
        let stamp = Session.begin(&state.session, startedAtMs: play.startedAtMs, startReason: context.startReason)
        // A session starts at the novelty share of the moment (5.5): the learned appetite while the gate has the learned weights on.
        // A control session (5.12 point 8) is ranked with the standard recipe, and that includes its share of new music.
        if firstSession || newSession {
            state.session.nuSession = state.learner.useLearned && Ranker.isControlSession(stamp.sessionId)
                ? Session.nuDefault : state.sessionNu(nowMs: play.startedAtMs)
        }
        // One session in ten is ranked with the prior and flagged (5.12 point 8). Which weights ranked a list, and whether it was a
        // control, was decided when the list was BUILT and travels with the queue entry (`BrainItemTag.control`, `modelVersion`):
        // it is read here, never worked out at the end of the play. An entry that carries nothing (a track the listener chose, a
        // queue saved by an older build) is the prior and not a control.
        var eventFlags = flags
        if tag?.control == true { eventFlags |= EventFlags.controlSession }
        // A novel slot the arm bandit drew is an exploration slot: logged, and weighted 1.5 by the grade (5.12 point 3).
        if tag?.explore == true { eventFlags |= EventFlags.exploreSlot }
        let surfaceId = String((tag?.surfaceId ?? "").unicodeScalars.prefix(PlayEvent.maxSurfaceIdLength))
        let log = self.log
        let event = PlayEvent(
            eventId: PlayEvent.mintId(startedAtMs: play.startedAtMs, origin: Origin.live, keyAtWrite: facts.keyAtWrite,
                                      identityAt: { log.eventIdentity(at: $0) }),
            origin: Origin.live,
            rid: rid,
            primaryAid: aids.first ?? 0,
            otherAids: Array(aids.dropFirst()),
            keyAtWrite: facts.keyAtWrite,
            startedAtMs: play.startedAtMs,
            tzOffsetMin: play.tzOffsetMin,
            playedMs: Int32(clamping: max(play.playedMs, 0)),
            durationMs: durationMs,
            startReason: context.startReason,
            endReason: play.endReason,
            flags: eventFlags,
            surface: Surface.codeOf(tag?.surface),
            surfaceId: surfaceId,
            recId: tag?.recId ?? 0,
            slot: Int32(clamping: tag?.slot ?? -1),
            arm: Arm.codeOf(tag?.arm),
            sessionId: stamp.sessionId,
            posInSession: stamp.posInSession,
            passiveRun: stamp.passiveRun,
            route: context.route,
            retrQ: Int32(clamping: tag?.retrQ ?? -1),
            radioRank: Int32(clamping: tag?.radioRank ?? -1),
            modelVersion: (tag?.modelVersion ?? -1) >= 0 ? Int32(clamping: tag?.modelVersion ?? 0) : 0,
            servedX: ServedVector.fromHex(tag?.servedX)
        )
        guard let graded = apply(event, to: &state) else { return nil }
        // A play a Home row may be built around is written down beside the event (8.1): the event itself holds
        // ids, not a title or a media id.
        if HomeAnchors.qualifies(event, graded) {
            let anchor = HomeAnchor(rid: rid, aid: event.primaryAid, mediaId: play.songId, title: facts.title,
                                    primaryArtist: facts.primaryArtist, spotifyId: facts.spotifyId,
                                    videoId: facts.videoId, durationMs: facts.durationMs, heardAtMs: event.endedAtMs)
            let current = HomeAnchors.decode(log.value(BrainEventLog.keyHomeAnchors))
            log.setValue(BrainEventLog.keyHomeAnchors, HomeAnchors.encode(HomeAnchors.push(current, anchor)))
        }
        // Keep what a radio request needs for the tracks the session now anchors on.
        let session = state.session
        let anchorRids = Array(session.anchors[0..<session.anchorCount])
        if anchorRids.contains(rid) {
            state.anchors[rid] = AnchorInfo(rid: rid, mediaId: play.songId, title: facts.title,
                                              primaryArtist: facts.primaryArtist, spotifyId: facts.spotifyId,
                                              videoId: facts.videoId, durationMs: facts.durationMs)
        }
        if state.anchors.count > Session.maxAnchors {
            for key in Array(state.anchors.keys) where !anchorRids.contains(key) { state.anchors[key] = nil }
        }
        // Only the engine's own picks, skipped hard three times in a row, turn it; the listener's next own track
        // turns it back (`Direction`).
        let notForMe = event.has(EventFlags.notForMe)
        let positiveFlags = EventFlags.likedDuring | EventFlags.savedDuring | EventFlags.addedToPlaylist | EventFlags.replayed
        let likedNow = !notForMe && event.flags & positiveFlags != 0
        let h = notForMe ? 1.0 : graded.h
        let changed = state.direction.onEvent(
            enginePick: context.isEngineOwned,
            station: event.surface == Surface.station,
            hardSkip: graded.c > 0.0 && h >= Session.hardSkip,
            positive: graded.c > 0.0 && h == 0.0 && (graded.isCompletion || likedNow),
            anchors: anchorRids)
        let known = state.anchors
        let turn = state.direction.turn
        return Reaction(
            event: event,
            graded: graded,
            title: facts.title,
            changedDirection: changed,
            anchors: anchorRids.compactMap { known[$0] },
            turn: turn,
            turnAnchors: turn == 0 ? [] : state.direction.follow(anchorRids).compactMap { known[$0] },
            artistKey: BrainText.fold(facts.primaryArtist),
            artistBlocked: session.isBlocked(event.primaryAid),
            played: AnchorInfo(rid: rid, mediaId: play.songId, title: facts.title, primaryArtist: facts.primaryArtist,
                               spotifyId: facts.spotifyId, videoId: facts.videoId, durationMs: facts.durationMs)
        )
        }
    }

    /// The play in flight, as far as it got; nil clears it. Written down so that a play cut off by a process death
    /// is still recorded, as `killed`.
    public func setOpenPlay(_ play: FinishedPlay?) {
        var play = play
        // A play that overlaps a private session is saved as left out, so one cut off by the process ending is not counted.
        if let p = play, privateSpans.overlaps(startMs: p.startedAtMs, endMs: clock()) { play?.flags |= EventFlags.learnExcluded }
        log.setValue(BrainEventLog.keyOpenPlay, play.map(OpenPlayCodec.encode))
    }

    /// A play left open by a process that died is recorded as `killed`, with what it had heard by its last pause.
    /// Runs once per process, before the first play is recorded.
    public func recoverKilledPlay() async {
        if recoveredKilledPlay { return }
        recoveredKilledPlay = true
        guard let saved = log.value(BrainEventLog.keyOpenPlay) else { return }
        log.setValue(BrainEventLog.keyOpenPlay, nil)
        guard var play = OpenPlayCodec.decode(saved) else { return }
        play.endReason = EndReason.killed
        _ = await record(play)
    }

    // MARK: Planning (7.1, 7.3)

    /// Runs the pure planner on the brain's state. `tail` non-nil asks for a patch of that tail (nil back means
    /// "nothing changes"). The plan is consumed: a like's scheduled slot and the "second skip" slot are spent.
    public func plan(_ inputs: AutoplayPlanInputs, count: Int, bridge: Bool, tail: [Int64]?) -> StationPlanner.Plan? {
        return withState { state -> StationPlanner.Plan? in
        // What the session's skip rules need to know about a station: its seed artist is thinned out after skips,
        // never blocked (5.5). Plain autoplay has no seed.
        let stationSeed = inputs.station != nil ? inputs.seeds.first : nil
        if let station = inputs.station, let stationSeed {
            state.session.seed = stationSeed.seedRid
            state.session.seedAid = stationSeed.seedAid
            state.session.seedKind = station.kind
        } else {
            state.session.seed = 0
            state.session.seedAid = 0
            state.session.seedKind = Session.seedNone
        }
        let session = state.session
        // Decided once, here, when the list is built; each queue entry carries it (5.12 point 8).
        let choice = state.rankingChoice(sessionId: state.session.sessionId, nowMs: clock())
        let graph = StationPlanner.buildGraph(seeds: inputs.seeds, candidates: inputs.candidates, session: session)
        // 6.2: a station's ties break by its seed and the day; autoplay's by the session.
        let tieSeed = stationSeed.map {
            $0.seedRid ^ BrainMath.localDay(inputs.nowMs, tzOffsetMin: inputs.tzOffsetMin) ^ inputs.batch
        } ?? (session.sessionId ^ inputs.batch)
        let request = StationPlanner.Request(
            mode: inputs.station != nil ? StationPlanner.modeStation : StationPlanner.modeAutoplay, count: count,
            candidates: inputs.candidates, seeds: inputs.seeds,
            prior: inputs.prior, nowMs: inputs.nowMs, tzOffsetMin: inputs.tzOffsetMin, nuMultiplier: inputs.nuMultiplier,
            tieSeed: tieSeed, excludedRids: inputs.excludedRids, bridge: bridge,
            closestOfSeeds: inputs.closestOfSeeds,
            // Stage 3: the learned weights, unless the gate has the prior on or this is a control session (5.12 point 8).
            ranking: choice.source,
            // 5.10: a novel slot goes to the arm the bandit draws, while the learned weights are on (nil: stage 2's choice, exactly).
            armPicker: state.armPicker(sessionId: state.session.sessionId, family: ArmBandit.station,
                                       seed: Int64(bitPattern: BrainHash.splitmix64(UInt64(bitPattern: state.session.sessionId ^ (inputs.batch << 8) ^ Self.armSeedTag))),
                                       nowMs: clock()))
        var plan: StationPlanner.Plan?
        if let tail {
            plan = Session.patchQueue(session, tail: tail, request: request, affinity: state.affinity, graph: graph)
        } else {
            plan = StationPlanner.plan(request, affinity: state.affinity, session: session, graph: graph)
        }
        if var made = plan {
            StationPlanner.consume(&state.session, made)
            made.control = choice.control
            made.modelVersion = choice.modelVersion
            plan = made
        }
        return plan
        }
    }

    /// Mixed into the seed of a batch's arm draws, so they do not repeat the tie-break's random stream.
    static let armSeedTag: Int64 = 0x41524D53

    // MARK: Home rows (8.1) and what the engine keeps out (6.1)

    /// True once the brain's state is in memory in this process: something played, or a plan was made. Home never
    /// loads it (nothing at app start).
    public var isLoaded: Bool { loaded != nil }

    /// The newest plays a Home row may be built around, newest first.
    public func homeAnchors() -> [HomeAnchor] {
        HomeAnchors.decode(log.value(BrainEventLog.keyHomeAnchors))
    }

    /// Plans one "Because you listened to" row. Home is not part of the listening session: the plan runs against a
    /// FRESH session, so a skip a minute ago does not reshuffle the page, and consumes nothing.
    public func planHomeRow(candidates: [Candidate], seed: Retrieval.SeedList, count: Int, nowMs: Int64, tzOffsetMin: Int32,
                            excludedRids: Set<Int64>) -> StationPlanner.Plan {
        withState { state in
            let session = SessionState()
            let choice = state.rankingChoice(sessionId: state.session.sessionId, nowMs: nowMs)
            let graph = StationPlanner.buildGraph(seeds: [seed], candidates: candidates, session: session)
            let tie = seed.seedRid ^ BrainMath.localDay(nowMs, tzOffsetMin: tzOffsetMin)
            let request = StationPlanner.Request(
                mode: StationPlanner.modeHomeRow, count: count, candidates: candidates, seeds: [seed], nowMs: nowMs,
                tzOffsetMin: tzOffsetMin, tieSeed: tie, excludedRids: excludedRids, ranking: choice.source,
                armPicker: state.armPicker(sessionId: state.session.sessionId, family: ArmBandit.home, seed: tie ^ Self.armSeedTag,
                                           nowMs: nowMs))
            var plan = StationPlanner.plan(request, affinity: state.affinity, session: session, graph: graph)
            plan.control = choice.control
            plan.modelVersion = choice.modelVersion
            return plan
        }
    }

    /// Recordings the listener ignored three times in the last 60 days (6.1): three or more engine-served plays
    /// under 30 s and none of 30 s or more.
    public func ignoredRids(nowMs: Int64) -> Set<Int64> {
        if ignoreTally == nil { ignoreTally = log.loadIgnoreTally(nowMs: nowMs) }
        return ignoreTally?.ignored(nowMs: nowMs) ?? []
    }

    /// For a change of direction with no other anchor (7.3): which of `aids` to try, best first. Artists the
    /// listener finishes more often than their base rate, outside the ones skipped or blocked in this session;
    /// highest affinity first, then the smaller id. At most `limit` indices into `aids`.
    public func otherDirectionOrder(aids: [Int64], nowMs: Int64, limit: Int = 5) -> [Int] {
        ensureLoaded()
        let state = loaded!
        let p0 = Affinity.p0(state.affinity, nowMs: nowMs)
        var scored: [(index: Int, aff: Double)] = []
        for (i, aid) in aids.enumerated() where aid != 0 && state.session.skipsOf(aid) == 0 && !state.session.isBlocked(aid) {
            let aff = Affinity.aff(state.affinity, family: Family.artist, key: aid, nowMs: nowMs, p0: p0)
            if aff > 0.0 { scored.append((i, aff)) }
        }
        scored.sort { a, b in
            let ka = BrainMath.orderKey(a.aff)
            let kb = BrainMath.orderKey(b.aff)
            if ka != kb { return ka > kb }
            return aids[a.index] < aids[b.index]
        }
        return scored.prefix(limit).map(\.index)
    }

    // MARK: Mixes (8.2) and the refresh (3.6, 3.7)

    /// How many different tracks the listener has played: what `BrainEngineChoice.hasState` reads. Loads the state on
    /// first use, which is why the callers wait until the app has started.
    public func heardTrackCount() -> Int {
        ensureLoaded()
        return loaded!.affinity.size(Family.track)
    }

    public func hasState() -> Bool { BrainEngineChoice.hasState(heardTracks: heardTrackCount()) }

    /// Reads the affinity tables for one synchronous step; nothing is changed.
    public func readAffinity<T: Sendable>(_ body: @Sendable (Affinity.State) -> T) -> T {
        ensureLoaded()
        return body(loaded!.affinity)
    }

    /// Plans a Daily Mix or Your Mix on the brain's state. Against a FRESH session (a skip a minute ago does not
    /// reshuffle a mix that was built this morning) and nothing is consumed: a mix is not part of the listening session.
    public func planMix(_ request: MixPlanner.Request) -> StationPlanner.Plan {
        ensureLoaded()
        // Stage 3: the learned weights rank the list while the gate has them on (one posterior sample per list and day, 5.10).
        var request = request
        let seed = Ranker.listSeed(salt: request.salt, listId: "mix:\(request.kind):\(request.islandIdx):\(request.regenerate)",
                                   localDay: Repetition.mixDay(request.nowMs, tzOffsetMin: request.tzOffsetMin))
        // How it was ranked is decided here, once, and saved with the list: its plays carry it (5.12 point 8).
        let choice = loaded!.rankingChoice(sessionId: loaded!.session.sessionId, seed: seed, nowMs: request.nowMs)
        request.ranking = choice.source
        // 5.10: the arm bandit and the learned appetite, while the learned weights rank this list; stage 2's values otherwise.
        request.armPicker = loaded!.armPicker(sessionId: loaded!.session.sessionId, family: ArmBandit.mix, seed: seed ^ Self.armSeedTag,
                                              nowMs: request.nowMs)
        request.nuBase = choice.modelVersion == Self.modelLearned
            ? NoveltyAppetite.nu(loaded!.learner.posteriors.appetite, nowMs: request.nowMs) : MixPlanner.nu0
        var plan = MixPlanner.plan(request, affinity: loaded!.affinity)
        plan.control = choice.control
        plan.modelVersion = choice.modelVersion
        return plan
    }

    /// The events that started at or after `sinceMs`, oldest first (the seeds of the refresh read the last weeks).
    public func recentEvents(sinceMs: Int64) -> [PlayEvent] { log.events(startedSince: sinceMs) }

    /// The install's random salt: lists differ between listeners. Made once and kept.
    public func salt() -> Int64 {
        if let text = log.value(Self.saltKey), let value = Int64(text) { return value }
        let fresh = Int64.random(in: Int64.min...Int64.max)
        log.setValue(Self.saltKey, String(fresh))
        return fresh
    }

    static let saltKey = "salt"

    // MARK: Rebuild (4.4)

    /// Asks for a rebuild in the background. Without `force` it only runs when one is needed.
    public func requestRebuild(force: Bool, urgentOnly: Bool = false, delayed: Bool = true) {
        guard sources != nil else { return }
        if rebuildTask != nil {
            // Not dropped: an exclusion, its Undo or the Spotify switch changed what the running rebuild reads.
            if force {
                rebuildAgain = true
                rebuildDelayCut = true
            }
            return
        }
        rebuildDelayCut = false
        let delay = force || !delayed ? 0 : rebuildDelayMs
        rebuildTask = Task { [weak self] in
            await self?.waitBeforeRebuild(delay)
            await self?.runRebuild(force: force, urgentOnly: urgentOnly)
            await self?.finishRebuilds()
        }
    }

    private func waitBeforeRebuild(_ ms: Int64) async {
        var left = ms
        while left > 0 && !rebuildDelayCut {
            try? await Task.sleep(for: .milliseconds(250))
            left -= 250
        }
    }

    private func finishRebuilds() async {
        while rebuildAgain {
            rebuildAgain = false
            await runRebuild(force: true)
        }
        rebuildTask = nil
    }

    /// Waits for a rebuild that is running. For tests; nothing in the app blocks on it.
    public func awaitRebuild() async {
        await rebuildTask?.value
    }

    /// The refresh worker's part (5.9, "no second job"): the replay that trains the learner and decides the gate, and the weekly refresh
    /// of the facts, when they are due. Waits for the rebuild it started, so the work stays inside the worker's run.
    public func rebuildIfDue() async {
        ensureLoaded()
        for _ in 0..<2 {
            requestRebuild(force: false, urgentOnly: false, delayed: false)
            await awaitRebuild()
        }
    }

    /// `urgentOnly`: only what cannot wait for the refresh worker (the tables are missing or were built by other logic, or the import or
    /// the Spotify switch changed). The learner's replay and the weekly refresh of the facts are not urgent.
    private func isRebuildNeeded(importSignature: String, nowMs: Int64, urgentOnly: Bool = false) -> Bool {
        if log.value(BrainEventLog.keyHistoryMigrated) == nil { return true }
        if log.value(BrainEventLog.keySpecVersion) != String(Brain.specVersion) { return true }
        if log.value(BrainEventLog.keyImportCount) != importSignature { return true }
        // "Use my Spotify music to shape picks" was flipped since the last rebuild: the tables change with it.
        if (log.value(BrainEventLog.keySpotifyShapes) ?? "true") != String(sources?.spotifyShapesPicks() ?? true) { return true }
        if urgentOnly { return false }
        // The learner (stage 3) is missing, or was built by other logic: replay it.
        if log.value(BrainEventLog.keyLearnVersion) != String(LearnReplay.version) { return true }
        // The facts (likes, top lists, follows, taste changes) are folded in at a rebuild; a weekly one keeps them
        // current without a background job.
        let rebuiltAt = log.value(BrainEventLog.keyRebuiltAtMs).flatMap { Int64($0) } ?? 0
        let age = nowMs - rebuiltAt
        return age < 0 || age > Self.factsRefreshMs
    }

    private func runRebuild(force: Bool, urgentOnly: Bool = false) async {
        guard let sources else { return }
        let nowMs = clock()
        let importSignature = await sources.importSignature()
        if !force && !isRebuildNeeded(importSignature: importSignature, nowMs: nowMs, urgentOnly: urgentOnly) { return }
        recordedDuringRebuild = []
        let epochAtStart = loaded?.learnEpoch ?? 0

        let library = await sources.library()
        var songById: [BrainKey: Song] = [:]
        songById.reserveCapacity(library.count)
        for song in library where songById[BrainKey(song.id)] == nil { songById[BrainKey(song.id)] = song }

        // The library by recording id: lengths for imported plays, and the facts below. Folding every title and
        // artist of the library is seconds of text work on a big one: off this actor, so a plan or a play that
        // ends meanwhile does not wait behind it.
        let libraryFacts = await Task.detached(priority: .utility) { library.map(TrackCatalog.facts(of:)) }.value
        var libraryRids = [Int64](repeating: 0, count: library.count)
        var from = 0
        while from < library.count {
            let to = min(from + Self.resolveBatch, library.count)
            let requests = (from..<to).map { i -> TrackRequest in
                TrackRequest(keys: libraryFacts[i]?.keys ?? Ids.TrackKeys(),
                             durationMs: Int32(clamping: max(libraryFacts[i]?.durationMs ?? 0, 0)))
            }
            let resolved = await repository.resolveTracks(requests)
            for i in from..<to { libraryRids[i] = resolved[i - from] }
            from = to
        }
        var durationByRid: [Int64: Int32] = [:]
        var ridBySongId: [BrainKey: Int64] = [:]
        for i in library.indices where libraryRids[i] != 0 {
            ridBySongId[BrainKey(library[i].id)] = libraryRids[i]
            if library[i].duration > 0 { durationByRid[libraryRids[i]] = Int32(clamping: library[i].duration) }
        }

        // Step 2: the app's own older plays, once.
        if log.value(BrainEventLog.keyHistoryMigrated) == nil {
            let cutoff = LegacyMigration.cutoff(
                firstUseMs: log.value(BrainEventLog.keyFirstUseMs).flatMap { Int64($0) } ?? nowMs,
                firstLiveStartMs: log.value(BrainEventLog.keyFirstLiveStartMs).flatMap { Int64($0) })
            let rows = await sources.history()
            var resolved: [BrainKey: ResolvedTrack] = [:]
            var seen: Set<BrainKey> = []
            for row in rows where seen.insert(BrainKey(row.songId)).inserted {
                var facts: TrackFacts?
                if let song = songById[BrainKey(row.songId)] {
                    facts = TrackCatalog.facts(of: song)
                } else if let record = await repository.playable(songId: row.songId) {
                    facts = TrackCatalog.facts(of: record)
                }
                guard let facts else { continue }
                let durationMs = Int32(clamping: max(facts.durationMs, 0))
                let names = [facts.primaryArtist] + facts.otherArtists.prefix(PlayEvent.maxOtherAids)
                let ids = await repository.resolve(keys: facts.keys, durationMs: durationMs, artistNames: names)
                if ids.rid == 0 { continue }
                resolved[BrainKey(row.songId)] = ResolvedTrack(rid: ids.rid, primaryAid: ids.aids.first ?? 0,
                                                               otherAids: Array(ids.aids.dropFirst()), key: facts.keyAtWrite,
                                                               durationMs: durationMs)
            }
            let log = self.log
            log.insert(LegacyMigration.events(rows: rows, cutoffMs: cutoff, resolved: resolved,
                                              identityAt: { log.eventIdentity(at: $0) }))
            log.setValue(BrainEventLog.keyHistoryMigrated, String(nowMs))
        }

        // Step 1: imported history is read, not copied. One resolution per distinct track.
        let shapes = sources.spotifyShapesPicks()
        var imported = await sources.imported()
        // Off: Spotify's own history and its lists are left out of the picks (owner question 1); the app's own plays stay.
        if !shapes { imported = (imported.plays.filter { !$0.source.isSpotify }, ExternalTasteSnapshot()) }
        let importedResolved = await resolveImported(imported.plays)

        // Step 4: facts that are not events.
        let adjustments = await sources.adjustments()
        let names = LibraryFactsBuilder.names(library: library, taste: imported.taste, adjustments: adjustments)
        let aids = await repository.resolveArtistNames(names.artists)
        var aidByName: [BrainKey: Int64] = [:]
        for (i, name) in names.artists.enumerated() { aidByName[BrainKey(name)] = aids[i] }
        let topTrackRids = await repository.resolveTracks(names.topTracks)
        let taste = imported.taste
        let ridsBySong = ridBySongId
        let aidsByName = aidByName
        // A genre the listener asked for more or less of (8.7) becomes a pseudo-count on its tag: only a name the atlas knows.
        var genreIds: [BrainKey: Int] = [:]
        let genreLabels = adjustments.filter { $0.targetType == .genre && $0.kind.isWeight }.map(\.label)
        if !genreLabels.isEmpty, let atlas = await atlasProvider?.atlas() {
            for label in genreLabels {
                let id = atlas.idForName(label)
                if id != GenreAtlas.none { genreIds[BrainKey(label)] = id }
            }
        }
        let genreIdByName = genreIds
        let facts = await Task.detached(priority: .utility) {
            LibraryFactsBuilder.build(library: library, ridBySongId: ridsBySong, taste: taste, adjustments: adjustments,
                                      aidByName: aidsByName, topTrackRids: topTrackRids, genreIdByName: genreIdByName)
        }.value

        let merges = await repository.trackMerges()
        let excludedAt = songExclusions(merges)
        let excludedMap = excludedAt
        // The stored events are read as bytes here and decoded off the actor (a long history is tens of thousands of
        // lines of JSON): a play that ends meanwhile is recorded without waiting for them.
        var liked: Set<Int64> = []
        for f in facts.liked { liked.insert(merges[f.rid] ?? f.rid) }
        let likedRids = liked
        let learnAfter = log.value(BrainEventLog.keyLearnAfter).flatMap { Int64($0) } ?? Int64.min
        let tzNowMin = Int32(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000)) / 60)
        let storedPayloads = log.allEventPayloads()
        let plays = imported.plays
        let lengths = durationByRid
        let resolvedImports = importedResolved
        // The fold itself is arithmetic over every play ever recorded or imported: off this actor, so a play that
        // ends meanwhile is recorded without waiting for it.
        let result = await Task.detached(priority: .utility) { () -> ReplayMerger.Result in
            let stored = BrainEventLog.decodeSorted(storedPayloads)
            let events = ImportedPlayAdapter.events(plays: plays, resolved: resolvedImports,
                                                    durationOfRid: { lengths[$0] ?? 0 })
            return ReplayMerger.rebuild(stored: stored, imported: events, facts: facts, nowMs: nowMs,
                                        excluded: excludedMap, learn: true, likedRids: likedRids,
                                        learnAfterEventId: learnAfter, tzNowMin: tzNowMin, survivorOf: { merges[$0] ?? $0 })
        }.value

        // Plays that ended while the rebuild ran and that it did not read from the log.
        var state = result.state
        var tracker = GradeTracker()
        // The learner of this replay, unless the listener reset what was learned while it ran.
        var adopted: Learner?
        if let replayed = result.learned, (loaded?.learnEpoch ?? 0) == epochAtStart {
            let summary = Gate.summarize(replayed.predictions, nowMs: nowMs)
            var learner = Learner(model: replayed.model)
            // From 2,000 graded plays a week counts only when the bootstrap interval of test 6 is above zero too (the gain is not noise).
            let above = summary.playsTotal < LearnReplay.test6MinPlays || LearnReplay.test6(replayed.predictions).gainLow > 0.0
            learner.gate = Gate.decide(loaded?.learner.gate ?? Gate.State(), summary, nowMs: nowMs, intervalAboveZero: above)
            learner.summary = summary
            learner.learnVersion = LearnReplay.version
            learner.rebuiltAtMs = nowMs
            learner.liked = likedRids
            learner.posteriors = replayed.posteriors
            adopted = learner
        }
        // The session features of these plays come from a session built from them, as the replay builds it (not an empty one), and the
        // clock is the one now: a play that started after the rebuild began keeps its own day.
        var catchUpSession = SessionState()
        let catchUpNow = max(clock(), nowMs)
        for event in recordedDuringRebuild ?? [] where !result.recentEventIds.contains(event.eventId) {
            let novelBefore = !Affinity.isHeard(state, family: Family.track, key: event.rid)
            let graded = tracker.grade(event, completions: state.completions)
            if Session.isExpired(catchUpSession, startedAtMs: event.startedAtMs) { catchUpSession = SessionState() }
            _ = Session.begin(&catchUpSession, startedAtMs: event.startedAtMs, startReason: event.startReason)
            if adopted != nil {
                var learner = adopted!
                adopted = nil
                LearnReplay.applyLive(&learner.model, posteriors: &learner.posteriors, event, graded,
                                      liked: learner.liked.contains(event.rid), affinity: state, session: catchUpSession,
                                      nowMs: catchUpNow)
                adopted = learner
            }
            Affinity.applyEvent(&state, event, graded, tMs: event.startedAtMs)
            Session.apply(&catchUpSession, event, graded, novel: novelBefore)
        }
        _ = state.drainTouched()
        recordedDuringRebuild = nil
        log.replaceAffinity(state.rows())
        if let adopted {
            log.setValue(BrainEventLog.keyLearner, LearnerCodec.encode(adopted.saved))
            log.setValue(BrainEventLog.keyPosteriors, PosteriorCodec.encode(adopted.posteriors))
            log.setLikedText(Self.encodeLiked(adopted.liked))
            log.setValue(BrainEventLog.keyLearnVersion, String(LearnReplay.version))
        }
        log.setValue(BrainEventLog.keySpecVersion, String(Brain.specVersion))
        log.setValue(BrainEventLog.keyImportCount, importSignature)
        log.setValue(BrainEventLog.keySpotifyShapes, String(shapes))
        log.setValue(BrainEventLog.keyRebuiltAtMs, String(nowMs))
        if loaded != nil {
            loaded!.affinity = state
            loaded!.tracker = tracker
            if let adopted {
                loaded!.learner = adopted
                learnGeneration += 1
            }
        }
    }

    /// One resolution per distinct imported track: the recording and artist ids a play of the imported history stands for.
    private func resolveImported(_ importedPlays: [ImportedPlay]) async -> [BrainKey: ResolvedTrack] {
        var importedResolved: [BrainKey: ResolvedTrack] = [:]
        // One key per imported play (50,000 and more of them, each a fold and a title clean): off this actor too.
        let pending = await Task.detached(priority: .utility) {
            () -> (keys: [BrainKey], requests: [TrackRequest], artists: [String], keyTexts: [String]) in
            var keys: [BrainKey] = []
            var requests: [TrackRequest] = []
            var artists: [String] = []
            var keyTexts: [String] = []
            var seen: Set<BrainKey> = []
            for play in importedPlays {
                let cacheKey = BrainKey(ImportedPlayAdapter.cacheKey(play))
                guard seen.insert(cacheKey).inserted, let found = ImportedPlayAdapter.keys(play) else { continue }
                keys.append(cacheKey)
                requests.append(TrackRequest(keys: found.keys, durationMs: 0))
                artists.append(play.artist)
                keyTexts.append(found.key)
            }
            return (keys, requests, artists, keyTexts)
        }.value
        var from = 0
        while from < pending.requests.count {
            let to = min(from + Self.resolveBatch, pending.requests.count)
            let rids = await repository.resolveTracks(Array(pending.requests[from..<to]))
            let aids = await repository.resolveArtistNames(Array(pending.artists[from..<to]))
            for i in from..<to where rids[i - from] != 0 {
                importedResolved[pending.keys[i]] = ResolvedTrack(rid: rids[i - from], primaryAid: aids[i - from],
                                                                  key: pending.keyTexts[i])
            }
            from = to
        }
        return importedResolved
    }

    /// "Don't count this" on a song reaches its imported plays too (the log holds only the plays made here): surviving recording -> when
    /// it was said.
    private func songExclusions(_ merges: [Int64: Int64]) -> [Int64: Int64] {
        var excludedAt: [Int64: Int64] = [:]
        for row in feedbackStore.active() where row.kind == FeedbackKinds.dontCount && row.targetKind == FeedbackKinds.targetSong {
            let survivor = merges[row.targetId] ?? row.targetId
            excludedAt[survivor] = max(excludedAt[survivor] ?? 0, row.createdAtMs)
        }
        return excludedAt
    }

    /// The stored log and the imported history as ONE stream in event order, as a rebuild reads them (duplicates dropped, merged
    /// recordings mapped to their survivor, "Don't count this" applied): what Your sound counts, so a listener with years of imported
    /// history sees them too. Off the engine's own work: the bytes are read here, decoding and merging run detached.
    public func mergedPlays() async -> [PlayEvent] {
        let nowMs = clock()
        let storedPayloads = log.allEventPayloads()
        guard let sources else { return await Task.detached(priority: .utility) { BrainEventLog.decodeSorted(storedPayloads) }.value }
        var imported = await sources.imported().plays
        if !sources.spotifyShapesPicks() { imported = imported.filter { !$0.source.isSpotify } }
        let resolved = await resolveImported(imported)
        let merges = await repository.trackMerges()
        let excluded = songExclusions(merges)
        let plays = imported
        return await Task.detached(priority: .utility) {
            let stored = BrainEventLog.decodeSorted(storedPayloads)
            let events = ImportedPlayAdapter.events(plays: plays, resolved: resolved, durationOfRid: { _ in 0 })
            return ReplayMerger.merged(stored: stored, imported: events, nowMs: nowMs, excluded: excluded,
                                       survivorOf: { merges[$0] ?? $0 }).events
        }.value
    }

    // MARK: The learner (5.9, 5.12)

    /// `play_event.modelVersion` of a pick that was ranked with the learned weights (0: the prior).
    public static let modelLearned: Int32 = 1

    /// The favourites kept for the live learner (feature 8). They have their own file, so a large set costs nothing per play.
    private static let maxLiked = 50_000

    static func encodeLiked(_ liked: Set<Int64>) -> String {
        liked.sorted().prefix(maxLiked).map { String($0, radix: 36) }.joined(separator: ",")
    }

    static func decodeLiked(_ text: String?) -> Set<Int64> {
        guard let text, !text.isEmpty else { return [] }
        var out: Set<Int64> = []
        for part in text.split(separator: ",") { if let v = Int64(part, radix: 36) { out.insert(v) } }
        return out
    }

    private func loadLearner() -> Learner? {
        guard let text = log.value(BrainEventLog.keyLearner), let saved = LearnerCodec.decode(text) else { return nil }
        var learner = Learner(model: saved.model)
        learner.gate = saved.gate
        learner.summary = saved.summary
        learner.learnVersion = saved.learnVersion
        learner.rebuiltAtMs = saved.rebuiltAtMs
        learner.liked = Self.decodeLiked(log.likedText())
        if let text = log.value(BrainEventLog.keyPosteriors), let posteriors = PosteriorCodec.decode(text) {
            learner.posteriors = posteriors
        } else {
            // A learner saved before the arm bandit and the novelty appetite existed, or a posterior state that cannot be read:
            // the replay is due again (it makes both from the log), and until then they start from their priors.
            learner.posteriors = Posteriors.newState(today: saved.model.anchorDay)
            if log.value(BrainEventLog.keyLearnVersion) != nil { log.setValue(BrainEventLog.keyLearnVersion, nil) }
        }
        return learner
    }

    /// "Reset what I've learned" (8.6): the weights go back to the prior now, the gate goes off, and what the listener has
    /// played so far is not learned from again (only plays after this moment are). Events, exclusions and taste changes
    /// stay. A rebuild realigns the saved state; one that was already running cannot bring the old weights back.
    public func resetLearned() {
        let nowMs = clock()
        // Event ids are (startedAtMs << 16) | sequence: this is above every play that has started so far.
        let after = (nowMs &<< 16) | 0xFFFF
        withState { state in
            var model = Ranker.newModel(today: BrainMath.localDay(nowMs, tzOffsetMin: 0))
            model.lastEventId = after
            var learner = Learner(model: model)
            learner.learnVersion = LearnReplay.version
            learner.rebuiltAtMs = nowMs
            learner.liked = state.learner.liked
            var fresh = Posteriors.newState(today: BrainMath.localDay(nowMs, tzOffsetMin: 0))
            fresh.lastEventId = after
            learner.posteriors = fresh
            state.learner = learner
            state.learnEpoch += 1
        }
        learnGeneration += 1
        log.setValue(BrainEventLog.keyLearnAfter, String(after))
        if let saved = loaded?.learner.saved {
            log.setValue(BrainEventLog.keyLearner, LearnerCodec.encode(saved))
            if let posteriors = loaded?.learner.posteriors { log.setValue(BrainEventLog.keyPosteriors, PosteriorCodec.encode(posteriors)) }
        }
        requestRebuild(force: true)
    }

    /// What Your sound reads of the model (`ModelVoice`): the figures of the last replay, whether the learned weights rank,
    /// and how many plays moved them since the model was last at its prior.
    public struct LearnerFigures: Sendable {
        public let summary: Gate.Summary?
        public let useLearned: Bool
        public let updates: Int64
        /// Changes whenever a rebuild adopts a new learner or the listener resets what was learned: a figure worked out under another
        /// generation is out of date (Your sound drops it).
        public let generation: Int
    }

    /// See `LearnerFigures.generation`.
    public func learnerGeneration() -> Int { learnGeneration }

    /// When "Reset what I've learned" last happened (ms), or nil for never: a list the learned weights ranked before it is not shown again.
    public func learnResetAtMs() -> Int64? { log.value(BrainEventLog.keyLearnAfter).flatMap { Int64($0) }.map { $0 >> 16 } }

    /// True while the gate has the learned weights on (the shelf bandit's order and the arm bandit are used only then).
    public func usesLearned() -> Bool {
        ensureLoaded()
        return loaded!.learner.useLearned
    }

    public func learnerFigures() -> LearnerFigures {
        ensureLoaded()
        let l = loaded!.learner
        return LearnerFigures(summary: l.summary, useLearned: l.useLearned, updates: l.model.updates, generation: learnGeneration)
    }

    /// The bytes of every stored event, for a reader that decodes them off the actor (Your sound).
    public func eventPayloads() -> [[UInt8]] { log.allEventPayloads() }

    // MARK: Backup (stage 3 completion; docs/brain-spec.md, 12.2, 13.2)

    /// What the brain's backup module holds besides the taste changes (which the app keeps): the install's salt, if it has one, and
    /// every recorded exclusion.
    public func backupState() -> (salt: Int64?, feedback: [FeedbackStore.Record]) {
        (log.value(Self.saltKey).flatMap { Int64($0) }, feedbackStore.all())
    }

    /// A restore: the salt and the exclusions go back, and one replay in the background makes the caches (affinities, islands, the
    /// learned weights) again from the log. Nothing here runs at app start.
    public func restoreBackupState(salt: Int64?, feedback: [FeedbackStore.Record]) {
        if let salt { log.setValue(Self.saltKey, String(salt)) }
        // Merged in, not swapped: an exclusion made here since the backup keeps its record, so nothing that already counts for nothing in
        // the log becomes impossible to undo. The restored records replace the ones with the same id.
        feedbackStore.merge(feedback)
        requestRebuild(force: true)
    }

    // MARK: Tests and diagnostics

    public func eventCount() -> Int { log.eventCount }
    public func events() -> [PlayEvent] { log.allEvents() }
    public func affinityRows() -> [Affinity.Row] {
        ensureLoaded()
        return loaded!.affinity.rows()
    }
    public func sessionSnapshot() -> SessionState {
        ensureLoaded()
        return loaded!.session
    }
    public func storedValue(_ name: String) -> String? { log.value(name) }
    /// Stores a small named value (`brain_state`); nil removes it.
    public func setStoredValue(_ name: String, _ value: String?) { log.setValue(name, value) }
}

/// The play in flight as one line of canonical JSON (`brain_state` value `open_play`).
enum OpenPlayCodec {
    static func encode(_ play: FinishedPlay) -> String {
        let c = play.context
        var w = BrainJson.Writer()
        w.beginObject()
        w.string("songId", play.songId); w.long("startedAtMs", play.startedAtMs); w.long("playedMs", play.playedMs)
        w.long("durationMs", play.durationMs); w.int("flags", play.flags); w.int("tz", play.tzOffsetMin)
        w.string("title", c.title); w.string("artist", c.artistDisplay)
        w.beginArray("artists")
        for name in c.artists { w.stringItem(name) }
        w.endArray()
        w.string("spotifyId", c.spotifyId ?? ""); w.string("videoId", c.videoId ?? ""); w.bool("inLibrary", c.inLibrary)
        w.int("startReason", c.startReason)
        w.string("surface", c.tag?.surface ?? ""); w.string("surfaceId", c.tag?.surfaceId ?? "")
        w.long("recId", c.tag?.recId ?? 0); w.int("slot", c.tag?.slot ?? -1); w.string("arm", c.tag?.arm ?? "")
        w.int("retrQ", c.tag?.retrQ ?? -1); w.int("radioRank", c.tag?.radioRank ?? -1)
        w.string("primaryArtist", c.tag?.primaryArtist ?? "")
        w.bool("control", c.tag?.control ?? false); w.int("model", c.tag?.modelVersion ?? -1); w.bool("explore", c.tag?.explore ?? false)
        if let sx = c.tag?.servedX { w.string("sx", sx) }
        w.bool("shuffle", c.shuffle); w.bool("repeatOne", c.repeatOne); w.int("route", c.route)
        w.endObject()
        return w.text
    }

    static func decode(_ text: String) -> FinishedPlay? {
        guard let m = try? BrainJson.parse(text) else { return nil }
        func str(_ k: String) -> String { m[k]?.stringValue ?? "" }
        func optional(_ k: String) -> String? { str(k).isEmpty ? nil : str(k) }
        func long(_ k: String) -> Int64 { m[k]?.longValue ?? 0 }
        func int(_ k: String, _ d: Int32 = 0) -> Int32 { m[k]?.bareLong.map { Int32(truncatingIfNeeded: $0) } ?? d }
        let songId = str("songId")
        if BrainText.isBlank(songId) { return nil }
        let tag = BrainItemTag(surface: optional("surface"), surfaceId: optional("surfaceId"), recId: long("recId"),
                               slot: Int(int("slot", -1)), arm: optional("arm"), radioRank: Int(int("radioRank", -1)),
                               retrQ: Int(int("retrQ", -1)), primaryArtist: optional("primaryArtist"),
                               control: m["control"]?.boolValue ?? false, modelVersion: Int(int("model", -1)),
                               explore: m["explore"]?.boolValue ?? false, servedX: optional("sx"))
        let hasTag = !tag.isEmpty || tag.primaryArtist != nil
        let context = PlayContext(
            title: str("title"), artistDisplay: str("artist"),
            artists: (m["artists"]?.arrayValue ?? []).compactMap(\.stringValue),
            spotifyId: optional("spotifyId"), videoId: optional("videoId"), inLibrary: m["inLibrary"]?.boolValue ?? true,
            startReason: int("startReason"), tag: hasTag ? tag : nil, shuffle: m["shuffle"]?.boolValue ?? false,
            repeatOne: m["repeatOne"]?.boolValue ?? false, route: int("route"))
        return FinishedPlay(songId: songId, context: context, startedAtMs: long("startedAtMs"), playedMs: long("playedMs"),
                            durationMs: long("durationMs"), endReason: EndReason.killed, flags: int("flags"),
                            tzOffsetMin: int("tz"))
    }
}

/// Hands plays to the engine one at a time and in order (Android's recorder worker). The tracker posts from the
/// main actor and returns at once; nothing here runs before the first play is posted.
public final class BrainRecorder: Sendable {
    private enum Message: Sendable {
        case finished(FinishedPlay)
        case open(FinishedPlay?)
    }

    private let continuation: AsyncStream<Message>.Continuation
    private let worker: Task<Void, Never>

    /// `onReaction` is called after each recorded play, on no particular executor.
    public init(engine: BrainEngine, onReaction: @escaping @Sendable (Reaction) async -> Void) {
        let (stream, continuation) = AsyncStream<Message>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        worker = Task.detached(priority: .utility) {
            var recovered = false
            for await message in stream {
                if !recovered {
                    recovered = true
                    await engine.recoverKilledPlay()
                }
                switch message {
                case .finished(let play):
                    if let reaction = await engine.record(play) { await onReaction(reaction) }
                case .open(let play):
                    await engine.setOpenPlay(play)
                }
            }
        }
    }

    deinit {
        continuation.finish()
        worker.cancel()
    }

    /// A play ended. Called for EVERY play, however short: there is no five-second floor here.
    public func playFinished(_ play: FinishedPlay) { continuation.yield(.finished(play)) }

    /// The play in flight, as far as it got (when it first sounds and when it pauses); nil clears it.
    public func playOpen(_ play: FinishedPlay?) { continuation.yield(.open(play)) }
}
