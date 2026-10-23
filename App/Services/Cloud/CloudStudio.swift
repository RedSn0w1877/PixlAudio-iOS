import Foundation
import Observation
import PixlModel
import PixlNet

/// Where a batch comes from (the queue's Add rows, shown in developer mode).
nonisolated enum CloudBatchKind: String, Sendable, CaseIterable {
    case current
    case missingLyrics
    case missingInstrumental

    var title: String {
        switch self {
        case .current: "Current song"
        case .missingLyrics: "Songs without word-timed lyrics"
        case .missingInstrumental: "Songs without an instrumental"
        }
    }
}

/// One batch the person is about to send (`CloudStudio.startNow` checks it first, design §7.3): what goes, what is
/// skipped and why, and the estimate against the month's cap.
nonisolated struct CloudBatchPreview: Identifiable, Equatable, Sendable {
    nonisolated struct Skip: Equatable, Sendable, Identifiable {
        let reason: CloudSkipReason
        let count: Int
        var id: String { reason.rawValue }
    }

    /// The batch id the records get.
    let id: String
    let songs: [Song]
    let plans: [CloudSongPlan]
    let skipped: [Skip]
    let estimate: CloudBatchEstimate
    let replaceUserSynced: Bool
    /// Where the songs came from ("Current song", "Songs without an instrumental", a playlist's name).
    let title: String
    /// Who is sending them: a tap on "Process in cloud", a tap on Sing, or songs prepared ahead.
    let origin: CloudJobOrigin

    var isEmpty: Bool { plans.isEmpty }
}

/// What starting a batch straight away did (`CloudStudio.startNow`); the callers show `message(useCellular:)` as a toast.
nonisolated enum CloudStartOutcome: Equatable, Sendable {
    /// This many songs are queued.
    case started(Int)
    /// The consent switch is off, so nothing was sent.
    case off
    /// Nothing to send, in words ("Nothing to process — Already has an instrumental and word-timed lyrics").
    case nothingToDo(String)
    /// The batch would go over this month's cloud budget.
    case overCap

    var didStart: Bool {
        if case .started = self { return true }
        return false
    }

    /// Uploads wait for Wi-Fi unless cellular data is allowed, so a start says when it will go.
    func message(useCellular: Bool) -> String {
        switch self {
        case .started(let count):
            let text = count == 1 ? "Processing 1 song in the cloud" : "Processing \(count) songs in the cloud"
            return useCellular ? text : text + " — it uploads when you're on Wi-Fi."
        case .off: return CloudStudio.Notice.off.message
        case .nothingToDo(let reason): return reason
        case .overCap: return CloudStudio.Notice.capReached.message
        }
    }
}

/// Whether a Sing tap can use the cloud for a song right now (`CloudStudio.singAvailability(for:)`).
typealias SingCloudAvailability = CloudStudio.SingCloudAvailability

/// Cloud Studio's orchestrator (design §1, §7): the per-song jobs from "Process in cloud" to the imported instrumental
/// and word-timed lyrics. It only sequences I/O; every rule (states, retries, caps, gates, checks) is PixlNet's
/// (`CloudQueuePolicy`, `CloudJobBuilder`), and every side effect goes through `Dependencies`, so AppTests drive it
/// with fakes.
///
/// - Nothing is sent while the consent switch is off, and the cloud is never used as a fallback: a song goes up
///   because the person tapped "Process in cloud" or Sing, or turned on "Prepare songs ahead in the cloud" in Settings ›
///   Sing — the one opt-in exception, whose jobs (origin `auto`) never use mobile data, post no notification, don't lift
///   safe mode and stay inside their own monthly budget.
/// - A priority job (Sing, or one song sent by hand) goes to the GPU first: the jobs RunPod has not started step aside
///   and follow it (`CloudPriorityLane`).
/// - Foreground: uploads start at once; `/run` goes out when the batch's uploads are done (or 2 minutes after the
///   first); `/status` is asked at most every 15 s and only while jobs are at RunPod (no timer while idle).
/// - Background: transfers continue in the system's daemon; BGAppRefresh and URL-session wakes run `pump()` once
///   (R2 listing, lyrics import, downloads queued, pending submissions). A force-quit stops everything until launch.
@MainActor
@Observable
final class CloudStudio {
    nonisolated struct Failure: LocalizedError, Sendable, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// A line above the queue that applies to every job.
    nonisolated enum Notice: Equatable, Sendable {
        case off
        case notConfigured
        case keysMissing
        case runpodKeyRefused
        case endpointNotFound
        case rateLimited
        case capReached
        case endpointPaused

        var message: String {
            switch self {
            case .off: "Cloud processing is off. Turn it on in Settings › Sing › Cloud processing."
            case .notConfigured: "Fill in the RunPod and storage fields in Cloud processing first."
            case .keysMissing: "Cloud keys missing — paste them again in Cloud processing."
            case .runpodKeyRefused: "RunPod refused the key. Check the Restricted key in Cloud processing."
            case .endpointNotFound: "RunPod doesn't know this Endpoint ID. Check it in Cloud processing."
            case .rateLimited: "RunPod asked to slow down. Sending continues in a minute."
            case .capReached: "This month's cloud budget is used up. Raise the monthly cap to send more."
            case .endpointPaused: CloudEndpointWatch.pausedMessage
            }
        }
    }

    /// Whether a Sing tap can use the cloud for this song now. Anything but `usable` and `alreadyPending` sends the tap
    /// to the phone's own renderer, with `fallbackMessage` as the reason.
    nonisolated enum SingCloudAvailability: Equatable, Sendable {
        /// Cloud on, set up, within the month's budget, a song of up to 15 minutes, and a connection uploads may use.
        case usable
        /// The song already has a job on its way: the tap joins it.
        case alreadyPending(jobKey: String)
        case off
        case notConfigured
        case keysMissing
        case overCap
        case notOnWiFi
        case tooLong
        /// Nothing for the cloud to add (the song already has an instrumental, or there is no audio to send).
        case nothingToDo

        /// Why the phone renders instead, in words for a toast; nil when the cloud takes the tap.
        var fallbackMessage: String? {
            switch self {
            case .usable, .alreadyPending: nil
            case .off: "Cloud processing is off — removing vocals on this phone instead."
            case .notConfigured, .keysMissing: "Cloud processing isn't set up — removing vocals on this phone instead."
            case .overCap: "This month's cloud budget is used up — removing vocals on this phone instead."
            case .notOnWiFi: "Not on Wi-Fi — removing vocals on this phone instead."
            case .tooLong: "This song is too long for the cloud — removing vocals on this phone instead."
            case .nothingToDo: "Removing vocals on this phone instead."
            }
        }
    }

    /// Everything the orchestrator talks to.
    struct Dependencies {
        var store: CloudJobStore
        var host: any CloudStudioHost
        var makeTransfers: () -> any CloudTransferring
        var preparer: any CloudAudioPreparing
        var inspector: any CloudFileInspecting
        var makeRunPod: (CloudConfigInput) -> (any RunPodJobsAPI)?
        var makeObjects: (CloudConfigInput) -> (any CloudObjectStoring)?
        var nowMs: () -> Int64
        /// Start of the month containing a time (the local calendar's in the app).
        var monthStartMs: (Int64) -> Int64
        var newJobKey: () -> String
        var build: String
        /// Deletes a job's downloaded-but-not-imported files.
        var removeStaged: (String) -> Void
        /// Keeps the app running for a submission burst that started in the background (nil in tests).
        var background: CloudBackground?
        /// "Your instrumentals are ready" (nil in tests unless a fake is given, and in the UI-test demo).
        var notifier: (any CloudNotifying)?
        /// Start of the local day containing a time (auto-prepare's daily count starts over then).
        var dayStartMs: (Int64) -> Int64 = { $0 - $0 % 86_400_000 }
        /// The network now. nil (tests, the demo) counts as an unmetered Wi-Fi.
        var networkConditions: (() -> StreamPrefetchPolicy.Conditions)?
        /// The phone's state for work done ahead of time (Wi-Fi, battery, heat, free space, power saving, the heavy lane,
        /// safe mode): `CloudAutoConditions.blockedReason` says why it must wait ("Waiting for Wi-Fi"…). nil (tests, the
        /// demo) means nothing holds it back.
        var autoConditions: (@MainActor () -> CloudAutoConditions)?
    }

    nonisolated struct Clients: Sendable {
        let runpod: any RunPodJobsAPI
        let objects: any CloudObjectStoring
    }

    /// A job of the current submit pass that is ready to go out, held until the next one is ready (`CloudSubmitBurst`).
    nonisolated struct PendingSubmit: Sendable {
        let jobKey: String
        let request: CloudJobRequest
        let estimateMicroUSD: Int64
    }

    static let instrumentalSlot = "instrumental"
    static let maxConcurrentPreparations = 2
    /// Priority jobs (Sing, one song sent by hand) prepare in a place of their own, on top of the ordinary two.
    static let reservedPrioritySlots = 1

    // MARK: Observable state

    let settings: CloudSettings
    /// Every job, oldest first.
    private(set) var jobs: [CloudJobRecord] = []
    private(set) var isLoaded = false
    private(set) var notice: Notice?
    /// Upload or download progress (0…1) of a job's running transfer.
    private(set) var transferProgress: [String: Double] = [:]
    /// The last "Test connection" and selftest.
    private(set) var connectionReport: CloudConnectionReport?
    private(set) var selftestCheck: CloudCheck?
    private(set) var isTesting = false
    private(set) var isPreviewing = false
    /// UI tests: demo jobs, nothing runs.
    let isDemo: Bool
    /// Settings › Sing › "Prepare songs ahead in the cloud": picks the songs and sends them with the auto origin
    /// (set once, when the app is put together).
    var autoPrepare: SingPrepareRunner?
    /// The phone's network and power facts for work done ahead of time (set once by `CloudStudio.make`; nil in tests and
    /// the demo, where `Dependencies.autoConditions` stands in).
    @ObservationIgnored var deviceConditions: CloudDeviceConditions?

    // MARK: Plumbing

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var transfersStorage: (any CloudTransferring)?
    @ObservationIgnored private var clientsKey: CloudConfigInput?
    @ObservationIgnored private var clientsStorage: Clients?
    @ObservationIgnored private var preparing: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var importing: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeTransfers: Set<String> = []
    @ObservationIgnored private var reconciled = false
    @ObservationIgnored private var isPumping = false
    @ObservationIgnored private var pumpRequested = false
    @ObservationIgnored private var pumpWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var pollLoop: Task<Void, Never>?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var lastListAtMs: Int64 = 0
    @ObservationIgnored private var lastHealthAtMs: Int64 = 0
    /// Set while a background wake runs: nothing new (a transfer, a submission, an import) starts in its last seconds.
    @ObservationIgnored private var backgroundWindow: BackgroundWorkWindow?
    /// iOS took a background pass's time back: nothing starts until the next wake or the app is opened.
    @ObservationIgnored private var backgroundExpired = false
    /// The batches that still had a job outstanding at the last check, to tell which just finished.
    @ObservationIgnored private var incompleteBatches: Set<String> = []
    /// Notifications are posted one after another, and a background wake waits for them before it ends.
    @ObservationIgnored private var notifyChain: Task<Void, Never>?
    /// The foreground polling interval (tests shorten it).
    @ObservationIgnored var pollInterval: Duration = .seconds(15)
    /// While a job is at RunPod (a few minutes at most, foreground only): a 7-second job used to wait up to 15 s to be seen.
    @ObservationIgnored var activePollInterval: Duration = .milliseconds(CloudTiming.statusPollIntervalMs)
    /// Between two checks of RunPod inside one long background pass (tests shorten it).
    @ObservationIgnored var processingPollInterval: Duration = .milliseconds(CloudBackgroundPlanner.processingPollMs)

    init(settings: CloudSettings, dependencies: Dependencies, isDemo: Bool = false) {
        self.settings = settings
        self.dependencies = dependencies
        self.isDemo = isDemo
    }

    /// UI tests: the demo's jobs and last test (no pass ever runs in the demo).
    func loadDemo(jobs: [CloudJobRecord], report: CloudConnectionReport?, selftest: CloudCheck? = nil,
                  progress: [String: Double]) {
        guard isDemo else { return }
        self.jobs = jobs
        isLoaded = true
        connectionReport = report
        selftestCheck = selftest
        transferProgress = progress
    }

    // MARK: Queries

    func job(_ jobKey: String) -> CloudJobRecord? { jobs.first { $0.jobKey == jobKey } }

    /// The latest job for a song, whatever its state (the Sing button follows its progress).
    func job(forSong songId: String) -> CloudJobRecord? { jobs.last { $0.songId == songId } }

    /// The song has a job that isn't finished (the automatic studio skips it; the song sheet says so).
    func hasPendingJob(songId: String) -> Bool { jobs.contains { $0.songId == songId && $0.state.isPending } }

    var pendingSongIds: Set<String> { Set(jobs.filter { $0.state.isPending }.map(\.songId)) }

    /// Jobs in flight / done / needing the person, for the queue screen and Home's job line.
    var activeJobs: [CloudJobRecord] { jobs.filter { $0.state.isPending } }
    var finishedJobs: [CloudJobRecord] { jobs.filter { $0.state == .imported }.reversed() }
    var attentionJobs: [CloudJobRecord] { jobs.filter { $0.state == .failed || $0.state == .cancelled || $0.state == .expired } }

    /// "Cloud: 12 waiting, 1 processing" (nil when nothing is pending).
    var summaryLine: String? {
        let active = activeJobs
        guard !active.isEmpty else { return nil }
        let processing = active.filter { $0.state == .running }.count
        let waiting = active.count - processing
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if processing > 0 { parts.append("\(processing) processing") }
        return "Cloud: " + parts.joined(separator: ", ")
    }

    /// The studio's clock (Unix ms): the one its rules use, so the runner that works with it agrees.
    var nowMs: Int64 { dependencies.nowMs() }

    /// The month's committed spend (recorded costs plus estimates of jobs at RunPod, and what jobs since removed from
    /// the list spent this month).
    var committedThisMonthMicroUSD: Int64 {
        let monthStart = dependencies.monthStartMs(dependencies.nowMs())
        return CloudBudget.committedMicroUSD(jobs, monthStartMs: monthStart,
                                             pricePerSecondMicroUSD: settings.effectivePricePerSecondMicroUSD)
            + settings.removedSpendMicroUSD(monthStartMs: monthStart)
    }

    // MARK: Lifecycle

    /// The app became active: catch up at once, then poll while jobs are at RunPod. Nothing at all while the
    /// feature is off (no file read, no session).
    func resume() {
        isActive = true
        // The person is here: no background window limits the work any more.
        backgroundWindow = nil
        backgroundExpired = false
        guard settings.isEnabled else { return }
        // Sing asks whether the phone is on Wi-Fi before it picks the cloud: the path monitor runs while the cloud is on.
        deviceConditions?.start()
        requestPump()
    }

    /// The queue screen opened: show the stored jobs even while the feature is off.
    func loadForDisplay() async {
        await loadIfNeeded()
    }

    /// The app went to the background: stop polling, and ask iOS for the wakes the outstanding jobs need.
    func didEnterBackground() {
        isActive = false
        pollLoop?.cancel()
        pollLoop = nil
        scheduleBackground()
    }

    /// Puts the BGAppRefresh and BGProcessing requests in place for the jobs as they are now, and takes back the ones
    /// nothing needs (`CloudBackgroundPlanner`).
    func scheduleBackground() {
        let plan = CloudBackgroundPlanner.plan(jobs: jobs, nowMs: dependencies.nowMs(), isEnabled: settings.isEnabled)
        dependencies.background?.apply(plan)
    }

    /// BGAppRefresh (about 30 s): one pass — the R2 listing, lyrics imports, downloads queued, pending submissions —
    /// that starts nothing new in its last seconds.
    func backgroundRefresh() async {
        await runBackgroundPass(window: .appRefresh(startedAtMs: dependencies.nowMs()))
    }

    /// The system woke the app for the transfer session: take its events, then submit what is ready.
    func transferSessionWake() async {
        // A relaunch for the session has read nothing yet: the stored jobs come first, so the events that arrive as
        // soon as the session exists find their jobs (and a save never writes an empty list over them).
        await loadIfNeeded()
        guard settings.isEnabled || !jobs.isEmpty else { return }
        let window = BackgroundWorkWindow.appRefresh(startedAtMs: dependencies.nowMs())
        let transfers = connectTransfers()
        if let session = transfers as? CloudTransfers { await session.waitForBackgroundEvents(timeoutSeconds: 20) }
        let assertion = dependencies.background?.beginAssertion()
        await runBackgroundPass(window: window)
        assertion?.end()
    }

    /// BGProcessingTask (iOS decides when; minutes, often overnight): the same pass, then — while a job is at RunPod
    /// or its results are coming in — a poll every 30 s inside a two-minute window, so a batch that finishes meanwhile
    /// is imported in this wake instead of waiting for the next. `window` is injectable for tests.
    func backgroundProcessing(window: BackgroundWorkWindow? = nil) async {
        let window = window ?? .processing(startedAtMs: dependencies.nowMs())
        await loadIfNeeded()
        backgroundWindow = window
        backgroundExpired = false
        repeat {
            await pump()
            // Preparations that started count too (this is the pass for songs still waiting to go up), not only imports.
            await settle()
            let now = dependencies.nowMs()
            guard !Task.isCancelled,
                  CloudBackgroundPlanner.shouldKeepWaiting(jobs: jobs, window: window, nowMs: now) else { break }
            // Not past the point after which nothing new may start: the pass ends with its window, not 30 s after it.
            let slack = Duration.milliseconds(max(window.remainingMs(nowMs: now) - window.safetyMarginMs, 0))
            try? await Task.sleep(for: min(processingPollInterval, slack))
        } while !Task.isCancelled
        await finishBackgroundWake()
    }

    /// iOS is taking a long background pass's time back: nothing new starts, what is known is saved, the next request
    /// is placed. The pass itself is cancelled by its owner.
    func backgroundWillExpire() async {
        backgroundExpired = true
        await finishBackgroundWake()
    }

    private func runBackgroundPass(window: BackgroundWorkWindow) async {
        backgroundWindow = window
        backgroundExpired = false
        await pump()
        await settleImports()
        await finishBackgroundWake()
    }

    /// The end of every background wake, whatever ended it: notifications posted, the job list on disk (a save still
    /// in flight when the app is suspended may never finish), and the next requests in place.
    private func finishBackgroundWake() async {
        backgroundWindow = nil
        await notifyChain?.value
        await persistNow()
        scheduleBackground()
    }

    /// Nothing new may start: inside a background wake's last seconds, or after iOS took the time back.
    private var canStartNewWork: Bool {
        if backgroundExpired { return false }
        return backgroundWindow?.canStartTransfer(nowMs: dependencies.nowMs()) ?? true
    }

    /// A tap on "Your instrumentals are ready" opens the queue (called once from `AppEnvironment.init`).
    func installNotificationRouting(router: Router) {
        dependencies.notifier?.install(onOpen: { [weak router] in router?.openCloudQueue() })
    }

    // MARK: Person's actions

    /// What sending `songs` would do (`startNow` checks it before sending). Selection runs here, off the main actor's
    /// hot path: the lyrics store and the file checks are actor and detached calls.
    /// `onlyMissing` keeps the songs that lack that output (the queue's Add rows); gathering stops once a full
    /// batch of such songs is found, so a large library isn't read end to end.
    func preview(songs: [Song], title: String, onlyMissing: CloudTask? = nil,
                 replaceUserSynced: Bool = false, origin: CloudJobOrigin = .manual) async -> CloudBatchPreview {
        isPreviewing = true
        defer { isPreviewing = false }
        await settings.loadBuiltInKeys()
        await loadIfNeeded()
        let host = dependencies.host
        let pending = pendingSongIds
        var facts: [CloudSongFacts] = []
        var byId: [String: Song] = [:]
        var uploadBytes: [String: Int64] = [:]
        for song in songs where byId[song.id] == nil {
            if onlyMissing != nil, facts.count >= CloudLimits.maxSongsPerBatch { break }
            let lyrics = await host.lyricsFacts(for: song)
            let instrumental = await host.hasInstrumental(songId: song.id)
            if onlyMissing == .lyrics, lyrics.state == .wordSynced || lyrics.state == .userSynced { continue }
            if onlyMissing == .instrumental, instrumental { continue }
            if onlyMissing != nil, pending.contains(song.id) { continue }
            byId[song.id] = song
            facts.append(CloudSongFacts(songId: song.id, durationMs: song.duration, hasInstrumental: instrumental,
                                        lyrics: lyrics.state, hasAudioSource: Self.hasAudioSource(song),
                                        isStreamed: Self.isStreamed(song), hasPendingJob: pending.contains(song.id)))
            uploadBytes[song.id] = Self.estimatedUploadBytes(song)
        }
        var options = settings.selectionOptions
        options.replaceUserSynced = replaceUserSynced
        // Sing and songs prepared ahead exist for the instrumental: it is asked for even when the Outputs switch for it
        // (Developer) is off. The lyrics follow the settings.
        if origin != .manual { options.instrumental = true }
        let selection = CloudSelector.select(facts, options: options)
        let skips = selection.skipCounts.map { CloudBatchPreview.Skip(reason: $0.reason, count: $0.count) }
        let estimate = CloudBatchEstimate.make(plans: selection.plans, uploadBytes: uploadBytes, quality: settings.quality,
                                               pricePerSecondMicroUSD: settings.effectivePricePerSecondMicroUSD,
                                               committedMicroUSD: committedThisMonthMicroUSD,
                                               capMicroUSD: settings.effectiveMonthlyCapMicroUSD)
        return CloudBatchPreview(id: dependencies.newJobKey(), songs: selection.plans.compactMap { byId[$0.songId] },
                                 plans: selection.plans, skipped: skips, estimate: estimate,
                                 replaceUserSynced: replaceUserSynced, title: title, origin: origin)
    }

    /// "Process in cloud" (the song card, a playlist's ⋯): sends `songs` at once, with no sheet to confirm. What that
    /// sheet gated still holds — the consent switch on, something to send, inside this month's cap — and the outcome
    /// says which one stopped it, for the caller's toast. `origin` is who is sending (`.sing` for a tap on Sing).
    func startNow(songs: [Song], title: String, onlyMissing: CloudTask? = nil,
                  origin: CloudJobOrigin = .manual) async -> CloudStartOutcome {
        // The consent defaults to on only while the built-in keys look available: know whether they open first.
        await settings.loadBuiltInKeys()
        guard settings.isEnabled else { return .off }
        let batch = await preview(songs: songs, title: title, onlyMissing: onlyMissing, origin: origin)
        guard !batch.isEmpty else {
            guard let reason = batch.skipped.first?.reason else { return .nothingToDo("Nothing to process") }
            return .nothingToDo("Nothing to process — \(reason.label)")
        }
        // A Sing tap exists for the instrumental: lyrics alone to add is not what it was asked for.
        if origin == .sing, !batch.plans.contains(where: { $0.tasks.contains(.instrumental) }) {
            return .nothingToDo("Nothing to process — \(CloudSkipReason.alreadyDone.label)")
        }
        guard batch.estimate.fitsCap else { return .overCap }
        let known = Set(jobs.map(\.jobKey))
        await send(batch)
        // `send` skips a song that got a pending job meanwhile: count what was really queued.
        let started = jobs.filter { !known.contains($0.jobKey) }.count
        return started > 0 ? .started(started) : .nothingToDo("Nothing to process — \(CloudSkipReason.pendingJob.label)")
    }

    /// One of the queue's Add rows (developer mode), sent at once.
    func startNow(_ kind: CloudBatchKind) async -> CloudStartOutcome {
        let host = dependencies.host
        switch kind {
        case .current:
            guard let song = host.currentSong else { return .nothingToDo("Play a song first") }
            return await startNow(songs: [song], title: kind.title)
        case .missingLyrics:
            return await startNow(songs: host.librarySongs, title: kind.title, onlyMissing: .lyrics)
        case .missingInstrumental:
            return await startNow(songs: host.librarySongs, title: kind.title, onlyMissing: .instrumental)
        }
    }

    // MARK: Sing and songs prepared ahead

    /// Can anything be sent: the switch on, the fields filled in, the keys readable. `usable` when so (the same check
    /// Sing and "Prepare songs ahead" start from).
    func cloudReadiness() async -> SingCloudAvailability {
        await settings.loadBuiltInKeys()
        guard settings.isEnabled else { return .off }
        await settings.loadSecrets()
        // A built-in blob that didn't open switches the default consent off.
        guard settings.isEnabled else { return .off }
        if settings.keysMissing { return .keysMissing }
        guard settings.configInput.isComplete else { return .notConfigured }
        return .usable
    }

    /// Whether a Sing tap can use the cloud for `song` now: the switch on and set up, a song of up to 15 minutes that
    /// has no instrumental yet, room in this month's budget and a connection uploads may use (Wi-Fi, or "Use cellular
    /// data" on). A song with a job on its way is `alreadyPending`: the tap joins it.
    func singAvailability(for song: Song) async -> SingCloudAvailability {
        let readiness = await cloudReadiness()
        guard readiness == .usable else { return readiness }
        await loadIfNeeded()
        if let pending = jobs.last(where: { $0.songId == song.id && $0.state.isPending }) {
            // A job that only makes lyrics can't give this tap its instrumental: the phone does that.
            return pending.tasks.contains(.instrumental) ? .alreadyPending(jobKey: pending.jobKey) : .nothingToDo
        }
        if song.duration > CloudLimits.maxDurationMs { return .tooLong }
        guard Self.hasAudioSource(song), !(await dependencies.host.hasInstrumental(songId: song.id)) else {
            return .nothingToDo
        }
        // The instrumental alone is what this tap asks for: its cost must fit what is left of the month.
        let plan = CloudSongPlan(songId: song.id, tasks: [.instrumental], lyricsMode: nil, isStreamed: Self.isStreamed(song),
                                 durationMs: song.duration > 0 ? song.duration : CloudCost.referenceSongMs)
        let estimate = CloudCost.estimateMicroUSD([plan], quality: settings.quality,
                                                  pricePerSecondMicroUSD: settings.effectivePricePerSecondMicroUSD)
        guard CloudBudget.allows(estimateMicroUSD: estimate, capMicroUSD: settings.effectiveMonthlyCapMicroUSD,
                                 spentMicroUSD: committedThisMonthMicroUSD) else { return .overCap }
        guard networkAllowsUpload() else { return .notOnWiFi }
        return .usable
    }

    /// A tap on Sing: the instrumental of `song` is made in the cloud, ahead of everything else in the queue. A song that
    /// already has a job on its way joins it (an auto job becomes the person's), instead of a second one.
    func startSing(song: Song) async -> CloudStartOutcome {
        await settings.loadBuiltInKeys()
        guard settings.isEnabled else { return .off }
        await loadIfNeeded()
        if let pending = jobs.last(where: { $0.songId == song.id && $0.state.isPending }) {
            guard pending.tasks.contains(.instrumental) else {
                return .nothingToDo("Nothing to process — \(CloudSkipReason.pendingJob.label)")
            }
            joinWithSing(pending.jobKey)
            return .started(1)
        }
        return await startNow(songs: [song], title: "Sing", origin: .sing)
    }

    /// A Sing tap on a song whose job is already on its way: that job is a Sing job from now on (prepared and sent first).
    private func joinWithSing(_ jobKey: String) {
        guard let record = job(jobKey), record.state.isPending else { return }
        // The person asked: safe mode waits for exactly this.
        HeavyWorkGate.shared.userStartedHeavyWork()
        if record.effectiveOrigin != .sing {
            let now = dependencies.nowMs()
            update(jobKey) { r in
                r.promote(nowMs: now)
                // It was waiting for a good moment (off Wi-Fi, low battery…) or stepped aside for another song: not any more.
                if r.state == .queued, r.lastError == nil { r.nextAttemptAtMs = nil }
                if r.isPaused { r.release() }
            }
            persist()
        }
        if record.state == .queued || record.state == .preparing {
            dependencies.background?.beginPreparing(count: 1)
            if settings.notifyWhenDone, let notifier = dependencies.notifier {
                Task { await notifier.requestAuthorizationIfNeeded() }
            }
        }
        requestPump()
    }

    /// "Prepare songs ahead": the first `limit` of `songs` the cloud can still do something for, sent as one batch of
    /// auto jobs, as many as the auto budget, today's count and the shared monthly cap allow. Returns how many went.
    func startAuto(songs: [Song], limit: Int, title: String = "Prepared ahead") async -> Int {
        guard limit > 0 else { return 0 }
        await settings.loadBuiltInKeys()
        guard settings.isEnabled else { return 0 }
        let batch = await preview(songs: songs, title: title, origin: .auto)
        // Prepared ahead means the instrumental: a song that only lacks word-timed lyrics is not worth a cold start here.
        let wanted = batch.plans.filter { $0.tasks.contains(.instrumental) }
        guard !wanted.isEmpty else { return 0 }
        let price = settings.effectivePricePerSecondMicroUSD
        var estimates = wanted.map { CloudCost.estimatedSeconds($0, quality: settings.quality) * price }
        // One cold start for the batch, on its first song.
        estimates[0] += CloudCost.coldStartSeconds * price
        let count = min(limit, CloudAutoBudget.affordableCount(
            estimates: estimates, ledger: projectedAutoLedger(), budgetMicroUSD: settings.effectiveAutoBudgetMicroUSD,
            dailyCap: settings.autoPrepareDailyCap, committedMicroUSD: committedThisMonthMicroUSD,
            totalCapMicroUSD: settings.effectiveMonthlyCapMicroUSD))
        guard count > 0 else { return 0 }
        let plans = Array(wanted.prefix(count))
        let songsById = Dictionary(batch.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let trimmed = CloudBatchPreview(
            id: batch.id, songs: plans.compactMap { songsById[$0.songId] }, plans: plans, skipped: batch.skipped,
            estimate: CloudBatchEstimate.make(plans: plans, uploadBytes: [:], quality: settings.quality,
                                              pricePerSecondMicroUSD: price, committedMicroUSD: committedThisMonthMicroUSD,
                                              capMicroUSD: settings.effectiveMonthlyCapMicroUSD),
            replaceUserSynced: false, title: title, origin: .auto)
        let known = Set(jobs.map(\.jobKey))
        await send(trimmed)
        return jobs.filter { !known.contains($0.jobKey) }.count
    }

    /// "Prepare songs ahead" was switched off: auto jobs the worker doesn't have stop and clear out; ones already
    /// running or coming down finish and land. A song the person has since asked for (a Sing tap made its job theirs) is
    /// not an auto job any more and is left alone.
    func cancelAutoJobs() async {
        for record in jobs where record.effectiveOrigin == .auto && (record.state.isBeforeSubmit || record.state == .submitted) {
            await cancel(record.jobKey)
        }
    }

    /// Which of `songs` already have an instrumental, in one look: a song that has one is not worth a cold start.
    func songIdsWithInstrumental(among songs: [Song]) async -> Set<String> {
        await dependencies.host.songIdsWithInstrumental(among: songs.map(\.id))
    }

    /// Songs whose auto job failed or expired since `sinceMs`: they rest before being picked again.
    func recentAutoFailureSongIds(sinceMs: Int64) -> Set<String> {
        Set(jobs.filter { record in
            record.effectiveOrigin == .auto && (record.state == .failed || record.state == .expired)
                && (record.updatedAtMs ?? record.createdAtMs) >= sinceMs
        }.map(\.songId))
    }

    /// The phone's state for work done ahead of time (nil: nothing holds it back, as in tests).
    func autoConditions() -> CloudAutoConditions? { dependencies.autoConditions?() }

    /// Why work done ahead of time must wait now, in plain words ("Waiting for Wi-Fi"…), or nil.
    var autoBlockedReason: String? { autoConditions()?.blockedReason }

    /// Songs prepared ahead come down only on an unmetered connection (never on mobile data, whatever the switch says).
    private func autoMayUseNetwork() -> Bool { autoConditions()?.isUnmetered ?? true }

    /// An auto job finds the phone not ready (off Wi-Fi, low battery, a hot phone…): it goes back to the queue for a
    /// while, without counting as a failure. True when it did.
    private func deferAutoJob(_ jobKey: String) -> Bool {
        guard autoBlockedReason != nil, job(jobKey)?.state == .preparing else { return false }
        let now = dependencies.nowMs()
        update(jobKey) { r in
            r.apply(.requeue, nowMs: now)
            r.nextAttemptAtMs = now + CloudTiming.autoDeferMs
        }
        persist()
        return true
    }

    /// A job stopped before RunPod's worker had it gives its reserved estimate back to the auto budget (it still counts
    /// for today). A job that may have started keeps what it reserved.
    private func refundUnstartedAutoReservation(_ record: CloudJobRecord) {
        guard let reserved = record.autoReservedMicroUSD else { return }
        let neverStarted = record.state == .submitted || (record.state == .uploaded && record.pausedNeverStarted == true)
        if neverStarted { refundAutoSpend(reserved) }
    }

    /// Tells the runner a job it sent has ended (imported, failed, cancelled, expired): room for the next batch.
    private func noteAutoJobEnded(_ record: CloudJobRecord) {
        guard record.effectiveOrigin == .auto else { return }
        autoPrepare?.autoJobFinished()
    }

    /// Auto jobs waiting out a "not ready" pause (off Wi-Fi, low battery…) are looked at again now: the phone just
    /// became ready for them.
    func wakeAutoJobs() {
        var woke = false
        for record in jobs where record.effectiveOrigin == .auto && record.state == .queued && record.lastError == nil
            && record.nextAttemptAtMs != nil {
            update(record.jobKey) { $0.nextAttemptAtMs = nil }
            woke = true
        }
        if woke {
            persist()
            requestPump()
        } else if jobs.contains(where: { $0.effectiveOrigin == .auto && $0.state == .resultsReady }) {
            requestPump()
        }
    }

    /// The auto jobs that have not finished.
    var outstandingAutoJobs: [CloudJobRecord] { jobs.filter { $0.effectiveOrigin == .auto && $0.state.isPending } }

    /// Auto-prepare's spending this month and count today, rolled to the clock.
    var autoLedger: CloudAutoLedger {
        let now = dependencies.nowMs()
        return settings.rolledAutoLedger(monthStartMs: dependencies.monthStartMs(now), dayStartMs: dependencies.dayStartMs(now))
    }

    /// The ledger plus the auto jobs on their way that have not been sent yet (they will spend and count).
    func projectedAutoLedger() -> CloudAutoLedger {
        var ledger = autoLedger
        let price = settings.effectivePricePerSecondMicroUSD
        for record in outstandingAutoJobs where record.autoReservedMicroUSD == nil {
            ledger.spentMicroUSD += CloudCost.estimatedSeconds(record.plan, quality: record.quality) * price
            ledger.dayCount += 1
        }
        return ledger
    }

    private func reserveAutoSpend(_ estimateMicroUSD: Int64) {
        let now = dependencies.nowMs()
        settings.updateAutoLedger(monthStartMs: dependencies.monthStartMs(now), dayStartMs: dependencies.dayStartMs(now)) {
            $0.reserve(estimateMicroUSD)
        }
        autoPrepare?.refreshStatus()
    }

    private func settleAutoSpend(reserved: Int64, actual: Int64) {
        let now = dependencies.nowMs()
        settings.updateAutoLedger(monthStartMs: dependencies.monthStartMs(now), dayStartMs: dependencies.dayStartMs(now)) {
            $0.settle(reservedMicroUSD: reserved, actualMicroUSD: actual)
        }
        autoPrepare?.refreshStatus()
    }

    private func refundAutoSpend(_ reserved: Int64) {
        let now = dependencies.nowMs()
        settings.updateAutoLedger(monthStartMs: dependencies.monthStartMs(now), dayStartMs: dependencies.dayStartMs(now)) {
            $0.refund(reserved)
        }
        autoPrepare?.refreshStatus()
    }

    /// The phone is on a connection uploads may use: any, with "Use cellular data"; else Wi-Fi or Ethernet that is not
    /// metered. Low Data Mode and no connection never. Unknown (the monitor hasn't reported yet) counts as fine.
    private func networkAllowsUpload() -> Bool {
        guard let conditions = dependencies.networkConditions?() else { return true }
        switch conditions.network {
        case .unknown: return true
        case .offline: return false
        case .wifi, .wired: return !conditions.isConstrained && (!conditions.isExpensive || settings.useCellular)
        case .cellular, .other: return settings.useCellular && !conditions.isConstrained
        }
    }

    /// The batch was checked (`startNow`, or a test): one job per song, then everything runs on its own.
    func send(_ preview: CloudBatchPreview) async {
        let origin = preview.origin
        let isAuto = origin == .auto
        // A person-started batch is the go-ahead that safe mode waits for. Songs prepared ahead are not: nobody asked.
        if !isAuto { HeavyWorkGate.shared.userStartedHeavyWork() }
        // Built-in keys that turn out not to open switch the default consent off: know before anything is queued.
        await settings.loadBuiltInKeys()
        guard settings.isEnabled, !preview.isEmpty, preview.estimate.fitsCap else { return }
        await loadIfNeeded()
        let now = dependencies.nowMs()
        let byId = Dictionary(preview.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for plan in preview.plans {
            guard let song = byId[plan.songId], !hasPendingJob(songId: song.id) else { continue }
            var record = CloudJobRecord(jobKey: CloudKeys.jobKey(uuid: dependencies.newJobKey()), songId: song.id,
                                        title: song.title, artist: song.displayArtist, batchId: preview.id,
                                        tasks: plan.tasks, lyricsMode: plan.lyricsMode,
                                        quality: CloudSelector.quality(settings.quality, durationMs: plan.durationMs),
                                        createdAtMs: now, isStreamed: plan.isStreamed,
                                        videoId: YouTubeSongIdentity.videoId(for: song),
                                        replaceUserSynced: preview.replaceUserSynced)
            record.songDurationMs = song.duration
            // A record without an origin is a manual one; a Sing tap goes to the front of the queue from the start.
            if origin != .manual { record.origin = origin }
            if origin == .sing { record.priorityAtMs = now }
            jobs.append(record)
        }
        persist()
        // Songs prepared ahead are quiet: no continued-processing task, no permission prompt (and no notification later).
        if !isAuto {
            // A person-started batch keeps preparing in the background (continued processing, design §7.4).
            dependencies.background?.beginPreparing(count: preview.plans.count)
            // The one moment iOS may ask about notifications: the person just sent songs and will probably leave the app.
            if settings.notifyWhenDone, let notifier = dependencies.notifier {
                Task { await notifier.requestAuthorizationIfNeeded() }
            }
        }
        requestPump()
    }

    /// Stops a job wherever it is: transfers, RunPod, and its objects in the bucket.
    func cancel(_ jobKey: String) async {
        guard let record = job(jobKey), !record.state.isFinished else { return }
        preparing[jobKey]?.cancel()
        preparing[jobKey] = nil
        if let transfers = transfersStorage { await transfers.cancel(jobKey: jobKey) }
        activeTransfers = activeTransfers.filter { !$0.hasPrefix(jobKey + "|") }
        transferProgress[jobKey] = nil
        let keys = CloudJobBuilder.objectKeys(for: record)
        let clients = currentClients()
        if record.state.isAtRunPod, let id = record.runpodJobId, let clients {
            _ = try? await clients.runpod.cancel(jobId: id)
        }
        // The reservation in the auto budget goes back when RunPod had not started the job.
        refundUnstartedAutoReservation(record)
        update(jobKey) { r in
            r.apply(.cancelled, nowMs: self.dependencies.nowMs())
            r.autoReservedMicroUSD = nil
            r.clearPause()
        }
        // Songs that stepped aside for this one carry on without it.
        releasePauses(of: jobKey)
        persist()
        cleanUpLocal(jobKey)
        if let clients { await deleteRemote(keys, clients) }
        noteAutoJobEnded(record)
    }

    /// Starts a failed, cancelled or expired job again from the upload.
    func retry(_ jobKey: String) {
        guard let record = job(jobKey), record.state == .failed || record.state == .cancelled || record.state == .expired else {
            return
        }
        update(jobKey) { r in
            r.attempts = 0
            r.resubmits = 0
            r.lastError = nil
            r.lastErrorCode = nil
            r.apply(.requeue, nowMs: self.dependencies.nowMs())
        }
        // The batch is outstanding again, and may be announced again when it finishes.
        settings.forgetNotified(record.batchId)
        persist()
        requestPump()
    }

    /// Removes a finished job from the list.
    func remove(_ jobKey: String) {
        guard let record = job(jobKey), record.state.isFinished else { return }
        rememberSpend(of: [record])
        jobs.removeAll { $0.jobKey == jobKey }
        persist()
    }

    /// Removes every imported job.
    func clearFinished() {
        rememberSpend(of: jobs.filter { $0.state == .imported })
        jobs.removeAll { $0.state == .imported }
        persist()
    }

    /// "Clear finished" on Active jobs: removes every job nothing more happens to (done, failed, cancelled, expired).
    /// Jobs still on their way are never touched.
    func clearAllFinished() {
        let removed = CloudJobClearing.clearable(jobs)
        guard !removed.isEmpty else { return }
        rememberSpend(of: removed)
        jobs.removeAll { $0.state.isFinished }
        persist()
    }

    /// "Clear failed" in the queue: removes the jobs that need the person (failed, cancelled, expired).
    func clearAttention() {
        let removed = jobs.filter { $0.state == .failed || $0.state == .cancelled || $0.state == .expired }
        guard !removed.isEmpty else { return }
        rememberSpend(of: removed)
        jobs.removeAll { $0.state == .failed || $0.state == .cancelled || $0.state == .expired }
        persist()
    }

    /// Removes one batch's finished jobs (the "Dismiss" of its row in Active jobs).
    func clearBatch(_ batchId: String) {
        let removed = CloudJobClearing.clearable(jobs).filter { $0.batchId == batchId }
        guard !removed.isEmpty else { return }
        rememberSpend(of: removed)
        let keys = Set(removed.map(\.jobKey))
        jobs.removeAll { keys.contains($0.jobKey) }
        persist()
    }

    /// Stops every job that is not finished, each wherever it is (the sheet's "Cancel all").
    func cancelAll() async {
        for record in CloudJobClearing.cancellable(jobs) { await cancel(record.jobKey) }
    }

    /// Stops one batch's unfinished jobs (the "Cancel" of its row in Active jobs).
    func cancelBatch(_ batchId: String) async {
        for record in CloudJobClearing.cancellable(jobs) where record.batchId == batchId { await cancel(record.jobKey) }
    }

    /// Starts one batch's failed and expired jobs again (the "Retry" of its row in Active jobs).
    func retryBatch(_ batchId: String) {
        for record in CloudJobClearing.retryable(jobs) where record.batchId == batchId { retry(record.jobKey) }
    }

    /// What jobs about to leave the list spent this month stays in the month's total (`CloudSettings.removedSpend`),
    /// so clearing the list never makes room under the monthly cap.
    private func rememberSpend(of removed: [CloudJobRecord]) {
        let monthStart = dependencies.monthStartMs(dependencies.nowMs())
        settings.addRemovedSpend(CloudBudget.spentMicroUSD(removed, monthStartMs: monthStart), monthStartMs: monthStart)
    }

    // MARK: Test connection

    /// RunPod's `/health` and the bucket probe, each on its own (design §7.2).
    func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        await settings.loadSecrets()
        let config = settings.configInput
        let runpod = dependencies.makeRunPod(config)
        let objects = dependencies.makeObjects(config)
        let probeId = dependencies.newJobKey()
        async let runpodCheck = CloudConnectionTest.checkRunPod(runpod)
        async let storageCheck = CloudConnectionTest.checkStorage(objects, probeId: probeId)
        connectionReport = CloudConnectionReport(runpod: await runpodCheck, storage: await storageCheck)
        if connectionReport?.allOK == true, notice == .runpodKeyRefused || notice == .endpointNotFound { notice = nil }
    }

    /// "Run selftest (~1¢)": one cold start through `/runsync`.
    func runSelftest() async {
        isTesting = true
        defer { isTesting = false }
        await settings.loadSecrets()
        let report = await CloudConnectionTest.selftestReport(dependencies.makeRunPod(settings.configInput),
                                                              build: dependencies.build)
        selftestCheck = report.check
        if let caps = report.caps { settings.workerCaps = caps }
    }

    // MARK: The pump

    /// Asks for a pass soon (coalesced).
    func requestPump() {
        guard !isDemo else { return }
        if isPumping {
            pumpRequested = true
            return
        }
        Task { await self.pump() }
    }

    /// One pass over every job: prepare, upload, submit, watch, collect. A call while a pass runs asks for one more
    /// pass and returns when that one has finished too.
    func pump() async {
        guard !isDemo else { return }
        if isPumping {
            pumpRequested = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pumpWaiters.append(continuation)
            }
            return
        }
        isPumping = true
        repeat {
            pumpRequested = false
            await pumpOnce()
        } while pumpRequested
        isPumping = false
        let waiters = pumpWaiters
        pumpWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        startPollLoopIfNeeded()
    }

    /// Waits until running preparations and imports have finished, pumping after each (tests and background wakes).
    func settle() async {
        for _ in 0..<20 {
            let running = Array(preparing.values) + Array(importing.values)
            guard !running.isEmpty else { break }
            for task in running { await task.value }
            await pump()
        }
    }

    private func settleImports() async {
        for task in importing.values { await task.value }
    }

    private func pumpOnce() async {
        await loadIfNeeded()
        prune()
        guard settings.isEnabled else {
            notice = .off
            return
        }
        await settings.loadSecrets()
        // On by default only while the built-in keys looked available: a blob that didn't open switches that off.
        guard settings.isEnabled else {
            notice = .off
            return
        }
        if settings.keysMissing {
            notice = .keysMissing
            return
        }
        guard let clients = currentClients() else {
            notice = .notConfigured
            return
        }
        if notice == .off || notice == .notConfigured || notice == .keysMissing || notice == .rateLimited { notice = nil }
        // Nothing sent and no session yet (the usual launch now that the feature can be on by default): no transfer
        // session, no RunPod or bucket call.
        guard !jobs.isEmpty || transfersStorage != nil else { return }
        _ = connectTransfers()
        await reconcileTransfers()
        startPreparations()
        restartStalledUploads(clients)
        // A priority job that is ready to go gets the GPU ahead of the jobs RunPod holds but has not started.
        await prioritizeQueue(clients)
        await submitReadyBatches(clients)
        await watchRunPod(clients)
        await collectResults(clients)
        // Continued processing lasts while songs are being prepared or are due to be; a song waiting out a retry
        // (up to an hour) doesn't hold the system's progress UI open. Songs prepared ahead are not part of it.
        let now = dependencies.nowMs()
        let toPrepare = jobs.filter {
            $0.effectiveOrigin != .auto && ($0.state == .preparing || ($0.state == .queued && $0.isDue(nowMs: now)))
        }.count
        if toPrepare == 0 {
            dependencies.background?.endPreparing()
        } else {
            dependencies.background?.updatePreparing(remaining: toPrepare)
        }
    }

    private func startPollLoopIfNeeded() {
        guard isActive, pollLoop == nil, needsPolling, settings.isEnabled, !isDemo else { return }
        pollLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.currentPollInterval else { break }
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, self.isActive, self.needsPolling else { break }
                await self.pump()
            }
            self?.pollLoop = nil
        }
    }

    private var currentPollInterval: Duration {
        jobs.contains { $0.state.isAtRunPod } ? activePollInterval : pollInterval
    }

    /// Something can change without the person or a transfer event: jobs at RunPod, a batch gate, a retry wait.
    private var needsPolling: Bool {
        jobs.contains { record in
            record.state.isAtRunPod || record.state == .uploaded
                || (record.state.isPending && (record.nextAttemptAtMs ?? 0) > 0)
        }
    }

    // MARK: Loading and saving

    private func loadIfNeeded() async {
        guard !isLoaded else { return }
        let loaded = await dependencies.store.load(nowMs: dependencies.nowMs())
        guard !isLoaded else { return }
        // A job a dead process left "preparing" goes back to the queue before anything shows it as running.
        var stored = loaded
        let recovered = CloudStartupRecovery.recover(&stored, nowMs: dependencies.nowMs())
        // Jobs added while the file was being read (none in practice) stay after the stored ones.
        jobs = stored + jobs.filter { added in !stored.contains { $0.jobKey == added.jobKey } }
        isLoaded = true
        // The baseline for "which batch just finished": what was outstanding when this launch (or background wake) began.
        incompleteBatches = CloudBatchNotifier.incompleteBatchIds(jobs)
        if recovered > 0 { persist() }
    }

    private func prune() {
        let now = dependencies.nowMs()
        let before = jobs.count
        rememberSpend(of: jobs.filter { CloudRetention.shouldPrune($0, nowMs: now) })
        jobs.removeAll { CloudRetention.shouldPrune($0, nowMs: now) }
        if jobs.count != before { persist() }
    }

    /// Saves the list in order (each save waits for the one before). Never before the stored list was read: an
    /// unread list is empty, and saving it would erase every stored job.
    private func persist() {
        guard isLoaded else { return }
        let snapshot = jobs
        let previous = saveChain
        let store = dependencies.store
        saveChain = Task {
            await previous?.value
            await store.save(snapshot)
        }
        checkBatchCompletions()
    }

    /// After every change: which batches just finished. A notification for each (when the switch is on and iOS allows
    /// it; the notifier stays quiet while PixlAudio is on screen), and the background requests are taken back once
    /// nothing is outstanding.
    private func checkBatchCompletions() {
        let outstanding = CloudBatchNotifier.incompleteBatchIds(jobs)
        // Nothing finished since the last check (the common case): just remember new batches.
        guard !incompleteBatches.isSubset(of: outstanding) else {
            incompleteBatches.formUnion(outstanding)
            return
        }
        let finished = CloudBatchNotifier.completions(previouslyIncomplete: incompleteBatches, jobs: jobs,
                                                      alreadyNotified: settings.notifiedBatchIds)
        incompleteBatches = outstanding
        if outstanding.isEmpty { dependencies.background?.apply(CloudBackgroundPlan.none) }
        guard settings.notifyWhenDone, let notifier = dependencies.notifier, !finished.isEmpty else { return }
        for outcome in finished { settings.markNotified(outcome.batchId) }
        let previous = notifyChain
        notifyChain = Task {
            await previous?.value
            for outcome in finished { await notifier.notifyBatchFinished(outcome) }
        }
    }

    /// Saves and waits (a RunPod job id is on disk before the next `/run`).
    private func persistNow() async {
        persist()
        await saveChain?.value
    }

    private func update(_ jobKey: String, _ change: (inout CloudJobRecord) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.jobKey == jobKey }) else { return }
        change(&jobs[index])
    }

    // MARK: Clients and transfers

    private func currentClients() -> Clients? {
        let config = settings.configInput
        if let clientsStorage, clientsKey == config { return clientsStorage }
        guard config.isComplete, let runpod = dependencies.makeRunPod(config),
              let objects = dependencies.makeObjects(config) else {
            clientsStorage = nil
            clientsKey = nil
            return nil
        }
        let clients = Clients(runpod: runpod, objects: objects)
        clientsStorage = clients
        clientsKey = config
        return clients
    }

    /// The background session, created on first use (a relaunch for its events creates it at once).
    @discardableResult
    func connectTransfers() -> any CloudTransferring {
        if let transfersStorage { return transfersStorage }
        let transfers = dependencies.makeTransfers()
        transfersStorage = transfers
        transfers.allowsCellular = settings.useCellular
        transfers.onProgress = { [weak self] jobKey, _, fraction in
            Task { @MainActor in self?.transferProgress[jobKey] = fraction }
        }
        transfers.onEvent = { [weak self] event in
            Task { @MainActor in await self?.handle(event) }
        }
        return transfers
    }

    /// After a launch: transfers the system no longer runs are started again; half-done preparations start over.
    private func reconcileTransfers() async {
        guard !reconciled, let transfers = transfersStorage else { return }
        reconciled = true
        let pending = Set(await transfers.pendingTaskDescriptions())
        activeTransfers.formUnion(pending)
        let now = dependencies.nowMs()
        for record in jobs {
            switch record.state {
            case .preparing where preparing[record.jobKey] == nil:
                update(record.jobKey) { _ = $0.apply(.requeue, nowMs: now) }
            case .downloading:
                let description = CloudTransfers.taskDescription(jobKey: record.jobKey, slot: Self.instrumentalSlot)
                if !pending.contains(description) { update(record.jobKey) { _ = $0.apply(.resultsReady, nowMs: now) } }
            default:
                break
            }
        }
        persist()
    }

    // MARK: Prepare and upload

    private func startPreparations() {
        guard canStartNewWork else { return }
        // Safe mode (the app closed unexpectedly) and Emergency stop: the stored queue does not start preparing (the decode
        // is the heavy part) by itself; sending songs again is the go-ahead (`send`). Uploads and results carry on.
        guard HeavyWorkGate.shared.allowsLaunchWork else { return }
        let now = dependencies.nowMs()
        // While lyric sync, a separation or a model install holds the heavy lane, preparing songs (a CPU-bound decode)
        // goes one at a time so the phone is not asked for everything at once.
        let limit = HeavyJobGovernor.shared.isBusy ? 1 : Self.maxConcurrentPreparations
        // A song somebody is waiting for (Sing, one song sent by hand) is prepared first, in a place of its own.
        let priorityKeys = CloudPriorityLane.priorityJobKeys(jobs)
        let due = jobs.filter { $0.state == .queued && $0.isDue(nowMs: now) }
        // Songs prepared ahead wait for a phone that is ready for them (Wi-Fi, charge, cool…); nothing starts otherwise.
        let autoWaits = due.contains { $0.effectiveOrigin == .auto } && autoBlockedReason != nil
        for record in CloudPriorityLane.ordered(due, priorityKeys: priorityKeys) {
            guard preparing[record.jobKey] == nil else { continue }
            let isPriority = priorityKeys.contains(record.jobKey)
            let priorityBusy = preparing.keys.filter { priorityKeys.contains($0) }.count
            if isPriority {
                guard priorityBusy < Self.reservedPrioritySlots else { continue }
            } else {
                guard preparing.count - priorityBusy < limit else { break }
                if record.effectiveOrigin == .auto, autoWaits { continue }
            }
            let jobKey = record.jobKey
            update(jobKey) { _ = $0.apply(.prepareStarted, nowMs: now) }
            // Utility: the decode and FLAC encode must not take cores from the UI. A song somebody waits for is the
            // exception.
            let taskPriority: TaskPriority = isPriority ? .userInitiated : .utility
            preparing[jobKey] = Task(priority: taskPriority) { [weak self] in
                await self?.prepare(jobKey: jobKey)
                self?.preparing[jobKey] = nil
                self?.requestPump()
            }
        }
    }

    private func prepare(jobKey: String) async {
        guard let record = job(jobKey), record.state == .preparing else { return }
        guard let song = dependencies.host.song(id: record.songId) else {
            fail(jobKey, "This song is no longer in your library.", code: nil, retryable: false)
            return
        }
        let isAuto = record.effectiveOrigin == .auto
        // A song somebody is waiting for is decoded at full speed; everything else leaves the cores half idle.
        let isPriority = CloudPriorityLane.priorityJobKeys(jobs).contains(jobKey)
        // Songs prepared ahead start only on a phone that is ready for them (the audio download below ignores the
        // cellular switch, so it is checked before it begins).
        if isAuto, deferAutoJob(jobKey) { return }
        do {
            let source = try await dependencies.host.audioSource(for: song)
            try Task.checkCancellation()
            // Wi-Fi, the charger or the heat may have changed while the audio came down.
            if isAuto, deferAutoJob(jobKey) { return }
            var identity: String?
            if record.isStreamed { identity = await dependencies.host.streamIdentity(for: song) }
            // A streamed song's download (YouTube's DASH AAC) always goes up decoded as FLAC (design §7.3): the worker
            // then sees exactly the samples this phone plays, whatever priming the download's container declares.
            let prepared = try await dependencies.preparer.prepare(source: source, jobKey: jobKey,
                                                                   forceDecode: record.isStreamed, paced: !isPriority)
            guard job(jobKey)?.state == .preparing else {
                dependencies.preparer.removeUpload(jobKey: jobKey)
                return
            }
            if let refusal = CloudLimits.workerRefusal(bytes: prepared.bytes, durationMs: prepared.durationMs,
                                                       caps: settings.workerCaps) {
                // The endpoint is set stricter than the app: stop before the upload and the GPU time.
                dependencies.preparer.removeUpload(jobKey: jobKey)
                update(jobKey) { _ = $0.apply(.requeue, nowMs: self.dependencies.nowMs()) }
                fail(jobKey, refusal, code: nil, retryable: false)
                return
            }
            let now = dependencies.nowMs()
            update(jobKey) { r in
                r.inputExt = prepared.ext
                r.sha256 = prepared.sha256
                r.bytes = prepared.bytes
                r.durationMs = prepared.durationMs
                r.decodedFrames = prepared.frames
                r.sampleRate = prepared.sampleRate
                if let identity { r.videoId = identity }
                r.lowQualitySource = r.isStreamed && prepared.lowQuality
                r.apply(.prepared, nowMs: now)
            }
            persist()
            if let clients = currentClients() { startUpload(jobKey, fileURL: prepared.fileURL, clients) }
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let decodeFailure = (error as? CloudAudioPreparer.Failure)?.isDecodeFailure ?? false
            update(jobKey) { _ = $0.apply(.requeue, nowMs: self.dependencies.nowMs()) }
            fail(jobKey, message, code: nil, retryable: !decodeFailure)
        }
    }

    /// The song upload: a presigned PUT valid 24 h, handed to the background session.
    private func startUpload(_ jobKey: String, fileURL: URL?, _ clients: Clients) {
        guard let record = job(jobKey), record.state == .uploading, let ext = record.inputExt else { return }
        // Left in "uploading" with no transfer: the next pass that may start work starts it (restartStalledUploads).
        guard canStartNewWork else { return }
        let now = dependencies.nowMs()
        guard let file = fileURL ?? dependencies.preparer.uploadFile(jobKey: jobKey, ext: ext) else {
            // The prepared file is gone (storage was cleaned): prepare it again.
            update(jobKey) { _ = $0.apply(.requeue, nowMs: now) }
            return
        }
        let key = CloudKeys.input(jobKey: jobKey, ext: ext)
        guard let text = clients.objects.presignedURL(.put, key: key, expiresSeconds: CloudTiming.uploadPresignSeconds),
              let url = URL(string: text) else {
            notice = .notConfigured
            return
        }
        update(jobKey) { $0.uploadURLExpiresAtMs = now + Int64(CloudTiming.uploadPresignSeconds) * 1000 }
        let transfers = connectTransfers()
        // Songs prepared ahead never use mobile data, whatever the switch says: their upload waits for Wi-Fi.
        transfers.allowsCellular = settings.useCellular && record.effectiveOrigin != .auto
        activeTransfers.insert(CloudTransfers.taskDescription(jobKey: jobKey, slot: CloudTransfers.uploadSlot))
        // When uploads share the connection, the song somebody waits for goes first and prepared-ahead work last.
        let priority = CloudPriorityLane.transferPriority(for: record, priorityKeys: CloudPriorityLane.priorityJobKeys(jobs))
        transfers.upload(fileURL: file, to: url, jobKey: jobKey, contentType: CloudKeys.contentType(ext: ext), priority: priority)
    }

    /// Uploads with no transfer running (after a relaunch, a failure's wait, an expired link) start again.
    private func restartStalledUploads(_ clients: Clients) {
        guard canStartNewWork else { return }
        let now = dependencies.nowMs()
        // The priority job's upload starts first.
        let uploading = jobs.filter { $0.state == .uploading && $0.isDue(nowMs: now) }
        for record in CloudPriorityLane.ordered(uploading, priorityKeys: CloudPriorityLane.priorityJobKeys(jobs)) {
            let description = CloudTransfers.taskDescription(jobKey: record.jobKey, slot: CloudTransfers.uploadSlot)
            let expired = CloudRetention.uploadURLExpired(expiresAtMs: record.uploadURLExpiresAtMs, nowMs: now)
            guard !activeTransfers.contains(description) || expired else { continue }
            startUpload(record.jobKey, fileURL: nil, clients)
        }
    }

    // MARK: Transfer events

    func handle(_ event: CloudTransferEvent) async {
        // After a background relaunch the session's events can come before the first pass has read the jobs.
        await loadIfNeeded()
        let now = dependencies.nowMs()
        switch event {
        case .uploaded(let jobKey):
            activeTransfers.remove(CloudTransfers.taskDescription(jobKey: jobKey, slot: CloudTransfers.uploadSlot))
            transferProgress[jobKey] = nil
            update(jobKey) { _ = $0.apply(.uploadFinished, nowMs: now) }
            persist()
            requestPump()
        case .uploadFailed(let jobKey, let message, let status):
            activeTransfers.remove(CloudTransfers.taskDescription(jobKey: jobKey, slot: CloudTransfers.uploadSlot))
            transferProgress[jobKey] = nil
            guard job(jobKey)?.state == .uploading else { return }
            if status == 403 || status == 400 {
                // Usually an expired or refused link: sign again on the next pass.
                update(jobKey) { $0.uploadURLExpiresAtMs = 0 }
            }
            fail(jobKey, "Upload: \(message)", code: nil, retryable: true)
            requestPump()
        case .downloaded(let jobKey, let slot, let staged):
            activeTransfers.remove(CloudTransfers.taskDescription(jobKey: jobKey, slot: slot))
            transferProgress[jobKey] = nil
            let task = Task { [weak self] in
                guard let self else { return }
                await self.importInstrumental(jobKey, slot: slot, staged: staged)
            }
            importing[jobKey] = task
            await task.value
            importing[jobKey] = nil
        case .downloadFailed(let jobKey, let slot, let message, let status):
            activeTransfers.remove(CloudTransfers.taskDescription(jobKey: jobKey, slot: slot))
            transferProgress[jobKey] = nil
            guard job(jobKey)?.state == .downloading else { return }
            if status == 404 {
                // The lifecycle (or someone) removed the result before it was fetched: start the job over.
                update(jobKey) { _ = $0.apply(.requeue, nowMs: now) }
                fail(jobKey, "The result was gone from storage; the song will be processed again.", code: nil,
                     retryable: true)
            } else {
                update(jobKey) { _ = $0.apply(.resultsReady, nowMs: now) }
                fail(jobKey, "Download: \(message)", code: nil, retryable: true)
            }
            requestPump()
        }
    }

    // MARK: The priority lane

    /// What became of one job the lane tried to step aside.
    private enum StepAside {
        /// Cancelled in RunPod's queue: back to `uploaded`, held for the priority job.
        case paused
        /// The worker has it (or it ended): it carries on as it was, and the intent is forgotten.
        case notPaused
        /// The cancel may or may not have gone through (the answer never came): the intent stays, polling settles it.
        case unknown
        /// Nothing was cancelled and RunPod can't be asked now: the pass stops.
        case stopPass
    }

    /// A priority job (Sing, or one song sent by hand) that is uploaded and about to go gets the GPU first. The jobs
    /// RunPod holds but the worker has not started are cancelled there — never a running one — go back to `uploaded`
    /// with their upload kept, and are sent again right behind it in the same burst, so only the final job of the burst
    /// asks the worker to stop (`CloudPriorityLane`, `submitReadyBatches`). Nothing is cancelled while the priority job
    /// is still preparing or uploading: the GPU keeps working through the queue until it is really ready to go.
    ///
    /// The order for every job, so a lost answer can't leave a job in two places: write the intent and save it, ask
    /// RunPod for a fresh status (only a job still `IN_QUEUE` goes on), cancel (only a `CANCELLED` answer counts), and
    /// only then move the job back to `uploaded`. Any failure leaves the job `submitted`: a later `CANCELLED` seen by
    /// polling completes the pause (`apply(_:to:_:)`), a job that started carries on.
    private func prioritizeQueue(_ clients: Clients) async {
        let now = dependencies.nowMs()
        endPausesWithoutPriorityJob()
        guard canStartNewWork else { return }
        let priorityKeys = CloudPriorityLane.priorityJobKeys(jobs)
        guard !priorityKeys.isEmpty,
              let priority = CloudPriorityLane.readyPriorityJob(jobs, priorityKeys: priorityKeys, nowMs: now) else { return }
        let candidates = CloudPriorityLane.newestFirst(CloudPriorityLane.pausable(jobs, priorityKeys: priorityKeys))
        guard !candidates.isEmpty else { return }
        // The month's cap would hold the priority job back anyway: cancelling the others for it would cost them their place.
        guard priorityFitsCap(priority, steppingAside: candidates) else { return }

        // The intent first, on disk: from here on a RunPod CANCELLED for these jobs is ours.
        var group: [(jobKey: String, runpodJobId: String)] = []
        for candidate in candidates {
            guard let runpodJobId = candidate.runpodJobId else { continue }
            update(candidate.jobKey) { $0.beginPause(runpodJobId: runpodJobId, by: priority.jobKey, nowMs: now) }
            group.append((candidate.jobKey, runpodJobId))
        }
        guard !group.isEmpty else { return }
        await persistNow()

        var paused: [String] = []
        var stopped = false
        for item in group {
            if stopped {
                // Never asked: forget the intent.
                update(item.jobKey) { $0.abortPause() }
                continue
            }
            guard let current = job(item.jobKey), current.state == .submitted,
                  current.runpodJobId == item.runpodJobId else {
                // It moved on while the others were being cancelled (it started, ended, or the person cancelled it).
                update(item.jobKey) { $0.abortPause() }
                continue
            }
            switch await stepAside(item.jobKey, runpodJobId: item.runpodJobId, by: priority.jobKey, clients) {
            case .paused: paused.append(item.jobKey)
            case .notPaused: break
            case .unknown, .stopPass: stopped = true
            }
        }

        // The worker writes out/<jobKey>/attempt.json when it starts a job: a folder there says the cancel came too
        // late, and the job must look in the bucket for its result before it is sent again.
        if !paused.isEmpty, let listing = try? await clients.objects.list(prefix: "out/", delimiter: "/") {
            let started = Set(listing.commonPrefixes.compactMap(CloudKeys.jobKey(fromOutputKey:)))
            for key in paused {
                update(key) { r in if r.isPaused { r.pausedNeverStarted = !started.contains(key) } }
            }
        }
        await persistNow()
    }

    /// One job of the lane: fresh status, cancel, pause (see `prioritizeQueue`).
    private func stepAside(_ jobKey: String, runpodJobId: String, by priorityKey: String,
                           _ clients: Clients) async -> StepAside {
        let fresh: RunPodJob
        do {
            fresh = try await clients.runpod.status(jobId: runpodJobId)
        } catch RunPodError.jobNotFound {
            update(jobKey) { $0.abortPause() }
            await handleMissingAtRunPod(jobKey, clients)
            return .notPaused
        } catch RunPodError.unauthorized {
            notice = .runpodKeyRefused
            update(jobKey) { $0.abortPause() }
            return .stopPass
        } catch {
            // Offline or a RunPod hiccup: nothing was cancelled, the next pass asks again.
            update(jobKey) { $0.abortPause() }
            return .stopPass
        }
        guard job(jobKey)?.state == .submitted else {
            update(jobKey) { $0.abortPause() }
            return .notPaused
        }
        switch CloudPriorityLane.outcome(afterStatus: fresh) {
        case nil:
            break  // still waiting in the queue: cancel it
        case .cancelledFromQueue?:
            // The cancel already went through (an earlier pass died before it could say so).
            return completePause(jobKey, by: priorityKey)
        case .alreadyStarted?:
            // The worker has it, or it ended: the ordinary handling takes it from here.
            update(jobKey) { $0.abortPause() }
            await apply(fresh, to: jobKey, clients)
            return .notPaused
        case .failed?:
            update(jobKey) { $0.abortPause() }
            return .notPaused
        }
        do {
            let answer = try await clients.runpod.cancel(jobId: runpodJobId)
            guard job(jobKey)?.state == .submitted else {
                update(jobKey) { $0.abortPause() }
                return .notPaused
            }
            switch CloudPriorityLane.outcome(afterCancel: answer) {
            case .cancelledFromQueue:
                return completePause(jobKey, by: priorityKey)
            case .alreadyStarted:
                // Too late: the worker took it. Polling shows it running.
                update(jobKey) { $0.abortPause() }
                return .notPaused
            case .failed:
                return .unknown
            }
        } catch RunPodError.jobNotFound {
            update(jobKey) { $0.abortPause() }
            await handleMissingAtRunPod(jobKey, clients)
            return .notPaused
        } catch RunPodError.unauthorized {
            notice = .runpodKeyRefused
            return .unknown
        } catch {
            // The cancel may have gone through without an answer: the intent stays on disk.
            return .unknown
        }
    }

    /// RunPod cancelled the job while it waited in the queue: it goes back to `uploaded` (its upload kept).
    private func completePause(_ jobKey: String, by priorityKey: String) -> StepAside {
        let now = dependencies.nowMs()
        var done = false
        update(jobKey) { r in done = r.completePause(by: priorityKey, neverStarted: nil, nowMs: now) }
        guard done else {
            update(jobKey) { $0.abortPause() }
            return .notPaused
        }
        return .paused
    }

    /// Whether the priority job still fits what is left of the month once the jobs stepping aside are out of the count.
    private func priorityFitsCap(_ priority: CloudJobRecord, steppingAside candidates: [CloudJobRecord]) -> Bool {
        let price = settings.effectivePricePerSecondMicroUSD
        let monthStart = dependencies.monthStartMs(dependencies.nowMs())
        var committed = CloudBudget.committedMicroUSD(jobs, monthStartMs: monthStart, pricePerSecondMicroUSD: price)
            + settings.removedSpendMicroUSD(monthStartMs: monthStart)
        for candidate in candidates where candidate.isRunningAtRunPod {
            committed -= CloudCost.estimatedSeconds(candidate.plan, quality: candidate.quality) * price
        }
        let estimate = CloudCost.estimatedSeconds(priority.plan, quality: priority.quality) * price
        return CloudBudget.allows(estimateMicroUSD: estimate, capMicroUSD: settings.effectiveMonthlyCapMicroUSD,
                                  spentMicroUSD: max(committed, 0))
    }

    /// Pauses whose priority job is gone (cancelled, failed, removed) end: the jobs are sent with the next batch as
    /// they are. A cancel that was never answered, for a priority job that has started since, is forgotten.
    private func endPausesWithoutPriorityJob() {
        let keys = CloudPriorityLane.pausesToEnd(jobs)
        guard !keys.isEmpty else { return }
        for key in keys {
            update(key) { r in
                if r.state == .uploaded { r.release() } else { r.abortPause() }
            }
        }
        persist()
    }

    /// The priority job went away: the jobs that stepped aside for it are sent as they are, without waiting.
    private func releasePauses(of priorityKey: String) {
        for record in jobs where record.pausedBy == priorityKey {
            update(record.jobKey) { r in
                if r.state == .uploaded { r.release() } else { r.abortPause() }
            }
        }
    }

    // MARK: Submit

    private func submitReadyBatches(_ clients: Clients) async {
        let now = dependencies.nowMs()
        let open = jobs.filter { !$0.state.isFinished }
        let priorityKeys = CloudPriorityLane.priorityJobKeys(jobs)
        var ready: [String] = []
        for (_, members) in Dictionary(grouping: open, by: \.batchId) {
            let uploaded = members.filter { $0.state == .uploaded }
            guard !uploaded.isEmpty else { continue }
            let pendingUploads = members.filter { $0.state == .queued || $0.state == .preparing || $0.state == .uploading }.count
            let firstDone = uploaded.compactMap(\.uploadedAtMs).min()
            if CloudBatchGate.shouldSubmit(uploadsPending: pendingUploads, uploadsDone: uploaded.count,
                                           firstUploadDoneAtMs: firstDone, nowMs: now) {
                ready += uploaded.map(\.jobKey)
            } else {
                // A job sent before (lost at RunPod, a retry) doesn't wait for the rest of its batch, and neither does a
                // song somebody is waiting for (a Sing tap joined a job whose batch is still uploading).
                ready += uploaded.filter { $0.submittedAtMs != nil || priorityKeys.contains($0.jobKey) }.map(\.jobKey)
            }
        }
        // The priority jobs first, then the jobs that stepped aside for them in their old order, then the rest in queue
        // order. Jobs waiting for a priority job that is still getting ready — and new auto jobs behind it — stay for a
        // later pass (`CloudPriorityLane.heldBack`; the hold ends after a few minutes so a Sing job that never gets
        // uploaded can't freeze the queue).
        ready = CloudPriorityLane.submitOrder(ready: ready, jobs: jobs)
        let held = CloudPriorityLane.heldBack(ready: ready, jobs: jobs, nowMs: now)
        if !held.isEmpty { ready.removeAll { held.contains($0) } }
        // The pass is one burst: its last job carries `policy.last_in_batch`, so the worker stops itself after it
        // instead of staying up, idle and billed. Each job waits until the next one is ready (or the pass ends) to go
        // out, since only then is it known whether it is the last (`CloudSubmitBurst`). The priority job and the jobs
        // that stepped aside for it are ONE burst, so only the final one of them asks the worker to stop.
        var burst = CloudSubmitBurst<PendingSubmit>()
        var outOfTime = false
        // Auto jobs accepted in this pass but not yet in the ledger (a job is only reserved once RunPod has taken it).
        var passAutoCount = 0
        var passAutoMicroUSD: Int64 = 0
        for jobKey in ready {
            // A background wake with no time left sends nothing more (a request cut off half-way is wasted).
            guard canStartNewWork else {
                outOfTime = true
                break
            }
            guard let record = job(jobKey), record.state == .uploaded, record.isDue(nowMs: now) else { continue }
            if CloudRetention.inputTooOldToSubmit(uploadedAtMs: record.uploadedAtMs, nowMs: now) {
                update(jobKey) { _ = $0.apply(.requeue, nowMs: now) }
                continue
            }
            let price = settings.effectivePricePerSecondMicroUSD
            let monthStart = dependencies.monthStartMs(now)
            // The held job isn't at RunPod yet, but it will be: count it.
            let committed = CloudBudget.committedMicroUSD(jobs, monthStartMs: monthStart, pricePerSecondMicroUSD: price)
                + settings.removedSpendMicroUSD(monthStartMs: monthStart)
                + (burst.holding?.estimateMicroUSD ?? 0)
            let estimate = CloudCost.estimatedSeconds(record.plan, quality: record.quality) * price
            guard CloudBudget.allows(estimateMicroUSD: estimate, capMicroUSD: settings.effectiveMonthlyCapMicroUSD,
                                     spentMicroUSD: committed) else {
                notice = .capReached
                break  // the job held so far still goes out, as the burst's last
            }
            if notice == .capReached { notice = nil }
            // Songs prepared ahead also stay inside their own budget and today's count (a job already reserved, one that
            // went out before and stepped aside or is sent again, is counted once).
            let needsReservation = record.effectiveOrigin == .auto && record.autoReservedMicroUSD == nil
            if needsReservation {
                var projected = autoLedger
                projected.spentMicroUSD += passAutoMicroUSD
                projected.dayCount += passAutoCount
                guard CloudAutoBudget.allows(estimateMicroUSD: estimate, ledger: projected,
                                             budgetMicroUSD: settings.effectiveAutoBudgetMicroUSD,
                                             dailyCap: settings.autoPrepareDailyCap, committedMicroUSD: committed,
                                             totalCapMicroUSD: settings.effectiveMonthlyCapMicroUSD) else { continue }
            }
            var lyrics: CloudLyricsRequest?
            if record.tasks.contains(.lyrics) {
                let song = dependencies.host.song(id: record.songId)
                let facts: CloudLyricsFacts
                if let song { facts = await dependencies.host.lyricsFacts(for: song) } else { facts = .none }
                lyrics = CloudJobBuilder.lyricsRequest(mode: record.lyricsMode ?? .auto, lines: facts.lines,
                                                       hasLineTimes: facts.hasLineTimes,
                                                       language: record.language ?? facts.language,
                                                       lyricsReferenceDurationMs: facts.referenceDurationMs,
                                                       audioDurationMs: record.durationMs ?? 0)
            }
            let objects = clients.objects
            let presign: CloudPresign = { method, key, seconds in objects.presignedURL(method, key: key, expiresSeconds: seconds) }
            guard let request = CloudJobBuilder.request(for: record, build: dependencies.build, lyrics: lyrics,
                                                        presign: presign) else {
                update(jobKey) { _ = $0.apply(.requeue, nowMs: now) }
                fail(jobKey, "This job lost its upload details; it will be uploaded again.", code: nil, retryable: true)
                continue
            }
            // A job that stepped aside while RunPod's queue still held it never reached the worker: nothing of it is in
            // the bucket, so there is nothing to clear and nothing to read.
            if record.submittedAtMs != nil && record.pausedNeverStarted != true {
                if record.wasPaused {
                    // The cancel may have come after the worker started (or even finished) the job: the bucket decides.
                    // Its result first; a job sent again into a missing input would only be uploaded all over.
                    if await takeManifestIfPresent(jobKey, clients) { continue }
                    guard self.job(jobKey)?.state == .uploaded else { continue }
                }
                // Sent before (a worker error, a lost job, a re-upload, Retry): the earlier run's manifest and guard
                // marker are still in the bucket, and the worker doesn't clear them. Left there, the next listing would
                // read the old error as this run's answer and send the job again and again.
                do {
                    try await clients.objects.delete(key: CloudKeys.manifest(jobKey: jobKey))
                    try await clients.objects.delete(key: CloudKeys.attempt(jobKey: jobKey))
                } catch is CancellationError {
                    return
                } catch {
                    fail(jobKey, "Couldn't clear the earlier attempt from storage; trying again soon.", code: nil,
                         retryable: true)
                    continue
                }
                guard self.job(jobKey)?.state == .uploaded else { continue }
            }
            if needsReservation {
                passAutoCount += 1
                passAutoMicroUSD += estimate
            }
            if let previous = burst.ready(PendingSubmit(jobKey: jobKey, request: request, estimateMicroUSD: estimate)) {
                guard await submit(previous, lastInBatch: false, clients) else { return }
            }
        }
        // The job held for the next one is not the batch's last when time ran out: it stays "uploaded" for the next wake,
        // so the worker is not told to stop itself while more jobs are still to come.
        if let last = burst.end(), !outOfTime {
            await submit(last, lastInBatch: true, clients)
        }
    }

    /// Sends one job of a burst. False when the pass should stop (the key, the Endpoint ID, rate limiting, missing
    /// settings, cancellation); a failure of this job alone carries on with the next.
    @discardableResult
    private func submit(_ pending: PendingSubmit, lastInBatch: Bool, _ clients: Clients) async -> Bool {
        let jobKey = pending.jobKey
        // Cancelled while it waited for the next job to be ready.
        guard job(jobKey)?.state == .uploaded else { return true }
        do {
            let job = try await clients.runpod.run(pending.request.markingLastInBatch(lastInBatch))
            guard self.job(jobKey)?.state == .uploaded else {
                // Cancelled while the request was out: stop it at RunPod too.
                _ = try? await clients.runpod.cancel(jobId: job.id)
                return true
            }
            let sentAt = dependencies.nowMs()
            // A song prepared ahead reserves its estimate in the auto budget the first time RunPod takes it (a job that
            // stepped aside and is sent again keeps its reservation); the real cost replaces it when the result lands.
            let reserves = self.job(jobKey).map { $0.effectiveOrigin == .auto && $0.autoReservedMicroUSD == nil } ?? false
            update(jobKey) { r in
                r.runpodJobId = job.id
                r.lastError = nil
                r.lastErrorCode = nil
                r.nextAttemptAtMs = nil
                // Sending ends any pause: it goes out, with the priority job it stepped aside for.
                r.apply(.submitted, nowMs: sentAt)
                if reserves { r.autoReservedMicroUSD = pending.estimateMicroUSD }
            }
            if reserves { reserveAutoSpend(pending.estimateMicroUSD) }
            // The id is on disk before the next POST (design §7.4).
            await persistNow()
            return true
        } catch let error as RunPodError {
            switch error {
            case .unauthorized:
                notice = .runpodKeyRefused
                return false
            case .endpointNotFound:
                notice = .endpointNotFound
                return false
            case .rateLimited:
                notice = .rateLimited
                return false
            case .notConfigured:
                notice = .notConfigured
                return false
            default:
                // A lost response may still have queued the job; the worker's guard makes a repeat harmless.
                fail(jobKey, error.description, code: nil, retryable: true)
                return true
            }
        } catch is CancellationError {
            return false
        } catch {
            fail(jobKey, CloudRedaction.redact(error.localizedDescription), code: nil, retryable: true)
            return true
        }
    }

    // MARK: Watch RunPod

    private func watchRunPod(_ clients: Clients) async {
        let now = dependencies.nowMs()
        guard jobs.contains(where: { $0.state.isAtRunPod }) else { return }
        // One listing of out/ finds finished (and started) jobs, even after /status has expired.
        if now - lastListAtMs >= CloudTiming.statusPollIntervalMs {
            lastListAtMs = now
            if let listing = try? await clients.objects.list(prefix: "out/", delimiter: "/") {
                let folders = Set(listing.commonPrefixes.compactMap(CloudKeys.jobKey(fromOutputKey:)))
                for record in jobs where record.state.isAtRunPod && folders.contains(record.jobKey) {
                    if await takeManifestIfPresent(record.jobKey, clients) { continue }
                    // attempt.json is there but no manifest yet: the worker has the job (and a cancel we were about to
                    // send, or had sent, came too late: that job is not stepping aside any more).
                    update(record.jobKey) { r in
                        r.apply(.started, nowMs: now)
                        if r.hasPauseIntent { r.abortPause() }
                    }
                }
            }
        }
        // /status for running jobs and the two oldest waiting ones, each at most every `statusPollIntervalMs`. The
        // priority job is always asked after (a Sing tap waits on it), and so is a job whose cancel is unanswered.
        let priorityKeys = CloudPriorityLane.priorityJobKeys(jobs)
        let running = jobs.filter { $0.state == .running }
        // Oldest first; jobs sent in the same instant (one burst) in queue order.
        let waitingInOrder = jobs.enumerated().filter { $0.element.state == .submitted }
            .sorted { lhs, rhs in
                let sentLeft = lhs.element.submittedAtMs ?? 0, sentRight = rhs.element.submittedAtMs ?? 0
                return sentLeft != sentRight ? sentLeft < sentRight : lhs.offset < rhs.offset
            }
            .map(\.element)
        let waiting = Array(waitingInOrder.prefix(2))
            + waitingInOrder.dropFirst(2).filter { priorityKeys.contains($0.jobKey) || $0.hasPauseIntent }
        for record in running + waiting where now - (record.lastPolledAtMs ?? 0) >= CloudTiming.statusPollIntervalMs {
            guard job(record.jobKey)?.state.isAtRunPod == true else { continue }
            guard let jobId = record.runpodJobId else {
                update(record.jobKey) { _ = $0.apply(.resubmit, nowMs: now) }
                continue
            }
            update(record.jobKey) { $0.lastPolledAtMs = now }
            do {
                let status = try await clients.runpod.status(jobId: jobId)
                await apply(status, to: record.jobKey, clients)
            } catch RunPodError.jobNotFound {
                await handleMissingAtRunPod(record.jobKey, clients)
            } catch RunPodError.unauthorized {
                notice = .runpodKeyRefused
                break
            } catch {
                // Offline or a RunPod hiccup: the next pass asks again.
            }
        }
        await checkForPausedEndpoint(clients)
        persist()
    }

    private func apply(_ status: RunPodJob, to jobKey: String, _ clients: Clients) async {
        let now = dependencies.nowMs()
        switch status.typedStatus {
        case .inQueue?, nil:
            break
        case .inProgress?:
            update(jobKey) { r in
                r.apply(.started, nowMs: now)
                // The worker has it: it is not stepping aside for anybody.
                if r.hasPauseIntent { r.abortPause() }
                if let progress = status.progress {
                    r.progressStage = progress.stage
                    r.progressPercent = progress.percent
                }
            }
        case .completed?:
            if let result = status.result, result.jobKey == jobKey {
                await take(result, jobKey, clients)
                return
            }
            let found = await takeManifestIfPresent(jobKey, clients)
            if !found { retryAtRunPod(jobKey, "RunPod finished the job without a result.") }
        case .failed?, .timedOut?, .cancelled?:
            // A CANCELLED for a job this app was stepping aside is the pause, not a failure: the cancel went through (its
            // answer was lost, or the pass that sent it ended first). No attempt is counted and nothing waits; the bucket
            // decides, when the job is sent again, whether the worker ever started it.
            if status.typedStatus == .cancelled, let record = job(jobKey), record.state == .submitted,
               let intent = record.pauseIntentRunpodJobId, intent == record.runpodJobId, let priorityKey = record.pausedBy {
                update(jobKey) { _ = $0.completePause(by: priorityKey, neverStarted: nil, nowMs: now) }
                persist()
                return
            }
            // The manifest in R2 has the details when the worker wrote one.
            if await takeManifestIfPresent(jobKey, clients) { return }
            if let code = status.errorCode {
                handleError(code, message: status.error.map(CloudRedaction.redact), jobKey, clients)
            } else {
                retryAtRunPod(jobKey, "RunPod stopped the job (\(status.status.lowercased())).")
            }
        }
    }

    /// `/status` 404: retention passed or it never existed (design §2.5). R2 decides; a job past its ttl with no
    /// manifest is lost and goes out once more with the same key.
    private func handleMissingAtRunPod(_ jobKey: String, _ clients: Clients) async {
        if await takeManifestIfPresent(jobKey, clients) { return }
        guard let record = job(jobKey), let submitted = record.submittedAtMs else { return }
        let now = dependencies.nowMs()
        guard CloudRetention.isPastTTL(submittedAtMs: submitted, nowMs: now) else { return }
        if record.resubmits < 1 {
            update(jobKey) { r in
                r.resubmits += 1
                r.apply(.resubmit, nowMs: now)
            }
        } else {
            let keys = CloudJobBuilder.objectKeys(for: record)
            update(jobKey) { r in
                r.lastError = "RunPod lost this job twice."
                r.apply(.expired, nowMs: now)
            }
            releasePauses(of: jobKey)
            noteAutoJobEnded(record)
            cleanUpLocal(jobKey)
            await deleteRemote(keys, clients)
        }
    }

    @discardableResult
    private func takeManifestIfPresent(_ jobKey: String, _ clients: Clients) async -> Bool {
        guard let data = try? await clients.objects.get(key: CloudKeys.manifest(jobKey: jobKey)),
              let result = try? CloudJSON.decode(CloudJobResult.self, from: data), result.jobKey == jobKey,
              CloudImportCheck.manifestDescribesUpload(result, uploadedSHA256: job(jobKey)?.sha256) else {
            // Absent, unreadable, or an earlier attempt's (another input): this upload's job goes on.
            return false
        }
        await take(result, jobKey, clients)
        return true
    }

    private func take(_ result: CloudJobResult, _ jobKey: String, _ clients: Clients) async {
        guard let record = job(jobKey), record.state.isAtRunPod || record.state == .uploaded else { return }
        let now = dependencies.nowMs()
        let price = settings.effectivePricePerSecondMicroUSD
        let costBefore = record.costMicroUSD ?? 0
        update(jobKey) { r in
            r.takeResult(result, fallbackPricePerSecondMicroUSD: price, nowMs: now)
            // The run is over; whatever pause the job was in is moot.
            r.clearPause()
        }
        settleAutoReservation(jobKey, costBefore: costBefore)
        if result.hasResults {
            update(jobKey) { r in
                r.lastError = nil
                r.lastErrorCode = nil
                r.apply(.resultsReady, nowMs: now)
            }
            persist()
        } else {
            handleError(result.errorCode ?? .internal, message: result.error?.message, jobKey, clients)
        }
    }

    /// A song prepared ahead reserved its estimate in the auto budget when RunPod took it; what the run really cost
    /// replaces that now (the cost of this run only: a redo adds its own run to the job's total).
    private func settleAutoReservation(_ jobKey: String, costBefore: Int64) {
        guard let record = job(jobKey), let reserved = record.autoReservedMicroUSD else { return }
        let actual = max((record.costMicroUSD ?? 0) - costBefore, 0)
        update(jobKey) { $0.autoReservedMicroUSD = nil }
        settleAutoSpend(reserved: reserved, actual: actual)
    }

    /// A worker error (design §2.3): upload again, send again, or stop.
    private func handleError(_ code: CloudErrorCode, message: String?, _ jobKey: String, _ clients: Clients) {
        let now = dependencies.nowMs()
        let text = code.message
        if code.needsReupload {
            update(jobKey) { _ = $0.apply(.requeue, nowMs: now) }
            fail(jobKey, text, code: code.rawValue, retryable: true)
        } else if code.isRetryable {
            update(jobKey) { _ = $0.apply(.resubmit, nowMs: now) }
            fail(jobKey, text, code: code.rawValue, retryable: true)
        } else {
            fail(jobKey, text, code: code.rawValue, retryable: false)
        }
        persist()
    }

    private func retryAtRunPod(_ jobKey: String, _ message: String) {
        update(jobKey) { _ = $0.apply(.resubmit, nowMs: self.dependencies.nowMs()) }
        fail(jobKey, message, code: nil, retryable: true)
    }

    private func checkForPausedEndpoint(_ clients: Clients) async {
        let now = dependencies.nowMs()
        guard let oldest = jobs.filter({ $0.state == .submitted }).compactMap(\.submittedAtMs).min(),
              now - oldest > CloudTiming.pausedEndpointAfterMs, now - lastHealthAtMs > 5 * 60_000 else {
            if notice == .endpointPaused, !jobs.contains(where: { $0.state == .submitted }) { notice = nil }
            return
        }
        lastHealthAtMs = now
        guard let health = try? await clients.runpod.health() else { return }
        if CloudEndpointWatch.looksPaused(oldestWaitingSinceMs: oldest, nowMs: now, health: health) {
            notice = .endpointPaused
        } else if notice == .endpointPaused {
            notice = nil
        }
    }

    // MARK: Collect and import

    private func collectResults(_ clients: Clients) async {
        let now = dependencies.nowMs()
        for record in jobs where record.state == .resultsReady && record.isDue(nowMs: now) {
            guard canStartNewWork else { return }
            // Songs prepared ahead come down only on an unmetered connection; off Wi-Fi they wait, not fail.
            if record.effectiveOrigin == .auto, !autoMayUseNetwork() { continue }
            await collect(record.jobKey, clients)
        }
    }

    /// Lyrics first (KB-sized, a normal request), so they show even while the instrumental waits for Wi-Fi; then the
    /// instrumental as a background download.
    private func collect(_ jobKey: String, _ clients: Clients) async {
        guard let record = job(jobKey), record.state == .resultsReady else { return }
        guard let song = dependencies.host.song(id: record.songId) else {
            let keys = CloudJobBuilder.objectKeys(for: record)
            fail(jobKey, "This song is no longer in your library.", code: nil, retryable: false)
            await deleteRemote(keys, clients)
            return
        }
        // A streamed song's results belong to the video that was uploaded (design §7.3).
        if let uploaded = record.videoId, let current = await dependencies.host.streamIdentity(for: song),
           current != uploaded {
            let keys = CloudJobBuilder.objectKeys(for: record)
            fail(jobKey, "This song now plays a different YouTube video than the one processed. Process it again.",
                 code: nil, retryable: false)
            await deleteRemote(keys, clients)
            return
        }
        if record.tasks.contains(.lyrics), !record.importedLyrics, let lyricsKey = record.lyricsKey {
            await importLyrics(jobKey, key: lyricsKey, song: song, clients)
        }
        guard let current = job(jobKey), current.state == .resultsReady else { return }
        if let output = current.outputs?[Self.instrumentalSlot], current.tasks.contains(.instrumental),
           !current.importedInstrumental {
            guard output.key.hasPrefix(CloudKeys.outputPrefix(jobKey: jobKey)), !output.key.contains(".."),
                  let text = clients.objects.presignedURL(.get, key: output.key,
                                                          expiresSeconds: CloudTiming.uploadPresignSeconds),
                  let url = URL(string: text) else {
                fail(jobKey, "The result named a file outside its folder.", code: nil, retryable: false)
                return
            }
            update(jobKey) { _ = $0.apply(.downloadStarted, nowMs: self.dependencies.nowMs()) }
            persist()
            let transfers = connectTransfers()
            transfers.allowsCellular = settings.useCellular && current.effectiveOrigin != .auto
            activeTransfers.insert(CloudTransfers.taskDescription(jobKey: jobKey, slot: Self.instrumentalSlot))
            transfers.download(from: url, jobKey: jobKey, slot: Self.instrumentalSlot)
            return
        }
        await finishIfDone(jobKey, clients)
    }

    private func importLyrics(_ jobKey: String, key: String, song: Song, _ clients: Clients) async {
        guard let record = job(jobKey) else { return }
        guard key.hasPrefix(CloudKeys.outputPrefix(jobKey: jobKey)), !key.contains("..") else {
            update(jobKey) { $0.importedLyrics = true }
            return
        }
        do {
            guard let data = try await clients.objects.get(key: key) else {
                update(jobKey) { r in
                    r.importedLyrics = true
                    r.warnings.append("The lyrics file was gone from storage.")
                }
                persist()
                return
            }
            if let summary = record.lyricsFile {
                let bytesOK = summary.bytes.map { $0 == Int64(data.count) } ?? true
                let shaOK = summary.sha256.map { $0.lowercased() == dependencies.inspector.sha256Hex(data) } ?? true
                guard bytesOK && shaOK else {
                    fail(jobKey, "The lyrics file arrived damaged; it will be fetched again.", code: nil, retryable: true)
                    return
                }
            }
            let cloud = try CloudJSON.decode(CloudLyricsDocument.self, from: data)
            let duration = song.duration > 0 ? song.duration : (record.durationMs ?? 0)
            let outcome: CloudLyricsSaveOutcome
            if let doc = CloudLyrics.lyricsDoc(cloud, durationMs: duration, title: song.title, artist: song.displayArtist,
                                               album: song.album) {
                outcome = await dependencies.host.saveLyrics(doc, for: song, replaceUserSynced: record.replaceUserSynced)
            } else {
                outcome = .unusable
            }
            update(jobKey) { r in
                r.importedLyrics = true
                switch outcome {
                case .saved: break
                case .keptBetter: r.warnings.append("Kept the lyrics you already had (they were as good or better).")
                case .keptUserSynced: r.warnings.append("Kept the lyrics you synced yourself.")
                case .unusable: r.warnings.append("The cloud lyrics had no usable timing.")
                }
            }
            persist()
            if outcome == .saved { dependencies.host.lyricsImported(song: song) }
        } catch is CancellationError {
            return
        } catch is DecodingError {
            update(jobKey) { r in
                r.importedLyrics = true
                r.warnings.append("The cloud lyrics file couldn't be read.")
            }
            persist()
        } catch {
            fail(jobKey, "Lyrics: \(CloudRedaction.redact(error.localizedDescription))", code: nil, retryable: true)
        }
    }

    /// Verifies a downloaded instrumental (size, SHA-256, sample count) and moves it into `Stems/` (design §7.5).
    private func importInstrumental(_ jobKey: String, slot: String, staged: URL) async {
        guard slot == Self.instrumentalSlot, let record = job(jobKey), record.state == .downloading,
              let output = record.outputs?[Self.instrumentalSlot] else {
            try? FileManager.default.removeItem(at: staged)
            return
        }
        let inspector = dependencies.inspector
        let now = dependencies.nowMs()
        do {
            let digest = try await Task.detached(priority: .utility) { try inspector.digest(staged) }.value
            guard CloudImportCheck.matches(expectedBytes: output.bytes, expectedSHA256: output.sha256,
                                           actualBytes: digest.bytes, actualSHA256: digest.sha256) else {
                try? FileManager.default.removeItem(at: staged)
                update(jobKey) { _ = $0.apply(.resultsReady, nowMs: now) }
                fail(jobKey, "The downloaded instrumental was damaged; it will be fetched again.", code: nil,
                     retryable: true)
                return
            }
            let frames = try await inspector.frames(staged)
            guard Self.samplesLineUp(record, output: output, decodedFrames: frames) else {
                try? FileManager.default.removeItem(at: staged)
                await redoAsFlacOrFail(jobKey)
                return
            }
            guard job(jobKey)?.state == .downloading else {
                try? FileManager.default.removeItem(at: staged)
                return
            }
            try dependencies.host.installInstrumental(from: staged, songId: record.songId,
                                                      flac: record.outputCodec == .flac)
            update(jobKey) { $0.importedInstrumental = true }
            persist()
            dependencies.host.instrumentalImported(songId: record.songId)
            if let clients = currentClients() { await finishIfDone(jobKey, clients) }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            update(jobKey) { _ = $0.apply(.resultsReady, nowMs: now) }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            fail(jobKey, "Import: \(CloudRedaction.redact(message))", code: nil, retryable: true)
        }
    }

    /// The result's length equals the phone's own decode of the uploaded audio within ±1 AAC frame — both the
    /// worker's count (the manifest) and this phone's decode of the downloaded file (R13's priming check).
    nonisolated static func samplesLineUp(_ record: CloudJobRecord, output: CloudOutputFile, decodedFrames: Int64) -> Bool {
        guard let source = record.decodedFrames, source > 0, let rate = record.sampleRate, rate > 0 else { return true }
        let resultRate = Double(output.sampleRate ?? Int(CloudImportCheck.workerSampleRate))
        if let samples = output.samples,
           !CloudImportCheck.samplesMatch(sourceFrames: source, sourceSampleRate: rate, resultFrames: samples,
                                          resultSampleRate: resultRate) {
            return false
        }
        return CloudImportCheck.samplesMatch(sourceFrames: source, sourceSampleRate: rate, resultFrames: decodedFrames,
                                             resultSampleRate: Double(CloudImportCheck.workerSampleRate))
    }

    /// An AAC result that doesn't line up is asked for once more as FLAC (no encoder delay); a FLAC one that doesn't
    /// line up stops with a message.
    private func redoAsFlacOrFail(_ jobKey: String) async {
        guard let record = job(jobKey) else { return }
        let keys = CloudJobBuilder.objectKeys(for: record)
        let clients = currentClients()
        if record.outputCodec == .aac && !record.flacRedone {
            let now = dependencies.nowMs()
            update(jobKey) { r in
                r.flacRedone = true
                r.outputCodec = .flac
                if r.importedLyrics { r.tasks.removeAll { $0 == .lyrics } }
                r.outputs = nil
                r.lyricsKey = nil
                r.lyricsFile = nil
                r.warnings.append("The AAC instrumental didn't line up with the song; asking for FLAC instead.")
                r.apply(.requeue, nowMs: now)
            }
            persist()
            // The worker deleted the input after its result: the redo uploads again. Old outputs go now.
            if let clients { await deleteRemote(keys, clients) }
            requestPump()
        } else {
            fail(jobKey, "The cloud instrumental doesn't line up with this song, so it wasn't used.", code: nil,
                 retryable: false)
            cleanUpLocal(jobKey)
            if let clients { await deleteRemote(keys, clients) }
        }
    }

    private func finishIfDone(_ jobKey: String, _ clients: Clients) async {
        guard let record = job(jobKey), record.state == .resultsReady || record.state == .downloading,
              record.isFullyImported else { return }
        let keys = CloudJobBuilder.objectKeys(for: record)
        update(jobKey) { _ = $0.apply(.imported, nowMs: self.dependencies.nowMs()) }
        persist()
        cleanUpLocal(jobKey)
        await deleteRemote(keys, clients)
        noteAutoJobEnded(record)
    }

    // MARK: Failures and cleanup

    /// Records a failure: retryable ones wait on the backoff ladder; the rest (and exhausted ones) stop as Failed.
    private func fail(_ jobKey: String, _ message: String, code: String?, retryable: Bool) {
        let now = dependencies.nowMs()
        update(jobKey) { $0.recordFailure(message, code: code, retryable: retryable, nowMs: now) }
        if job(jobKey)?.state == .failed {
            if let record = job(jobKey) {
                // Songs that stepped aside for this one carry on without it.
                releasePauses(of: jobKey)
                noteAutoJobEnded(record)
            }
            cleanUpLocal(jobKey)
            if let clients = currentClients(), let record = job(jobKey) {
                let keys = CloudJobBuilder.objectKeys(for: record)
                Task { await self.deleteRemote(keys, clients) }
            }
        }
        persist()
    }

    private func cleanUpLocal(_ jobKey: String) {
        dependencies.preparer.removeUpload(jobKey: jobKey)
        dependencies.removeStaged(jobKey)
    }

    /// Best effort: the lifecycle rules remove anything left (7 d `in/`, 30 d `out/`).
    private func deleteRemote(_ keys: [String], _ clients: Clients) async {
        for key in keys { try? await clients.objects.delete(key: key) }
    }

    // MARK: Song facts

    /// A local file, a music-library item, or a stream this iPhone can download.
    nonisolated static func hasAudioSource(_ song: Song) -> Bool {
        let uri = song.contentUriString.lowercased()
        if uri.hasPrefix("file:") || uri.hasPrefix("ipod-library:") || !song.path.isEmpty { return true }
        return isStreamed(song)
    }

    nonisolated static func isStreamed(_ song: Song) -> Bool {
        YouTubeSongIdentity.videoId(for: song) != nil || SpotifyPlayableURLResolver.spotifyId(of: song) != nil
    }

    /// AAC-LC files go up as they are; everything else as FLAC (a batch's upload size).
    nonisolated static func estimatedUploadBytes(_ song: Song) -> Int64 {
        let ext = (song.path.isEmpty ? song.contentUriString : song.path).split(separator: ".").last.map { $0.lowercased() } ?? ""
        let aac = !isStreamed(song) && (ext == "m4a" || ext == "mp4") && (song.mimeType?.lowercased().contains("alac") != true)
        guard aac, let bitrate = song.bitrate, bitrate > 0 else {
            return CloudUploadEstimate.bytes(durationMs: song.duration, passthroughBitsPerSecond: nil)
        }
        // Libraries store kbps or bps: anything under 10,000 is kbps.
        let bps = bitrate < 10_000 ? bitrate * 1000 : bitrate
        return CloudUploadEstimate.bytes(durationMs: song.duration, passthroughBitsPerSecond: bps)
    }

    /// Moves `source` to `destination`, replacing it in one step when it exists.
    nonisolated static func moveAtomically(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: source)
        } else {
            try manager.moveItem(at: source, to: destination)
        }
    }
}
