import Foundation
import PixlLibrary
import PixlModel
import PixlNet

/// Autoplay: when two or fewer tracks are left, five more are appended, so music does not stop at the end of a
/// queue (docs/brain-spec.md, 7.1). The port of Android's `AutoplayController`.
///
/// Every decision is in PixlCore: `AutoplayPolicy` (when to top up, what may follow what), `AutoplayPool` (which
/// tracks, from which radios, or from the library) and `BrainRepository` (the radio cache and its fallbacks). This
/// class only reads the engine, asks them, and carries out the answer on the main actor.
///
/// Rules it keeps:
///  - The trigger asks the in-memory pool, never the network. A radio request starts no earlier than 1.5 s into a
///    track, and all of a pool's work (files, network, text folding) runs off the main actor.
///  - One queue edit per top-up, never while one deck hands over to the other or the next song is already prepared
///    for that; and never from inside an engine callback (the edit runs on the next main-actor turn).
///  - Never at the end of the queue, except as the backstop: picks that land within 10 s of the end resume playback,
///    unless the listener touched play or pause meanwhile or a sleep timer ended the queue.
///  - Only tracks the listener chose are anchors. Engine picks that merely played are not, so an hour of autoplay is
///    still about what the listener started with.
///  - Tracks the listener queued are never moved or removed. Engine items are only ever appended.
///  - Off under repeat, during Spotify Connect, and while a saved queue is being restored.
///
/// Stage 1a picks in radio order under the hard constraints. There is no scorer and no session state yet (stage
/// 1b), so a skip does not change what comes next.
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
    private var fillTask: Task<Void, Never>?
    private var fillKey = ""
    private var fillGeneration = 0
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
        guard engine.hasEnded, decide() == .topUp, engine.queue.nextIndexForAutoAdvance == nil else { return }
        let anchors = anchorSongs()
        guard !anchors.isEmpty else { return }
        adoptPool(for: anchors)
        let endedAt = now()
        queueEndedAtMs = endedAt
        var appended = false
        if let held = pendingAppend {
            // A batch that was waiting for a hand-over which never came: it goes in now, if it is still for this queue.
            pendingAppend = nil
            heldAppendTask?.cancel()
            heldAppendTask = nil
            if held.key == poolKey {
                engine.appendEngineItems(held.songs, tags: held.tags)
                appended = true
            }
        }
        if !appended { appended = appendFromPool() }
        if appended, resumeAfterQueueEnd() { return }
        setFinding(true)
        startFill(anchors: anchors, settle: false, deepen: false)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(AutoplayPolicy.backstopWindowMs + 250))
            guard let self, self.queueEndedAtMs == endedAt else { return }
            // Nothing landed in time: the queue simply ended, as it always did.
            self.queueEndedAtMs = 0
            self.setFinding(false)
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

    private func decide() -> AutoplayPolicy.Decision {
        AutoplayPolicy.decide(autoplayEnabled: sources.isEnabled(), repeatMode: Int32(engine.queue.repeatMode.rawValue),
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
        if appendFromPool() {
            if pool.count < AutoplayPolicy.poolRefillBelow, !poolFromLibrary, !poolDeepened {
                startFill(anchors: anchors, settle: true, deepen: true)
            }
            return
        }
        // Nothing fits from what is in memory: build it, or once per set of anchors rebuild it deeper (continuation
        // pages, then the library behind them). After that the queue is allowed to end.
        if !pool.isEmpty, poolDeepened { return }
        startFill(anchors: anchors, settle: settle, deepen: !pool.isEmpty)
    }

    /// A pool belongs to its anchors: other anchors, another pool.
    private func adoptPool(for anchors: [Song]) {
        let key = AutoplayPool.key(of: anchors.map(\.id))
        guard key != poolKey else { return }
        poolKey = key
        pool = []
        poolFromLibrary = false
        poolDeepened = false
        if fillKey != key {
            fillTask?.cancel()
            fillTask = nil
        }
    }

    /// The last tracks the listener chose, at or before the current one, newest first.
    private func anchorSongs() -> [Song] {
        let entries = engine.queue.entries
        return AutoplayPolicy.anchorIndices(currentAbsoluteIndex: engine.queue.currentIndex ?? -1,
                                            queueSize: entries.count,
                                            engineOwned: { entries[$0].isEngineOwned },
                                            mediaIdAt: { entries[$0].song.id }).map { entries[$0].song }
    }

    // MARK: Append

    /// Appends one batch from the in-memory pool. True when a batch went in (or is held until a hand-over is done).
    /// No I/O: a few hundred comparisons over what is already in memory.
    private func appendFromPool() -> Bool {
        guard !pool.isEmpty else { return false }
        let nowMs = now()
        let entries = engine.queue.entries
        var excluded = Set<BrainKey>()
        excluded.reserveCapacity(entries.count + 64)
        var tail: [AutoplayPolicy.Slot] = []
        for entry in entries {
            excluded.insert(BrainKey(entry.song.id))
            if entry.isEngineOwned {
                tail.append(AutoplayPolicy.Slot(artistKey: BrainLibraryIndex.artistKey(of: entry.song),
                                                albumKey: BrainLibraryIndex.albumKey(of: entry.song.album)))
            }
        }
        // 6.4: nothing played in the last four hours. Until the event log records (stage 1b) the existing playback
        // history answers this; only its newest entries are read.
        let since = nowMs - Self.fourHoursMs
        for event in sources.events().suffix(Self.recentHistoryScan) where event.timestamp >= since {
            excluded.insert(BrainKey(event.songId))
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
        let surfaceId = poolKey.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
        var songs: [Song] = []
        var tags: [BrainItemTag] = []
        var engineTracks: [EngineTrack] = []
        for (slot, candidate) in picked.enumerated() {
            guard let entry = byId[BrainKey(candidate.mediaId)] else { continue }
            let song: Song
            if let librarySong = entry.librarySong {
                // The library's current row (a favourite flag set since the pool was built).
                song = sources.librarySong(librarySong.id) ?? librarySong
            } else if let track = entry.engineTrack {
                song = BrainService.queueSong(for: track, nowMs: nowMs)
                engineTracks.append(track)
            } else {
                continue
            }
            songs.append(song)
            tags.append(BrainItemTag(surface: Surface.nameOf(Surface.autoplay), surfaceId: surfaceId, recId: recId,
                                     slot: slot, arm: Arm.nameOf(candidate.arm),
                                     whyArg: entry.whyArtist.isEmpty ? nil : entry.whyArtist,
                                     radioRank: candidate.radioRank > 0 ? Int(candidate.radioRank) : -1))
        }
        guard !songs.isEmpty else { return false }
        // Known to the app, and stored, before they can play: Recently Played and Like find them by id.
        brain.register(engineTracks)
        if brain.autoplay.fromLibrary != poolFromLibrary { brain.autoplay.fromLibrary = poolFromLibrary }
        if AutoplayPolicy.mustDeferQueueEdit(isTransitionRunning: engine.isHandOverPrepared) {
            pendingAppend = (songs, tags, poolKey)
            watchHeldAppend()
        } else {
            engine.appendEngineItems(songs, tags: tags)
        }
        return true
    }

    /// An append held during a hand-over goes in as soon as the hand-over is done.
    private func releaseHeldAppend() {
        guard let held = pendingAppend, !engine.isHandOverPrepared else { return }
        pendingAppend = nil
        heldAppendTask?.cancel()
        heldAppendTask = nil
        // Dropped when the queue no longer needs it, or is no longer the one it was picked for.
        guard decide() == .topUp, held.key == AutoplayPool.key(of: anchorSongs().map(\.id)) else { return }
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
        fillTask = Task { [weak self] in
            guard let self else { return }
            // Only the newest fill clears the slot: an older, cancelled one must not free it under a running one.
            defer { if self.fillGeneration == generation { self.fillTask = nil } }
            if settle {
                let settled = await self.waitUntilSettled(songId: currentSongId)
                if !settled { return }
            }
            guard !Task.isCancelled, let built = await self.buildPool(anchors: anchors, deepen: deepen) else { return }
            guard !Task.isCancelled, key == self.poolKey else { return }
            self.pool = built.entries
            self.poolFromLibrary = built.fromLibrary
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
        guard decide() == .topUp, pendingAppend == nil else { return }
        if queueEndedAtMs != 0 {
            // Backstop: outside the window the queue stays ended and nothing is added.
            guard AutoplayPolicy.backstopMayResume(endedAtMs: queueEndedAtMs, nowMs: now(), playWhenReady: true) else {
                queueEndedAtMs = 0
                setFinding(false)
                return
            }
            if appendFromPool() {
                _ = resumeAfterQueueEnd()
            } else {
                queueEndedAtMs = 0
                setFinding(false)
            }
            return
        }
        _ = appendFromPool()
    }

    /// Captures what a build reads (cheap copies of values), then builds off the main actor: the anchors' audio ids,
    /// the library index, the radios (cache first, then the network when it may), the filters.
    private func buildPool(anchors: [Song], deepen: Bool) async -> BuiltAutoplayPool? {
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
            let request = AutoplayPoolRequest(
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
            let pool = await AutoplayPool.build(request, index: index, repository: repository)
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

    // MARK: Small things

    private func cancelWork() {
        fillTask?.cancel()
        fillTask = nil
        heldAppendTask?.cancel()
        heldAppendTask = nil
        pendingAppend = nil
        queueEndedAtMs = 0
        setFinding(false)
    }

    private func setFinding(_ finding: Bool) {
        if brain.autoplay.finding != finding { brain.autoplay.finding = finding }
    }

    /// Where the queue draws the Autoplay line (assigned only when it changed).
    private func syncLine() {
        let index = engine.queue.firstUpcomingEngineIndex
        if brain.autoplay.lineIndex != index { brain.autoplay.lineIndex = index }
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
