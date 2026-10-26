import Foundation
import Observation
import PixlLibrary
import PixlModel
import PixlNet
import UIKit

/// Settings › Sing › "Prepare songs ahead in the cloud" (off until the person turns it on, and the one way a song goes to
/// the cloud without a tap on it): while PixlAudio is open on Wi-Fi it picks the songs you are most likely to sing next
/// (`SingPrepareRanker`: favourites, what you play and finish, the songs after the ones you just played in a playlist,
/// new additions, the rest of an album you like) and has Cloud Studio get their instrumentals ready, so the Sing tap finds
/// them already there. Cloud Studio sends them as auto jobs (`CloudStudio.startAuto`): no notification, never mobile data,
/// inside their own monthly budget (default $1) and a daily count (default 12), after anything the person asked for.
///
/// It looks at the day only when something changed — the app became active (after a settle of 20 s), a song finished
/// playing, the phone reached Wi-Fi, one of its songs finished — and never twice within 5 minutes; no timer ticks while
/// it has nothing to do. It reacts to the three settings on its own (`CloudSettings.autoPrepare*`): switching it off
/// cancels the auto jobs still waiting, and a change the person makes (the switch, a new budget or daily cap) is looked
/// at again within seconds. Playback does not stop it: the phone-side work is a paced decode and an upload, and it steps
/// back for a hot phone, Low Power Mode, a low battery, the heavy lane being busy, safe mode (`CloudAutoConditions`).
@MainActor
@Observable
final class SingPrepareRunner {
    /// What the app knows about the library and the listening, read when the runner looks (nothing is kept).
    struct Sources {
        var songs: () -> [Song]
        var playlists: () -> [Playlist]
        var events: () -> [PlaybackEvent]
        /// Learned feedback per song; empty while "Learn from listening" is off.
        var signals: () -> [String: MusicRecommendationEngine.Signal]
        var blocked: () -> BlockedArtistMatcher
        var isAppActive: () -> Bool
        /// Imported Spotify / YouTube Music listening (plays and signals join the app's own).
        var imported: () -> ImportedHistoryAggregate
        /// Ask Taizo's taste changes: mutes and blocks leave songs out, boosts and reductions move the ranking.
        var adjustments: () -> TasteAdjustmentSet

        init(songs: @escaping () -> [Song], playlists: @escaping () -> [Playlist],
             events: @escaping () -> [PlaybackEvent],
             signals: @escaping () -> [String: MusicRecommendationEngine.Signal],
             blocked: @escaping () -> BlockedArtistMatcher, isAppActive: @escaping () -> Bool,
             imported: @escaping () -> ImportedHistoryAggregate = { .empty },
             adjustments: @escaping () -> TasteAdjustmentSet = { .empty }) {
            self.songs = songs
            self.playlists = playlists
            self.events = events
            self.signals = signals
            self.blocked = blocked
            self.isAppActive = isAppActive
            self.imported = imported
            self.adjustments = adjustments
        }
    }

    // MARK: What Settings shows

    /// The line under the budget: "3 songs today · $0.12 of $1.00 this month", or what it is waiting for ("Waiting for
    /// Wi-Fi"). Empty while the feature is off.
    private(set) var statusLine = ""
    /// Developer mode, "Why these songs": the songs it would prepare next and what lifted each, one line per song.
    private(set) var whyLines: [String] = []
    /// Songs sent today.
    private(set) var todayCount = 0
    /// What the songs sent this month are estimated or recorded to have cost (µ$).
    private(set) var monthSpentMicroUSD: Int64 = 0

    // MARK: Plumbing

    @ObservationIgnored private let cloud: CloudStudio
    @ObservationIgnored private let sources: Sources
    /// What it is waiting for right now (shown instead of the numbers), or nil.
    @ObservationIgnored private var waitingFor: String?
    @ObservationIgnored private var lastEvaluationMs: Int64 = 0
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDueMs: Int64?
    @ObservationIgnored private var isEvaluating = false
    @ObservationIgnored private var wasEnabled = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// The songs of the latest pick (the ones the cloud is about to prepare), and whether the cloud could be used then:
    /// the phone's own automatic studio leaves their instrumentals to the cloud (`owns(songId:)`).
    @ObservationIgnored private var pickedSongIds: Set<String> = []
    @ObservationIgnored private var cloudIsUsable = false

    /// Two looks are at least this far apart.
    static let minGapMs: Int64 = 5 * 60_000
    /// The app opened: wait for it to settle before looking.
    static let settleMs: Int64 = 20_000
    /// How many of the best songs are offered to the cloud (and listed in the developer's "Why these songs").
    static let candidateLimit = 12
    /// A song whose auto job failed rests this long before it is picked again (Android rests 12 h too).
    static let failureCooldownMs: Int64 = 12 * 3_600_000

    init(cloud: CloudStudio, sources: Sources) {
        self.cloud = cloud
        self.sources = sources
    }

    // MARK: Lifecycle

    /// Follows the settings, the app's foreground state and the network. Nothing is read or sent while the switch is off.
    func start() {
        guard !started else { return }
        started = true
        wasEnabled = cloud.settings.autoPrepareEnabled
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        })
        cloud.deviceConditions?.onNetworkChange = { [weak self] in self?.networkChanged() }
        observeSettings()
        refreshStatus()
        if wasEnabled {
            activate()
            if sources.isAppActive() { schedule(afterMs: Self.settleMs) }
        }
    }

    /// A song finished playing (the listening history has a new entry): the picks may have changed.
    func engagementRecorded() {
        guard cloud.settings.autoPrepareEnabled else { return }
        schedule(afterMs: 5_000)
    }

    /// One of its songs reached the end (imported, failed, cancelled): room for the next batch.
    func autoJobFinished() {
        guard cloud.settings.autoPrepareEnabled else { return }
        refreshStatus()
        schedule(afterMs: 5_000)
    }

    /// Whether the phone's own automatic studio should leave this song's instrumental to the cloud: it is on, the cloud is
    /// usable, and the song is one of the latest picks or has an auto job on its way.
    func owns(songId: String) -> Bool {
        guard cloud.settings.autoPrepareEnabled, cloudIsUsable else { return false }
        return pickedSongIds.contains(songId) || cloud.outstandingAutoJobs.contains { $0.songId == songId }
    }

    // MARK: Triggers

    private func appBecameActive() {
        guard cloud.settings.autoPrepareEnabled else { return }
        cloud.deviceConditions?.start()
        schedule(afterMs: Self.settleMs)
    }

    private func networkChanged() {
        guard cloud.settings.autoPrepareEnabled else { return }
        // Wi-Fi is back (or something else changed): songs that waited for it carry on, and the picks are looked at.
        if cloud.autoConditions()?.isUnmetered != false { cloud.wakeAutoJobs() }
        refreshStatus()
        schedule(afterMs: 3_000)
    }

    /// The switch, the budget, the daily cap or the cloud's own consent changed. Re-armed after every change.
    private func observeSettings() {
        let settings = cloud.settings
        _ = withObservationTracking {
            (settings.autoPrepareEnabled, settings.autoPrepareBudgetMicroUSD, settings.autoPrepareDailyCap, settings.isEnabled)
        } onChange: { [weak self] in
            Task { @MainActor in self?.settingsChanged() }
        }
    }

    private func settingsChanged() {
        observeSettings()
        let enabled = cloud.settings.autoPrepareEnabled
        if enabled != wasEnabled {
            wasEnabled = enabled
            if enabled {
                activate()
                refreshStatus()
                schedule(afterMs: 1_000, force: true)
            } else {
                deactivate()
            }
            return
        }
        guard enabled else { return }
        // A new budget or daily cap: the numbers change now, and what fits is looked at again within seconds.
        refreshStatus()
        schedule(afterMs: 2_000, force: true)
    }

    private func activate() {
        cloud.deviceConditions?.start()
    }

    /// Switched off: nothing more is picked, and the auto jobs the worker doesn't have yet stop.
    private func deactivate() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingDueMs = nil
        clearStatus()
        Task { await cloud.cancelAutoJobs() }
    }

    // MARK: Scheduling

    /// A look in `delayMs`, but not within `minGapMs` of the last one (`force`: for a change the person just made). A
    /// look already waiting that is due earlier stands.
    private func schedule(afterMs delayMs: Int64, force: Bool = false) {
        guard cloud.settings.autoPrepareEnabled else { return }
        let now = cloud.nowMs
        let earliestAllowed = force ? now : lastEvaluationMs + Self.minGapMs
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

    // MARK: One look

    /// If the phone and the budget allow, picks the best songs and sends them as one batch of auto jobs. Everything that
    /// holds it back says so in the status line.
    func evaluate() async {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        lastEvaluationMs = cloud.nowMs
        let settings = cloud.settings
        guard settings.autoPrepareEnabled else {
            clearStatus()
            return
        }
        // Songs already sent carry on by themselves; new ones start only while PixlAudio is open.
        guard sources.isAppActive() else { return }
        let readiness = await cloud.cloudReadiness()
        cloudIsUsable = readiness == .usable
        guard readiness == .usable else {
            setWaiting(Self.notReadyLine(readiness))
            return
        }
        // Switched off while the keys were being read.
        guard settings.autoPrepareEnabled else {
            clearStatus()
            return
        }
        if let reason = cloud.autoBlockedReason {
            setWaiting(reason)
            return
        }
        // The phone is ready: songs that were waiting for it carry on.
        cloud.wakeAutoJobs()
        // Songs the person asked for come first: nothing is picked while one is on its way.
        if cloud.jobs.contains(where: { $0.state.isPending && $0.effectiveOrigin != .auto }) {
            setWaiting("Getting your songs ready first")
            return
        }
        let ledger = cloud.projectedAutoLedger()
        let room = min(CloudAutoBudget.maxBatchSongs, CloudAutoBudget.maxOutstanding - cloud.outstandingAutoJobs.count,
                       settings.autoPrepareDailyCap - ledger.dayCount)
        // Enough on their way, today's count reached, or the month's budget used: the numbers say so.
        guard room > 0, settings.effectiveAutoBudgetMicroUSD > ledger.spentMicroUSD else {
            setWaiting(nil)
            return
        }

        let now = cloud.nowMs
        let songs = sources.songs(), playlists = sources.playlists(), events = sources.events()
        let signals = sources.signals(), blocked = sources.blocked(), imported = sources.imported()
        let adjustments = sources.adjustments()
        // Not candidates: songs that already have an instrumental (one look at the folder), songs with a job on their way,
        // and songs whose last auto job failed lately. They still count for the ranking's album and playlist terms.
        let haveInstrumental = await cloud.songIdsWithInstrumental(among: songs)
        let excluded = cloud.pendingSongIds.union(haveInstrumental)
            .union(cloud.recentAutoFailureSongIds(sinceMs: now - Self.failureCooldownMs))
        let limit = Self.candidateLimit
        let ranked = await Task.detached(priority: .utility) { () -> [SingPrepareRanker.Candidate] in
            let merged = HomeStore.recommendationInputs(songs: songs, events: events, signals: signals, imported: imported)
            let inputs = SingPrepareInputs(songs: songs, engagements: merged.engagements, signals: merged.signals,
                                           recentEvents: events, playlists: playlists, excluded: excluded,
                                           blocked: blocked, adjustments: adjustments, nowMs: now)
            return SingPrepareRanker.rank(inputs, limit: limit)
        }.value
        guard settings.autoPrepareEnabled else {
            clearStatus()
            return
        }
        // The best few, best first: what the cloud is offered, and what the developer's list shows.
        let top = Array(ranked.prefix(Self.candidateLimit))
        let picks = top.map(\.song)
        pickedSongIds = Set(picks.map(\.id))
        whyLines = top.map(Self.whyLine)
        guard !picks.isEmpty else {
            setWaiting(nil)
            return
        }
        _ = await cloud.startAuto(songs: picks, limit: room)
        // Switched off while the songs were being sent: the ones just sent stop too (the switch's own cancel ran before
        // they existed).
        guard settings.autoPrepareEnabled else {
            await cloud.cancelAutoJobs()
            clearStatus()
            return
        }
        setWaiting(nil)
    }

    // MARK: Status

    /// The numbers and the waiting line, from the ledger as it stands.
    func refreshStatus() {
        let settings = cloud.settings
        guard settings.autoPrepareEnabled else {
            statusLine = ""
            return
        }
        // Songs chosen but not yet taken by RunPod count at their estimate: the line follows the pick at once.
        let ledger = cloud.projectedAutoLedger()
        todayCount = ledger.dayCount
        monthSpentMicroUSD = ledger.spentMicroUSD
        statusLine = Self.statusText(todayCount: ledger.dayCount, monthSpentMicroUSD: ledger.spentMicroUSD,
                                     budgetMicroUSD: settings.effectiveAutoBudgetMicroUSD, waitingFor: waitingFor)
    }

    private func setWaiting(_ text: String?) {
        waitingFor = text
        refreshStatus()
    }

    private func clearStatus() {
        waitingFor = nil
        statusLine = ""
        whyLines = []
        pickedSongIds = []
    }

    /// "3 songs today · $0.12 of $1.00 this month", or what it is waiting for in its place. (The Android app says the same.)
    nonisolated static func statusText(todayCount: Int, monthSpentMicroUSD: Int64, budgetMicroUSD: Int64,
                                       waitingFor: String?) -> String {
        if let waitingFor, !waitingFor.isEmpty { return waitingFor }
        let songs: String
        switch todayCount {
        case ..<1: songs = "No songs yet today"
        case 1: songs = "1 song today"
        default: songs = "\(todayCount) songs today"
        }
        return "\(songs) · \(CloudCost.format(microUSD: monthSpentMicroUSD)) of \(CloudCost.format(microUSD: budgetMicroUSD)) this month"
    }

    /// Why it can't start when the cloud itself isn't ready, in plain words.
    nonisolated static func notReadyLine(_ readiness: SingCloudAvailability) -> String {
        switch readiness {
        case .off: "Turn on Cloud processing to prepare songs ahead"
        case .notConfigured, .keysMissing: "Finish setting up Cloud processing first"
        default: "Waiting for Cloud processing"
        }
    }

    /// One line of the developer's "Why these songs": the song, then what lifted it.
    nonisolated static func whyLine(_ candidate: SingPrepareRanker.Candidate) -> String {
        let reasons = candidate.reasons.map(reasonText)
        let why = reasons.isEmpty ? "ranked by your listening" : reasons.joined(separator: ", ")
        return "\(candidate.song.title) · \(candidate.song.displayArtist) — \(why) (\(String(format: "%.1f", candidate.score)))"
    }

    nonisolated static func reasonText(_ reason: SingPrepareRanker.Reason) -> String {
        switch reason {
        case .favorite: "a favorite"
        case .playedOften: "played often"
        case .playedRecently: "played lately"
        case .addedRecently: "added lately"
        case .nextInPlaylist: "follows a song you played in a playlist"
        case .sameAlbum: "on an album you play"
        }
    }
}
