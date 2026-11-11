import Foundation
import Observation
import PixlModel
import PixlNet

/// The cloud side of Spatial audio (`SpatialLibrary`; cloud audio spec of 2026-11-10, sections 6.1, 6.2 and 6.4):
/// the local store of verified renders, the shared library in R2, the jobs that fill it, the caps and the background
/// queue. `SpatialLibraryFactory` builds it; the Spatial audio model and the player use it through the protocol.
///
/// - Cloud renders are on when Cloud Studio's own "Process songs in the cloud" (the master) AND `spatial.cloud` are.
///   With either off nothing leaves or reaches the phone: `request` answers `ready` for a render already stored and
///   `none` otherwise.
/// - A request runs spec 6.2 as one Cloud Studio job of the library kind (`CloudStudio.enqueueLibraryRender`): the
///   local store, then the shared library (a signed GET of the manifest; a hit is only downloaded), then a GPU job for
///   what is missing. Cloud Studio does the I/O; this object follows its records and says where each rendition stands
///   (`CloudLibraryStatus`), in events.
/// - A failed rendition is tried again only after its backoff (10 minutes, an hour, a day; `CloudLibraryRetryBook`,
///   kept across launches).
/// - The store keeps `cloudAudio.storageMB`; the least recently played renders go first (`markPlayed`).
/// - While a job for the playing song is under way, Cloud Studio is asked to look every few seconds, also while
///   PixlAudio plays in the background, so a render can land while its song still plays.
///
/// Main-actor isolated (it follows Cloud Studio, which is); every file operation is the store's, off the main actor.
/// Lookups answer from memory.
@MainActor
final class SpatialCloudLibrary: SpatialLibrary, CloudRenderInstalling {
    /// Where the retry ladder is kept (`UserDefaults`, JSON).
    nonisolated static let retryBookKey = "cloud_audio_retry_book"
    /// How often Cloud Studio is asked to look while a job of the playing song is under way.
    static let followInterval: Duration = .seconds(5)
    /// Only failures this recent are counted (older records were counted when they happened).
    static let bookingWindowMs: Int64 = 2 * 86_400_000

    private let cloud: CloudStudio
    private let store: CloudAudioStore
    private let defaults: UserDefaults
    private let hub = SpatialEventHub<SpatialLibraryEvent>()
    /// The settings in force (spec 6.1).
    private(set) var settings: CloudAudioSettings
    /// The background queue (spec 6.4); set by the factory.
    var ahead: CloudAudioPrepareAhead?

    private var index: [RenditionKey: CloudAudioStore.Item] = [:]
    private var isLoaded = false
    private var loading: Task<Void, Never>?
    private var retry: CloudLibraryRetryBook
    /// The status last sent for each rendition anything is known about.
    private var reported: [RenditionKey: RenditionStatus] = [:]
    private var lastUsage: CloudAudioUsage?
    private var following: Task<Void, Never>?
    private var started = false

    init(cloud: CloudStudio, store: CloudAudioStore, defaults: UserDefaults, settings: CloudAudioSettings) {
        self.cloud = cloud
        self.store = store
        self.defaults = defaults
        self.settings = settings
        retry = defaults.data(forKey: Self.retryBookKey)
            .flatMap { try? JSONDecoder().decode(CloudLibraryRetryBook.self, from: $0) } ?? CloudLibraryRetryBook()
    }

    /// Reads the store's index (off the main actor), follows Cloud Studio's jobs and the network. Called once, by the
    /// factory, while the app is put together: nothing here waits for it.
    func start() {
        guard !started else { return }
        started = true
        pushCaps()
        loading = Task { [weak self] in await self?.loadIndex() }
        observeJobs()
        cloud.deviceConditions?.addNetworkObserver { [weak self] in self?.networkChanged() }
        if cloudRendersOn { cloud.deviceConditions?.start() }
    }

    /// Both switches: Cloud Studio's own (the master) and `spatial.cloud` (spec 6.1 "Two switches").
    var cloudRendersOn: Bool { settings.cloud && cloud.settings.isEnabled }

    // MARK: SpatialLibrary

    func apply(_ settings: CloudAudioSettings) async {
        let old = self.settings
        self.settings = settings
        pushCaps()
        if cloudRendersOn { cloud.deviceConditions?.start() }
        if old.cloud, !settings.cloud {
            // On the phone only from now on: nothing more leaves or reaches it (spec 6.1, "Off = on-device only").
            await cloud.cancelLibraryJobs { _ in true }
        } else if !settings.prepareAhead || settings.profile != old.profile {
            // The background queue prepares the selected profile only: its songs the worker doesn't have yet stop.
            let selected = settings.prepareAhead ? settings.profile.profile : nil
            await cloud.cancelLibraryJobs { record in
                guard record.isPreparedAhead, record.state.isBeforeSubmit || record.state == .submitted else { return false }
                guard let selected else { return true }
                return record.library?.profiles.contains(selected.rawValue) != true
            }
        }
        if settings.storageMB < old.storageMB { await evictIfNeeded(keeping: []) }
        // A higher cap, a new daily count or the switch back on: what waited for them may go now.
        if settings.monthlyCapMicroUSD != old.monthlyCapMicroUSD || settings.dailyAhead != old.dailyAhead
            || (settings.cloud && !old.cloud) {
            cloud.requestPump()
        }
        refreshStatuses()
        sendUsageIfChanged()
        ahead?.apply(settings, old: old)
    }

    func localRendition(_ key: RenditionKey) async -> LocalRendition? {
        await ensureLoaded()
        return index[key]?.rendition
    }

    func localRenditions(videoId: String) async -> [LocalRendition] {
        await ensureLoaded()
        return SpatialProfile.allCases.compactMap { index[RenditionKey(videoId: videoId, profile: $0)]?.rendition }
    }

    func status(_ key: RenditionKey) async -> RenditionStatus {
        await ensureLoaded()
        return currentStatus(key, networkFacts())
    }

    func request(_ request: RenditionRequest) async -> RenditionStatus {
        await ensureLoaded()
        // A failure that just happened counts before the backoff is asked about.
        bookFailures()
        let key = request.key
        if index[key] != nil { return .ready }
        guard cloudRendersOn, CloudLibrary.isValidVideoId(key.videoId) else { return .none }
        let playing = request.reason == .playing
        if CloudLibraryStatus.pendingJob(for: key, in: cloud.jobs) == nil {
            // Waiting out a failure's backoff: nothing changes until it is over.
            guard retry.mayTry(key, nowMs: cloud.nowMs) else { return currentStatus(key, networkFacts()) }
            await cloud.enqueueLibraryRender(song: request.song, videoId: key.videoId, profile: key.profile, ahead: !playing)
        } else if playing {
            // On its way already (the background queue's): it is the playing song's from now on.
            await cloud.enqueueLibraryRender(song: request.song, videoId: key.videoId, profile: key.profile, ahead: false)
        }
        startFollowing()
        let status = currentStatus(key, networkFacts())
        report(key, status)
        return status
    }

    func markPlayed(_ key: RenditionKey) async {
        await ensureLoaded()
        guard var item = index[key] else { return }
        let now = cloud.nowMs
        item.lastPlayedMs = now
        index[key] = item
        await store.markPlayed(key, nowMs: now)
    }

    func usage() async -> CloudAudioUsage {
        await ensureLoaded()
        return currentUsage()
    }

    func removeAll() async -> CloudAudioUsage {
        await ensureLoaded()
        let removed = await store.removeAll()
        let keys = Set(removed).union(index.keys)
        index.removeAll()
        for key in keys.sorted(by: { $0.description < $1.description }) { hub.send(.renditionRemoved(key)) }
        refreshStatuses()
        let usage = currentUsage()
        lastUsage = usage
        hub.send(.usageChanged(usage))
        return usage
    }

    func events() async -> AsyncStream<SpatialLibraryEvent> { hub.stream() }

    // MARK: CloudRenderInstalling (Cloud Studio hands over verified renders)

    func hasRender(_ key: RenditionKey) -> Bool { index[key] != nil }

    func installRender(staged: URL, manifest: CloudLibraryManifest) async throws {
        await ensureLoaded()
        let item = try await store.install(staged: staged, manifest: manifest, nowMs: cloud.nowMs)
        let key = item.rendition.key
        index[key] = item
        retry.clear(key)
        saveRetry()
        hub.send(.renditionReady(item.rendition))
        report(key, .ready)
        await evictIfNeeded(keeping: [key])
        sendUsageIfChanged()
    }

    // MARK: The background queue

    /// A rendition the background queue may ask for: not on the phone, nothing on its way, not waiting out a failure.
    func wantsAhead(_ key: RenditionKey) async -> Bool {
        await ensureLoaded()
        guard index[key] == nil, CloudLibraryStatus.pendingJob(for: key, in: cloud.jobs) == nil else { return false }
        return retry.mayTry(key, nowMs: cloud.nowMs)
    }

    // MARK: Following Cloud Studio

    private func loadIndex() async {
        let items = await store.load()
        var map: [RenditionKey: CloudAudioStore.Item] = [:]
        for item in items { map[item.rendition.key] = item }
        index = map
        isLoaded = true
        refreshStatuses()
        await evictIfNeeded(keeping: [])
        sendUsageIfChanged()
    }

    private func ensureLoaded() async {
        guard !isLoaded else { return }
        await loading?.value
    }

    /// The caps and the daily count live in Spatial audio's settings; Cloud Studio applies them to library jobs.
    private func pushCaps() {
        cloud.libraryMonthlyCapMicroUSD = settings.monthlyCapMicroUSD
        cloud.libraryDailyAhead = settings.dailyAhead
    }

    private func observeJobs() {
        withObservationTracking {
            _ = cloud.jobs
        } onChange: { [weak self] in
            Task { @MainActor in self?.jobsChanged() }
        }
    }

    private func jobsChanged() {
        observeJobs()
        bookFailures()
        refreshStatuses()
        sendUsageIfChanged()
        startFollowing()
        ahead?.libraryJobsChanged()
    }

    private func networkChanged() {
        refreshStatuses()
        // A render that waited for a network it may use starts now.
        if cloud.jobs.contains(where: { $0.isLibraryJob && $0.state == .queued }) { cloud.requestPump() }
        ahead?.networkChanged()
    }

    /// The network facts a status needs, read once per pass: whether the playing song's jobs may use the network there
    /// is, and whether the background queue's may.
    private func networkFacts() -> (playing: Bool, ahead: Bool) {
        (cloud.libraryMayUseNetwork(ahead: false), cloud.libraryMayUseNetwork(ahead: true))
    }

    private func currentStatus(_ key: RenditionKey, _ network: (playing: Bool, ahead: Bool),
                               job: CloudJobRecord?? = nil) -> RenditionStatus {
        let record = job ?? CloudLibraryStatus.latestJob(for: key, in: cloud.jobs)
        let allowed = record?.isPreparedAhead == true ? network.ahead : network.playing
        return CloudLibraryStatus.status(for: key, isLocal: index[key] != nil, job: record, networkAllowed: allowed,
                                         retry: retry.entry(for: key), nowMs: cloud.nowMs)
    }

    private func report(_ key: RenditionKey, _ status: RenditionStatus) {
        guard reported[key] != status else { return }
        reported[key] = status
        hub.send(.statusChanged(key, status))
    }

    /// Sends the status of every rendition anything is known about whose status moved: those of library jobs, those
    /// reported before, those in the store.
    private func refreshStatuses() {
        guard isLoaded else { return }
        let network = networkFacts()
        // The latest library job per rendition, in one pass over the list (oldest first).
        var latest: [RenditionKey: CloudJobRecord] = [:]
        for record in cloud.jobs where record.isLibraryJob && record.state != .cancelled {
            for key in record.library?.keys ?? [] { latest[key] = record }
        }
        var keys = Set(reported.keys).union(latest.keys)
        keys.formUnion(index.keys)
        for key in keys {
            let status = currentStatus(key, network, job: .some(latest[key]))
            report(key, status)
            // Nothing known about it any more: forget it (the map stays small).
            if status == .none, latest[key] == nil { reported[key] = nil }
        }
    }

    /// Counts each failed library job once in the retry ladder (a job that failed, a render that was not made or did
    /// not pass the phone's checks).
    private func bookFailures() {
        let now = cloud.nowMs
        var changed = false
        for record in cloud.jobs where record.isLibraryJob && record.state != .cancelled {
            guard now - (record.updatedAtMs ?? record.createdAtMs) < Self.bookingWindowMs, let info = record.library else {
                continue
            }
            let jobFailed = record.state == .failed || record.state == .expired
            for key in info.keys where jobFailed || info.didFail(key.profile) {
                if retry.recordFailure(key, jobKey: record.jobKey, nowMs: now) { changed = true }
            }
        }
        if changed {
            retry.prune(nowMs: now)
            saveRetry()
        }
    }

    private func saveRetry() {
        if let data = try? JSONEncoder().encode(retry) { defaults.set(data, forKey: Self.retryBookKey) }
    }

    /// While a job of the playing song is under way, Cloud Studio looks every few seconds (its own polling stops in the
    /// background, where music plays on).
    private func startFollowing() {
        guard following == nil, hasActiveLibraryWork else { return }
        following = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.followInterval)
                guard let self, !Task.isCancelled, self.hasActiveLibraryWork, self.cloud.settings.isEnabled else { break }
                await self.cloud.pump()
            }
            self?.following = nil
        }
    }

    private var hasActiveLibraryWork: Bool {
        cloud.jobs.contains { record in
            guard record.isLibraryJob, !record.isPreparedAhead, record.library?.heldByCap != true else { return false }
            switch record.state {
            case .preparing, .uploading, .uploaded, .submitted, .running, .resultsReady, .downloading: return true
            case .queued, .imported, .failed, .cancelled, .expired: return false
            }
        }
    }

    // MARK: The store

    private func evictIfNeeded(keeping: Set<RenditionKey>) async {
        guard isLoaded else { return }
        let removed = await store.evict(budgetBytes: settings.storageBytes, keeping: keeping)
        guard !removed.isEmpty else { return }
        for key in removed {
            index[key] = nil
            hub.send(.renditionRemoved(key))
        }
        refreshStatuses()
        sendUsageIfChanged()
    }

    private func currentUsage() -> CloudAudioUsage {
        let stored = CloudAudioStorePolicy.usage(index.values.map(\.entry))
        let ledger = cloud.libraryLedgerNow
        return CloudAudioUsage(songsReady: stored.songs, bytes: stored.bytes,
                               spentThisMonthMicroUSD: ledger.spentMicroUSD, sentToday: ledger.dayCount)
    }

    private func sendUsageIfChanged() {
        guard isLoaded else { return }
        let usage = currentUsage()
        guard usage != lastUsage else { return }
        lastUsage = usage
        hub.send(.usageChanged(usage))
    }
}
