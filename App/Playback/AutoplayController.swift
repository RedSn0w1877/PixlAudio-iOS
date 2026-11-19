import Foundation
import Observation
import PixlLibrary
import PixlModel
import PixlNet

/// Autoplay: when two or fewer tracks are left, five more are appended, so music does not stop at the end of a
/// queue (docs/brain-spec.md, 7.1), and what the listener skips or likes changes what comes next (7.3). The port of
/// Android's `AutoplayController`.
///
/// Every decision is in PixlCore: `AutoplayPolicy` (when to top up, what may follow what, what a re-score may
/// touch), `AutoplayPool` (which tracks, from which radios, or from the library), `AutoplayPlanning` (what a plan
/// reads from the queue), `BrainEngine` (the planner over the affinity tables and the session) and `BrainRepository`
/// (the radio cache and its fallbacks). This class only reads the engine, asks them, and carries out the answer on
/// the main actor.
///
/// Rules it keeps:
///  - The trigger asks the in-memory pool, never the network. A radio request starts no earlier than 1.5 s into a
///    track, and all of a pool's work (files, network, text folding) runs off the main actor. A plan is a few
///    milliseconds of arithmetic on the brain's actor.
///  - One queue edit per top-up and per re-score, and never from inside an engine callback (the edit runs on a later
///    main-actor turn). An append goes in at once: behind the track that is already next it changes nothing the
///    player has prepared. Only an edit that would replace the next track during the last moments of a hand-over
///    waits for the track change (`AutoplayPolicy.mustDeferQueueEdit`).
///  - One plan at a time: a top-up waits for a re-score, and a pick that is already in the queue is not queued again.
///  - A re-score never touches the track after the current one, nor the one after that on unmetered Wi-Fi (the
///    prefetcher has warmed them), and only the unbroken run of engine items at the end of the queue.
///  - Never at the end of the queue, except as the backstop: picks that land within 10 s of the end resume playback,
///    unless the listener touched play or pause meanwhile or a sleep timer ended the queue.
///  - Only tracks the listener chose, and engine picks they liked, are anchors. Engine picks that merely played are
///    not, so an hour of autoplay is still about what the listener started with.
///  - Tracks the listener queued are never moved or removed.
///  - Off under repeat and while a saved queue is being restored. On a Spotify Connect device it runs, limited to what
///    Spotify has: a pick is looked up before it is queued, the tail is not re-scored, and the settle wait is a plain
///    delay (`AutoplayPolicy.remoteRule`). An AirPlay route is the phone's own output and changes nothing.
///  - Three of the engine's picks skipped in a row turn it to another anchor (`Direction`); the listener's next own
///    track turns it back, and while a track of theirs plays autoplay follows that track.
///  - With no network the pool is the library alone, and only tracks with a copy on the phone; such a pool, and a
///    library pool that stands in for radios that could not be had, is built again after a while.
///  - A station (8.3) is the same machinery with one fixed anchor, its seed: the first batch is 20, the planner runs
///    in station mode, and it keeps going with the Autoplay switch off, because the listener asked for it. It ends
///    when the queue no longer holds its seed.
final class AutoplayController {
    /// What Autoplay reads from the rest of the app. Closures, so nothing is loaded until music plays.
    struct Sources {
        var isEnabled: () -> Bool
        var youTubeSourceEnabled: () -> Bool
        /// Where the queue is sounding: this phone (an AirPlay route included: the phone still plays the audio) or a
        /// Spotify Connect device (`AutoplayPolicy.remoteRule`).
        var remoteOutput: () -> RemoteOutput
        /// Which of these songs the remote output can play, in order: on Spotify Connect a real Spotify id or a strict
        /// search match. Asked only on an output that plays some tracks and not others; it may search.
        var playableOnRemote: @MainActor ([Song]) async -> [Bool]
        var library: () -> [Song]
        var librarySong: (String) -> Song?
        var events: () -> [PlaybackEvent]
        var blocked: () -> BlockedArtistMatcher
        var adjustments: () -> TasteAdjustmentSet
        var signals: () -> [String: MusicRecommendationEngine.Signal]
        var imported: () -> ImportedHistoryAggregate
        var exploration: () -> Float
        /// The stored YouTube match of a Spotify song (one indexed read, off the main actor).
        var matchedVideoId: @Sendable (String) async -> String?
        /// Which of these library songs play with no network, by song id (asked only when the phone is offline).
        var offlinePlayable: @Sendable ([Song]) async -> Set<String>
    }

    /// What a pool is seeded from, and whether that is a change of direction (`Reaction.turn`).
    private struct Seeding {
        var anchors: [Song]
        var turn = 0
        /// Turned, with nothing of the session left to turn to: the pool is seeded from the library.
        var otherDirection = false
    }

    /// Why a pool is being built: one that is only wanted to top the queue up is dropped once the queue is long
    /// enough again.
    private enum FillPurpose {
        case topUp, refill, turn, backstop
    }

    private static let fourHoursMs: Int64 = 4 * 60 * 60 * 1000
    private static let oneDayMs: Int64 = 24 * 60 * 60 * 1000
    private static let sixtyDaysMs: Int64 = 60 * oneDayMs
    private static let libraryPicks = 40
    private static let settlePolls = 8
    private static let emptyBuildRetryMs: Int64 = 5 * 60 * 1000
    /// How many of the newest history entries the 4-hour rule reads (a few hours of listening is far fewer).
    private static let recentHistoryScan = 400
    /// A pick that could not be loaded is kept out of new pools for this long.
    private static let failedMemoryMs: Int64 = 30 * 60 * 1000
    private static let failedLimit = 64
    /// Engine items this process put in a queue that a re-score may still need to know.
    private static let servedLimit = 400
    private static let directionNote: Duration = .seconds(12)

    private let engine: DualDeckEngine
    private let brain: BrainService
    private let sources: Sources
    /// Created with the first pool build, never at launch (its path monitor starts then too).
    private lazy var network = NetworkConditionsMonitor()
    private var now: () -> Int64 = { currentTimeMillis() }

    private var pool: [AutoplayPoolEntry] = []
    private var poolKey = ""
    private var poolFromLibrary = false
    private var poolDeepened = false
    /// The radios the pool came from, newest anchor first; empty for a pool that is picked in its own order.
    private var poolSeeds: [Retrieval.SeedList] = []
    private var poolArtistNames: [Int64: String] = [:]
    /// When the pool was built, and how long it may be used (`AutoplayPolicy.poolTtlMs`; nil: until it runs out).
    private var poolBuiltAtMs: Int64 = 0
    private var poolTtlMs: Int64?
    private var fillTask: Task<Void, Never>?
    private var fillKey = ""
    private var fillGeneration = 0
    private var fillPurpose = FillPurpose.topUp
    /// The running fill is still waiting for the current track to settle.
    private var fillSettling = false
    /// A plan for a top-up is being made on the brain's actor.
    private var planTask: Task<Void, Never>?
    private var rescoreTask: Task<Void, Never>?
    private var pendingRescore = false
    private var queueEndedAtMs: Int64 = 0
    /// Next was pressed with nothing queued: when, and on which song.
    private var nextAskedAtMs: Int64 = 0
    private var nextAskedSongId: String?
    private var batchSeq: Int64 = 0
    private var emptyBuildKey = ""
    private var emptyBuildAtMs: Int64 = 0
    private var emptyBuildRetry: Int64 = AutoplayController.emptyBuildRetryMs
    /// Picks that could not be loaded, by song id, with when.
    private var failedAtMs: [String: Int64] = [:]
    private var evaluateScheduled = false
    private var libraryIndex: (index: BrainLibraryIndex, count: Int, builtAtMs: Int64)?
    private var lastPruneAtMs: Int64 = 0

    /// Engine items that went into a queue, by media id: a re-score needs to know what they are.
    private var served: [BrainKey: AutoplayPoolEntry] = [:]
    private var servedOrder: [BrainKey] = []

    // What the event recorder last said about the session.
    private var sessionAnchors: [AnchorInfo] = []
    private var sessionAnchorsAtMs: Int64 = 0
    /// 0 while the engine follows the session's anchors; otherwise the number of the turn (`Direction`).
    private var sessionTurn = 0
    private var turnAnchors: [AnchorInfo] = []
    private var likedTitles: [Int64: String] = [:]
    private var noteTask: Task<Void, Never>?

    /// The station the current queue is, as last read from the queue (`refreshStation`); nil for none.
    private var station: Station?
    /// Batches appended for the current `station`: its first one is the long one (6.2).
    private var stationBatches = 0
    private var stationRecheck: Task<Void, Never>?
    /// What the Familiar / Blend / Discover switch multiplies the novelty share by.
    private var noveltyFactor = 1.0
    private var tasteTask: Task<Void, Never>?
    private var tasteDirty = false
    /// Bumped at every taste change: a pool that was being built meanwhile is matched against the change again.
    private var tasteEpoch = 0
    /// A taste change wanted the next track out during the last moments of a hand-over: it is tried again at the
    /// track change.
    private var pendingTasteFilter = false
    private var tasteRevision: (() -> Int)?

    /// Autoplay is switched on, or the queue is a station (which the listener asked for by hand).
    private var isActive: Bool { station != nil || sources.isEnabled() }

    /// Set by `PlaybackServices` when it restores a saved queue at launch, and cleared when playback first starts:
    /// a restored queue near its end must not send a radio request at app start.
    var isRestoringQueue = false

    init(engine: DualDeckEngine, brain: BrainService, sources: Sources) {
        self.engine = engine
        self.brain = brain
        self.sources = sources
    }

    // MARK: Engine hooks (called by `PlaybackServices`, on the main actor)

    /// A new track became current.
    func itemTransition() {
        queueEndedAtMs = 0
        nextAskedAtMs = 0
        setFinding(false)
        syncLine()
        scheduleEvaluate()
    }

    /// The queue changed (an edit, shuffle, a restore, an append of ours).
    func queueChanged() {
        syncLine()
        scheduleEvaluate()
    }

    /// Playback started or paused.
    func playingChanged(_ playing: Bool) {
        // A restored queue is the listener's again from the moment something plays.
        if playing, isRestoringQueue { isRestoringQueue = false }
        // After the queue ended, a touch of play or pause is the listener's own decision: the backstop stands down.
        if queueEndedAtMs != 0 {
            queueEndedAtMs = 0
            setFinding(false)
        }
        // A pool that could not settle while paused gets its chance.
        if playing, pool.isEmpty, fillTask == nil { scheduleEvaluate() }
    }

    /// The Autoplay switch changed (the queue's own switch).
    func settingChanged() {
        scheduleEvaluate()
    }

    /// The backstop: the engine reached the end of the queue. If picks are ready they go in and playback goes on;
    /// otherwise they are looked for at once (nothing is playing, so nothing competes) and resume playback only if
    /// they land inside the window. `stoppedByTimer`: a sleep timer's "end of track" ended it, which Autoplay never
    /// undoes.
    func queueEnded(stoppedByTimer: Bool) {
        guard !stoppedByTimer else { return }
        // On the next main-actor turn: the engine calls this in the middle of ending the queue (it still has to
        // reload the last song, paused), and the backstop edits the queue and may start playback.
        Task { [weak self] in
            guard let self else { return }
            self.backstop()
        }
    }

    private func backstop() {
        refreshStation()
        guard engine.hasEnded, decide() == .topUp, engine.queue.nextIndexForAutoAdvance == nil else { return }
        let seeding = currentSeeding()
        guard !seeding.anchors.isEmpty else { return }
        adoptPool(for: seeding)
        expirePool()
        let endedAt = now()
        queueEndedAtMs = endedAt
        nextAskedAtMs = 0
        // The window closes by itself, whatever becomes of the plan and the fill below.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(AutoplayPolicy.backstopWindowMs + 250))
            guard let self, self.queueEndedAtMs == endedAt else { return }
            // Nothing landed in time: the queue simply ended, as it always did.
            self.queueEndedAtMs = 0
            self.setFinding(false)
        }
        appendFromPool { [weak self] _ in
            // A batch that went in has resumed playback and cleared the mark (`deliver`).
            guard let self, self.queueEndedAtMs == endedAt else { return }
            self.setFinding(true)
            self.startFill(seeding, settle: false, deepen: false, purpose: .backstop)
        }
    }

    /// Next was pressed with nothing after the current track (a song tapped on its own, skipped before the first
    /// picks were in, or "Not for me" on it). The press itself did nothing. Picks are looked for at once, with no
    /// settle wait since the listener wants to leave this track, and when they land inside the backstop window
    /// while the same track is still current, the player moves on to the first of them.
    func nextWithNothingQueued() {
        // On the next main-actor turn: the engine calls this from inside its own `skipToNext`.
        Task { [weak self] in
            guard let self else { return }
            self.rememberNext()
        }
    }

    private func rememberNext() {
        refreshStation()
        guard !engine.hasEnded, decide() == .topUp, engine.queue.nextIndexForSkip == nil else { return }
        let seeding = currentSeeding()
        guard !seeding.anchors.isEmpty else { return }
        let askedAt = now()
        nextAskedAtMs = askedAt
        nextAskedSongId = engine.queue.current?.song.id
        setFinding(true)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(AutoplayPolicy.backstopWindowMs + 250))
            guard let self, self.nextAskedAtMs == askedAt else { return }
            self.nextAskedAtMs = 0
            if self.queueEndedAtMs == 0 { self.setFinding(false) }
        }
        adoptPool(for: seeding)
        expirePool()
        appendFromPool { [weak self] appended in
            guard let self, !appended else { return }
            self.startFill(seeding, settle: false, deepen: false, purpose: .backstop)
        }
    }

    /// The picks a pressed Next was waiting for are in: move on to them, if it is still wanted. On the next
    /// main-actor turn, so the move is the listener's Next and not part of the append that made it possible.
    private func skipToPicksIfAsked() {
        let askedAt = nextAskedAtMs
        guard askedAt != 0, engine.queue.nextIndexForSkip != nil else { return }
        nextAskedAtMs = 0
        if queueEndedAtMs == 0 { setFinding(false) }
        let askedSongId = nextAskedSongId
        Task { [weak self] in
            guard let self,
                  AutoplayPolicy.nextMayStillSkip(askedAtMs: askedAt, nowMs: self.now(), askedMediaId: askedSongId,
                                                  currentMediaId: self.engine.queue.current?.song.id) else { return }
            self.engine.skipToNext()
        }
    }

    /// A pick of the engine's could not be loaded (the player has already moved on, without a message). It leaves
    /// the pool and stays out of new ones for a while; the trigger tops the queue up from what is left.
    func enginePickFailed(songId: String) {
        if failedAtMs.count > Self.failedLimit { failedAtMs.removeAll() }
        failedAtMs[songId] = now()
        pool.removeAll { $0.candidate.mediaId == songId }
    }

    private func failedRecently(_ songId: String, nowMs: Int64) -> Bool {
        guard let at = failedAtMs[songId] else { return false }
        return nowMs - at >= 0 && nowMs - at < Self.failedMemoryMs
    }

    // MARK: Reactions (docs/brain-spec.md, 7.3)

    /// A play ended and the session changed (called on the main actor by the event recorder). Decides whether the
    /// engine's tail must be re-scored.
    func reaction(_ reaction: Reaction) {
        sessionAnchors = reaction.anchors
        sessionAnchorsAtMs = now()
        sessionTurn = reaction.turn
        turnAnchors = reaction.turnAnchors
        if reaction.liked {
            if likedTitles.count > 32 { likedTitles.removeAll() }
            likedTitles[reaction.event.rid] = reaction.title
        }
        refreshStation()
        // A station stays on its seed: three skips there thin out what was skipped (the session's blocks), they do
        // not turn the station into another one.
        if reaction.changedDirection, station == nil { showDirectionNote() }
        guard isActive else { return }
        if reaction.changedDirection, station == nil, remoteRule().rescore, !isRestoringQueue {
            // Turning does not wait for the queue to run low: the pool of the new direction is built now, and when
            // it is ready the engine's tail is re-scored against it (`poolReady`).
            let seeding = currentSeeding()
            if !seeding.anchors.isEmpty {
                adoptPool(for: seeding)
                if pool.isEmpty { startFill(seeding, settle: true, deepen: false, purpose: .turn) }
            }
        }
        // A skip, a like or a change of direction changes what should come next; a plain completion does not move
        // the tail.
        if reaction.graded.h > 0.0 || reaction.liked || reaction.changedDirection {
            // A tail that cannot be planned again (after a restart, picked from the library, or behind a pool the
            // library carries on) still loses the artist that was just skipped.
            if !rescoreTail(), reaction.graded.h > 0.0, reaction.artistBlocked { dropArtistFromTail(reaction.artistKey) }
        }
        // New anchors mean another pool; the trigger decides whether anything is needed now.
        scheduleEvaluate()
    }

    private func showDirectionNote() {
        if !brain.autoplay.changedDirection { brain.autoplay.changedDirection = true }
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: AutoplayController.directionNote)
            guard let self, !Task.isCancelled else { return }
            self.brain.autoplay.changedDirection = false
        }
    }

    /// Re-scores the engine-owned end of the queue against the pool, as ONE queue edit, and only when the result
    /// differs. The track after the current one is never touched, nor the one after that on unmetered Wi-Fi: the
    /// prefetcher has warmed them (2.3 step 7, decision D8). False when this tail cannot be planned again.
    @discardableResult
    private func rescoreTail() -> Bool {
        guard isActive, !poolFromLibrary, !poolSeeds.isEmpty, remoteRule().rescore, !isRestoringQueue,
              let brainEngine = brain.engine else { return false }
        if !AutoplayPolicy.mayPlanNow(topUpRunning: planTask != nil, rescoreRunning: rescoreTask != nil) {
            pendingRescore = true
            return true
        }
        let queue = queueItems()
        let start = rescoreStart(of: queue)
        // An engine item this process did not put there (a restored queue): the tail is left alone.
        guard start >= 0, let tailEntries = AutoplayPlanning.tailEntries(queue: queue, start: start, served: served) else {
            return false
        }
        let tailRids = tailEntries.compactMap { $0.brain?.rid }
        guard tailRids.count == tailEntries.count else { return false }
        let tailIds = queue[start...].map(\.mediaId)
        let context = planContext(queue: queue, tailStart: start, tailEntries: tailEntries)
        let key = poolKey
        rescoreTask = Task { [weak self] in
            let plan = await brainEngine.plan(context.inputs, count: tailRids.count, bridge: false, tail: tailRids)
            guard let self else { return }
            self.rescoreTask = nil
            self.applyRescore(plan, context: context, start: start, tailIds: tailIds, tailEntries: tailEntries, key: key)
            // A second reaction arrived while this one was planned: look once more. A top-up that waited for this
            // plan gets its turn; the backstop, which owns an ended queue, picks up where it was.
            self.runPendingRescore()
            if self.queueEndedAtMs != 0 || self.nextAskedAtMs != 0 { self.poolReady() } else { self.scheduleEvaluate() }
        }
        return true
    }

    /// The first index a re-score may replace: past the current track and the warmed ones, and only the unbroken
    /// run of engine items at the end; -1 for none.
    private func rescoreStart(of queue: [AutoplayQueueItem]) -> Int {
        network.startIfNeeded()
        let conditions = network.conditions
        let unmetered = (conditions.network == .wifi || conditions.network == .wired) && !conditions.isExpensive
            && !conditions.isConstrained
        return AutoplayPolicy.rescoreStart(queueSize: queue.count, currentAbsoluteIndex: engine.queue.currentIndex ?? -1,
                                           warmedAhead: AutoplayPolicy.warmedAhead(unmeteredWifi: unmetered),
                                           engineOwned: { queue[$0].engineOwned })
    }

    private func applyRescore(_ plan: StationPlanner.Plan?, context: AutoplayPlanContext, start: Int, tailIds: [String],
                              tailEntries: [AutoplayPoolEntry], key: String) {
        guard let plan, key == poolKey, isActive else { return }
        // The queue may have moved on while the plan was made: only an unchanged tail is replaced.
        let entries = engine.queue.entries
        let protectedUntil = (engine.queue.currentIndex ?? -1) + 1
        guard entries.count == start + tailIds.count, start > protectedUntil else { return }
        for (offset, id) in tailIds.enumerated() where entries[start + offset].song.id != id { return }

        let items = AutoplayPlanning.items(plan: plan, context: context, surfaceId: surfaceId(),
                                           artistNames: poolArtistNames, likedTitles: likedTitles,
                                           station: context.inputs.station)
        let made = materialize(items, nowMs: context.inputs.nowMs)
        guard !made.songs.isEmpty else { return }
        guard engine.replaceEngineTail(from: start, songs: made.songs, tags: made.tags) else {
            // Refused in the last moments of a hand-over: the track change looks again.
            if engine.isHandOverScheduled { pendingRescore = true }
            return
        }
        // What left the tail goes back to the pool; what came from the pool is now served.
        let kept = Set(made.entries.map { BrainKey($0.candidate.mediaId) })
        for entry in tailEntries where !kept.contains(BrainKey(entry.candidate.mediaId)) {
            served[BrainKey(entry.candidate.mediaId)] = nil
            pool.append(entry)
        }
        pool.removeAll { kept.contains(BrainKey($0.candidate.mediaId)) }
        for entry in made.entries { remember(entry) }
    }

    /// A re-score that had to wait for a plan in flight runs once that is over.
    private func runPendingRescore() {
        guard pendingRescore, AutoplayPolicy.mayPlanNow(topUpRunning: planTask != nil, rescoreRunning: rescoreTask != nil),
              !engine.isHandOverScheduled else { return }
        pendingRescore = false
        rescoreTail()
    }

    /// Takes the upcoming picks by `artistKey` out of the engine's end of the queue, in one edit: what a hard skip
    /// asks for in a tail that cannot be planned again (restored after a restart, picked from the library, or
    /// behind a pool the library carries on). The track that is next and the warmed ones stay (decision D8), and
    /// so does everything the listener queued. Not in a station, whose own artist is thinned out by the planner.
    private func dropArtistFromTail(_ artistKey: String) {
        guard !artistKey.isEmpty, isActive, station == nil, remoteRule().rescore, !isRestoringQueue else { return }
        // A pool that is picked in its own order hears of the skip no other way.
        if poolFromLibrary || poolSeeds.isEmpty {
            pool.removeAll { BrainKey.sameBytes($0.candidate.artistKey, artistKey) }
        }
        let entries = engine.queue.entries
        let start = rescoreStart(of: queueItems())
        guard start >= 0 else { return }
        // A handful of names at most: the engine's upcoming picks.
        let keys = entries.map { $0.isEngineOwned ? BrainLibraryIndex.artistKey(of: $0.song) : "" }
        let first = AutoplayPolicy.firstIndexOfArtist(start: start, size: entries.count, artistKey: artistKey) { keys[$0] }
        guard first >= 0 else { return }
        var ids = Set<String>()
        for index in first..<entries.count where BrainKey.sameBytes(keys[index], artistKey) { ids.insert(entries[index].song.id) }
        if engine.removeUpcomingEnginePicks(ids: ids) {
            for id in ids { served[BrainKey(id)] = nil }
            servedOrder.removeAll { ids.contains($0.text) }
        }
    }

    // MARK: Trigger

    /// Runs `evaluate` on the next main-actor turn, once: the engine calls its hooks in the middle of its own state
    /// changes, and a queue edit must not land there.
    private func scheduleEvaluate() {
        guard !evaluateScheduled else { return }
        evaluateScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.evaluateScheduled = false
            self.evaluate(settle: true)
        }
    }

    /// What the engine may do on the output the queue is sounding on (`AutoplayPolicy.remoteRule`).
    private func remoteRule() -> RemoteRule { AutoplayPolicy.remoteRule(sources.remoteOutput()) }

    private func decide() -> AutoplayPolicy.Decision {
        AutoplayPolicy.decide(autoplayEnabled: isActive, repeatMode: Int32(engine.queue.repeatMode.rawValue),
                              isRemoteSession: !remoteRule().picks, isRestoring: isRestoringQueue,
                              fullQueueSize: engine.queue.count, currentAbsoluteIndex: engine.queue.currentIndex ?? -1)
    }

    private func evaluate(settle: Bool) {
        refreshStation()
        if pendingTasteFilter, !engine.isHandOverScheduled {
            pendingTasteFilter = false
            tasteChanged()
        }
        runPendingRescore()
        let decision = decide()
        guard decision == .topUp else {
            // Enough is queued: nothing is needed, and neither is a pool that was being built only to top this
            // queue up. Anything else (off, repeat, Connect, a restore) stops the work.
            if decision == .enoughQueued { cancelTopUpFill() } else { cancelWork() }
            return
        }
        // The backstop owns the queue's end: its own fill and timer finish the job.
        guard queueEndedAtMs == 0 else { return }
        let seeding = currentSeeding()
        guard !seeding.anchors.isEmpty else { return }
        adoptPool(for: seeding)
        expirePool()
        appendFromPool { [weak self] appended in
            guard let self else { return }
            if appended {
                if self.pool.count < AutoplayPolicy.poolRefillBelow, !self.poolFromLibrary, !self.poolDeepened {
                    self.startFill(seeding, settle: true, deepen: true, purpose: .refill)
                }
                return
            }
            // Nothing fits from what is in memory: build it, or once per set of anchors rebuild it deeper
            // (continuation pages, then the library behind them). After that the queue is allowed to end.
            if !self.pool.isEmpty, self.poolDeepened { return }
            self.startFill(seeding, settle: settle, deepen: !self.pool.isEmpty, purpose: .topUp)
        }
    }

    /// A pool that is being built only because the queue ran low is not needed once it no longer is.
    private func cancelTopUpFill() {
        guard fillPurpose == .topUp, fillTask != nil else { return }
        fillTask?.cancel()
        fillTask = nil
        fillSettling = false
    }

    /// A pool built without the network, or one where the library stands in for radios that could not be had, is
    /// not kept until it runs out: the network, or the request allowance, may be back.
    private func expirePool() {
        guard poolBuiltAtMs != 0,
              AutoplayPolicy.poolExpired(builtAtMs: poolBuiltAtMs, nowMs: now(), ttlMs: poolTtlMs) else { return }
        pool = []
        poolFromLibrary = false
        poolDeepened = false
        poolSeeds = []
        poolBuiltAtMs = 0
        poolTtlMs = nil
        if emptyBuildKey == poolKey { emptyBuildKey = "" }
    }

    /// The key of the pool this seeding asks for: other anchors, a station or another direction, another pool.
    private func keyOfPool(for seeding: Seeding) -> String {
        let key = AutoplayPool.key(of: seeding.anchors.map(\.id))
        if let station { return key + "|station:" + station.id }
        return seeding.turn != 0 ? key + "|turn:\(seeding.turn)" : key
    }

    /// A pool belongs to what it was seeded from.
    private func adoptPool(for seeding: Seeding) {
        let key = keyOfPool(for: seeding)
        guard key != poolKey else { return }
        poolKey = key
        pool = []
        poolFromLibrary = false
        poolDeepened = false
        poolSeeds = []
        poolArtistNames = [:]
        poolBuiltAtMs = 0
        poolTtlMs = nil
        if fillKey != key {
            fillTask?.cancel()
            fillTask = nil
            fillSettling = false
        }
    }

    /// What the pool is seeded from (7.1 "Seed set"): the track the listener chose and is hearing now, then the
    /// session's anchors as the recorder last gave them, three at most. While the session has none yet, the last
    /// track the listener chose at or before the current one.
    ///
    /// After three skipped picks the engine is turned (`Reaction.turn`) and follows what it turned to. That holds
    /// only while the engine's own picks play: when the track that is playing is one the listener chose, they are
    /// steering, and autoplay follows that track.
    private func currentSeeding() -> Seeding {
        let entries = engine.queue.entries
        // A station has one anchor for as long as it lasts: its seed (8.3).
        if let station {
            return Seeding(anchors: entries.first { station.isSeed(mediaId: $0.song.id, tag: $0.brain) }.map { [$0.song] } ?? [])
        }
        let age = now() - sessionAnchorsAtMs
        let fresh = sessionAnchorsAtMs != 0 && age >= 0 && age < Session.gapMs
        let current = engine.queue.current
        let currentIsListeners = current.map { !$0.isEngineOwned } ?? false
        if AutoplayPolicy.turnApplies(turn: sessionTurn, reactionIsFresh: fresh, currentIsListenersChoice: currentIsListeners) {
            let followed = turnAnchors.prefix(Session.maxAnchors).compactMap { anchorSong(for: $0, in: entries) }
            if !followed.isEmpty { return Seeding(anchors: followed, turn: sessionTurn) }
            // Nothing of the session is left to turn to: the pool is seeded from the library, around the artist
            // the listener finishes most outside the ones just skipped (`AutoplayPool.otherDirectionAnchor`).
            return Seeding(anchors: normalAnchors(entries, current: current, currentIsListeners: currentIsListeners,
                                                  fresh: fresh),
                           turn: sessionTurn, otherDirection: true)
        }
        return Seeding(anchors: normalAnchors(entries, current: current, currentIsListeners: currentIsListeners, fresh: fresh))
    }

    private func anchorSong(for info: AnchorInfo, in entries: [QueueEntry]) -> Song? {
        sources.librarySong(info.mediaId) ?? entries.first(where: { $0.song.id == info.mediaId })?.song
            ?? brain.song(id: info.mediaId)
    }

    private func normalAnchors(_ entries: [QueueEntry], current: QueueEntry?, currentIsListeners: Bool, fresh: Bool) -> [Song] {
        if fresh, !sessionAnchors.isEmpty {
            var anchors: [Song] = []
            // The track the listener chose and is hearing right now leads, though the session has not heard it out
            // yet: tap one song after an album, and autoplay follows the song.
            if let current, currentIsListeners, !sessionAnchors.contains(where: { $0.mediaId == current.song.id }) {
                anchors.append(current.song)
            }
            for info in sessionAnchors where anchors.count < Session.maxAnchors {
                if let song = anchorSong(for: info, in: entries) { anchors.append(song) }
            }
            if !anchors.isEmpty { return anchors }
        }
        return AutoplayPolicy.anchorIndices(currentAbsoluteIndex: engine.queue.currentIndex ?? -1,
                                            queueSize: entries.count,
                                            engineOwned: { entries[$0].isEngineOwned },
                                            mediaIdAt: { entries[$0].song.id }, max: 1).map { entries[$0].song }
    }

    // MARK: Append

    private func queueItems() -> [AutoplayQueueItem] {
        engine.queue.entries.map { AutoplayQueueItem(mediaId: $0.song.id, engineOwned: $0.isEngineOwned) }
    }

    /// The first anchor's id: what a batch's `surfaceId` names.
    private func surfaceId() -> String {
        poolKey.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
    }

    /// Media ids played in the last four hours (6.4). The affinity tables answer that for anything the brain
    /// recorded; the playback history covers a play it could not identify. Only its newest entries are read.
    private func recentlyPlayed(nowMs: Int64) -> Set<BrainKey> {
        var ids = Set<BrainKey>()
        let since = nowMs - Self.fourHoursMs
        for event in sources.events().suffix(Self.recentHistoryScan) where event.timestamp >= since {
            ids.insert(BrainKey(event.songId))
        }
        return ids
    }

    /// Everything a plan reads, taken from the queue and the pool on the main actor.
    private func planContext(queue: [AutoplayQueueItem], tailStart: Int, tailEntries: [AutoplayPoolEntry]) -> AutoplayPlanContext {
        let nowMs = now()
        batchSeq = (batchSeq + 1) & 0xff
        return AutoplayPlanning.inputs(queue: queue, tailStart: tailStart, tailEntries: tailEntries, pool: pool,
                                       served: served, recentlyPlayed: recentlyPlayed(nowMs: nowMs), seeds: poolSeeds,
                                       nowMs: nowMs, tzOffsetMin: Int32(clamping: TimeZone.current.secondsFromGMT() / 60),
                                       batch: batchSeq, station: station, noveltyFactor: noveltyFactor)
    }

    /// Appends one batch from the in-memory pool and tells `onDone` whether one went in. No network. The plan
    /// itself runs on the brain's actor; the library-only pool is picked in place. Nothing happens, and `onDone` is
    /// not called, while another plan is in flight (a top-up or a re-score: both read the same pool, and two plans
    /// side by side can pick the same track): that plan's end looks at the queue again.
    private func appendFromPool(_ onDone: @escaping @MainActor (Bool) -> Void) {
        guard AutoplayPolicy.mayPlanNow(topUpRunning: planTask != nil, rescoreRunning: rescoreTask != nil) else { return }
        guard !pool.isEmpty else {
            onDone(false)
            return
        }
        guard !poolFromLibrary, !poolSeeds.isEmpty, let brainEngine = brain.engine else {
            onDone(appendInPoolOrder())
            return
        }
        let queue = queueItems()
        let context = planContext(queue: queue, tailStart: queue.count, tailEntries: [])
        guard !context.inputs.candidates.isEmpty else {
            onDone(false)
            return
        }
        let key = poolKey
        let queueSize = queue.count
        // The first batch behind what the listener chose opens with the bridge of 7.1. A station opens with a long
        // first batch instead (6.2); its seed is what was just heard, so it needs no bridge.
        let planStation = context.inputs.station
        let bridge = planStation == nil && context.inputs.prior.isEmpty
        let count = StationRules.batchSize(isStation: planStation != nil, batchesSoFar: stationBatches)
        planTask = Task { [weak self] in
            var plan = await brainEngine.plan(context.inputs, count: count, bridge: bridge, tail: nil)
            guard let self else { return }
            // On an output that plays only some tracks (Spotify Connect) the picks are looked up first, and the ones
            // it does not have never reach the queue. The plan stays "in flight" meanwhile: one plan at a time.
            if let planned = plan, self.remoteRule().onlyWhatTheOutputPlays {
                plan = await self.keepWhatTheOutputPlays(planned, context: context)
            }
            self.planTask = nil
            guard key == self.poolKey, self.isActive else { return }
            // Someone else changed the queue while the plan was made: the trigger looks again.
            if self.engine.queue.count != queueSize {
                self.scheduleEvaluate()
                return
            }
            onDone(plan.map { self.commit($0, context: context) } ?? false)
            self.runPendingRescore()
        }
    }

    /// `plan` without the picks the remote output cannot play (Spotify Connect: a pick Spotify does not have). Those
    /// leave the pool and are not offered again for a while. On this phone, and on an output that takes everything it
    /// is given, the plan comes back as it is.
    private func keepWhatTheOutputPlays(_ plan: StationPlanner.Plan, context: AutoplayPlanContext) async -> StationPlanner.Plan {
        guard remoteRule().onlyWhatTheOutputPlays, !plan.picks.isEmpty else { return plan }
        var ids: [String] = []
        var songs: [Song] = []
        for entry in AutoplayPlanning.pickedEntries(plan: plan, context: context) {
            guard let song = entry.librarySong
                ?? entry.engineTrack.map({ BrainService.queueSong(for: $0, nowMs: context.inputs.nowMs) }) else { continue }
            ids.append(entry.candidate.mediaId)
            songs.append(song)
        }
        let playable = await sources.playableOnRemote(songs)
        let kept = Set(AutoplayPolicy.keepPlayable(mediaIds: ids, playable: playable).map(BrainKey.init))
        if kept.count == ids.count { return plan }
        let nowMs = now()
        for id in ids where !kept.contains(BrainKey(id)) {
            if failedAtMs.count > Self.failedLimit { failedAtMs.removeAll() }
            failedAtMs[id] = nowMs
        }
        let asked = Set(ids.map(BrainKey.init))
        pool.removeAll { asked.contains(BrainKey($0.candidate.mediaId)) && !kept.contains(BrainKey($0.candidate.mediaId)) }
        return AutoplayPlanning.narrowed(plan, context: context, kept: kept)
    }

    /// Puts a plan's picks at the end of the queue in one edit. True when anything went in.
    private func commit(_ plan: StationPlanner.Plan, context: AutoplayPlanContext) -> Bool {
        // A pick that got into the queue while the plan was made is not queued a second time.
        let queued = Set(engine.queue.entries.map { BrainKey($0.song.id) })
        let items = AutoplayPlanning.notQueued(
            AutoplayPlanning.items(plan: plan, context: context, surfaceId: surfaceId(), artistNames: poolArtistNames,
                                   likedTitles: likedTitles, station: context.inputs.station),
            queuedIds: queued)
        let made = materialize(items, nowMs: context.inputs.nowMs)
        guard !made.songs.isEmpty else { return false }
        if let planned = context.inputs.station, planned == station { stationBatches += 1 }
        let picked = Set(made.entries.map { BrainKey($0.candidate.mediaId) })
        pool.removeAll { picked.contains(BrainKey($0.candidate.mediaId)) }
        for entry in made.entries { remember(entry) }
        deliver(songs: made.songs, tags: made.tags)
        return true
    }

    /// The songs of planned items: a library track plays from its current library row, a track from outside the
    /// library as its `yt:` song, known to the app (and stored) before it can play.
    private func materialize(_ items: [AutoplayPlannedItem], nowMs: Int64)
        -> (songs: [Song], tags: [BrainItemTag], entries: [AutoplayPoolEntry]) {
        var songs: [Song] = []
        var tags: [BrainItemTag] = []
        var entries: [AutoplayPoolEntry] = []
        var engineTracks: [EngineTrack] = []
        for item in items {
            let song: Song
            if let librarySong = item.entry.librarySong {
                // The library's current row (a favourite flag set since the pool was built).
                song = sources.librarySong(librarySong.id) ?? librarySong
            } else if let track = item.entry.engineTrack {
                song = brain.linked(BrainService.queueSong(for: track, nowMs: nowMs))
                engineTracks.append(track)
            } else {
                continue
            }
            songs.append(song)
            tags.append(item.tag)
            entries.append(item.entry)
        }
        // Recently Played and Like find them by id.
        brain.register(engineTracks)
        return (songs, tags, entries)
    }

    /// The library-only pool (offline, the YouTube source off, or no radio had anything), and a radio pool the
    /// library had to carry on behind: in pool order under the hard constraints, as in stage 1a.
    private func appendInPoolOrder() -> Bool {
        guard !pool.isEmpty else { return false }
        let nowMs = now()
        let entries = engine.queue.entries
        var excluded = recentlyPlayed(nowMs: nowMs)
        excluded.reserveCapacity(excluded.count + entries.count)
        var tail: [AutoplayPolicy.Slot] = []
        for entry in entries {
            excluded.insert(BrainKey(entry.song.id))
            if entry.isEngineOwned {
                tail.append(AutoplayPolicy.Slot(artistKey: BrainLibraryIndex.artistKey(of: entry.song),
                                                albumKey: BrainLibraryIndex.albumKey(of: entry.song.album)))
            }
        }
        // On Spotify Connect a library pick goes in only when it carries an id Spotify gave out: this path has no room
        // for a lookup, and a track saved from YouTube Music may not be on Spotify.
        let onlySpotifyIds = remoteRule().onlyWhatTheOutputPlays
        let picked = AutoplayPolicy.pickBatch(pool: pool.filter { !onlySpotifyIds || AutoplayPolicy.isSpotifyTrackId($0.librarySong?.spotifyId) }
                                                  .map(\.candidate), engineTail: Array(tail.suffix(50)),
                                              excludedMediaIds: excluded, excludedRids: [])
        guard !picked.isEmpty else { return false }

        let pickedIds = Set(picked.map { BrainKey($0.mediaId) })
        var byId: [BrainKey: AutoplayPoolEntry] = [:]
        for entry in pool where pickedIds.contains(BrainKey(entry.candidate.mediaId)) {
            byId[BrainKey(entry.candidate.mediaId)] = entry
        }
        pool.removeAll { pickedIds.contains(BrainKey($0.candidate.mediaId)) }

        batchSeq = (batchSeq + 1) & 0xff
        let recId = (nowMs << 8) | batchSeq
        let surface = surfaceId()
        var items: [AutoplayPlannedItem] = []
        for (slot, candidate) in picked.enumerated() {
            guard let entry = byId[BrainKey(candidate.mediaId)] else { continue }
            items.append(AutoplayPlannedItem(entry: entry, tag: AutoplayPlanning.tag(
                entry: entry, pick: nil, recId: recId, slot: tail.count + slot, surfaceId: surface,
                artistNames: poolArtistNames, likedTitles: likedTitles, station: station)))
        }
        let made = materialize(items, nowMs: nowMs)
        guard !made.songs.isEmpty else { return false }
        for entry in made.entries { remember(entry) }
        deliver(songs: made.songs, tags: made.tags)
        return true
    }

    /// Appends the batch, then resumes an ended queue, or moves on when Next was pressed with nothing queued. An
    /// append never waits: behind the track that is already next it changes nothing the player has prepared.
    private func deliver(songs: [Song], tags: [BrainItemTag]) {
        if brain.autoplay.fromLibrary != poolFromLibrary { brain.autoplay.fromLibrary = poolFromLibrary }
        engine.appendEngineItems(songs, tags: tags)
        if queueEndedAtMs != 0 {
            _ = resumeAfterQueueEnd()
        } else {
            skipToPicksIfAsked()
        }
    }

    private func remember(_ entry: AutoplayPoolEntry) {
        let key = BrainKey(entry.candidate.mediaId)
        if served[key] == nil { servedOrder.append(key) }
        served[key] = entry
        if servedOrder.count > Self.servedLimit {
            let dropped = servedOrder.removeFirst()
            served[dropped] = nil
        }
    }

    /// After the backstop appended: start the first appended track, if the listener still wants music.
    @discardableResult
    private func resumeAfterQueueEnd() -> Bool {
        let endedAt = queueEndedAtMs
        guard endedAt != 0,
              AutoplayPolicy.backstopMayResume(endedAtMs: endedAt, nowMs: now(), playWhenReady: true) else { return false }
        // Cleared first: the engine reports "playing" on the way, which would otherwise read as the listener's touch.
        queueEndedAtMs = 0
        setFinding(false)
        return engine.continueAfterQueueEnd()
    }

    // MARK: Pool

    private func startFill(_ seeding: Seeding, settle: Bool, deepen: Bool, purpose: FillPurpose) {
        if fillTask != nil, fillKey == poolKey {
            // One fill per pool. The backstop does not wait behind one that is waiting for the settle time of a
            // track that has ended (or that the listener wants to leave): that one would never see it.
            guard purpose == .backstop,
                  AutoplayPolicy.backstopReplacesFill(fillRunning: true, fillIsWaitingToSettle: fillSettling) else { return }
        }
        let key = poolKey
        let startedAt = now()
        // A build that found nothing at all is not repeated on every play and pause for a while.
        if key == emptyBuildKey, startedAt - emptyBuildAtMs >= 0, startedAt - emptyBuildAtMs < emptyBuildRetry {
            setFinding(false)
            return
        }
        fillKey = key
        fillTask?.cancel()
        fillGeneration &+= 1
        fillPurpose = purpose
        fillSettling = settle
        let generation = fillGeneration
        let currentSongId = engine.queue.current?.song.id
        let fillStation = station
        let anchors = seeding.anchors
        let otherDirection = seeding.otherDirection && fillStation == nil
        let tasteAtStart = tasteEpoch
        fillTask = Task { [weak self] in
            guard let self else { return }
            // Only the newest fill clears the slot: an older, cancelled one must not free it under a running one.
            defer {
                if self.fillGeneration == generation {
                    self.fillTask = nil
                    self.fillSettling = false
                }
            }
            if settle {
                let settled = await self.waitUntilSettled(songId: currentSongId)
                if !settled { return }
                if self.fillGeneration == generation { self.fillSettling = false }
            }
            guard !Task.isCancelled,
                  let built = await self.buildPool(anchors: anchors, deepen: deepen, otherDirection: otherDirection,
                                                   station: fillStation) else { return }
            guard !Task.isCancelled, key == self.poolKey else { return }
            let builtAt = self.now()
            // A pick that just failed to load does not come straight back.
            self.pool = self.failedAtMs.isEmpty ? built.entries
                : built.entries.filter { !self.failedRecently($0.candidate.mediaId, nowMs: builtAt) }
            self.poolFromLibrary = built.fromLibrary
            self.poolSeeds = built.seeds
            self.poolArtistNames = built.artistNames
            self.poolBuiltAtMs = builtAt
            self.poolTtlMs = AutoplayPolicy.poolTtlMs(offline: built.offline, fellBack: built.fellBack)
            if deepen { self.poolDeepened = true }
            if built.entries.isEmpty {
                self.emptyBuildKey = key
                self.emptyBuildAtMs = builtAt
                // Without the network "nothing" may only mean "nothing that plays offline".
                self.emptyBuildRetry = built.offline ? AutoplayPolicy.offlinePoolTtlMs : AutoplayController.emptyBuildRetryMs
            }
            // The listener changed their taste while this pool was being built: it is matched against that too.
            if self.tasteEpoch != tasteAtStart { self.tasteChanged() }
            self.poolReady()
        }
    }

    /// Waits until the current track is 1.5 s in, so a radio request never competes with the first bytes of the
    /// track. False when the track changed (the new one re-triggers) or it stayed paused: `playingChanged` and the
    /// backstop pick that case up, without a polling loop.
    private func waitUntilSettled(songId: String?) async -> Bool {
        if !remoteRule().settleOnLocalPlayer {
            // The queue sounds on another device: this phone streams nothing and its own player sits paused at the
            // start of the track, so there is no position to read. A plain wait keeps the request off the moment of
            // the track change.
            try? await Task.sleep(for: .milliseconds(AutoplayPolicy.settleMs))
            return !Task.isCancelled && engine.queue.current?.song.id == songId
        }
        for _ in 0..<Self.settlePolls {
            if Task.isCancelled || engine.queue.current?.song.id != songId { return false }
            let position = engine.currentPositionMs()
            if AutoplayPolicy.isSettled(positionMs: position) { return true }
            let wait = min(max(AutoplayPolicy.settleMs - position, 100), AutoplayPolicy.settleMs)
            try? await Task.sleep(for: .milliseconds(wait))
        }
        return false
    }

    private func poolReady() {
        let decision = decide()
        guard decision == .topUp else {
            // The queue is long enough, but its engine tail may be from the direction just left.
            if decision == .enoughQueued { rescoreTail() }
            return
        }
        if queueEndedAtMs != 0 {
            // Backstop: outside the window the queue stays ended and nothing is added.
            guard AutoplayPolicy.backstopMayResume(endedAtMs: queueEndedAtMs, nowMs: now(), playWhenReady: true) else {
                queueEndedAtMs = 0
                setFinding(false)
                return
            }
            appendFromPool { [weak self] appended in
                guard let self, !appended else { return }
                self.queueEndedAtMs = 0
                self.setFinding(false)
            }
            return
        }
        appendFromPool { _ in }
    }

    /// Captures what a build reads (cheap copies of values), then builds off the main actor: the anchors' audio ids,
    /// the library index, the radios (cache first, then the network when it may), the filters, the recording and
    /// artist ids.
    private func buildPool(anchors: [Song], deepen: Bool, otherDirection: Bool, station: Station?) async -> BuiltAutoplayPool? {
        let nowMs = now()
        let library = sources.library()
        let events = sources.events()
        let blocked = sources.blocked()
        let adjustments = sources.adjustments()
        let signals = sources.signals()
        let imported = sources.imported()
        let exploration = sources.exploration()
        let matchedVideoId = sources.matchedVideoId
        let offlinePlayable = sources.offlinePlayable
        let repository = brain.repository
        let brainEngine = brain.engine
        let queueIds = Set(engine.queue.entries.map(\.song.id))
        network.startIfNeeded()
        let online = network.conditions.network != .offline
        let allowNetwork = AutoplayPolicy.mayUseNetwork(online: online, youTubeSourceEnabled: sources.youTubeSourceEnabled())
        let cachedIndex = libraryIndex.flatMap { cached in
            cached.count == library.count && nowMs - cached.builtAtMs >= 0 && nowMs - cached.builtAtMs < 10 * 60 * 1000
                ? cached.index : nil
        }
        let prune = nowMs - lastPruneAtMs < 0 || nowMs - lastPruneAtMs >= Self.oneDayMs
        if prune { lastPruneAtMs = nowMs }
        let seed = Int64(bitPattern: BrainHash.fnv1a64(AutoplayPool.key(of: anchors.map(\.id))))
        let picksLimit = Self.libraryPicks
        let sixtyDaysMs = Self.sixtyDaysMs

        let result = await Task.detached(priority: .utility) { () -> (pool: BuiltAutoplayPool, index: BrainLibraryIndex) in
            var seeds: [AutoplayAnchor] = []
            for song in anchors {
                let spotifyId = AutoplayController.spotifyId(of: song)
                var videoId = YouTubeSongIdentity.videoId(for: song)
                if videoId == nil, let spotifyId { videoId = await matchedVideoId(spotifyId) }
                seeds.append(AutoplayAnchor(song: song, videoId: videoId,
                                            spotifyId: spotifyId.flatMap { AutoplayController.isSyntheticId($0) ? nil : $0 }))
            }
            let index = cachedIndex ?? BrainLibraryIndex(songs: library)
            var everPlayed = Set<String>()
            for event in events { everPlayed.insert(event.songId) }
            var request = AutoplayPoolRequest(
                anchors: seeds, deepen: deepen, allowNetwork: allowNetwork, library: library, everPlayed: everPlayed,
                blocked: blocked, adjustments: adjustments,
                libraryPicks: {
                    let inputs = HomeStore.recommendationInputs(songs: library, events: events, signals: signals,
                                                                imported: imported)
                    return DailyMix.personalizedPicks(
                        allSongs: library, favoriteSongIds: Set(library.filter(\.isFavorite).map(\.id)),
                        engagements: inputs.engagements, storedSignals: inputs.signals, exploration: exploration,
                        nowMs: nowMs, limit: picksLimit, seed: seed,
                        artistAffinity: inputs.artistAffinity, adjustments: adjustments).map(\.song)
                })
            request.otherDirection = otherDirection
            request.matchedVideoId = matchedVideoId
            request.nowMs = nowMs
            request.station = station
            // With no network at all, only what plays from the phone may be queued.
            request.offline = !online
            request.offlinePlayable = offlinePlayable
            let pool = await AutoplayPool.build(request, index: index, repository: repository, engine: brainEngine)
            if prune, let repository {
                // `playable` rows nobody used for 60 days go, except what the queue or the history still names.
                var keep = queueIds
                let since = nowMs - sixtyDaysMs
                for event in events where event.timestamp >= since { keep.insert(event.songId) }
                await repository.prunePlayable(keepSongIds: keep, nowMs: nowMs)
            }
            return (pool, index)
        }.value
        libraryIndex = (result.index, library.count, nowMs)
        return result.pool
    }

    /// Whether a radio may be asked for right now: online, and the YouTube source is switched on (Home's rows ask
    /// the same question as the pool).
    func mayUseNetwork() -> Bool {
        network.startIfNeeded()
        return AutoplayPolicy.mayUseNetwork(online: network.conditions.network != .offline,
                                            youTubeSourceEnabled: sources.youTubeSourceEnabled())
    }

    // MARK: Station (8.3), the novelty switch and taste changes (8.5)

    /// Reads off the queue whether it is still the station the listener started: it is, for as long as it holds the
    /// station's seed entry. Any other play replaces that entry, so a queue without it ends the station (and it is
    /// forgotten); an empty queue, or one that is still being restored, decides nothing.
    private func refreshStation() {
        let stations = brain.stations
        var next: Station?
        if let wanted = stations.current {
            let entries = engine.queue.entries
            let holdsSeed = entries.contains { wanted.isSeed(mediaId: $0.song.id, tag: $0.brain) }
            switch StationRules.state(holdsSeed: holdsSeed, queueIsEmpty: entries.isEmpty, isRestoring: isRestoringQueue) {
            case .running: next = wanted
            case .ended: stations.clear()
            case .unknown: break
            }
        }
        if next != station {
            station = next
            stationBatches = 0
        }
        let state = brain.autoplay
        if state.stationTitle != next?.title { state.stationTitle = next?.title }
        let isArtist = next?.isArtist ?? false
        if state.stationIsArtist != isArtist { state.stationIsArtist = isArtist }
        // The switch's stored level, the first time anything looks.
        let level = stations.novelty
        if state.novelty != level { state.novelty = level }
        noveltyFactor = Novelty.factor(level)
    }

    /// A station was started (`BrainActions`): the trigger looks at the queue again, and once more a moment later,
    /// because a station started from the track that is playing first drops what was queued behind it.
    func stationChanged() {
        scheduleEvaluate()
        stationRecheck?.cancel()
        stationRecheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard let self, !Task.isCancelled else { return }
            self.stationRecheck = nil
            self.scheduleEvaluate()
        }
    }

    /// The Familiar / Blend / Discover switch moved. It applies from the next track: the engine's tail is planned
    /// again.
    func noveltyChanged() {
        let factor = Novelty.factor(brain.stations.novelty)
        guard factor != noveltyFactor else { return }
        noveltyFactor = factor
        rescoreTail()
    }

    /// Calls `tasteChanged` whenever the listener's taste changes move (`revision` is read under observation: a
    /// mute, a boost, a reduce, an undo, from anywhere in the app). Nothing runs until one does.
    func observeTasteChanges(_ revision: @escaping () -> Int) {
        tasteRevision = revision
        trackTasteRevision()
    }

    private func trackTasteRevision() {
        guard let tasteRevision else { return }
        withObservationTracking {
            _ = tasteRevision()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.tasteChanged()
                self.trackTasteRevision()
            }
        }
    }

    /// The listener muted, blocked or reduced something ("Not for me", "Less from ..."). What is now excluded
    /// leaves the pool at once, and the engine's upcoming picks that match leave the queue in one edit (never the
    /// listener's own items, never during a hand-over). A reduce changes scores, so the tail is planned again.
    func tasteChanged() {
        tasteEpoch &+= 1
        if tasteTask != nil {
            tasteDirty = true
            return
        }
        // Which tracks the engine holds are now excluded, and what the listener's boosts and reduces now add to
        // each score, is worked out off the main actor (it folds every artist name); the main actor only drops
        // and updates them by id.
        let held = pool + Array(served.values)
        let blocked = sources.blocked()
        let adjustments = sources.adjustments()
        tasteTask = Task { [weak self] in
            let change = await Task.detached(priority: .utility) {
                (gone: AutoplayTasteFilter.excludedIds(held: held, blocked: blocked, adjustments: adjustments),
                 boosts: AutoplayTasteFilter.boosts(held: held, adjustments: adjustments))
            }.value
            guard let self else { return }
            self.tasteTask = nil
            self.applyTaste(gone: change.gone, boosts: change.boosts)
            // A second change arrived while this one was applied: look once more.
            if self.tasteDirty {
                self.tasteDirty = false
                self.tasteChanged()
            }
        }
    }

    private func applyTaste(gone: Set<String>, boosts: [String: Double]) {
        if !gone.isEmpty {
            pool.removeAll { gone.contains($0.candidate.mediaId) }
            let entries = engine.queue.entries
            let current = engine.queue.currentIndex ?? -1
            let queued = entries.indices.contains { $0 > current && entries[$0].isEngineOwned && gone.contains(entries[$0].song.id) }
            if queued {
                if engine.removeUpcomingEnginePicks(ids: gone) {
                    for id in gone { served[BrainKey(id)] = nil }
                    servedOrder.removeAll { gone.contains($0.text) }
                } else {
                    // The pick that must go is the next track and its hand-over is already on the host clock: the
                    // track change (`evaluate`) works the list out again.
                    pendingTasteFilter = true
                }
            }
        }
        // "Less from X" and every other boost or reduce: the scores of what the engine already holds follow, so
        // the re-score below and every later top-up use them (a pool is built once per set of anchors).
        let pooled = AutoplayTasteFilter.applying(boosts, to: pool)
        if pooled.changed { pool = pooled.entries }
        for key in servedOrder {
            guard let entry = served[key], let boost = boosts[entry.candidate.mediaId], let scored = entry.brain,
                  scored.boostLn != boost else { continue }
            served[key]?.brain?.boostLn = boost
        }
        rescoreTail()
        scheduleEvaluate()
    }

    // MARK: Small things

    private func cancelWork() {
        fillTask?.cancel()
        fillTask = nil
        fillSettling = false
        pendingRescore = false
        nextAskedAtMs = 0
        pendingTasteFilter = false
        queueEndedAtMs = 0
        setFinding(false)
    }

    private func setFinding(_ finding: Bool) {
        if brain.autoplay.finding != finding { brain.autoplay.finding = finding }
    }

    /// Where the queue draws the Autoplay line, and the reason line of every entry that has one (assigned only
    /// when they changed).
    private func syncLine() {
        let queue = engine.queue
        let index = queue.firstUpcomingEngineIndex
        if brain.autoplay.lineIndex != index { brain.autoplay.lineIndex = index }
        let why = QueueWhy.map(queue.entries.lazy.map { (mediaId: $0.song.id, tag: $0.brain) })
        if brain.autoplay.why != why { brain.autoplay.why = why }
        refreshStation()
    }

    /// The Spotify id of a library song (its own field, else its `spotify://<id>` URL).
    nonisolated static func spotifyId(of song: Song) -> String? {
        if let id = song.spotifyId, !id.isEmpty { return id }
        let prefix = "spotify://"
        guard song.contentUriString.hasPrefix(prefix) else { return nil }
        let id = String(song.contentUriString.dropFirst(prefix.count).prefix { $0 != "/" })
        return id.isEmpty ? nil : id
    }

    /// A YouTube Music import carries a synthetic id (22 lower-case hex characters), not a Spotify track id.
    nonisolated static func isSyntheticId(_ id: String) -> Bool {
        id.utf8.count == 22 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
