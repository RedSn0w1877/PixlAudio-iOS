import Foundation
import Observation
import PixlAudioCore
import PixlFoundation
import PixlLyrics
import PixlModel
import PixlNet

/// TAIS Studio — the "Remaster Song" jobs (Android `TaisStudioWorker`, `StemSeparatorWorker`,
/// `BsRoformerRenderWorker` on WorkManager): word-by-word lyric sync, the on-device instrumental and the cloud
/// BS-RoFormer render. Jobs run one at a time in a single lane (Android shares one process-wide lane between lyric
/// sync and separation), each reporting `(percent, detail)` for `TaisStudioProgressCard`; a run the person started
/// keeps going in the background through `TaisBackgroundRun` (the system's continued-processing Live Activity,
/// cancellable there) and any job can be cancelled from the card. Unattended jobs (`AutomaticStudioRunner`) never
/// start, show in or keep alive that background run, and give way to anything the person starts (Android cancels
/// `AUTO_STUDIO_WORK_TAG` work while manual work is present).
@MainActor
@Observable
final class TaisStudio {
    nonisolated enum JobKind: String, Sendable, Hashable, CaseIterable {
        case instrumental
        case lyrics
        case roformer
    }

    nonisolated struct JobState: Equatable, Sendable {
        nonisolated enum Phase: Equatable, Sendable {
            case queued
            case running
            /// Finished; `updated` is false for a skip ("already word-synced", "kept your timing").
            case succeeded(updated: Bool)
            case failed(String)
            case cancelled
        }

        var phase: Phase
        var percent: Int
        var detail: String?
        /// No meaningful percentage yet (waiting, downloading, connecting).
        var indeterminate: Bool
        /// Started but queued behind other heavy work (`HeavyJobGovernor`): Active jobs shows it as waiting.
        var waiting = false

        var isActive: Bool { phase == .queued || phase == .running }
    }

    nonisolated struct JobKey: Hashable, Sendable {
        let kind: JobKind
        let songId: String
    }

    /// The latest state of every job started this session (finished ones stay, like WorkManager's history).
    private(set) var jobs: [JobKey: JobState] = [:]
    /// Bumped whenever an instrumental lands on disk (the instrumental controller and the lyrics screen re-check).
    private(set) var instrumentalRevision = 0
    /// Bumped whenever a lyric sync saved new lyrics.
    private(set) var lyricsRevision = 0

    @ObservationIgnored let models: ModelManager
    @ObservationIgnored private let dependencies: Dependencies?
    @ObservationIgnored private let aligner = Wav2Vec2Aligner()
    @ObservationIgnored private let separator = MdxStemSeparator()
    @ObservationIgnored private let background = TaisBackgroundRun()
    @ObservationIgnored private var pending: [Job] = []
    @ObservationIgnored private var memoryObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var running: (key: JobKey, unattended: Bool, task: Task<Void, Never>)?

    /// What the jobs need from the rest of the app. nil = UI tests (states are set by the demo).
    struct Dependencies {
        let settings: SettingsStore
        let lyricsService: LyricsService?
        let lyricsController: LyricsController
        /// A URL AVFoundation can decode for the song — a local file, a library item, or a finished download.
        let audioSource: (Song) async throws -> URL
    }

    private struct Job {
        let key: JobKey
        let song: Song
        let overrideUser: Bool
        let forceResync: Bool
        /// Started by `AutomaticStudioRunner`, not by the person.
        var unattended: Bool
    }

    nonisolated struct JobFailure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    init(models: ModelManager, dependencies: Dependencies?) {
        self.models = models
        self.dependencies = dependencies
        background.onExpired = { [weak self] in self?.cancelAll() }
        // By name, like the other memory-warning observers (UIApplication's constant is main-actor).
        memoryObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.releaseModelsIfIdle() } }
    }

    func state(_ kind: JobKind, songId: String) -> JobState? { jobs[JobKey(kind: kind, songId: songId)] }

    /// UI-test demo data.
    func setDemoState(_ state: JobState?, kind: JobKind, songId: String) {
        jobs[JobKey(kind: kind, songId: songId)] = state
    }

    // MARK: Starting and cancelling

    /// Enqueues a job (`ExistingWorkPolicy.KEEP`: a job already queued or running for that song is kept).
    ///
    /// `unattended` jobs come from `AutomaticStudioRunner`: they run only in the foreground lane, with no system
    /// progress UI. A job the person starts cancels any unattended one first, and asking for the song an unattended
    /// job is already working on makes that job the person's own.
    func start(_ kind: JobKind, song: Song, overrideUser: Bool = false, forceResync: Bool = true,
               unattended: Bool = false) {
        let key = JobKey(kind: kind, songId: song.id)
        if jobs[key]?.isActive == true {
            if !unattended { adopt(key, song: song) }
            return
        }
        let waiting = kind == .lyrics ? "Waiting for the lyric sync engine…" : "Queued…"
        jobs[key] = JobState(phase: .queued, percent: 0, detail: waiting, indeterminate: true)
        guard dependencies != nil else { return }
        if !unattended { cancelUnattended() }
        pending.append(Job(key: key, song: song, overrideUser: overrideUser, forceResync: forceResync,
                           unattended: unattended))
        if !unattended { background.begin(title: "Remaster Song", subtitle: "\(Self.title(kind)) · \(song.title)") }
        runNextIfIdle()
    }

    /// Whether this song's active job was started by `AutomaticStudioRunner` and nobody has asked for it since.
    func isUnattended(_ kind: JobKind, songId: String) -> Bool {
        let key = JobKey(kind: kind, songId: songId)
        if let running, running.key == key { return running.unattended }
        return pending.first { $0.key == key }?.unattended ?? false
    }

    /// The person asked for a song an unattended job already has: it becomes theirs (system progress UI, keeps going
    /// in the background, no longer cancelled by the automatic runner).
    private func adopt(_ key: JobKey, song: Song) {
        if let index = pending.firstIndex(where: { $0.key == key && $0.unattended }) {
            pending[index].unattended = false
        } else if let current = running, current.key == key, current.unattended {
            running = (current.key, false, current.task)
        } else {
            return
        }
        background.begin(title: "Remaster Song", subtitle: "\(Self.title(key.kind)) · \(song.title)")
        if let state = jobs[key] {
            background.update(subtitle: state.detail ?? Self.title(key.kind), fraction: Double(state.percent) / 100)
        }
    }

    /// Manual work comes first: unattended jobs stop (the runner retries them later).
    private func cancelUnattended() {
        for job in pending where job.unattended {
            jobs[job.key] = JobState(phase: .cancelled, percent: 0, detail: nil, indeterminate: false)
        }
        pending.removeAll { $0.unattended }
        if let running, running.unattended { running.task.cancel() }
    }

    /// The continued-processing run covers only the jobs the person started: it ends once none of them is queued or
    /// running, even while an unattended job carries on in the lane.
    private func endBackgroundRunIfNoAttendedWork(success: Bool) {
        let attended = pending.contains { !$0.unattended } || running?.unattended == false
        if !attended { background.end(success: success) }
    }

    // MARK: Playlist batches (Android `playlistWorkName` + `PlaylistLyricSyncState`)

    /// Song ids of each playlist's latest "sync lyrics for all songs" run.
    private(set) var lyricBatches: [String: [String]] = [:]

    /// Queues lyric sync for every song (already word-synced songs are skipped, failures don't stop the run).
    func syncLyrics(playlistId: String, songs: [Song]) {
        lyricBatches[playlistId] = songs.map(\.id)
        for song in songs { start(.lyrics, song: song, forceResync: false) }
    }

    /// Queues an instrumental for every song that has none yet; returns how many were queued.
    @discardableResult
    func renderInstrumentals(_ songs: [Song]) -> Int {
        var queued = 0
        for song in songs where InstrumentalFiles.bestAvailable(songId: song.id) == nil
            && state(.instrumental, songId: song.id)?.isActive != true {
            start(.instrumental, song: song)
            queued += 1
        }
        return queued
    }

    /// The playlist card's counts, from the batch's job states.
    func lyricSyncState(playlistId: String) -> PlaylistLyricSyncState {
        guard let ids = lyricBatches[playlistId], !ids.isEmpty else { return .idle }
        var state = PlaylistLyricSyncState()
        state.total = ids.count
        for id in ids {
            guard let job = self.state(.lyrics, songId: id) else { continue }
            switch job.phase {
            case .queued: break
            case .running:
                state.isRunning = true
                state.detail = job.detail
            case .succeeded(let updated):
                state.completed += 1
                if updated { state.synced += 1 } else { state.skipped += 1 }
            case .failed, .cancelled:
                state.completed += 1
                state.failedSongIds.append(id)
            }
        }
        if ids.contains(where: { self.state(.lyrics, songId: $0)?.phase == .queued }) { state.isRunning = true }
        return state
    }

    /// "Cancel remaining".
    func cancelLyricBatch(playlistId: String) {
        for id in lyricBatches[playlistId] ?? [] where state(.lyrics, songId: id)?.isActive == true {
            cancel(.lyrics, songId: id)
        }
    }

    /// "Retry unfinished songs".
    func retryLyricBatch(playlistId: String, songs: [Song]) {
        let failed = Set(lyricSyncState(playlistId: playlistId).failedSongIds)
        for song in songs where failed.contains(song.id) { start(.lyrics, song: song, forceResync: false) }
    }

    func cancel(_ kind: JobKind, songId: String) {
        let key = JobKey(kind: kind, songId: songId)
        if let index = pending.firstIndex(where: { $0.key == key }) {
            pending.remove(at: index)
            jobs[key] = JobState(phase: .cancelled, percent: 0, detail: nil, indeterminate: false)
            endBackgroundRunIfNoAttendedWork(success: false)
            return
        }
        if running?.key == key { running?.task.cancel() }
    }

    func cancelAll() {
        for job in pending { jobs[job.key] = JobState(phase: .cancelled, percent: 0, detail: nil, indeterminate: false) }
        pending.removeAll()
        if let running {
            // The row says so at once; the task stops at its next check (late progress never revives it: `report`).
            if jobs[running.key]?.isActive == true { jobs[running.key] = Self.cancelledState }
            running.task.cancel()
        } else {
            background.end(success: false)
        }
    }

    /// "Cancel" on Active jobs' row for one kind: every queued or running job of that kind stops.
    func cancelAll(kind: JobKind) {
        for job in pending where job.key.kind == kind { jobs[job.key] = Self.cancelledState }
        pending.removeAll { $0.key.kind == kind }
        if let running, running.key.kind == kind {
            if jobs[running.key]?.isActive == true { jobs[running.key] = Self.cancelledState }
            running.task.cancel()
        }
        endBackgroundRunIfNoAttendedWork(success: false)
    }

    private static let cancelledState = JobState(phase: .cancelled, percent: 0, detail: nil, indeterminate: false)

    /// "Clear finished": forgets every job that is not queued or running (done, failed, cancelled). Active ones stay.
    func clearFinished() {
        let active = jobs.filter { $0.value.isActive }
        if active.count != jobs.count { jobs = active }
    }

    /// "Dismiss" on one finished or failed job. A queued or running one is not dismissed (cancel it first).
    func dismiss(_ kind: JobKind, songId: String) {
        let key = JobKey(kind: kind, songId: songId)
        guard let state = jobs[key], !state.isActive else { return }
        jobs[key] = nil
    }

    /// How many jobs are queued or running.
    var activeCount: Int { jobs.values.reduce(0) { $0 + ($1.isActive ? 1 : 0) } }

    /// A memory warning with no job running: the Core ML models (≈ 190 MB and more) go now, not after the lane drains.
    /// A running job keeps its own reference until it ends and then releases them (`runNextIfIdle`).
    private func releaseModelsIfIdle() {
        guard running == nil else { return }
        Task { await aligner.unload(); await separator.unload() }
    }

    /// Emergency stop: the Core ML models go now (a running job keeps its own reference until it ends).
    func releaseModels() {
        Task { await aligner.unload(); await separator.unload() }
    }

    /// A memory warning: nothing the person did not ask for goes on (unattended jobs stop and are retried later by the
    /// runner), and idle models are released. A job the person started carries on, slowed by `HeavyWorkGate`.
    func handleMemoryWarning() {
        cancelUnattended()
        releaseModelsIfIdle()
    }

    /// A critical memory event: every queued and running job stops now, saying why (a Retry stays on its row), before the
    /// system ends the app for it.
    func stopForMemory() {
        let reason = "Stopped: the iPhone ran low on memory. Retry when other apps are closed."
        let stopped = JobState(phase: .failed(reason), percent: 0, detail: nil, indeterminate: false)
        for job in pending { jobs[job.key] = stopped }
        pending.removeAll()
        if let running {
            if jobs[running.key]?.isActive == true { jobs[running.key] = stopped }
            running.task.cancel()
        }
        endBackgroundRunIfNoAttendedWork(success: false)
        releaseModels()
    }

    private func runNextIfIdle() {
        guard running == nil else { return }
        guard !pending.isEmpty else {
            background.end(success: true)
            Task { await aligner.unload(); await separator.unload() }
            return
        }
        let job = pending.removeFirst()
        // Utility priority: a minutes-long CPU-bound job must not compete with the UI for the cores.
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.run(job)
            self.running = nil
            self.runNextIfIdle()
        }
        running = (job.key, job.unattended, task)
        endBackgroundRunIfNoAttendedWork(success: true)
    }

    private func run(_ job: Job) async {
        // One Core ML model at a time: the other kind's is released before this one loads.
        switch job.key.kind {
        case .lyrics: await separator.unload()
        case .instrumental: await aligner.unload()
        case .roformer:
            await aligner.unload()
            await separator.unload()
        }
        report(job.key, 0, jobs[job.key]?.detail, indeterminate: true)
        let telemetryKind = Self.telemetryKind(job.key.kind)
        JobTelemetry.shared.started(telemetryKind, id: job.key.songId)
        do {
            let outcome: (updated: Bool, detail: String?)
            switch job.key.kind {
            case .lyrics: outcome = try await runLyricSync(job)
            case .instrumental: outcome = try await runInstrumental(job)
            case .roformer: outcome = try await runRoformer(job)
            }
            try Task.checkCancellation()
            jobs[job.key] = JobState(phase: .succeeded(updated: outcome.updated), percent: 100, detail: outcome.detail,
                                     indeterminate: false)
            JobTelemetry.shared.ended(telemetryKind, id: job.key.songId, .finished)
        } catch is CancellationError {
            // `stopForMemory` already said why (a failed row with a Retry): that stays.
            var stoppedForMemory = false
            if case .failed? = jobs[job.key]?.phase { stoppedForMemory = true }
            if !stoppedForMemory { jobs[job.key] = JobState(phase: .cancelled, percent: 0, detail: nil, indeterminate: false) }
            JobTelemetry.shared.ended(telemetryKind, id: job.key.songId,
                                      .cancelled(stoppedForMemory ? "low memory" : "cancelled"))
        } catch {
            // A terminal state with a reason; the lane, the model lease and the background run are released by the
            // `defer`s of the job's steps and by `runNextIfIdle` right after.
            let message = Self.failureMessage(error)
            jobs[job.key] = JobState(phase: .failed(String(message.prefix(800))), percent: 0, detail: nil, indeterminate: false)
            JobTelemetry.shared.ended(telemetryKind, id: job.key.songId, .failed(message))
        }
    }

    /// The `ActiveJob.Kind` raw value of a studio kind (what the in-flight journal and the log call it).
    nonisolated static func telemetryKind(_ kind: JobKind) -> String {
        switch kind {
        case .lyrics: "lyricsSync"
        case .instrumental: "instrumental"
        case .roformer: "roformer"
        }
    }

    /// The words of a failure: the network's plain wording for a network error, else the error's own text.
    nonisolated static func failureMessage(_ error: any Error) -> String {
        if let url = error as? URLError, let words = JobFailureText.urlError(code: url.code.rawValue) { return words }
        return JobFailureText.short((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, limit: 800)
    }

    /// Updates the card and the system's Live Activity together (Android `reportProgress`).
    private func report(_ key: JobKey, _ percent: Int, _ detail: String?, indeterminate: Bool = false) {
        // Late progress (a chunk finishing after a cancel) never revives a finished job.
        guard jobs[key]?.isActive == true, running?.key == key else { return }
        let state = JobState(phase: .running, percent: min(max(percent, 0), 100), detail: detail, indeterminate: indeterminate)
        // Equal progress does not re-render the screens that watch the jobs.
        if jobs[key] != state { jobs[key] = state }
        // Unattended work never shows in the system's progress UI.
        if running?.unattended == false {
            background.update(subtitle: detail ?? Self.title(key.kind), fraction: Double(percent) / 100)
        }
    }

    static func title(_ kind: JobKind) -> String {
        switch kind {
        case .instrumental: "Magic Instrumentalize"
        case .lyrics: "Lyric Sync"
        case .roformer: "BS-RoFormer"
        }
    }

    // MARK: Heavy lane

    /// A place in the shared heavy lane (`HeavyJobGovernor`) for the compute part of a job, saying "waiting" in the row
    /// while another heavy job (or the model install) holds it. Taken after the model is in hand, never before: the
    /// install needs the lane too, and a job waiting for its model while holding the lane would block it for ever.
    private func acquireHeavy(for key: JobKey) async throws -> HeavyJobGovernor.Lease {
        let governor = HeavyJobGovernor.shared
        if governor.isBusy, jobs[key]?.isActive == true {
            let previous = jobs[key]
            jobs[key] = JobState(phase: .running, percent: previous?.percent ?? 0,
                                 detail: "Waiting for other heavy work to finish…", indeterminate: true, waiting: true)
        }
        return try await governor.acquire()
    }

    // MARK: Models

    /// The compiled model, reporting the first-use download inside the job's row.
    private func model(_ id: ModelDescriptor.ID, for key: JobKey) async throws -> URL {
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                switch self.models.state(id) {
                case .downloading(let fraction):
                    let title = ModelCatalog.descriptor(id).title.lowercased()
                    let suffix = fraction.map { " — \(Int($0 * 100))%" } ?? "…"
                    self.report(key, 0, "Downloading the \(title)\(suffix)", indeterminate: true)
                case .installing:
                    self.report(key, 0, "Installing the \(ModelCatalog.descriptor(id).title.lowercased())…",
                                indeterminate: true)
                default: break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { watcher.cancel() }
        // Cancelling the job stops the wait only; the download itself keeps going for next time.
        return try await models.ensureInstalled(id)
    }

    // MARK: Lyric sync (TaisStudioWorker)

    private func runLyricSync(_ job: Job) async throws -> (Bool, String?) {
        guard let dependencies, let service = dependencies.lyricsService else {
            throw JobFailure(message: "Lyrics aren't available.")
        }
        let song = job.song, key = job.key
        let kept = "You synced this song yourself — kept your timing"
        if !job.overrideUser, await service.isUserSyncedStored(song) { return (false, kept) }

        report(key, 0, "Finding lyrics for \(song.title)…", indeterminate: true)
        let preference = LyricsSourcePreference(rawValue: dependencies.settings.lyrics.sourcePreference) ?? .embeddedFirst
        let loaded = await service.lyrics(for: song, preference: preference, allowOnline: true, forceRefresh: false)
        try Task.checkCancellation()
        let state = TaisLyricsAlignment.alignmentState(for: loaded?.lyrics, forceResync: job.forceResync)
        if state == .wordSynced { return (false, "Already word-synced — \(song.title)") }

        report(key, 0, "Checking pre-synced lyric catalogs…", indeterminate: true)
        if let online = await Self.withTimeout(seconds: 25, { await service.fetchFromRemote(song: song) }),
           case .success(let found) = online, !(found.lyrics.synced ?? []).isEmpty {
            try Task.checkCancellation()
            let vocalLines = (found.lyrics.synced ?? []).filter { !$0.line.isKotlinBlank }
            let wordLines = vocalLines.filter { !($0.words ?? []).isEmpty }.count
            guard await service.saveOnline(song: song, lyrics: found.lyrics, source: found.source,
                                           rawContent: found.rawContent, overrideUser: job.overrideUser) != nil else {
                return (false, kept)
            }
            reloadLyricsIfShowing(song)
            let hasWords = !vocalLines.isEmpty && wordLines == vocalLines.count
            if hasWords { return (true, "Word-synced lyrics from \(found.source)") }
            if wordLines > 0 {
                return (true, "Lyrics from \(found.source); word timing on \(wordLines) of \(vocalLines.count) lines.")
            }
            return (true, "Line-synced lyrics from \(found.source); word timings are not available for this recording.")
        }
        guard let lines = TaisLyricsAlignment.lines(for: state), !lines.isEmpty else {
            return (false, "No lyrics found — skipped \(song.title)")
        }

        report(key, 0, "Getting \(song.title) ready…", indeterminate: true)
        let source = try await dependencies.audioSource(song)
        let modelURL = try await model(.wav2vec2, for: key)
        try Task.checkCancellation()
        let lease = try await acquireHeavy(for: key)
        defer { lease.release() }
        try Task.checkCancellation()
        report(key, 5, "Syncing \(song.title) word-by-word…")
        let samples = try await AudioPCMReader.read(url: source, sampleRate: Double(Wav2Vec2Vocabulary.sampleRate),
                                                    channels: 1)[0]
        try Task.checkCancellation()
        let totalDurationMs = Int(Int64(samples.count) * 1000 / Int64(Wav2Vec2Vocabulary.sampleRate))
        let targetWords = TaisLyricsAlignment.targetWords(lines: lines)
        guard !samples.isEmpty, !targetWords.isEmpty else {
            throw JobFailure(message: TaisLyricsAlignment.Failure.noUsableTiming.message)
        }
        let title = song.title
        let timings: [AlignedWordTiming]
        do {
            timings = try await aligner.align(samples: samples, words: targetWords.map(\.word), modelURL: modelURL,
                                              pacer: HeavyWorkGate.shared.makePacer()) { done, total in
                let overall = min(max(5 + Int(Double(done) / Double(max(total, 1)) * 95), 5), 100)
                await self.report(key, overall, "\(title) — pass \(done) of \(total)…")
            }
        } catch let failure as TaisLyricsAlignment.Failure {
            throw JobFailure(message: failure.message)
        }
        guard !timings.isEmpty else { throw JobFailure(message: TaisLyricsAlignment.Failure.noUsableTiming.message) }
        let aligned: [SyncedLine]
        do {
            aligned = try TaisLyricsAlignment.assemble(lines: lines, targetWords: targetWords, timings: timings,
                                                       totalDurationMs: totalDurationMs)
            try TaisLyricsAlignment.validateForSave(aligned)
        } catch let failure as TaisLyricsAlignment.Failure {
            throw JobFailure(message: failure.message)
        }
        try Task.checkCancellation()
        // Alignment takes minutes: re-check right before the write, not only when the job started.
        if !job.overrideUser, await service.isUserSyncedStored(song) { return (false, kept) }
        let doc = TaisLyricsAlignment.lyricsDoc(lines: aligned, totalDurationMs: max(totalDurationMs, Int(song.duration)),
                                                title: song.title, artist: song.displayArtist, album: song.album)
        guard await service.save(song: song, rawContent: LyricsDocCodec.encode(doc),
                                 source: TaisLyricsAlignment.source) != nil else {
            throw JobFailure(message: TaisLyricsAlignment.Failure.noUsableTiming.message)
        }
        reloadLyricsIfShowing(song)
        return (true, "Done — \(song.title) lyrics synced")
    }

    /// Cloud Studio moved an instrumental into `Stems/` (design §7.5): the instrumental switch and the lyrics screen
    /// look again.
    func noteInstrumentalImported() { instrumentalRevision += 1 }

    /// Cloud Studio saved word-timed lyrics for `song`: the lyrics screen reloads them if it shows that song.
    func noteLyricsImported(song: Song) { reloadLyricsIfShowing(song) }

    private func reloadLyricsIfShowing(_ song: Song) {
        lyricsRevision += 1
        guard let controller = dependencies?.lyricsController, controller.loadedSongId == song.id else { return }
        controller.load(song, forceRefresh: false)
    }

    // MARK: Instrumental (StemSeparatorWorker)

    private func runInstrumental(_ job: Job) async throws -> (Bool, String?) {
        guard let dependencies else { throw JobFailure(message: "Unavailable.") }
        let song = job.song, key = job.key
        if InstrumentalFiles.bestAvailable(songId: song.id) != nil { return (false, "Instrumental ready.") }
        report(key, 0, "Separating \(song.title)…", indeterminate: true)
        let source = try await dependencies.audioSource(song)
        let modelURL: URL
        do {
            modelURL = try await model(.mdxnet, for: key)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The cloud separator is the fallback when the on-device model can't be had.
            if Self.roformerSettings(dependencies.settings).isConfigured {
                report(key, 0, "The on-device model is unavailable — rendering in the cloud…", indeterminate: true)
                return try await renderInCloud(song: song, key: key, source: source)
            }
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw JobFailure(message: "\(reason) Magic Instrumentalize in Experimental settings still reduces vocals live.")
        }
        let lease = try await acquireHeavy(for: key)
        defer { lease.release() }
        try Task.checkCancellation()
        try InstrumentalFiles.prepareDirectory()
        guard let destination = InstrumentalFiles.instrumentalURL(songId: song.id) else {
            throw JobFailure(message: "No storage for instrumentals.")
        }
        let separator = self.separator
        report(key, 0, "Rendering the instrumental — 0% through the track…")
        try await separator.renderInstrumental(source: source, destination: destination, modelURL: modelURL,
                                               pacer: HeavyWorkGate.shared.makePacer()) { done, total in
            let percent = total > 0 ? min(max(done * 100 / total, 0), 100) : 0
            Task { @MainActor [weak self] in
                self?.report(key, percent, "Rendering the instrumental — \(percent)% through the track…")
            }
        }
        guard InstrumentalFiles.isComplete(destination) else {
            throw JobFailure(message: "Incomplete separation output; previous render was kept")
        }
        instrumentalRevision += 1
        return (true, "Instrumental ready.")
    }

    // MARK: BS-RoFormer (BsRoformerRenderWorker)

    static func roformerSettings(_ settings: SettingsStore) -> StemBackendSettings {
        let experimental = settings.experimental
        experimental.loadSecretsIfNeeded()
        let key = experimental.roformerApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = experimental.roformerExtraArg.trimmingCharacters(in: .whitespacesAndNewlines)
        return StemBackendSettings(type: StemBackendType(rawValue: experimental.roformerBackendType) ?? .gradioSpace,
                                   baseURL: experimental.roformerBaseUrl, apiName: experimental.roformerApiName,
                                   apiKey: key.isEmpty ? nil : key, extraArgument: extra.isEmpty ? nil : extra)
    }

    private func runRoformer(_ job: Job) async throws -> (Bool, String?) {
        guard let dependencies else { throw JobFailure(message: "Unavailable.") }
        guard Self.roformerSettings(dependencies.settings).isConfigured else {
            throw JobFailure(message: "No BS-RoFormer backend configured — set one in Experimental Settings first.")
        }
        report(job.key, 0, "Connecting to BS-RoFormer GPU…", indeterminate: true)
        let source = try await dependencies.audioSource(job.song)
        return try await renderInCloud(song: job.song, key: job.key, source: source)
    }

    private func renderInCloud(song: Song, key: JobKey, source: URL) async throws -> (Bool, String?) {
        guard let dependencies else { throw JobFailure(message: "Unavailable.") }
        let settings = Self.roformerSettings(dependencies.settings)
        guard source.isFileURL, let data = try? Data(contentsOf: source, options: .mappedIfSafe) else {
            throw JobFailure(message: "Couldn't read this song's audio file for upload.")
        }
        let file = MultipartFile(fieldName: "file", fileName: source.lastPathComponent, data: data)
        let onStage: StemStageReporter = { [weak self] stage in
            await self?.report(key, stage.hasPrefix("Downloading") ? 90 : 40, stage, indeterminate: true)
        }
        let http = URLSessionHTTPClient()
        let result: StemRenderResult?
        switch settings.type {
        case .gradioSpace: result = await GradioStemClient(http: http).separate(settings: settings, audio: file, onStage: onStage)
        case .directPost: result = await DirectPostStemClient(http: http).separate(settings: settings, audio: file, onStage: onStage)
        }
        try Task.checkCancellation()
        guard let result else {
            throw JobFailure(message: "BS-RoFormer render failed — check the backend URL/route in Experimental Settings and try again.")
        }
        try InstrumentalFiles.prepareDirectory()
        guard let destination = InstrumentalFiles.roformerURL(songId: song.id) else {
            throw JobFailure(message: "No storage for instrumentals.")
        }
        guard StemFiles.isCompleteStem(firstBytes: [UInt8](result.instrumental.prefix(12)),
                                       fileLength: Int64(result.instrumental.count)) else {
            throw JobFailure(message: "The backend returned incomplete audio. Your previous render was kept.")
        }
        try result.instrumental.write(to: destination, options: .atomic)
        instrumentalRevision += 1
        return (true, "Done — studio master ready")
    }

    // MARK: Helpers

    /// `withTimeoutOrNull`.
    nonisolated static func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
