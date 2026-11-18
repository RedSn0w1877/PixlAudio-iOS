import AVFoundation
import Foundation
import Observation
import PixlAudioCore
import PixlLibrary
import PixlModel
import UIKit

/// Assembles the playback stack for real launches (UI tests keep `DemoPlaybackEngine`): the audio session, the
/// dual-deck engine, Now Playing + remote commands, the sleep timer, listening stats / history / engagement and the
/// queue snapshot, and keeps the engine in sync with `SettingsStore` (crossfade, transitions, ReplayGain, equalizer,
/// resume-on-reconnect).
@MainActor
final class PlaybackServices {
    let session: AudioSessionController
    let engine: DualDeckEngine
    let nowPlaying: NowPlayingController
    let sleepTimer: SleepTimerController
    let stats = ListeningStatsTracker()
    let snapshots: QueueSnapshotStore
    let history: PlaybackHistoryStore?
    /// Where finished listening sessions go. `AppEnvironment` points this at Home's `ListeningHistoryStore`, so one
    /// object owns `playback_history.json`; without it the sessions are written through `history`.
    var recordHistory: ((_ songId: String, _ durationMs: Int64, _ timestamp: Int64) -> Void)?
    /// Every finished listening session, for music intelligence's feedback (Android `tasteRepository.record`).
    var recordTaste: ((ListeningStatsTracker.Record) -> Void)?
    /// The current item or the queue changed (stage 11's prefetcher resolves the next streamed song).
    var onUpcomingChanged: (() -> Void)?
    /// Playback started or paused (the prefetcher prepares upcoming streamed songs only while playing).
    var onPlayStateChanged: ((Bool) -> Void)?
    /// Autoplay (docs/brain-spec.md, 7.1): told about track changes, queue changes, play state and the end of the
    /// queue, next to the hooks above (which the prefetcher owns and which stay as they are).
    var autoplay: AutoplayController?
    /// The music brain's side of a play (docs/brain-spec.md, 4.2). `AppEnvironment` sets both: whether the library
    /// has a row for a song id, and whether Autoplay brought the id from outside the library.
    var isInLibrary: ((String) -> Bool)?
    var isEngineTrack: ((String) -> Bool)?
    /// A finished listening session's engagement row (its play count) has been written. `recordHistory` bumps the
    /// history revision before that write lands, so `AppEnvironment` re-reads the play counts from here.
    var onEngagementRecorded: (() -> Void)?

    private let settings: SettingsStore
    private let defaults: UserDefaults
    private let persistence: PersistenceActor?
    private var lifecycleObservers: [any NSObjectProtocol] = []
    private var started = false
    private var queuePreload: Task<PlaybackQueueSnapshot?, Never>?

    // What the reason table of docs/brain-spec.md 4.2 reads: where the queue stood before the last change.
    private var lastQueueIndex = -1
    private var lastQueueCount = 0
    private var queueCountBeforeChange = 0
    /// The queue was replaced or edited in this main-actor turn (a track change in the same turn is its doing).
    private var queueChangedThisTurn = false
    private var isRestoringQueue = false
    private var seenLoadFailures = 0
    private var routeCode: Int32 = PixlLibrary.Route.unknown
    private var routeReadAtMs: Int64 = 0

    /// Settings › Playback › Pause when volume reaches zero.
    private let volumeZero = VolumeZeroPauser()

    init(settings: SettingsStore, persistence: PersistenceActor?, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        self.persistence = persistence
        session = AudioSessionController()
        engine = DualDeckEngine(session: session)
        nowPlaying = NowPlayingController(engine: engine)
        sleepTimer = SleepTimerController(engine: engine)
        snapshots = QueueSnapshotStore(defaults: defaults,
                                       file: defaults === UserDefaults.standard
                                           ? QueueSnapshotFile.defaultURL().map(QueueSnapshotFile.init) : nil)
        history = PlaybackHistoryStore.defaultURL().map { PlaybackHistoryStore(url: $0) }
        wireEngine()
    }

    /// Launch work: remote commands, settings, transition rules, lifecycle. Cheap; no I/O on the main actor.
    func start() {
        guard !started else { return }
        started = true
        engine.restorePreferences(repeatMode: settings.playback.repeatMode,
                                  shuffle: settings.playback.persistentShuffleEnabled && settings.playback.isShuffleOn)
        nowPlaying.install()
        observeSettings()
        observeLifecycle()
        let settings = self.settings
        volumeZero.start(isEnabled: { settings.playback.pauseOnVolumeZero },
                         pauseIfPlaying: { [weak self] in
                             guard let self, self.engine.active.isPlaying else { return }
                             self.engine.pause()
                         })
        Task { await reloadTransitionRules() }
    }

    /// Starts decoding the saved queue off the main actor now (launch), so `restoreQueue` finds it ready once the
    /// library's cache is installed instead of decoding it then.
    func prepareQueueRestore() {
        guard queuePreload == nil else { return }
        let snapshots = self.snapshots
        queuePreload = Task { await snapshots.loadInBackground() }
    }

    /// Restores the saved queue (paused) once the library is loaded. The JSON is decoded off the main actor.
    /// `beforeRestore` gets the song the queue will show first, before the queue is restored (launch themes it then).
    func restoreQueue(lookup: (String) -> Song?, beforeRestore: ((Song) async -> Void)? = nil) async {
        let loaded: PlaybackQueueSnapshot?
        if let queuePreload {
            self.queuePreload = nil
            loaded = await queuePreload.value
        } else {
            loaded = await snapshots.loadInBackground()
        }
        guard let snapshot = loaded, !snapshot.items.isEmpty else { return }
        let songs = QueueSnapshotStore.songs(for: snapshot, lookup: lookup)
        if let beforeRestore, !songs.isEmpty {
            await beforeRestore(songs[DualDeckEngine.restoredIndex(snapshot, songs: songs)])
        }
        // A restored queue brings its own engine items back; Autoplay adds nothing until playback starts.
        autoplay?.isRestoringQueue = true
        isRestoringQueue = true
        engine.restore(snapshot, songs: songs)
        isRestoringQueue = false
    }

    /// Re-reads the per-playlist transition rules (stage 7d calls this after editing them).
    func reloadTransitionRules() async {
        guard let persistence else { return }
        let rules = (try? await persistence.transitionRules()) ?? []
        engine.transitionRules = rules
    }

    // MARK: Engine hooks

    private func wireEngine() {
        snapshots.makeSnapshot = { [weak self] in self?.engine.makeSnapshot() }
        snapshots.makeCapture = { [weak self] in self?.engine.makeSnapshotCapture() }
        sleepTimer.titleForSongId = { [weak self] id in
            self?.engine.queue.entries.first { $0.song.id == id }?.song.title
        }
        engine.onItemTransition = { [weak self] new, previous, automatic in
            guard let self else { return }
            self.sleepTimer.itemTransition(new: new, previous: previous, automatic: automatic)
            if !automatic, let new { self.stats.onVoluntarySelection(songId: new.id) }
            let reasons = self.transitionReasons(automatic: automatic)
            self.stats.onTrackChanged(songId: new?.id, positionMs: 0, durationMs: new?.duration ?? 0,
                                      isPlaying: self.engine.playWhenReady,
                                      context: self.brainContext(startReason: reasons.start), endReason: reasons.end,
                                      isOutsideLibrary: self.isOutsideLibrary(new))
            self.nowPlaying.update()
            self.snapshots.scheduleSave()
            self.onUpcomingChanged?()
            self.autoplay?.itemTransition()
        }
        engine.onRepeatLoop = { [weak self] in
            guard let self else { return }
            self.sleepTimer.repeatLoop()
            let song = self.engine.queue.current?.song
            // Repeat is a finished track that starts again by itself.
            self.stats.onTrackChanged(songId: song?.id, positionMs: 0, durationMs: song?.duration ?? 0,
                                      isPlaying: self.engine.playWhenReady,
                                      context: self.brainContext(startReason: StartReason.autoAdvance),
                                      endReason: EndReason.trackDone, isOutsideLibrary: self.isOutsideLibrary(song))
            self.nowPlaying.update()
        }
        engine.onSeek = { [weak self] from, to in
            self?.stats.onSeek(fromPositionMs: from, toPositionMs: to)
        }
        engine.onQueueEnded = { [weak self] in
            guard let self else { return }
            // Read before the timer hears about the end: an "end of track" timer that ended the queue stays ended.
            let stoppedByTimer = self.engine.stopAfterCurrentItem
            self.sleepTimer.queueEnded()
            // The last track of the queue played out.
            self.stats.finalizeCurrentSession(endReason: EndReason.trackDone)
            self.nowPlaying.update()
            self.autoplay?.queueEnded(stoppedByTimer: stoppedByTimer)
        }
        engine.onPlayingChanged = { [weak self] playing in
            guard let self else { return }
            self.stats.onPlayStateChanged(isPlaying: playing, positionMs: self.engine.currentPositionMs())
            self.nowPlaying.update()
            // Coalesced and encoded off the main actor (the pause position is the same a second later).
            if !playing { self.snapshots.scheduleSave() }
            self.onPlayStateChanged?(playing)
            self.autoplay?.playingChanged(playing)
        }
        engine.onQueueChanged = { [weak self] in
            self?.noteQueueChanged()
            self?.nowPlaying.update()
            self?.snapshots.scheduleSave()
            self?.onUpcomingChanged?()
            self?.autoplay?.queueChanged()
        }
        engine.onNextWithNothingQueued = { [weak self] in
            self?.autoplay?.nextWithNothingQueued()
        }
        engine.onEnginePickFailed = { [weak self] songId in
            self?.autoplay?.enginePickFailed(songId: songId)
        }
        engine.onTimingChanged = { [weak self] in
            guard let self else { return }
            self.stats.updateDuration(self.engine.currentDurationMs())
            self.nowPlaying.update()
        }
        engine.onRepeatModeChanged = { [weak self] mode in
            guard let self else { return }
            if self.settings.playback.repeatMode != mode { self.settings.playback.repeatMode = mode }
            self.sleepTimer.repeatModeChanged(mode)
            self.nowPlaying.update()
            self.snapshots.scheduleSave()
        }
        engine.onShuffleChanged = { [weak self] enabled in
            guard let self else { return }
            if self.settings.playback.persistentShuffleEnabled, self.settings.playback.isShuffleOn != enabled {
                self.settings.playback.isShuffleOn = enabled
            }
            self.nowPlaying.update()
            self.snapshots.scheduleSave()
        }
        stats.onRecord = { [weak self] record in
            guard let self else { return }
            let history = self.recordHistory == nil ? self.history : nil
            // The play history is written for every track: an engine track shows in Recently Played through it.
            self.recordHistory?(record.songId, record.listenedMs, record.timestamp)
            // The taste counters and the engagement rows are capped stores that feed rankers which spend money in
            // the cloud: a track Autoplay played from outside the library stays out of them until it is saved
            // (docs/brain-spec.md, 4.2).
            let countsForLegacy = !record.isOutsideLibrary
            if countsForLegacy { self.recordTaste?(record) }
            let persistence = self.persistence
            Task.detached(priority: .utility) { [weak self] in
                await history?.recordPlayback(songId: record.songId, durationMs: record.listenedMs,
                                              timestamp: record.timestamp)
                if countsForLegacy {
                    try? await persistence?.recordEngagement(songId: record.songId, durationMs: record.listenedMs,
                                                             timestamp: record.timestamp)
                }
                await self?.engagementRecorded()
            }
        }
    }

    // MARK: The music brain's play (docs/brain-spec.md, 4.2)

    /// The queue was replaced or edited. A track change in the same main-actor turn is that edit's doing; one that
    /// comes later is the listener moving inside the queue.
    private func noteQueueChanged() {
        queueCountBeforeChange = lastQueueCount
        lastQueueCount = engine.queue.count
        guard !queueChangedThisTurn else { return }
        queueChangedThisTurn = true
        Task { [weak self] in
            guard let self else { return }
            self.queueChangedThisTurn = false
            // An edit can move the current entry without changing it (a song queued or removed above it).
            self.lastQueueIndex = self.engine.queue.currentIndex ?? -1
        }
    }

    /// Why the track that was current ended and how the new one starts (the table is `PlayReasons`, in PixlLibrary).
    private func transitionReasons(automatic: Bool) -> PlayReasons.Reasons {
        let newIndex = engine.queue.currentIndex ?? -1
        let enginePick = engine.queue.current?.isEngineOwned ?? false
        let failed = engine.loadFailureCount != seenLoadFailures
        seenLoadFailures = engine.loadFailureCount
        let reasons: PlayReasons.Reasons
        if failed, automatic {
            reasons = PlayReasons.afterFailure(newItemIsEnginePick: enginePick)
        } else {
            reasons = PlayReasons.forTransition(
                reason: PlayReasons.kind(automatic: automatic, queueChanged: queueChangedThisTurn),
                oldIndex: lastQueueIndex, newIndex: newIndex, oldQueueSize: queueCountBeforeChange,
                newQueueSize: engine.queue.count, newItemIsEnginePick: enginePick, isRestoring: isRestoringQueue)
        }
        lastQueueIndex = newIndex
        return reasons
    }

    /// What the brain needs to know about the entry that is now current.
    private func brainContext(startReason: Int32) -> PlayContext? {
        guard let entry = engine.queue.current else { return nil }
        let song = entry.song
        return PlayContext.of(song: song, inLibrary: isInLibrary?(song.id) ?? true,
                              videoId: TrackCatalog.videoId(ofSongId: song.id), tag: entry.brain, startReason: startReason,
                              shuffle: engine.queue.isShuffled, repeatOne: engine.queue.repeatMode == .one,
                              route: currentRoute())
    }

    /// A track Autoplay brought from outside the library, not saved since.
    private func isOutsideLibrary(_ song: Song?) -> Bool {
        guard let song else { return false }
        // Right after a restart the brain's files are not read yet: the restored queue entry still says that the
        // engine picked it.
        let current = engine.queue.current
        let isPick = current?.song.id == song.id && (current?.isEngineOwned ?? false)
        return AutoplayPolicy.isOutsideLibrary(inLibrary: isInLibrary?(song.id) ?? true,
                                               knownEngineTrack: isEngineTrack?(song.id) ?? false,
                                               entryIsEnginePick: isPick,
                                               hasYouTubeId: TrackCatalog.videoId(ofSongId: song.id) != nil)
    }

    /// The audio route as the event log stores it. Read from the audio session at most twice a minute.
    private func currentRoute() -> Int32 {
        // Not while a saved queue is restored at launch: the audio session is asked when something plays.
        if isRestoringQueue { return routeCode }
        let now = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        if routeReadAtMs != 0, now - routeReadAtMs < 30_000 { return routeCode }
        routeReadAtMs = now
        routeCode = Self.routeCode(of: AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType)
        return routeCode
    }

    nonisolated static func routeCode(of port: AVAudioSession.Port?) -> Int32 {
        guard let port else { return PixlLibrary.Route.unknown }
        switch port {
        case .builtInSpeaker, .builtInReceiver: return PixlLibrary.Route.speaker
        case .headphones, .lineOut, .usbAudio, .HDMI: return PixlLibrary.Route.wired
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return PixlLibrary.Route.bluetooth
        case .carAudio: return PixlLibrary.Route.car
        case .airPlay: return PixlLibrary.Route.cast
        default: return PixlLibrary.Route.unknown
        }
    }

    private func engagementRecorded() {
        onEngagementRecorded?()
    }

    // MARK: Settings

    /// Applies the settings now and again whenever an observed one changes.
    private func observeSettings() {
        withObservationTracking {
            applySettings()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSettings() }
        }
    }

    private func applySettings() {
        let playback = settings.playback
        engine.crossfadeEnabled = playback.isCrossfadeEnabled
        engine.globalTransition = Self.globalTransition(json: playback.globalTransitionSettingsJSON,
                                                        crossfadeDurationMs: playback.crossfadeDurationMs)
        engine.replayGainEnabled = playback.replayGainEnabled
        engine.replayGainUseAlbumGain = playback.replayGainUseAlbumGain
        session.resumeOnHeadsetReconnect = playback.resumeOnHeadsetReconnect
        // Stage 14: Magic Instrumentalize (Experimental), the tap's mid/side vocal reducer.
        engine.setVocalAttenuation(Float(settings.experimental.vocalAttenuation))
        // Stage 7d's mapping: observed preferences, saved custom presets and loudness included.
        engine.applyEqualizer(settings.equalizer.engineSettings)
    }

    /// Android `globalTransitionSettingsFlow`: the stored JSON (or defaults) with `crossfade_duration` (1–12 s).
    nonisolated static func globalTransition(json: String?, crossfadeDurationMs: Int) -> TransitionSettings {
        var settings = TransitionSettings()
        if let json, let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(TransitionSettings.self, from: data) {
            settings = decoded
        }
        settings.durationMs = min(max(crossfadeDurationMs, 1000), 12_000)
        return settings
    }

    // MARK: Lifecycle

    private func observeLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                     object: nil, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                // Encoded off the main actor; a background task keeps the app running until it is written.
                let application = UIApplication.shared
                let taskId = application.beginBackgroundTask(withName: "QueueSnapshot", expirationHandler: nil).rawValue
                self?.snapshots.saveInBackground {
                    let identifier = UIBackgroundTaskIdentifier(rawValue: taskId)
                    if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
                }
            }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                     object: nil, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.sleepTimer.checkClock() }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willTerminateNotification,
                                                     object: nil, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                self?.stats.finalizeCurrentSession(endReason: EndReason.stopped)
                self?.snapshots.saveNow()
            }
        })
    }
}
