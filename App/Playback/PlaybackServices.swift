import Foundation
import Observation
import PixlAudioCore
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
    /// The current item or the queue changed (stage 11's prefetcher resolves the next streamed song).
    var onUpcomingChanged: (() -> Void)?

    private let settings: SettingsStore
    private let defaults: UserDefaults
    private let persistence: PersistenceActor?
    private var lifecycleObservers: [any NSObjectProtocol] = []
    private var started = false

    init(settings: SettingsStore, persistence: PersistenceActor?, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        self.persistence = persistence
        session = AudioSessionController()
        engine = DualDeckEngine(session: session)
        nowPlaying = NowPlayingController(engine: engine)
        sleepTimer = SleepTimerController(engine: engine)
        snapshots = QueueSnapshotStore(defaults: defaults)
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
        Task { await reloadTransitionRules() }
    }

    /// Restores the saved queue (paused) once the library is loaded. The JSON is decoded off the main actor.
    func restoreQueue(lookup: (String) -> Song?) async {
        guard let snapshot = await snapshots.loadInBackground(), !snapshot.items.isEmpty else { return }
        let songs = QueueSnapshotStore.songs(for: snapshot, lookup: lookup)
        engine.restore(snapshot, songs: songs)
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
            self.stats.onTrackChanged(songId: new?.id, positionMs: 0, durationMs: new?.duration ?? 0,
                                      isPlaying: self.engine.playWhenReady)
            self.nowPlaying.update()
            self.snapshots.scheduleSave()
            self.onUpcomingChanged?()
        }
        engine.onRepeatLoop = { [weak self] in
            guard let self else { return }
            self.sleepTimer.repeatLoop()
            let song = self.engine.queue.current?.song
            self.stats.onTrackChanged(songId: song?.id, positionMs: 0, durationMs: song?.duration ?? 0,
                                      isPlaying: self.engine.playWhenReady)
            self.nowPlaying.update()
        }
        engine.onQueueEnded = { [weak self] in
            guard let self else { return }
            self.sleepTimer.queueEnded()
            self.stats.finalizeCurrentSession()
            self.nowPlaying.update()
        }
        engine.onPlayingChanged = { [weak self] playing in
            guard let self else { return }
            self.stats.onPlayStateChanged(isPlaying: playing, positionMs: self.engine.currentPositionMs())
            self.nowPlaying.update()
            // Coalesced and encoded off the main actor (the pause position is the same a second later).
            if !playing { self.snapshots.scheduleSave() }
        }
        engine.onQueueChanged = { [weak self] in
            self?.nowPlaying.update()
            self?.snapshots.scheduleSave()
            self?.onUpcomingChanged?()
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
            self.recordHistory?(record.songId, record.listenedMs, record.timestamp)
            let persistence = self.persistence
            Task.detached(priority: .utility) {
                await history?.recordPlayback(songId: record.songId, durationMs: record.listenedMs,
                                              timestamp: record.timestamp)
                try? await persistence?.recordEngagement(songId: record.songId, durationMs: record.listenedMs,
                                                         timestamp: record.timestamp)
            }
        }
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
                self?.stats.finalizeCurrentSession()
                self?.snapshots.saveNow()
            }
        })
    }
}
