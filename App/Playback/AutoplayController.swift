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
///  - One queue edit per top-up and per re-score, never while one deck hands over to the other or the next song is
///    already prepared for that; and never from inside an engine callback (the edit runs on a later main-actor turn).
///  - A re-score never touches the track after the current one, nor the one after that on unmetered Wi-Fi (the
///    prefetcher has warmed them), and only the unbroken run of engine items at the end of the queue.
///  - Never at the end of the queue, except as the backstop: picks that land within 10 s of the end resume playback,
///    unless the listener touched play or pause meanwhile or a sleep timer ended the queue.
///  - Only tracks the listener chose, and engine picks they liked, are anchors. Engine picks that merely played are
///    not, so an hour of autoplay is still about what the listener started with.
///  - Tracks the listener queued are never moved or removed.
///  - Off under repeat, during Spotify Connect, and while a saved queue is being restored.
///  - A station (8.3) is the same machinery with one fixed anchor, its seed: the first batch is 20, the planner runs
///    in station mode, and it keeps going with the Autoplay switch off, because the listener asked for it. It ends
///    when the queue no longer holds its seed.
final class AutoplayController {
    /// What Autoplay reads from the rest of the app. Closures, so nothing is loaded until music plays.
    struct Sources {
        var isEnabled: () -> Bool
        var youTubeSourceEnabled: () -> Bool
        var isRemoteSession: () -> Bool
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
    }

    private static let fourHoursMs: Int64 = 4 * 60 * 60 * 1000
    private static let oneDayMs: Int64 = 24 * 60 * 60 * 1000
    private static let sixtyDaysMs: Int64 = 60 * oneDayMs
    private static let libraryPicks = 40
    private static let settlePolls = 8
    private static let emptyBuildRetryMs: Int64 = 5 * 60 * 1000
    /// How many of the newest history entries the 4-hour rule reads (a few hours of listening is far fewer).
    private static let recentHistoryScan = 400
    /// How often, and how many times, a held append looks again while a crossfade runs (12 s at most).
    private static let heldAppendPoll: Duration = .seconds(2)
    private static let heldAppendPolls = 8
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
    private var fillTask: Task<Void, Never>?
    private var fillKey = ""
    private var fillGeneration = 0
    /// A plan for a top-up is being made on the brain's actor.
    private var planTask: Task<Void, Never>?
    private var rescoreTask: Task<Void, Never>?
    private var pendingRescore = false
    /// A batch held until a hand-over is done, with the pool key it was picked for.
    private var pendingAppend: (songs: [Song], tags: [BrainItemTag], key: String)?
    private var heldAppendTask: Task<Void, Never>?
    private var queueEndedAtMs: Int64 = 0
    private var batchSeq: Int64 = 0
    private var emptyBuildKey = ""
    private var emptyBuildAtMs: Int64 = 0
    private var evaluateScheduled = false
    private var libraryIndex: (index: BrainLibraryIndex, count: Int, builtAtMs: Int64)?
    private var lastPruneAtMs: Int64 = 0

    /// Engine items that went into a queue, by media id: a re-score needs to know what they are.
    private var served: [BrainKey: AutoplayPoolEntry] = [:]
    private var servedOrder: [BrainKey] = []

    // What the event recorder last said about the session.
    private var sessionAnchors: [AnchorInfo] = []
    private var sessionAnchorsAtMs: Int64 = 0
    private var needsOtherDirection = false
    private var sessionTurned = false
    /// Bumped at every change of direction that has no other anchor to turn to: the same anchors, another pool.
    private var directionEpoch = 0
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
    /// A taste change arrived while a hand-over was prepared: its queue edit waits for the track change.
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
        let anchors = anchorSongs()
        guard !anchors.isEmpty else { return }
        adoptPool(for: anchors)
        let endedAt = now()
        queueEndedAtMs = endedAt
        if let held = pendingAppend {
            // A batch that was waiting for a hand-over which never came: it goes in now, if it is still for this queue.
            pendingAppend = nil
            heldAppendTask?.cancel()
            heldAppendTask = nil
            if held.key == poolKey {
                engine.appendEngineItems(held.songs, tags: held.tags)
                if resumeAfterQueueEnd() { return }
            }
        }
        appendFromPool { [weak self] _ in
            // A batch that went in has resumed playback and cleared the mark (`deliver`).
            guard let self, self.queueEndedAtMs == endedAt else { return }
            self.setFinding(true)
            self.startFill(anchors: anchors, settle: false, deepen: false)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(AutoplayPolicy.backstopWindowMs + 250))
                guard let self, self.queueEndedAtMs == endedAt else { return }
                // Nothing landed in time: the queue simply ended, as it always did.
                self.queueEndedAtMs = 0
                self.setFinding(false)
            }
        }
    }

    // MARK: Reactions (docs/brain-spec.md, 7.3)

    /// A play ended and the session changed (called on the main actor by the event recorder). Decides whether the
    /// engine's tail must be re-scored.
    func reaction(_ reaction: Reaction) {
        sessionAnchors = reaction.anchors
        sessionAnchorsAtMs = now()
        needsOtherDirection = reaction.needsOtherDirection
        sessionTurned = reaction.turned
        if reaction.liked {
            if likedTitles.count > 32 { likedTitles.removeAll() }
            likedTitles[reaction.event.rid] = reaction.title
        }
        refreshStation()
        // A station stays on its seed: three skips there thin out what was skipped (the session's blocks), they do
        // not turn the station into another one.
        if reaction.changedDirection, station == nil {
            if reaction.needsOtherDirection { directionEpoch += 1 }
            showDirectionNote()
        }
        guard isActive else { return }
        if reaction.changedDirection, station == nil, !sources.isRemoteSession(), !isRestoringQueue {
            // Turning does not wait for the queue to run low: the pool of the new direction is built now, and when
            // it is ready the engine's tail is re-scored against it (`poolReady`).
            let anchors = anchorSongs()
            if !anchors.isEmpty {
                adoptPool(for: anchors)
                if pool.isEmpty { startFill(anchors: anchors, settle: true, deepen: false) }
            }
        }
        // A skip, a like or a change of direction changes what should come next; a plain completion does not move
        // the tail.
        if reaction.graded.h > 0.0 || reaction.liked || reaction.changedDirection { rescoreTail() }
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
    /// prefetcher has warmed them (2.3 step 7, decision D8).
    private func rescoreTail() {
        guard isActive, !poolFromLibrary, !poolSeeds.isEmpty, !sources.isRemoteSession(), !isRestoringQueue,
              let brainEngine = brain.engine else { return }
        if rescoreTask != nil || planTask != nil || pendingAppend != nil || engine.isHandOverPrepared {
            pendingRescore = true
            return
        }
        let queue = queueItems()
        network.startIfNeeded()
        let conditions = network.conditions
        let unmetered = (conditions.network == .wifi || conditions.network == .wired) && !conditions.isExpensive
            && !conditions.isConstrained
        let start = AutoplayPolicy.rescoreStart(queueSize: queue.count, currentAbsoluteIndex: engine.queue.currentIndex ?? -1,
                                                warmedAhead: AutoplayPolicy.warmedAhead(unmeteredWifi: unmetered),
                                                engineOwned: { queue[$0].engineOwned })
        // An engine item this process did not put there (a restored queue): the tail is left alone.
        guard start >= 0, let tailEntries = AutoplayPlanning.tailEntries(queue: queue, start: start, served: served) else {
            return
        }
        let tailRids = tailEntries.compactMap { $0.brain?.rid }
        guard tailRids.count == tailEntries.count else { return }
        let tailIds = queue[start...].map(\.mediaId)
        let context = planContext(queue: queue, tailStart: start, tailEntries: tailEntries)
        let key = poolKey
        rescoreTask = Task { [weak self] in
            let plan = await brainEngine.plan(context.inputs, count: tailRids.count, bridge: false, tail: tailRids)
            guard let self else { return }
            self.rescoreTask = nil
            self.applyRescore(plan, context: context, start: start, tailIds: tailIds, tailEntries: tailEntries, key: key)
            // A second reaction arrived while this one was planned: look once more.
            self.runPendingRescore()
        }
    }

    private func applyRescore(_ plan: StationPlanner.Plan?, context: AutoplayPlanContext, start: Int, tailIds: [String],
                              tailEntries: [AutoplayPoolEntry], key: String) {
        guard let plan, key == poolKey, isActive else { return }
        // The queue may have moved on while the plan was made: only an unchanged tail is replaced, and never during
        // a hand-over.
        let entries = engine.queue.entries
        let protectedUntil = (engine.queue.currentIndex ?? -1) + 1
        guard entries.count == start + tailIds.count, start > protectedUntil, !engine.isHandOverPrepared else { return }
        for (offset, id) in tailIds.enumerated() where entries[start + offset].song.id != id { return }

        let items = AutoplayPlanning.items(plan: plan, context: context, surfaceId: surfaceId(),
                                           artistNames: poolArtistNames, likedTitles: likedTitles,
                                           station: context.inputs.station)
        let made = materialize(items, nowMs: context.inputs.nowMs)
        guard !made.songs.isEmpty, engine.replaceEngineTail(from: start, songs: made.songs, tags: made.tags) else { return }
        // What left the tail goes back to the pool; what came from the pool is now served.
        let kept = Set(made.entries.map { BrainKey($0.candidate.mediaId) })
        for entry in tailEntries where !kept.contains(BrainKey(entry.candidate.mediaId)) {
            served[BrainKey(entry.candidate.mediaId)] = nil
            pool.append(entry)
        }
        pool.removeAll { kept.contains(BrainKey($0.candidate.mediaId)) }
        for entry in made.entries { remember(entry) }
    }

    /// A re-score that had to wait (for a plan in flight, or a hand-over) runs once that is over.
    private func runPendingRescore() {
        guard pendingRescore, !engine.isHandOverPrepared, planTask == nil, rescoreTask == nil else { return }
        pendingRescore = false
        rescoreTail()
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

    private func decide() -> AutoplayPolicy.Decision {
        AutoplayPolicy.decide(autoplayEnabled: isActive, repeatMode: Int32(engine.queue.repeatMode.rawValue),
                              isRemoteSession: sources.isRemoteSession(), isRestoring: isRestoringQueue,
                              fullQueueSize: engine.queue.count, currentAbsoluteIndex: engine.queue.currentIndex ?? -1)
    }

    private func evaluate(settle: Bool) {
        if pendingAppend != nil {
            releaseHeldAppend()
            // Still held (a crossfade is running, or the next song is prepared): look again shortly.
            if pendingAppend != nil { watchHeldAppend() }
            return
        }
        refreshStation()
        if pendingTasteFilter, !engine.isHandOverPrepared {
            pendingTasteFilter = false
            tasteChanged()
        }
        runPendingRescore()
        let decision = decide()
        guard decision == .topUp else {
            if decision != .enoughQueued { cancelWork() }
            return
        }
        // The backstop owns the queue's end: its own fill and timer finish the job.
        guard queueEndedAtMs == 0 else { return }
        let anchors = anchorSongs()
        guard !anchors.isEmpty else { return }
        adoptPool(for: anchors)
        appendFromPool { [weak self] appended in
            guard let self else { return }
            if appended {
                if self.pool.count < AutoplayPolicy.poolRefillBelow, !self.poolFromLibrary, !self.poolDeepened {
                    self.startFill(anchors: anchors, settle: true, deepen: true)
                }
                return
            }
            // Nothing fits from what is in memory: build it, or once per set of anchors rebuild it deeper
            // (continuation pages, then the library behind them). After that the queue is allowed to end.
            if !self.pool.isEmpty, self.poolDeepened { return }
            self.startFill(anchors: anchors, settle: settle, deepen: !self.pool.isEmpty)
        }
    }

    /// The key of the pool these anchors ask for. A change of direction with no other anchor asks for another pool
    /// from the same anchors.
    private func keyOfPool(for anchors: [Song]) -> String {
        let key = AutoplayPool.key(of: anchors.map(\.id))
        if let station { return key + "|station:" + station.id }
        return needsOtherDirection ? key + "|#\(directionEpoch)" : key
    }

    /// A pool belongs to its anchors: other anchors, another pool.
    private func adoptPool(for anchors: [Song]) {
        let key = keyOfPool(for: anchors)
        guard key != poolKey else { return }
        poolKey = key
        pool = []
        poolFromLibrary = false
        poolDeepened = false
        poolSeeds = []
        poolArtistNames = [:]
        if fillKey != key {
            fillTask?.cancel()
            fillTask = nil
        }
    }

    /// What the pool is seeded from (7.1 "Seed set"): the track the listener chose and is hearing now, then the
    /// session's anchors as the recorder last gave them, three at most. While the session has none yet, the last
    /// track the listener chose at or before the current one.
    private func anchorSongs() -> [Song] {
        let entries = engine.queue.entries
        // A station has one anchor for as long as it lasts: its seed (8.3).
        if let station {
            return entries.first { station.isSeed(mediaId: $0.song.id, tag: $0.brain) }.map { [$0.song] } ?? []
        }
        let nowMs = now()
        let fresh = !sessionAnchors.isEmpty && nowMs - sessionAnchorsAtMs >= 0 && nowMs - sessionAnchorsAtMs < Session.gapMs
        if fresh {
            var anchors: [Song] = []
            // The track the listener chose and is hearing right now leads, though the session has not heard it out
            // yet: tap one song after an album, and autoplay follows the song. Not after a change of direction,
            // which follows the one anchor it turned to.
            if !sessionTurned, let current = engine.queue.current, !current.isEngineOwned,
               !sessionAnchors.contains(where: { $0.mediaId == current.song.id }) {
                anchors.append(current.song)
            }
            for info in sessionAnchors where anchors.count < Session.maxAnchors {
                if let song = sources.librarySong(info.mediaId) ?? entries.first(where: { $0.song.id == info.mediaId })?.song
                    ?? brain.song(id: info.mediaId) {
                    anchors.append(song)
                }
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

    /// Appends one batch from the in-memory pool and tells `onDone` whether one went in (or is held until a
    /// hand-over is done). No network. The plan itself runs on the brain's actor; the library-only pool is picked in
    /// place. Nothing happens, and `onDone` is not called, while another plan is in flight: that plan's own callback
    /// finishes the job.
    private func appendFromPool(_ onDone: @escaping @MainActor (Bool) -> Void) {
        guard planTask == nil else { return }
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
            let plan = await brainEngine.plan(context.inputs, count: count, bridge: bridge, tail: nil)
            guard let self else { return }
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

    /// Puts a plan's picks at the end of the queue in one edit. True when anything went in.
    private func commit(_ plan: StationPlanner.Plan, context: AutoplayPlanContext) -> Bool {
        let items = AutoplayPlanning.items(plan: plan, context: context, surfaceId: surfaceId(),
                                           artistNames: poolArtistNames, likedTitles: likedTitles,
                                           station: context.inputs.station)
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
                song = BrainService.queueSong(for: track, nowMs: nowMs)
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
        let picked = AutoplayPolicy.pickBatch(pool: pool.map(\.candidate), engineTail: Array(tail.suffix(50)),
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

    /// Appends now, or holds the batch until a prepared hand-over is done; then resumes an ended queue.
    private func deliver(songs: [Song], tags: [BrainItemTag]) {
        if brain.autoplay.fromLibrary != poolFromLibrary { brain.autoplay.fromLibrary = poolFromLibrary }
        if AutoplayPolicy.mustDeferQueueEdit(isTransitionRunning: engine.isHandOverPrepared) {
            pendingAppend = (songs, tags, poolKey)
            watchHeldAppend()
        } else {
            engine.appendEngineItems(songs, tags: tags)
        }
        if queueEndedAtMs != 0 { _ = resumeAfterQueueEnd() }
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

    /// An append held during a hand-over goes in as soon as the hand-over is done.
    private func releaseHeldAppend() {
        guard let held = pendingAppend, !engine.isHandOverPrepared else { return }
        pendingAppend = nil
        heldAppendTask?.cancel()
        heldAppendTask = nil
        // Dropped when the queue no longer needs it, or is no longer the one it was picked for.
        guard decide() == .topUp, held.key == keyOfPool(for: anchorSongs()) else { return }
        engine.appendEngineItems(held.songs, tags: held.tags)
    }

    /// Looks again a few times while a crossfade finishes. When the next song is merely prepared, the next track
    /// change releases the append instead (`itemTransition`).
    private func watchHeldAppend() {
        guard heldAppendTask == nil else { return }
        heldAppendTask = Task { [weak self] in
            for _ in 0..<AutoplayController.heldAppendPolls {
                try? await Task.sleep(for: AutoplayController.heldAppendPoll)
                guard let self, !Task.isCancelled, self.pendingAppend != nil else { return }
                if !self.engine.isHandOverPrepared {
                    self.heldAppendTask = nil
                    self.releaseHeldAppend()
                    return
                }
            }
            self?.heldAppendTask = nil
        }
    }

    /// After the backstop appended: start the first appended track, if the listener still wants music.
    @discardableResult
    private func resumeAfterQueueEnd() -> Bool {
        let endedAt = queueEndedAtMs
        guard endedAt != 0, pendingAppend == nil,
              AutoplayPolicy.backstopMayResume(endedAtMs: endedAt, nowMs: now(), playWhenReady: true) else { return false }
        // Cleared first: the engine reports "playing" on the way, which would otherwise read as the listener's touch.
        queueEndedAtMs = 0
        setFinding(false)
        return engine.continueAfterQueueEnd()
    }

    // MARK: Pool

    private func startFill(anchors: [Song], settle: Bool, deepen: Bool) {
        if fillTask != nil, fillKey == poolKey { return }
        let key = poolKey
        let startedAt = now()
        // A build that found nothing at all is not repeated on every play and pause for a while.
        if key == emptyBuildKey, startedAt - emptyBuildAtMs >= 0, startedAt - emptyBuildAtMs < Self.emptyBuildRetryMs {
            setFinding(false)
            return
        }
        fillKey = key
        fillTask?.cancel()
        fillGeneration &+= 1
        let generation = fillGeneration
        let currentSongId = engine.queue.current?.song.id
        let fillStation = station
        let otherDirection = needsOtherDirection && fillStation == nil
        fillTask = Task { [weak self] in
            guard let self else { return }
            // Only the newest fill clears the slot: an older, cancelled one must not free it under a running one.
            defer { if self.fillGeneration == generation { self.fillTask = nil } }
            if settle {
                let settled = await self.waitUntilSettled(songId: currentSongId)
                if !settled { return }
            }
            guard !Task.isCancelled,
                  let built = await self.buildPool(anchors: anchors, deepen: deepen, otherDirection: otherDirection,
                                                   station: fillStation) else { return }
            guard !Task.isCancelled, key == self.poolKey else { return }
            self.pool = built.entries
            self.poolFromLibrary = built.fromLibrary
            self.poolSeeds = built.seeds
            self.poolArtistNames = built.artistNames
            if deepen { self.poolDeepened = true }
            if built.entries.isEmpty {
                self.emptyBuildKey = key
                self.emptyBuildAtMs = self.now()
            }
            self.poolReady()
        }
    }

    /// Waits until the current track is 1.5 s in, so a radio request never competes with the first bytes of the
    /// track. False when the track changed (the new one re-triggers) or it stayed paused: `playingChanged` and the
    /// backstop pick that case up, without a polling loop.
    private func waitUntilSettled(songId: String?) async -> Bool {
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
        guard decision == .topUp, pendingAppend == nil else {
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
        if tasteTask != nil {
            tasteDirty = true
            return
        }
        // Which tracks the engine holds are now excluded is worked out off the main actor (it folds every artist
        // name); the main actor only drops them by id.
        let held = pool + Array(served.values)
        let blocked = sources.blocked()
        let adjustments = sources.adjustments()
        tasteTask = Task { [weak self] in
            let gone = await Task.detached(priority: .utility) {
                AutoplayTasteFilter.excludedIds(held: held, blocked: blocked, adjustments: adjustments)
            }.value
            guard let self else { return }
            self.tasteTask = nil
            self.dropExcluded(gone)
            // A second change arrived while this one was applied: look once more.
            if self.tasteDirty {
                self.tasteDirty = false
                self.tasteChanged()
            }
        }
    }

    private func dropExcluded(_ gone: Set<String>) {
        if !gone.isEmpty {
            pool.removeAll { gone.contains($0.candidate.mediaId) }
            let entries = engine.queue.entries
            let current = engine.queue.currentIndex ?? -1
            let queued = entries.indices.contains { $0 > current && entries[$0].isEngineOwned && gone.contains(entries[$0].song.id) }
            if queued {
                if AutoplayPolicy.mustDeferQueueEdit(isTransitionRunning: engine.isHandOverPrepared) {
                    // The edit waits for the track change (`evaluate`), which works the list out again.
                    pendingTasteFilter = true
                    return
                }
                if engine.removeUpcomingEnginePicks(ids: gone) {
                    for id in gone { served[BrainKey(id)] = nil }
                    servedOrder.removeAll { gone.contains($0.text) }
                }
            }
        }
        rescoreTail()
        scheduleEvaluate()
    }

    // MARK: Small things

    private func cancelWork() {
        fillTask?.cancel()
        fillTask = nil
        heldAppendTask?.cancel()
        heldAppendTask = nil
        pendingAppend = nil
        pendingRescore = false
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
