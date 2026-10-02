import AVFoundation
import Foundation
import PixlAudioCore
import PixlLibrary
import PixlModel

/// The real `PlaybackEngine` (architecture §2): two `AVQueuePlayer` decks with a processing tap on every item.
///
/// - Transition NONE (and every case without a crossfade) is **gapless**: the next item is prerolled on the idle deck
///   and started on the host clock at the current item's last frame (`DualDeckEngine+Crossfade.swift`). A pre-insert
///   on the same AVQueuePlayer is not gapless once items carry a processing tap.
/// - FADE_IN_OUT / OVERLAP / SMOOTH run Android's overlap crossfade (`DualDeckEngine+Crossfade.swift`): the next
///   item is prepared on the idle deck, started at `end − fade`, both taps apply their gain curves from their own media
///   time, and the decks swap.
/// - Queue, shuffle and repeat follow Media3 (`PlaybackQueue`); position is never pushed, only read on demand.
@MainActor
final class DualDeckEngine: PlaybackEngine {
    let events: AsyncStream<PlaybackEngineEvent>
    let continuation: AsyncStream<PlaybackEngineEvent>.Continuation

    let session: AudioSessionController
    let effects: AudioEffectsParameters
    let factory: DeckItemFactory
    let replayGainReader = ReplayGainReader()

    private(set) var deckA: Deck
    private(set) var deckB: Deck
    /// The deck playing the current item.
    var active: Deck
    var idle: Deck { active === deckA ? deckB : deckA }

    // MARK: State
    var queue = PlaybackQueue()
    /// Media3 `playWhenReady`: what the user asked for (the UI shows it).
    private(set) var playWhenReady = false
    private(set) var rate: Float = 1
    private(set) var shuffleEnabled = false
    /// The item treated as current (on `active`); nil while loading.
    var activeItem: DeckItem?
    /// The queue ran out (repeat off): `play()` restarts the current song.
    private(set) var hasEnded = false
    /// Position to report while the current item loads.
    private var pendingStartSeconds: Double = 0
    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var nextTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var isPreparing = false
    /// Set by a manual skip that uses the pre-inserted item (so the advance is not reported as automatic).
    private var manualAdvancePending = false

    // MARK: Crossfade state (see +Crossfade)
    var crossfadeTask: Task<Void, Never>?
    var preparedIncoming: DeckItem?
    var preparingIncomingTask: Task<Void, Never>?
    var plannedTransition: CrossfadePlan?
    /// A gapless hand-over waiting for its host time (the incoming deck is already scheduled).
    var scheduledHandOver: ScheduledHandOver?
    var fade: FadeRun?
    var fadeMonitorTask: Task<Void, Never>?
    var nextPlanId = 0

    // MARK: Settings (PlaybackServices keeps these in sync with SettingsStore)
    var crossfadeEnabled = false { didSet { if oldValue != crossfadeEnabled { rescheduleNext() } } }
    /// Global transition (Android: the stored JSON with `crossfade_duration` applied).
    var globalTransition = TransitionSettings() { didSet { if oldValue != globalTransition { rescheduleNext() } } }
    var transitionRules: [TransitionRule] = [] { didSet { if oldValue != transitionRules { rescheduleNext() } } }
    /// The playlist the queue came from (per-playlist transition rules); nil for other sources.
    var queuePlaylistId: String? { didSet { if oldValue != queuePlaylistId { rescheduleNext() } } }
    private(set) var suspensions = TransitionSuspensions()
    /// Open exact-timing sessions (the lyrics sync editor): no hand-over, pause at the end of the song.
    private(set) var exactTimingSessions = 0
    /// The current song reached its end during an exact-timing session (playback paused on it).
    var onExactTimingItemEnded: (() -> Void)?
    /// The sleep timer's end-of-track mode: don't hand over or crossfade into the next song.
    var stopAfterCurrentItem = false { didSet { if oldValue != stopAfterCurrentItem { rescheduleNext() } } }
    var replayGainEnabled = false { didSet { if oldValue != replayGainEnabled { refreshReplayGain() } } }
    var replayGainUseAlbumGain = false { didSet { if oldValue != replayGainUseAlbumGain { refreshReplayGain() } } }
    private var lastAppliedReplayGain: Float?

    // MARK: Hooks (PlaybackServices fans these out to the sleep timer, stats, Now Playing and the snapshot)
    /// The current song changed: (new, previous, automatic).
    var onItemTransition: ((Song?, Song?, Bool) -> Void)?
    /// The same queue entry started again on its own (repeat-one loop, or a crossfade into itself).
    var onRepeatLoop: (() -> Void)?
    /// The queue ended (repeat off).
    var onQueueEnded: (() -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?
    var onQueueChanged: (() -> Void)?
    /// A seek or a rate change (Now Playing elapsed time).
    var onTimingChanged: (() -> Void)?
    var onRepeatModeChanged: ((RepeatMode) -> Void)?
    var onShuffleChanged: ((Bool) -> Void)?

    init(session: AudioSessionController, effects: AudioEffectsParameters, factory: DeckItemFactory) {
        (events, continuation) = AsyncStream.makeStream(of: PlaybackEngineEvent.self)
        self.session = session
        self.effects = effects
        self.factory = factory
        let first = Deck(name: "A")
        deckA = first
        deckB = Deck(name: "B")
        active = first
        session.configure()
        wireDecks()
        wireSession()
    }

    convenience init(session: AudioSessionController) {
        let effects = AudioEffectsParameters()
        self.init(session: session, effects: effects, factory: DeckItemFactory(effects: effects))
    }

    // MARK: - PlaybackEngine

    func setQueue(_ songs: [Song], startIndex: Int, startPositionMs: Int64, playWhenReady: Bool) {
        let previous = queue.current?.song
        queue.replace(with: songs, startIndex: startIndex, shuffle: shuffleEnabled)
        hasEnded = false
        consecutiveFailures = 0
        self.playWhenReady = playWhenReady && !queue.isEmpty
        // Activate the audio session off the main actor while the item loads.
        if self.playWhenReady { session.prepareActivation() }
        emit(.queueChanged(queue.songs, currentIndex: queue.currentIndex))
        onQueueChanged?()
        emit(.currentIndexChanged(queue.currentIndex))
        emitPlaying()
        onItemTransition?(queue.current?.song, previous, false)
        loadCurrent(at: Double(max(startPositionMs, 0)) / 1000)
    }

    func play() {
        guard queue.current != nil else { return }
        session.clearRouteLossPause()
        playWhenReady = true
        emitPlaying()
        if hasEnded {
            hasEnded = false
            if activeItem != nil { active.seek(to: 0) } else { loadCurrent(at: 0); return }
        }
        guard activeItem != nil else {
            if loadTask == nil { loadCurrent(at: pendingStartSeconds) }
            return
        }
        startActive()
        resumeCrossfadeWork()
    }

    func pause() {
        playWhenReady = false
        emitPlaying()
        active.pause()
        fade?.deck.pause()
        suspendCrossfadeWork()
    }

    func skipToNext() {
        guard let target = queue.nextIndexForSkip else { return }
        jump(to: target)
    }

    func skipToPrevious() {
        guard let target = queue.previousIndex, currentPositionMs() <= PlaybackQueue.restartThresholdMs else {
            seek(toMs: 0)
            return
        }
        jump(to: target)
    }

    func seek(toMs positionMs: Int64) {
        finishFadeNow()
        hasEnded = false
        let seconds = Double(max(positionMs, 0)) / 1000
        guard activeItem != nil else {
            pendingStartSeconds = seconds
            if loadTask == nil, queue.current != nil { loadCurrent(at: seconds) }
            return
        }
        active.seek(to: seconds)
        onTimingChanged?()
        rescheduleCrossfadeCountdown()
    }

    func setRepeatMode(_ mode: RepeatMode) {
        guard queue.repeatMode != mode else { return }
        queue.repeatMode = mode
        emit(.repeatModeChanged(mode))
        onRepeatModeChanged?(mode)
        rescheduleNext()
    }

    func setShuffleEnabled(_ enabled: Bool) {
        guard shuffleEnabled != enabled else { return }
        shuffleEnabled = enabled
        queue.setShuffle(enabled)
        emit(.shuffleChanged(enabled))
        emit(.queueChanged(queue.songs, currentIndex: queue.currentIndex))
        onShuffleChanged?(enabled)
        onQueueChanged?()
        rescheduleNext()
    }

    func currentPositionMs() -> Int64 {
        guard let activeItem else { return Int64(pendingStartSeconds * 1000) }
        return Int64(activeItem.positionSeconds * 1000)
    }

    func currentDurationMs() -> Int64 {
        if let activeItem { return Int64(activeItem.durationSeconds * 1000) }
        return queue.current?.song.duration ?? 0
    }

    // MARK: Queue editing

    func playNext(_ songs: [Song]) {
        let wasEmpty = queue.isEmpty
        queue.playNext(songs)
        queueEdited(currentChanged: wasEmpty)
    }

    func addToQueue(_ songs: [Song]) {
        let wasEmpty = queue.isEmpty
        queue.append(songs)
        queueEdited(currentChanged: wasEmpty)
    }

    func moveQueueItem(from: Int, to: Int) {
        queue.move(from: from, to: to)
        queueEdited(currentChanged: false)
    }

    func removeQueueItem(at index: Int) {
        let previous = queue.current?.song
        let currentChanged = queue.remove(at: index)
        queueEdited(currentChanged: currentChanged, previous: previous)
    }

    func skipToQueueItem(at index: Int) {
        guard queue.entry(at: index) != nil else { return }
        if index == queue.currentIndex {
            seek(toMs: 0)
        } else {
            jump(to: index)
        }
    }

    /// Pitch-preserving playback rate (0.25…2; the sync editor uses 1 / 0.75 / 0.5).
    func setPlaybackRate(_ newRate: Float) {
        rate = min(max(newRate, 0.25), 2)
        active.setRate(rate)
        fade?.deck.setRate(rate)
        onTimingChanged?()
        rescheduleCrossfadeCountdown()
    }

    /// Owners (e.g. the lyrics sync editor) that forbid crossfades while active (`TransitionController.suspend`).
    func suspendTransitions(owner: String) {
        if suspensions.suspend(owner) { rescheduleNext() }
    }

    func resumeTransitions(owner: String) {
        if suspensions.resume(owner) { rescheduleNext() }
    }

    /// The lyrics sync editor's session (Android `DualPlayerEngine.beginExactTimingSession`): nothing is handed over
    /// or crossfaded into the next song, and when the song ends playback pauses at its end instead of advancing, so
    /// the editor can offer "Keep going" / "Time the rest roughly". Counted, like the transition suspensions.
    func beginExactTimingSession() {
        exactTimingSessions += 1
        if exactTimingSessions == 1 { rescheduleNext() }
    }

    func endExactTimingSession() {
        guard exactTimingSessions > 0 else { return }
        exactTimingSessions -= 1
        if exactTimingSessions == 0 { rescheduleNext() }
    }

    /// Stops playback and empties both decks (the queue is kept).
    func stop() {
        pause()
        finishFadeNow()
        cancelLoading()
        discard(active.removeAll())
        discard(idle.removeAll())
        activeItem = nil
        session.deactivate()
    }

    // MARK: Effects

    func applyEqualizer(_ settings: EqualizerSettings) {
        effects.setEqualizer(settings, sampleRate: session.outputSampleRate)
    }

    /// Mid/side instrumental fallback, 0 (off) … 1.
    func setVocalAttenuation(_ attenuation: Float) {
        effects.midSideAttenuation.store(min(max(attenuation, 0), 1))
    }

    // MARK: Snapshot

    /// The queue as Android persists it (`PlaybackQueueSnapshot`).
    func makeSnapshot(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> PlaybackQueueSnapshot? {
        makeSnapshotCapture(nowMs: nowMs)?.makeSnapshot()
    }

    /// What a snapshot needs, without building it: the queue value and the position (cheap on the main actor;
    /// `QueueSnapshotStore` maps and encodes it off the main actor).
    func makeSnapshotCapture(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> QueueSnapshotCapture? {
        guard !queue.isEmpty else { return nil }
        return QueueSnapshotCapture(queue: queue, positionMs: currentPositionMs(), playWhenReady: playWhenReady,
                                    shuffleEnabled: shuffleEnabled, nowMs: nowMs)
    }

    /// Restores a saved queue paused at its position (only into an empty engine). `songs` are the snapshot's items
    /// resolved against the library, in snapshot order.
    func restore(_ snapshot: PlaybackQueueSnapshot, songs: [Song]) {
        guard queue.isEmpty, !songs.isEmpty else { return }
        var index = min(max(snapshot.currentIndex, 0), songs.count - 1)
        if let id = snapshot.currentMediaId, songs[index].id != id, let found = songs.firstIndex(where: { $0.id == id }) {
            index = found
        }
        queue.restore(songs: songs, currentIndex: index, originalSongs: nil)
        queue.repeatMode = RepeatMode(rawValue: snapshot.repeatMode) ?? .off
        shuffleEnabled = snapshot.shuffleEnabled
        playWhenReady = false
        emit(.queueChanged(queue.songs, currentIndex: queue.currentIndex))
        emit(.repeatModeChanged(queue.repeatMode))
        emit(.shuffleChanged(shuffleEnabled))
        emit(.currentIndexChanged(queue.currentIndex))
        emitPlaying()
        onQueueChanged?()
        onItemTransition?(queue.current?.song, nil, false)
        loadCurrent(at: Double(max(snapshot.currentPositionMs, 0)) / 1000)
    }

    /// Restores repeat / shuffle preferences at launch (before any queue exists).
    func restorePreferences(repeatMode: RepeatMode, shuffle: Bool) {
        queue.repeatMode = repeatMode
        shuffleEnabled = shuffle
        emit(.repeatModeChanged(repeatMode))
        emit(.shuffleChanged(shuffle))
    }

    // MARK: - Loading

    /// Replaces the active deck's content with the current queue entry at `seconds`.
    func loadCurrent(at seconds: Double) {
        cancelCrossfadePlan()
        finishFadeNow()
        cancelLoading()
        discard(active.removeAll())
        discard(idle.removeAll())
        activeItem = nil
        loadGeneration += 1
        let generation = loadGeneration
        pendingStartSeconds = seconds
        guard let entry = queue.current else {
            setPreparing(false)
            return
        }
        setPreparing(true)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await self.factory.makeItem(for: entry)
                guard generation == self.loadGeneration else {
                    self.factory.discard(item)
                    return
                }
                self.loadTask = nil
                self.install(item, at: seconds)
            } catch {
                guard generation == self.loadGeneration else { return }
                self.loadTask = nil
                self.loadFailed(entry: entry, error: error)
            }
        }
    }

    private func install(_ item: DeckItem, at seconds: Double) {
        prepareReplayGain(item)
        activeItem = item
        active.load(item, at: seconds)
        pendingStartSeconds = 0
        consecutiveFailures = 0
        if playWhenReady { startActive() }
        setPreparing(false)
        onTimingChanged?()
        scheduleNext()
    }

    private func loadFailed(entry: QueueEntry, error: any Error) {
        setPreparing(false)
        emit(.failed(message: "Couldn't play \"\(entry.song.title)\" (\(error.localizedDescription))"))
        consecutiveFailures += 1
        if playWhenReady, consecutiveFailures < queue.count, let next = queue.nextIndexForSkip {
            advance(to: next, automatic: true, previous: entry.song)
        } else {
            playWhenReady = false
            emitPlaying()
        }
    }

    private func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        nextTask?.cancel()
        nextTask = nil
    }

    func startActive() {
        session.activate()
        active.play(rate: rate)
    }

    func discard(_ items: [DeckItem]) {
        for item in items { factory.discard(item) }
    }

    /// Moves to `index` and loads it from the start.
    private func advance(to index: Int, automatic: Bool, previous: Song?) {
        queue.setCurrentIndex(index)
        emit(.currentIndexChanged(queue.currentIndex))
        onItemTransition?(queue.current?.song, previous, automatic)
        loadCurrent(at: 0)
    }

    /// A user-initiated move to `index`. Uses the pre-inserted gapless item when it is exactly that entry (instant).
    private func jump(to index: Int) {
        hasEnded = false
        guard let target = queue.entry(at: index) else { return }
        if fade == nil, let upcoming = active.upcoming.first, upcoming.entry.id == target.id, activeItem != nil {
            cancelCrossfadePlan()
            manualAdvancePending = true
            active.player.advanceToNextItem()
            if playWhenReady { startActive() }
            return
        }
        advance(to: index, automatic: false, previous: queue.current?.song)
    }

    // MARK: - What comes next

    /// Plans what follows the current item: a crossfade when the rules ask for one, otherwise a gapless hand-over to
    /// the next entry (both prepared on the idle deck near the end).
    func scheduleNext() {
        nextTask?.cancel()
        nextTask = nil
        cancelCrossfadePlan()
        discard(active.removeUpcoming())
        guard let current = activeItem, !stopAfterCurrentItem, exactTimingSessions == 0 else { return }
        if let plan = crossfadePlan(for: current) {
            startCrossfade(plan)
            return
        }
        guard let nextIndex = queue.nextIndexForAutoAdvance, let entry = queue.entry(at: nextIndex) else { return }
        startCrossfade(handOverPlan(for: current, target: entry))
    }

    /// Re-plans after a queue, repeat, shuffle or settings change.
    func rescheduleNext() {
        guard activeItem != nil else { return }
        scheduleNext()
    }

    private func queueEdited(currentChanged: Bool, previous: Song? = nil) {
        emit(.queueChanged(queue.songs, currentIndex: queue.currentIndex))
        onQueueChanged?()
        if currentChanged {
            emit(.currentIndexChanged(queue.currentIndex))
            onItemTransition?(queue.current?.song, previous, false)
            if queue.current == nil {
                stop()
                playWhenReady = false
                emitPlaying()
            } else {
                loadCurrent(at: 0)
            }
        } else {
            rescheduleNext()
        }
    }

    // MARK: - Deck events

    private func wireDecks() {
        for deck in [deckA, deckB] {
            deck.onEvent = { [weak self] deck, event in self?.handle(deck, event) }
        }
    }

    private func handle(_ deck: Deck, _ event: Deck.Event) {
        switch event {
        case .currentItemChanged(let item):
            guard deck === active else { return }
            if let item {
                if item !== activeItem { autoAdvanced(to: item) }
            } else if activeItem != nil {
                // A hand-over scheduled for this very moment takes over instead of a reload.
                if completeScheduledHandOver() { return }
                activeItemEndedWithoutSuccessor()
            }
        case .statusChanged(let status):
            guard deck === active else { return }
            setPreparing(loadTask != nil || (playWhenReady && status == .waitingToPlayAtSpecifiedRate))
        case .itemEnded(let item):
            guard deck === active, item === activeItem, deck.upcoming.isEmpty else { return }
            if completeScheduledHandOver() { return }
            activeItemEndedWithoutSuccessor()
        case .itemFailed(let item, let message):
            if deck === active, item === activeItem {
                activeItem = nil
                loadFailed(entry: item.entry, error: PlaybackFailure(message: message))
            } else {
                deck.remove(item)
                factory.discard(item)
                if item === preparedIncoming { preparedIncoming = nil }
            }
        }
    }

    /// AVQueuePlayer moved to the pre-inserted item (gapless), or a manual skip used it.
    private func autoAdvanced(to item: DeckItem) {
        let previous = activeItem
        let manual = manualAdvancePending
        manualAdvancePending = false
        activeItem = item
        hasEnded = false
        pendingStartSeconds = 0
        guard let index = queue.index(ofEntry: item.entry.id) else {
            scheduleNext()
            return
        }
        queue.setCurrentIndex(index)
        if !manual, previous?.entry.id == item.entry.id {
            onRepeatLoop?()
        } else {
            emit(.currentIndexChanged(index))
            onItemTransition?(item.song, previous?.song, !manual)
        }
        if let volume = lastAppliedReplayGainFor(item) { lastAppliedReplayGain = volume }
        onTimingChanged?()
        scheduleNext()
    }

    private func activeItemEndedWithoutSuccessor() {
        guard let ended = activeItem else { return }
        activeItem = nil
        if exactTimingSessions > 0 {
            // The sync editor: stay on this song, paused at its end.
            playWhenReady = false
            emitPlaying()
            loadCurrent(at: max(0, ended.durationSeconds - 0.05))
            onExactTimingItemEnded?()
            return
        }
        if let next = queue.nextIndexForAutoAdvance {
            if stopAfterCurrentItem {
                // End-of-track sleep timer: move on, paused.
                playWhenReady = false
                emitPlaying()
            }
            if next == queue.currentIndex {
                // Repeat-one without a pre-inserted copy (e.g. the end-of-track timer cancelled it): loop.
                onRepeatLoop?()
                loadCurrent(at: 0)
            } else {
                advance(to: next, automatic: true, previous: ended.song)
            }
        } else {
            playWhenReady = false
            hasEnded = true
            emitPlaying()
            emit(.queueEnded)
            onQueueEnded?()
            // Keep the last song loaded at its start so play / seek work (Media3 restarts on play after ENDED).
            loadCurrent(at: 0)
            hasEnded = true
        }
    }

    // MARK: - Audio session

    private func wireSession() {
        session.deckSnapshot = { [weak self] in
            guard let self else {
                return DeckPlaybackSnapshot(masterPlayWhenReady: false, masterIsPlaying: false, transitionRunning: false)
            }
            return DeckPlaybackSnapshot(masterPlayWhenReady: self.playWhenReady,
                                        masterIsPlaying: self.active.isPlaying,
                                        transitionRunning: self.fade != nil,
                                        auxiliaryPlayWhenReady: self.fade != nil && self.playWhenReady,
                                        auxiliaryIsPlaying: self.fade?.deck.isPlaying ?? false)
        }
        session.isTransitionRunning = { [weak self] in self?.fade != nil }
        session.onCommand = { [weak self] command in self?.handle(command) }
    }

    func handle(_ command: AudioSessionController.Command) {
        switch command {
        case .focus(let actions):
            // Pausing both decks (master + auxiliary) is one `pause()`; the session remembers whether to resume.
            if actions.contains(.pauseMaster) || actions.contains(.pauseAuxiliary) { pause() }
            if actions.contains(.resumeMaster) { play() }
            if actions.contains(.abandonFocus) { session.deactivate() }
        case .pauseForRouteLoss:
            pause()
        case .resumeForRouteReturn:
            play()
        case .rebuildAfterReset:
            rebuildAfterMediaServicesReset()
        case .routeChanged:
            let rate = session.outputSampleRate
            if abs(rate - effects.designSampleRate.load()) > 0.5 { effects.setEqualizer(effects.settings, sampleRate: rate) }
        }
    }

    /// Every player and tap died with the media server: rebuild both decks and reload the current item.
    private func rebuildAfterMediaServicesReset() {
        let position = currentPositionMs()
        let wasPlaying = playWhenReady
        cancelCrossfadePlan()
        fadeMonitorTask?.cancel()
        fade = nil
        cancelLoading()
        discard(deckA.removeAll())
        discard(deckB.removeAll())
        deckA.onEvent = nil
        deckB.onEvent = nil
        let first = Deck(name: "A")
        deckA = first
        deckB = Deck(name: "B")
        active = first
        activeItem = nil
        wireDecks()
        guard queue.current != nil else { return }
        playWhenReady = wasPlaying
        loadCurrent(at: Double(position) / 1000)
    }

    // MARK: - ReplayGain

    /// Sets the item's ReplayGain volume: the last applied value at once (no full-volume spike), then the file's own
    /// value once its tags are read (Android `ReplayGainProcessor.apply`).
    func prepareReplayGain(_ item: DeckItem) {
        guard replayGainEnabled, item.isLocalFile else {
            item.tap.replayGainVolume.store(1)
            return
        }
        if let last = lastAppliedReplayGain { item.tap.replayGainVolume.store(last) }
        let url = item.asset.url
        let useAlbum = replayGainUseAlbumGain
        Task { [weak self] in
            guard let self else { return }
            let values = await self.replayGainReader.values(for: url)
            let volume = ReplayGain.volumeMultiplier(values, useAlbumGain: useAlbum)
            item.tap.replayGainVolume.store(volume)
            item.replayGainVolume = volume
            if item === self.activeItem { self.lastAppliedReplayGain = volume }
        }
    }

    private func lastAppliedReplayGainFor(_ item: DeckItem) -> Float? {
        replayGainEnabled ? item.replayGainVolume : nil
    }

    private func refreshReplayGain() {
        lastAppliedReplayGain = nil
        for item in deckA.items + deckB.items { prepareReplayGain(item) }
    }

    // MARK: - Events

    func emit(_ event: PlaybackEngineEvent) {
        continuation.yield(event)
    }

    private func emitPlaying() {
        emit(.playingChanged(playWhenReady))
        onPlayingChanged?(playWhenReady)
    }

    private func setPreparing(_ preparing: Bool) {
        guard preparing != isPreparing else { return }
        isPreparing = preparing
        emit(.preparingChanged(preparing))
    }
}

nonisolated struct PlaybackFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
