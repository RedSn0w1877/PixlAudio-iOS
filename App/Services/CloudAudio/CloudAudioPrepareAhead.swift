import Foundation
import PixlLibrary
import PixlModel
import PixlNet
import UIKit

/// Spatial audio's background queue (cloud audio spec 6.4, "prepare ahead"): the songs you are most likely to play next
/// get the selected profile's cloud render before you play them. The ranking is Sing's prepare-ahead ranking
/// (`SingPrepareRanker`: favourites, play count, recency, skip rate, the songs after the ones you just played in a
/// playlist, the rest of an album you like), for the selected profile only.
///
/// For each picked song the library job looks in the shared library first (a hit is only downloaded, which is cheap and
/// not counted), and only then renders, within `cloudAudio.dailyAhead` songs a day and the month's cap for library
/// jobs (`CloudStudio`'s library job does both checks). Wi-Fi only, never in Low Data Mode or Low Power Mode, never on
/// a low battery (`CloudAutoConditions`). A song whose audio is not on the phone is fetched into the stream cache for it
/// (Wi-Fi only). Silent: no notification; the Active jobs row is all that shows.
///
/// Like Sing's runner, it looks only when something changed (the app became active, after a settle of 20 s; the
/// network; a setting; one of its songs finished), never twice within 5 minutes, and starts new work only while
/// PixlAudio is open. Jobs already sent carry on in the background as every Cloud Studio job does (Cloud Studio's own
/// background task identifiers, no new ones).
@MainActor
final class CloudAudioPrepareAhead {
    /// What the app knows about the library and the listening, read when the queue looks (nothing is kept).
    struct Sources {
        var songs: () -> [Song]
        var playlists: () -> [Playlist]
        var events: () -> [PlaybackEvent]
        var signals: () -> [String: MusicRecommendationEngine.Signal]
        var blocked: () -> BlockedArtistMatcher
        var isAppActive: () -> Bool
        var imported: () -> ImportedHistoryAggregate
        var adjustments: () -> TasteAdjustmentSet
    }

    /// The app opened: wait for it to settle before looking.
    static let settleMs: Int64 = 20_000
    /// A song whose library job failed rests this long before it is picked again (Sing's runner rests 12 h too).
    static let failureCooldownMs: Int64 = 12 * 3_600_000

    private let cloud: CloudStudio
    private weak var library: SpatialCloudLibrary?
    private let sources: Sources
    private var settings: CloudAudioSettings
    private var lastEvaluationMs: Int64 = 0
    private var pendingTask: Task<Void, Never>?
    private var pendingDueMs: Int64?
    private var isEvaluating = false
    private var started = false
    private var observers: [any NSObjectProtocol] = []
    private var lastOutstanding = 0

    init(cloud: CloudStudio, library: SpatialCloudLibrary, settings: CloudAudioSettings, sources: Sources) {
        self.cloud = cloud
        self.library = library
        self.settings = settings
        self.sources = sources
    }

    /// Follows the app's foreground state. Nothing is read or sent while the queue is off.
    func start() {
        guard !started else { return }
        started = true
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        })
        if isOn, sources.isAppActive() { schedule(afterMs: Self.settleMs) }
    }

    /// The settings changed (the library passes every change on).
    func apply(_ settings: CloudAudioSettings, old: CloudAudioSettings) {
        self.settings = settings
        guard isOn else {
            cancelPending()
            return
        }
        let wasOn = old.prepareAhead && old.profile.isOn && old.cloud
        if !wasOn || settings.profile != old.profile || settings.dailyAhead != old.dailyAhead
            || settings.monthlyCapUSD != old.monthlyCapUSD {
            schedule(afterMs: 2_000, force: true)
        }
    }

    func networkChanged() {
        guard isOn else { return }
        schedule(afterMs: 3_000)
    }

    /// One of its songs finished (stored, failed, cancelled): room for the next one.
    func libraryJobsChanged() {
        let outstanding = cloud.outstandingLibraryJobs(ahead: true).count
        defer { lastOutstanding = outstanding }
        guard isOn, outstanding < lastOutstanding else { return }
        schedule(afterMs: 5_000)
    }

    private func appBecameActive() {
        guard isOn else { return }
        schedule(afterMs: Self.settleMs)
    }

    /// The queue works for the selected profile, with "Prepare ahead" on and both cloud switches on.
    private var isOn: Bool {
        settings.prepareAhead && settings.profile.isOn && settings.cloud && cloud.settings.isEnabled
    }

    // MARK: Scheduling

    /// A look in `delayMs`, but not within `CloudLibraryAhead.minGapMs` of the last one (`force`: a change the person
    /// just made). A look already waiting that is due earlier stands.
    private func schedule(afterMs delayMs: Int64, force: Bool = false) {
        let now = cloud.nowMs
        let earliestAllowed = force ? now : lastEvaluationMs + CloudLibraryAhead.minGapMs
        let due = max(now + delayMs, earliestAllowed)
        if let pendingDueMs, pendingDueMs <= due { return }
        pendingTask?.cancel()
        pendingDueMs = due
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(max(due - now, 0)))
            guard !Task.isCancelled, let self else { return }
            self.pendingDueMs = nil
            self.pendingTask = nil
            await self.evaluate()
        }
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingDueMs = nil
    }

    // MARK: One look

    /// When the phone, the day's count and the month's cap allow, picks the best songs that have no render of the
    /// selected profile yet and hands them to Cloud Studio as one batch of library jobs.
    func evaluate() async {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        lastEvaluationMs = cloud.nowMs
        guard isOn, let profile = settings.profile.profile, let library, sources.isAppActive() else { return }
        guard await cloud.cloudReadiness() == .usable, isOn else { return }
        // Wi-Fi that is not metered and not in Low Data Mode, no Low Power Mode, a battery that is not low… (spec 6.4).
        guard cloud.libraryMayUseNetwork(ahead: true) else { return }
        let estimate = CloudLibraryBudget.estimateMicroUSD(durationMs: CloudCost.referenceSongMs, profiles: 1,
                                                           pricePerSecondMicroUSD: cloud.settings.effectivePricePerSecondMicroUSD)
        let room = CloudLibraryAhead.room(outstanding: cloud.outstandingLibraryJobs(ahead: true).count,
                                          ledger: cloud.libraryLedgerNow, dailyAhead: settings.dailyAhead,
                                          capMicroUSD: settings.monthlyCapMicroUSD, estimateMicroUSD: estimate)
        guard room > 0 else { return }

        let now = cloud.nowMs
        // Not candidates: songs with a library job on its way, and songs whose library job failed lately. A song whose
        // render is already on the phone is skipped below, by its video.
        let excluded = Set(cloud.jobs.filter { record in
            guard record.isLibraryJob else { return false }
            if record.state.isPending { return true }
            let failed = record.state == .failed || record.state == .expired
            return failed && now - (record.updatedAtMs ?? record.createdAtMs) < Self.failureCooldownMs
        }.map(\.songId))
        let songs = sources.songs(), playlists = sources.playlists(), events = sources.events()
        let signals = sources.signals(), blocked = sources.blocked(), imported = sources.imported()
        let adjustments = sources.adjustments()
        let limit = CloudLibraryAhead.candidateLimit
        let ranked = await Task.detached(priority: .utility) { () -> [SingPrepareRanker.Candidate] in
            let merged = HomeStore.recommendationInputs(songs: songs, events: events, signals: signals, imported: imported)
            let inputs = SingPrepareInputs(songs: songs, engagements: merged.engagements, signals: merged.signals,
                                           recentEvents: events, playlists: playlists, excluded: excluded,
                                           blocked: blocked, adjustments: adjustments, nowMs: now)
            return SingPrepareRanker.rank(inputs, limit: limit)
        }.value
        let batchId = "spatial-ahead-\(UUID().uuidString.lowercased())"
        var sent = 0
        for candidate in ranked where sent < room {
            // Switched off, or another profile picked, while it looked.
            guard isOn, settings.profile.profile == profile else { return }
            // Turned off for this song (`spatial.songsOff`, Hoa, 2026-11-11): it plays its original, so nothing is
            // prepared (or paid for) for it. Android's `SpatialAhead` skips it the same way.
            if settings.isOffFor(candidate.song.spotifyId) { continue }
            // A Spotify song is rendered from its matched video; one that was never matched waits until it plays.
            guard let videoId = await cloud.streamIdentity(for: candidate.song), CloudLibrary.isValidVideoId(videoId) else {
                continue
            }
            let key = RenditionKey(videoId: videoId, profile: profile)
            guard await library.wantsAhead(key) else { continue }
            if await cloud.enqueueLibraryRender(song: candidate.song, videoId: videoId, profile: profile, ahead: true,
                                                batchId: batchId) != nil {
                sent += 1
            }
        }
        lastOutstanding = cloud.outstandingLibraryJobs(ahead: true).count
    }
}
