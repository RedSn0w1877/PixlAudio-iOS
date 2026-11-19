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

    public init(event: PlayEvent, graded: Reward.Graded, title: String, changedDirection: Bool, anchors: [AnchorInfo],
                turn: Int = 0, turnAnchors: [AnchorInfo] = [], artistKey: String = "", artistBlocked: Bool = false) {
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

    struct Loaded {
        var affinity: Affinity.State
        var tracker = GradeTracker()
        var session = SessionState()
        /// What a radio request needs for each of the session's anchors, by rid.
        var anchors: [Int64: AnchorInfo] = [:]
        /// Which way three skipped picks turned the engine, for this session.
        var direction = Direction()

        /// Starts a new session: the old one's lists, blocks, anchors and direction are gone.
        mutating func newSession() {
            session = SessionState()
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
    private let sources: Sources?
    var loaded: Loaded?
    private var rebuildTask: Task<Void, Never>?
    private var recordedDuringRebuild: [PlayEvent]?
    private var recoveredKilledPlay = false
    /// 6.1 "ignored three times": read with the first pool or Home row that asks, then kept current.
    private var ignoreTally: IgnoreTally?

    public init(directory: URL, repository: BrainRepository, sources: Sources?,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        log = BrainEventLog(directory: directory)
        feedbackStore = FeedbackStore(directory: directory)
        self.repository = repository
        self.sources = sources
        self.clock = clock
    }

    // MARK: State

    private func ensureLoaded() {
        if loaded != nil { return }
        var state = Affinity.State()
        log.loadAffinity(into: &state)
        _ = state.drainTouched()
        if log.value(BrainEventLog.keyFirstUseMs) == nil {
            log.setValue(BrainEventLog.keyFirstUseMs, String(clock()))
        }
        loaded = Loaded(affinity: state)
        requestRebuild(force: false)
    }

    /// One graded play into the state and the log: the event and the affinity rows it touched. Nil when the event
    /// was already stored (nothing changes then).
    func apply(_ event: PlayEvent, to state: inout Loaded) -> Reward.Graded? {
        if log.hasEvent(event.eventId) { return nil }
        let graded = Brain.onEvent(affinity: &state.affinity, tracker: &state.tracker, session: &state.session,
                                   event: event)
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
        if countsForTally, let row = ignoreTally?.note(event) { log.putIgnoreRow(rid: event.rid, row) }
        recordedDuringRebuild?.append(event)
        if Affinity.clockJumpedBack(state.affinity, nowMs: clock()) { requestRebuild(force: true) }
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
        if state.session.sessionId != 0 && Session.isExpired(state.session, startedAtMs: play.startedAtMs) {
            state.newSession()
        }
        let stamp = Session.begin(&state.session, startedAtMs: play.startedAtMs, startReason: context.startReason)
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
            flags: flags,
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
            radioRank: Int32(clamping: tag?.radioRank ?? -1)
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
            artistBlocked: session.isBlocked(event.primaryAid)
        )
        }
    }

    /// The play in flight, as far as it got; nil clears it. Written down so that a play cut off by a process death
    /// is still recorded, as `killed`.
    public func setOpenPlay(_ play: FinishedPlay?) {
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
            closestOfSeeds: inputs.closestOfSeeds)
        let plan: StationPlanner.Plan?
        if let tail {
            plan = Session.patchQueue(session, tail: tail, request: request, affinity: state.affinity, graph: graph)
        } else {
            plan = StationPlanner.plan(request, affinity: state.affinity, session: session, graph: graph)
        }
        if let plan { StationPlanner.consume(&state.session, plan) }
        return plan
        }
    }

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
            let graph = StationPlanner.buildGraph(seeds: [seed], candidates: candidates, session: session)
            let request = StationPlanner.Request(
                mode: StationPlanner.modeHomeRow, count: count, candidates: candidates, seeds: [seed], nowMs: nowMs,
                tzOffsetMin: tzOffsetMin, tieSeed: seed.seedRid ^ BrainMath.localDay(nowMs, tzOffsetMin: tzOffsetMin),
                excludedRids: excludedRids)
            return StationPlanner.plan(request, affinity: state.affinity, session: session, graph: graph)
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
        return MixPlanner.plan(request, affinity: loaded!.affinity)
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
    public func requestRebuild(force: Bool) {
        guard rebuildTask == nil, sources != nil else { return }
        rebuildTask = Task { [weak self] in
            await self?.runRebuild(force: force)
        }
    }

    /// Waits for a rebuild that is running. For tests; nothing in the app blocks on it.
    public func awaitRebuild() async {
        await rebuildTask?.value
    }

    private func isRebuildNeeded(importSignature: String, nowMs: Int64) -> Bool {
        if log.value(BrainEventLog.keyHistoryMigrated) == nil { return true }
        if log.value(BrainEventLog.keySpecVersion) != String(Brain.specVersion) { return true }
        if log.value(BrainEventLog.keyImportCount) != importSignature { return true }
        // "Use my Spotify music to shape picks" was flipped since the last rebuild: the tables change with it.
        if (log.value(BrainEventLog.keySpotifyShapes) ?? "true") != String(sources?.spotifyShapesPicks() ?? true) { return true }
        // The facts (likes, top lists, follows, taste changes) are folded in at a rebuild; a weekly one keeps them
        // current without a background job.
        let rebuiltAt = log.value(BrainEventLog.keyRebuiltAtMs).flatMap { Int64($0) } ?? 0
        let age = nowMs - rebuiltAt
        return age < 0 || age > Self.factsRefreshMs
    }

    private func runRebuild(force: Bool) async {
        defer { rebuildTask = nil }
        guard let sources else { return }
        let nowMs = clock()
        let importSignature = await sources.importSignature()
        if !force && !isRebuildNeeded(importSignature: importSignature, nowMs: nowMs) { return }
        recordedDuringRebuild = []

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
        var importedResolved: [BrainKey: ResolvedTrack] = [:]
        // One key per imported play (50,000 and more of them, each a fold and a title clean): off this actor too.
        let importedPlays = imported.plays
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
        let pendingKeys = pending.keys
        let pendingRequests = pending.requests
        let pendingArtists = pending.artists
        let pendingKeyTexts = pending.keyTexts
        from = 0
        while from < pendingRequests.count {
            let to = min(from + Self.resolveBatch, pendingRequests.count)
            let rids = await repository.resolveTracks(Array(pendingRequests[from..<to]))
            let aids = await repository.resolveArtistNames(Array(pendingArtists[from..<to]))
            for i in from..<to where rids[i - from] != 0 {
                importedResolved[pendingKeys[i]] = ResolvedTrack(rid: rids[i - from], primaryAid: aids[i - from],
                                                                 key: pendingKeyTexts[i])
            }
            from = to
        }

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
        let facts = await Task.detached(priority: .utility) {
            LibraryFactsBuilder.build(library: library, ridBySongId: ridsBySong, taste: taste, adjustments: adjustments,
                                      aidByName: aidsByName, topTrackRids: topTrackRids)
        }.value

        let merges = await repository.trackMerges()
        // The stored events are read as bytes here and decoded off the actor (a long history is tens of thousands of
        // lines of JSON): a play that ends meanwhile is recorded without waiting for them.
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
                                        survivorOf: { merges[$0] ?? $0 })
        }.value

        // Plays that ended while the rebuild ran and that it did not read from the log.
        var state = result.state
        var tracker = GradeTracker()
        for event in recordedDuringRebuild ?? [] where !result.recentEventIds.contains(event.eventId) {
            let graded = tracker.grade(event, completions: state.completions)
            Affinity.applyEvent(&state, event, graded, tMs: event.startedAtMs)
        }
        _ = state.drainTouched()
        recordedDuringRebuild = nil
        log.replaceAffinity(state.rows())
        log.setValue(BrainEventLog.keySpecVersion, String(Brain.specVersion))
        log.setValue(BrainEventLog.keyImportCount, importSignature)
        log.setValue(BrainEventLog.keySpotifyShapes, String(shapes))
        log.setValue(BrainEventLog.keyRebuiltAtMs, String(nowMs))
        if loaded != nil {
            loaded!.affinity = state
            loaded!.tracker = tracker
        }
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
                               retrQ: Int(int("retrQ", -1)), primaryArtist: optional("primaryArtist"))
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
