import Foundation
import Observation
import PixlAudioCore
import PixlLibrary
import PixlModel
import UIKit

/// Settings › AI › "Ready when you play" (Android `AutomaticStudioManager`): while "Automatic lyric sync" or
/// "Automatic instrumentals" is on, PixlAudio prepares word-synced lyrics and instrumentals for the songs you play
/// most — one song at a time, through the same TAIS Studio lane as the manual buttons.
///
/// iOS gives an app no background processing time it could rely on (and a free Apple ID has no extensions), so this
/// runs while PixlAudio is open, with Android's limits (`AutomaticStudioPolicy`): never during playback (a job is
/// cancelled the moment playback starts), 15 s after the app opens or the song changes, at most 8 jobs per 6 hours,
/// only on charge or at 40 % battery and up, never while the phone is hot or short of storage, songs up to 6 minutes,
/// and a persistent per-song retry ledger. Unlike a manual job it never downloads a model: automatic work starts once
/// the model is on the phone (the first manual sync or instrumental downloads it).
///
/// Its jobs are `unattended`: they never start the system's continued-processing task (that UI is for work the person
/// started, and the card promises no automatic notifications), and the job is cancelled — and retried a little later —
/// as soon as the app leaves the foreground, so it never runs behind the lock screen during playback.
@MainActor
@Observable
final class AutomaticStudioRunner {
    /// What the card shows under the switches.
    private(set) var status = "Waiting for songs to prepare"

    @ObservationIgnored private let studio: TaisStudio
    @ObservationIgnored private let models: ModelManager
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let playback: PlaybackStore
    @ObservationIgnored private let history: ListeningHistoryStore
    @ObservationIgnored private let lyricsService: LyricsService?
    @ObservationIgnored private let isEnabled: Bool
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var cooldowns: AutomaticStudioCooldowns
    /// Jobs this runner started that haven't been accounted for yet.
    @ObservationIgnored private var observed: [AutomaticStudioKind: String] = [:]
    @ObservationIgnored private var isAppActive = false
    @ObservationIgnored private var readyAfterMs: Int64 = 0
    @ObservationIgnored private var lastSongId: String?
    @ObservationIgnored private var nextKind: AutomaticStudioKind = .lyrics
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private static let ledgerKey = "automatic_studio_cooldowns_v1"
    private static let windowStartKey = "automatic_studio_window_start_ms"
    private static let windowCountKey = "automatic_studio_window_jobs"
    /// Android rechecks every 30 s while the process lives.
    private static let tick: Duration = .seconds(30)

    init(studio: TaisStudio, models: ModelManager, settings: SettingsStore, library: LibraryStore,
         playback: PlaybackStore, history: ListeningHistoryStore, lyricsService: LyricsService?, isEnabled: Bool) {
        self.studio = studio
        self.models = models
        self.settings = settings
        self.library = library
        self.playback = playback
        self.history = history
        self.lyricsService = lyricsService
        self.isEnabled = isEnabled
        let saved = UserDefaults.standard.dictionary(forKey: Self.ledgerKey) as? [String: Double] ?? [:]
        cooldowns = AutomaticStudioCooldowns(saved.mapValues { Int64($0) })
    }

    /// Launch: follow the app's foreground state; the loop only runs while a switch is on and the app is open.
    func start() {
        guard isEnabled, observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppActive(true) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAppActive(false) }
        })
        setAppActive(UIApplication.shared.applicationState == .active)
        observePlayback()
    }

    /// Playback comes first, at once rather than on the next 30 s check (Android: `onIsPlayingChanged` →
    /// `onSongChanged` → `scanNow`, whose scan cancels automatic work while playback is active).
    private func observePlayback() {
        let isPlaying = withObservationTracking {
            playback.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePlayback() }
        }
        if isPlaying, deferActiveJob() { status = "Waiting until playback is idle" }
    }

    /// A switch changed, or "Check queue now": re-evaluate at once (never bypasses the limits).
    func scanNow() {
        guard isEnabled else { return }
        cancelSwitchedOffJobs()
        updateLoop()
        Task { await scan() }
    }

    /// A switch turned off cancels that kind's automatic work (Android `cancelAllWorkByTag`).
    private func cancelSwitchedOffJobs() {
        let lyricsOn = settings.lyrics.automaticLyrics, stemsOn = settings.playback.automaticInstrumentals
        for (kind, songId) in observed where (kind == .lyrics ? !lyricsOn : !stemsOn) {
            let jobKind: TaisStudio.JobKind = kind == .lyrics ? .lyrics : .instrumental
            guard studio.state(jobKind, songId: songId)?.isActive == true,
                  studio.isUnattended(jobKind, songId: songId) else { continue }
            studio.cancel(jobKind, songId: songId)
            observed[kind] = nil
        }
    }

    private func setAppActive(_ active: Bool) {
        isAppActive = active
        if active {
            UIDevice.current.isBatteryMonitoringEnabled = true
            readyAfterMs = Self.nowMs() + AutomaticStudioPolicy.settleMs
        } else {
            // Unattended work stays in the foreground: the job stops now and is retried a little later.
            deferActiveJob()
        }
        updateLoop()
        Task { await scan() }
    }

    private var isSwitchedOn: Bool { settings.lyrics.automaticLyrics || settings.playback.automaticInstrumentals }

    /// Whether a switched-on kind could ever run now: its model is on the phone (automatic work never downloads).
    private var canEverRun: Bool {
        (settings.lyrics.automaticLyrics && isModelInstalled(for: .lyrics))
            || (settings.playback.automaticInstrumentals && isModelInstalled(for: .instrumental))
    }

    /// No timer while it has nothing to do: the loop lives only while the app is open, a switch is on and its model
    /// is installed (otherwise each activation, switch change or "Check queue now" scans once).
    private func updateLoop() {
        if isAppActive, isSwitchedOn, canEverRun {
            guard loop == nil else { return }
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.tick)
                    guard let self, !Task.isCancelled else { return }
                    await self.scan()
                }
            }
        } else {
            loop?.cancel()
            loop = nil
        }
    }

    // MARK: Scan (Android `scan`)

    private func scan() async {
        guard isEnabled, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let now = Self.nowMs()
        accountForFinishedJobs(now: now)
        let lyricsOn = settings.lyrics.automaticLyrics, stemsOn = settings.playback.automaticInstrumentals
        cancelSwitchedOffJobs()
        updateLoop()
        guard lyricsOn || stemsOn else {
            status = "Off"
            return
        }
        guard isAppActive else {
            status = "Prepares songs while PixlAudio is open"
            return
        }
        if let job = activeObservedJob() {
            if playback.isPlaying {
                // Playback comes first: the unattended job stops and is retried a little later.
                deferActiveJob()
                status = "Waiting until playback is idle"
            } else {
                let state = studio.state(job.kind == .lyrics ? .lyrics : .instrumental, songId: job.songId)
                status = state?.detail ?? "Preparing the next song quietly"
            }
            return
        }
        if studio.jobs.values.contains(where: \.isActive) {
            status = "Waiting for your manually started processing"
            return
        }
        if playback.isPlaying {
            status = "Waiting until playback is idle"
            return
        }
        if playback.currentSongId != lastSongId {
            lastSongId = playback.currentSongId
            readyAfterMs = now + AutomaticStudioPolicy.settleMs
        }
        if now < readyAfterMs {
            status = "Letting playback settle before automatic processing"
            return
        }
        var windowStart = Int64(defaults.double(forKey: Self.windowStartKey))
        var jobsInWindow = defaults.integer(forKey: Self.windowCountKey)
        if now - windowStart >= AutomaticStudioPolicy.backgroundWindowMs {
            windowStart = now
            jobsInWindow = 0
            defaults.set(Double(windowStart), forKey: Self.windowStartKey)
            defaults.set(0, forKey: Self.windowCountKey)
        }
        guard jobsInWindow < AutomaticStudioPolicy.maxJobsPerWindow else {
            status = "Automatic processing is paced to protect battery and playback"
            return
        }

        let conditions = Self.conditions(lyricsOn: lyricsOn, stemsOn: stemsOn)
        let kinds = [nextKind, nextKind == .lyrics ? AutomaticStudioKind.instrumental : .lyrics]
            .filter { ($0 == .lyrics && lyricsOn) || ($0 == .instrumental && stemsOn) }
        var reasons: [String] = []
        let allowed = kinds.filter { kind in
            if let reason = AutomaticStudioPolicy.blockedReason(conditions, kind) {
                reasons.append(reason)
                return false
            }
            if !isModelInstalled(for: kind) {
                reasons.append(kind == .lyrics
                    ? "Starts once the lyric sync model is on this iPhone (sync one song by hand)"
                    : "Starts once the instrumental model is on this iPhone (make one instrumental by hand)")
                return false
            }
            return true
        }
        guard !allowed.isEmpty else {
            status = reasons.first ?? "Waiting for suitable conditions"
            return
        }

        for song in candidates(now: now) where AutomaticStudioPolicy.canProcessDuration(song.duration) {
            let hasLocalAudio = Self.hasLocalAudio(song)
            for kind in allowed {
                let key = AutomaticStudioPolicy.ledgerKey(kind, songId: song.id)
                if cooldowns.until(key) > now { continue }
                if await isComplete(kind, song: song) {
                    record(key, now + AutomaticStudioPolicy.completedCooldownMs)
                    continue
                }
                guard AutomaticStudioPolicy.canSchedule(kind, hasLocalAudio: hasLocalAudio, alreadyComplete: false,
                                                        cooldownUntil: cooldowns.until(key), now: now) else { continue }
                // Conditions may have changed while lyrics were read.
                guard isAppActive, !playback.isPlaying, isSwitchedOn else { return }
                studio.start(kind == .lyrics ? .lyrics : .instrumental, song: song, forceResync: false,
                             unattended: true)
                observed[kind] = song.id
                defaults.set(jobsInWindow + 1, forKey: Self.windowCountKey)
                record(key, now + AutomaticStudioPolicy.scheduledCooldownMs) // no retry loop after a crash
                nextKind = kind == .lyrics ? .instrumental : .lyrics
                status = kind == .lyrics ? "Finding synced lyrics for \(song.title)"
                    : "Preparing an instrumental for \(song.title)"
                return
            }
        }
        status = "Up to date for your recent songs; instrumentals use audio already on this iPhone"
    }

    /// Android `recordCompletion`: a finished job sets when the song is looked at again.
    private func accountForFinishedJobs(now: Int64) {
        for (kind, songId) in observed {
            guard let state = studio.state(kind == .lyrics ? .lyrics : .instrumental, songId: songId),
                  !state.isActive else { continue }
            let delay: Int64
            switch state.phase {
            case .cancelled: delay = AutomaticStudioPolicy.deferredCooldownMs
            case .failed: delay = AutomaticStudioPolicy.failureCooldownMs
            case .succeeded(let updated):
                delay = kind == .lyrics && !updated ? AutomaticStudioPolicy.catalogCooldownMs
                    : AutomaticStudioPolicy.completedCooldownMs
            case .queued, .running: continue
            }
            record(AutomaticStudioPolicy.ledgerKey(kind, songId: songId), now + delay)
            observed[kind] = nil
        }
    }

    /// The running or queued job this runner started — unless the person has since asked for that song themselves
    /// (`TaisStudio.start` then makes it theirs, and it is no longer the runner's to cancel).
    private func activeObservedJob() -> (kind: AutomaticStudioKind, songId: String)? {
        for (kind, songId) in observed {
            let jobKind: TaisStudio.JobKind = kind == .lyrics ? .lyrics : .instrumental
            if studio.state(jobKind, songId: songId)?.isActive == true, studio.isUnattended(jobKind, songId: songId) {
                return (kind: kind, songId: songId)
            }
        }
        return nil
    }

    /// Stops the runner's active job and retries it after `deferredCooldownMs` (playback started, or the app left
    /// the foreground). Returns whether there was one.
    @discardableResult
    private func deferActiveJob() -> Bool {
        guard let job = activeObservedJob() else { return false }
        studio.cancel(job.kind == .lyrics ? .lyrics : .instrumental, songId: job.songId)
        record(AutomaticStudioPolicy.ledgerKey(job.kind, songId: job.songId),
               Self.nowMs() + AutomaticStudioPolicy.deferredCooldownMs)
        observed[job.kind] = nil
        return true
    }

    private func record(_ key: String, _ deadline: Int64) {
        cooldowns.record(key, deadline)
        defaults.set(cooldowns.snapshot().mapValues { Double($0) }, forKey: Self.ledgerKey)
    }

    // MARK: Inputs

    /// Android `candidates`: the current song, then by `AutomaticStudioPolicy.priority` (recent, played, liked).
    private func candidates(now: Int64) -> [Song] {
        let engagements = HomeStore.engagementStats(history.events)
        let current = playback.currentSongId
        return library.songs
            .map { song -> (Song, Int64) in
                let stats = engagements[song.id]
                return (song, AutomaticStudioPolicy.priority(songId: song.id, currentId: current,
                                                             favorite: song.isFavorite,
                                                             playCount: stats?.playCount ?? 0,
                                                             lastPlayedMs: stats?.lastPlayedTimestamp ?? 0, nowMs: now))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(40)
            .map { $0.0 }
    }

    private func isComplete(_ kind: AutomaticStudioKind, song: Song) async -> Bool {
        switch kind {
        case .instrumental:
            return InstrumentalFiles.bestAvailable(songId: song.id) != nil
        case .lyrics:
            guard let lyricsService else { return true }
            let preference = LyricsSourcePreference(rawValue: settings.lyrics.sourcePreference) ?? .embeddedFirst
            // A probe: it never fills the lyrics memory cache (which holds what the person opened).
            let loaded = await lyricsService.lyrics(for: song, preference: preference, allowOnline: false,
                                                    forceRefresh: false, remember: false)
            return TaisLyricsAlignment.alignmentState(for: loaded?.lyrics) == .wordSynced
        }
    }

    private func isModelInstalled(for kind: AutomaticStudioKind) -> Bool {
        if case .installed = models.state(kind == .lyrics ? .wav2vec2 : .mdxnet) { return true }
        return false
    }

    /// Audio already on the phone: a file, a music-library item or a finished download.
    private static func hasLocalAudio(_ song: Song) -> Bool {
        if let url = DefaultPlayableURLResolver.url(for: song), url.isFileURL || url.scheme == "ipod-library" {
            return true
        }
        if let videoId = YouTubeSongIdentity.videoId(for: song), DownloadFiles.existingFile(videoId: videoId) != nil {
            return true
        }
        return false
    }

    /// Android `AutomaticStudioEnvironment.blockedReason`'s inputs, from UIKit and the file system.
    private static func conditions(lyricsOn: Bool, stemsOn: Bool) -> AutomaticStudioPolicy.Conditions {
        let device = UIDevice.current
        let level = device.batteryLevel
        let charging = device.batteryState == .charging || device.batteryState == .full
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? nil
        return AutomaticStudioPolicy.Conditions(
            appVisible: true, lyricsEnabled: lyricsOn, instrumentalsEnabled: stemsOn,
            batteryPercent: level < 0 ? -1 : Int((level * 100).rounded()), charging: charging,
            thermalStatus: ProcessInfo.processInfo.thermalState.rawValue,
            freeBytes: free ?? AutomaticStudioPolicy.minFreeBytes)
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
