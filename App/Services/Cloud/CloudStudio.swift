import Foundation
import Observation
import PixlModel
import PixlNet

/// Where a batch comes from (the queue's Add menu).
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

/// One batch the person is about to send (the confirm sheet, design §7.3): what goes, what is skipped and why, and
/// the estimate against the month's cap.
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

    var isEmpty: Bool { plans.isEmpty }
}

/// Cloud Studio's orchestrator (design §1, §7): the per-song jobs from "Send" to the imported instrumental and
/// word-timed lyrics. It only sequences I/O; every rule (states, retries, caps, gates, checks) is PixlNet's
/// (`CloudQueuePolicy`, `CloudJobBuilder`), and every side effect goes through `Dependencies`, so AppTests drive it
/// with fakes.
///
/// - Nothing is sent while the consent switch is off, and the cloud is never used automatically or as a fallback:
///   only batches the person confirmed run.
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
            case .off: "Cloud processing is off. Nothing leaves this iPhone until you switch it on."
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
    }

    nonisolated struct Clients: Sendable {
        let runpod: any RunPodJobsAPI
        let objects: any CloudObjectStoring
    }

    static let instrumentalSlot = "instrumental"
    static let maxConcurrentPreparations = 2

    // MARK: Observable state

    let settings: CloudSettings
    /// Every job, oldest first.
    private(set) var jobs: [CloudJobRecord] = []
    private(set) var isLoaded = false
    private(set) var notice: Notice?
    /// Upload or download progress (0…1) of a job's running transfer.
    private(set) var transferProgress: [String: Double] = [:]
    /// The batch waiting on the confirm sheet.
    var pendingBatch: CloudBatchPreview?
    /// The last "Test connection" and selftest.
    private(set) var connectionReport: CloudConnectionReport?
    private(set) var selftestCheck: CloudCheck?
    private(set) var isTesting = false
    private(set) var isPreviewing = false
    /// UI tests: demo jobs, nothing runs.
    let isDemo: Bool

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
    /// The foreground polling interval (tests shorten it).
    @ObservationIgnored var pollInterval: Duration = .seconds(15)

    init(settings: CloudSettings, dependencies: Dependencies, isDemo: Bool = false) {
        self.settings = settings
        self.dependencies = dependencies
        self.isDemo = isDemo
    }

    /// UI tests: the demo's jobs, last test and pending batch (no pass ever runs in the demo).
    func loadDemo(jobs: [CloudJobRecord], report: CloudConnectionReport?, selftest: CloudCheck? = nil,
                  progress: [String: Double], batch: CloudBatchPreview?) {
        guard isDemo else { return }
        self.jobs = jobs
        isLoaded = true
        connectionReport = report
        selftestCheck = selftest
        transferProgress = progress
        pendingBatch = batch
    }

    // MARK: Queries

    func job(_ jobKey: String) -> CloudJobRecord? { jobs.first { $0.jobKey == jobKey } }

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

    /// The month's committed spend (recorded costs plus estimates of jobs at RunPod).
    var committedThisMonthMicroUSD: Int64 {
        let now = dependencies.nowMs()
        return CloudBudget.committedMicroUSD(jobs, monthStartMs: dependencies.monthStartMs(now),
                                             pricePerSecondMicroUSD: settings.pricePerSecondMicroUSD)
    }

    // MARK: Lifecycle

    /// The app became active: catch up at once, then poll while jobs are at RunPod. Nothing at all while the
    /// feature is off (no file read, no session).
    func resume() {
        isActive = true
        guard settings.isEnabled else { return }
        requestPump()
    }

    /// The queue screen opened: show the stored jobs even while the feature is off.
    func loadForDisplay() async {
        await loadIfNeeded()
    }

    /// The app went to the background: stop polling, ask iOS for a refresh while jobs are in flight.
    func didEnterBackground() {
        isActive = false
        pollLoop?.cancel()
        pollLoop = nil
        if hasWorkInFlight { dependencies.background?.scheduleRefresh() }
    }

    /// BGAppRefresh (about 25 s): one pass — the R2 listing, lyrics imports, downloads queued, pending submissions.
    func backgroundRefresh() async {
        await pump()
        await settleImports()
        if hasWorkInFlight { dependencies.background?.scheduleRefresh() }
    }

    /// The system woke the app for the transfer session: take its events, then submit what is ready.
    func transferSessionWake() async {
        // A relaunch for the session has read nothing yet: the stored jobs come first, so the events that arrive as
        // soon as the session exists find their jobs (and a save never writes an empty list over them).
        await loadIfNeeded()
        guard settings.isEnabled || !jobs.isEmpty else { return }
        let transfers = connectTransfers()
        if let session = transfers as? CloudTransfers { await session.waitForBackgroundEvents(timeoutSeconds: 20) }
        let assertion = dependencies.background?.beginAssertion()
        await pump()
        await settleImports()
        assertion?.end()
        if hasWorkInFlight { dependencies.background?.scheduleRefresh() }
    }

    /// Jobs whose next step happens without the person.
    var hasWorkInFlight: Bool {
        jobs.contains { !$0.state.isFinished && $0.state != .queued && $0.state != .preparing }
    }

    // MARK: Person's actions

    /// What sending `songs` would do (the confirm sheet). Selection runs here, off the main actor's hot path: the
    /// lyrics store and the file checks are actor and detached calls.
    /// `onlyMissing` keeps the songs that lack that output (the Add menu's filters); gathering stops once a full
    /// batch of such songs is found, so a large library isn't read end to end.
    func preview(songs: [Song], title: String, onlyMissing: CloudTask? = nil,
                 replaceUserSynced: Bool = false) async -> CloudBatchPreview {
        isPreviewing = true
        defer { isPreviewing = false }
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
        let selection = CloudSelector.select(facts, options: options)
        let skips = selection.skipCounts.map { CloudBatchPreview.Skip(reason: $0.reason, count: $0.count) }
        let estimate = CloudBatchEstimate.make(plans: selection.plans, uploadBytes: uploadBytes, quality: settings.quality,
                                               pricePerSecondMicroUSD: settings.pricePerSecondMicroUSD,
                                               committedMicroUSD: committedThisMonthMicroUSD,
                                               capMicroUSD: settings.monthlyCapMicroUSD)
        return CloudBatchPreview(id: dependencies.newJobKey(), songs: selection.plans.compactMap { byId[$0.songId] },
                                 plans: selection.plans, skipped: skips, estimate: estimate,
                                 replaceUserSynced: replaceUserSynced, title: title)
    }

    /// Prepares the confirm sheet for `songs` (a playlist's ⋯, the song sheet).
    func requestBatch(songs: [Song], title: String) async {
        pendingBatch = await preview(songs: songs, title: title)
    }

    /// Prepares the confirm sheet for one of the queue's Add choices.
    func requestBatch(_ kind: CloudBatchKind) async {
        let host = dependencies.host
        switch kind {
        case .current:
            guard let song = host.currentSong else {
                pendingBatch = nil
                notice = nil
                return
            }
            pendingBatch = await preview(songs: [song], title: kind.title)
        case .missingLyrics:
            pendingBatch = await preview(songs: host.librarySongs, title: kind.title, onlyMissing: .lyrics)
        case .missingInstrumental:
            pendingBatch = await preview(songs: host.librarySongs, title: kind.title, onlyMissing: .instrumental)
        }
    }

    /// The person confirmed the batch: one job per song, then everything runs on its own.
    func send(_ preview: CloudBatchPreview) async {
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
            jobs.append(record)
        }
        if pendingBatch?.id == preview.id { pendingBatch = nil }
        persist()
        // A person-started batch keeps preparing in the background (continued processing, design §7.4).
        dependencies.background?.beginPreparing(count: preview.plans.count)
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
            try? await clients.runpod.cancel(jobId: id)
        }
        update(jobKey) { _ = $0.apply(.cancelled, nowMs: self.dependencies.nowMs()) }
        persist()
        cleanUpLocal(jobKey)
        if let clients { await deleteRemote(keys, clients) }
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
        persist()
        requestPump()
    }

    /// Removes a finished job from the list.
    func remove(_ jobKey: String) {
        guard let record = job(jobKey), record.state.isFinished else { return }
        jobs.removeAll { $0.jobKey == jobKey }
        persist()
    }

    /// Removes every imported job.
    func clearFinished() {
        jobs.removeAll { $0.state == .imported }
        persist()
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
        if settings.keysMissing {
            notice = .keysMissing
            return
        }
        guard let clients = currentClients() else {
            notice = .notConfigured
            return
        }
        if notice == .off || notice == .notConfigured || notice == .keysMissing || notice == .rateLimited { notice = nil }
        _ = connectTransfers()
        await reconcileTransfers()
        startPreparations()
        restartStalledUploads(clients)
        await submitReadyBatches(clients)
        await watchRunPod(clients)
        await collectResults(clients)
        // Continued processing lasts while songs are being prepared or are due to be; a song waiting out a retry
        // (up to an hour) doesn't hold the system's progress UI open.
        let now = dependencies.nowMs()
        let toPrepare = jobs.filter { $0.state == .preparing || ($0.state == .queued && $0.isDue(nowMs: now)) }.count
        if toPrepare == 0 {
            dependencies.background?.endPreparing()
        } else {
            dependencies.background?.updatePreparing(remaining: toPrepare)
        }
    }

    private func startPollLoopIfNeeded() {
        guard isActive, pollLoop == nil, needsPolling, settings.isEnabled, !isDemo else { return }
        let interval = pollInterval
        pollLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, self.isActive, self.needsPolling else { break }
                await self.pump()
            }
            self?.pollLoop = nil
        }
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
        // Jobs added while the file was being read (none in practice) stay after the stored ones.
        jobs = loaded + jobs.filter { added in !loaded.contains { $0.jobKey == added.jobKey } }
        isLoaded = true
    }

    private func prune() {
        let now = dependencies.nowMs()
        let before = jobs.count
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
        let now = dependencies.nowMs()
        for record in jobs where record.state == .queued && record.isDue(nowMs: now) {
            guard preparing.count < Self.maxConcurrentPreparations else { break }
            guard preparing[record.jobKey] == nil else { continue }
            let jobKey = record.jobKey
            update(jobKey) { _ = $0.apply(.prepareStarted, nowMs: now) }
            preparing[jobKey] = Task { [weak self] in
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
        do {
            let source = try await dependencies.host.audioSource(for: song)
            try Task.checkCancellation()
            var identity: String?
            if record.isStreamed { identity = await dependencies.host.streamIdentity(for: song) }
            // A streamed song's download (YouTube's DASH AAC) always goes up decoded as FLAC (design §7.3): the worker
            // then sees exactly the samples this phone plays, whatever priming the download's container declares.
            let prepared = try await dependencies.preparer.prepare(source: source, jobKey: jobKey,
                                                                   forceDecode: record.isStreamed)
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
        transfers.allowsCellular = settings.useCellular
        activeTransfers.insert(CloudTransfers.taskDescription(jobKey: jobKey, slot: CloudTransfers.uploadSlot))
        transfers.upload(fileURL: file, to: url, jobKey: jobKey, contentType: CloudKeys.contentType(ext: ext))
    }

    /// Uploads with no transfer running (after a relaunch, a failure's wait, an expired link) start again.
    private func restartStalledUploads(_ clients: Clients) {
        let now = dependencies.nowMs()
        for record in jobs where record.state == .uploading && record.isDue(nowMs: now) {
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

    // MARK: Submit

    private func submitReadyBatches(_ clients: Clients) async {
        let now = dependencies.nowMs()
        let open = jobs.filter { !$0.state.isFinished }
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
                // A job sent before (lost at RunPod, a retry) doesn't wait for the rest of its batch.
                ready += uploaded.filter { $0.submittedAtMs != nil }.map(\.jobKey)
            }
        }
        var order: [String: Int] = [:]
        for (index, record) in jobs.enumerated() where order[record.jobKey] == nil { order[record.jobKey] = index }
        ready.sort { (order[$0] ?? 0) < (order[$1] ?? 0) }
        for jobKey in ready {
            guard let record = job(jobKey), record.state == .uploaded, record.isDue(nowMs: now) else { continue }
            if CloudRetention.inputTooOldToSubmit(uploadedAtMs: record.uploadedAtMs, nowMs: now) {
                update(jobKey) { _ = $0.apply(.requeue, nowMs: now) }
                continue
            }
            let price = settings.pricePerSecondMicroUSD
            let committed = CloudBudget.committedMicroUSD(jobs, monthStartMs: dependencies.monthStartMs(now),
                                                          pricePerSecondMicroUSD: price)
            let estimate = CloudCost.estimatedSeconds(record.plan, quality: record.quality) * price
            guard CloudBudget.allows(estimateMicroUSD: estimate, capMicroUSD: settings.monthlyCapMicroUSD,
                                     spentMicroUSD: committed) else {
                notice = .capReached
                return
            }
            if notice == .capReached { notice = nil }
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
            if record.submittedAtMs != nil {
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
            do {
                let job = try await clients.runpod.run(request)
                guard self.job(jobKey)?.state == .uploaded else {
                    // Cancelled while the request was out: stop it at RunPod too.
                    try? await clients.runpod.cancel(jobId: job.id)
                    continue
                }
                let sentAt = dependencies.nowMs()
                update(jobKey) { r in
                    r.runpodJobId = job.id
                    r.lastError = nil
                    r.lastErrorCode = nil
                    r.nextAttemptAtMs = nil
                    r.apply(.submitted, nowMs: sentAt)
                }
                // The id is on disk before the next POST (design §7.4).
                await persistNow()
            } catch let error as RunPodError {
                switch error {
                case .unauthorized:
                    notice = .runpodKeyRefused
                    return
                case .endpointNotFound:
                    notice = .endpointNotFound
                    return
                case .rateLimited:
                    notice = .rateLimited
                    return
                case .notConfigured:
                    notice = .notConfigured
                    return
                default:
                    // A lost response may still have queued the job; the worker's guard makes a repeat harmless.
                    fail(jobKey, error.description, code: nil, retryable: true)
                }
            } catch is CancellationError {
                return
            } catch {
                fail(jobKey, CloudRedaction.redact(error.localizedDescription), code: nil, retryable: true)
            }
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
                    // attempt.json is there but no manifest yet: the worker has the job.
                    update(record.jobKey) { _ = $0.apply(.started, nowMs: now) }
                }
            }
        }
        // /status for running jobs and the two oldest waiting ones, each at most every 15 s.
        let running = jobs.filter { $0.state == .running }
        let waiting = jobs.filter { $0.state == .submitted }
            .sorted { ($0.submittedAtMs ?? 0) < ($1.submittedAtMs ?? 0) }
            .prefix(2)
        for record in running + Array(waiting) where now - (record.lastPolledAtMs ?? 0) >= CloudTiming.statusPollIntervalMs {
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
        let price = settings.pricePerSecondMicroUSD
        update(jobKey) { $0.takeResult(result, fallbackPricePerSecondMicroUSD: price, nowMs: now) }
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
            transfers.allowsCellular = settings.useCellular
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
    }

    // MARK: Failures and cleanup

    /// Records a failure: retryable ones wait on the backoff ladder; the rest (and exhausted ones) stop as Failed.
    private func fail(_ jobKey: String, _ message: String, code: String?, retryable: Bool) {
        let now = dependencies.nowMs()
        update(jobKey) { $0.recordFailure(message, code: code, retryable: retryable, nowMs: now) }
        if job(jobKey)?.state == .failed {
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

    /// AAC-LC files go up as they are; everything else as FLAC (the confirm sheet's upload size).
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
