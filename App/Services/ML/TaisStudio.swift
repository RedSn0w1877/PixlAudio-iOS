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
/// sync and separation), each reporting `(percent, detail)` for `TaisStudioProgressCard`; a run keeps going in the
/// background through `TaisBackgroundRun` (the system's continued-processing Live Activity, cancellable there) and
/// any job can be cancelled from the card.
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
    @ObservationIgnored private var running: (key: JobKey, task: Task<Void, Never>)?

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
    }

    nonisolated struct JobFailure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    init(models: ModelManager, dependencies: Dependencies?) {
        self.models = models
        self.dependencies = dependencies
        background.onExpired = { [weak self] in self?.cancelAll() }
    }

    func state(_ kind: JobKind, songId: String) -> JobState? { jobs[JobKey(kind: kind, songId: songId)] }

    /// UI-test demo data.
    func setDemoState(_ state: JobState?, kind: JobKind, songId: String) {
        jobs[JobKey(kind: kind, songId: songId)] = state
    }

    // MARK: Starting and cancelling

    /// Enqueues a job (`ExistingWorkPolicy.KEEP`: a job already queued or running for that song is kept).
    func start(_ kind: JobKind, song: Song, overrideUser: Bool = false, forceResync: Bool = true) {
        let key = JobKey(kind: kind, songId: song.id)
        if jobs[key]?.isActive == true { return }
        let waiting = kind == .lyrics ? "Waiting for the lyric sync engine…" : "Queued…"
        jobs[key] = JobState(phase: .queued, percent: 0, detail: waiting, indeterminate: true)
        guard dependencies != nil else { return }
        pending.append(Job(key: key, song: song, overrideUser: overrideUser, forceResync: forceResync))
        background.begin(title: "Remaster Song", subtitle: "\(Self.title(kind)) · \(song.title)")
        runNextIfIdle()
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
            if running == nil && pending.isEmpty { background.end(success: false) }
            return
        }
        if running?.key == key { running?.task.cancel() }
    }

    func cancelAll() {
        for job in pending { jobs[job.key] = JobState(phase: .cancelled, percent: 0, detail: nil, indeterminate: false) }
        pending.removeAll()
        running?.task.cancel()
    }

    private func runNextIfIdle() {
        guard running == nil else { return }
        guard !pending.isEmpty else {
            background.end(success: true)
            Task { await aligner.unload(); await separator.unload() }
            return
        }
        let job = pending.removeFirst()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(job)
            self.running = nil
            self.runNextIfIdle()
        }
        running = (job.key, task)
    }

    private func run(_ job: Job) async {
        report(job.key, 0, jobs[job.key]?.detail, indeterminate: true)
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
        } catch is CancellationError {
            jobs[job.key] = JobState(phase: .cancelled, percent: 0, detail: nil, indeterminate: false)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            jobs[job.key] = JobState(phase: .failed(String(message.prefix(800))), percent: 0, detail: nil, indeterminate: false)
        }
    }

    /// Updates the card and the system's Live Activity together (Android `reportProgress`).
    private func report(_ key: JobKey, _ percent: Int, _ detail: String?, indeterminate: Bool = false) {
        // Late progress (a chunk finishing after a cancel) never revives a finished job.
        guard jobs[key]?.isActive == true, running?.key == key else { return }
        jobs[key] = JobState(phase: .running, percent: min(max(percent, 0), 100), detail: detail, indeterminate: indeterminate)
        background.update(subtitle: detail ?? Self.title(key.kind), fraction: Double(percent) / 100)
    }

    static func title(_ kind: JobKind) -> String {
        switch kind {
        case .instrumental: "Magic Instrumentalize"
        case .lyrics: "Lyric Sync"
        case .roformer: "BS-RoFormer"
        }
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
                                           overrideUser: job.overrideUser) != nil else {
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
            timings = try await aligner.align(samples: samples, words: targetWords.map(\.word), modelURL: modelURL) { done, total in
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
        try InstrumentalFiles.prepareDirectory()
        guard let destination = InstrumentalFiles.instrumentalURL(songId: song.id) else {
            throw JobFailure(message: "No storage for instrumentals.")
        }
        let separator = self.separator
        report(key, 0, "Rendering the instrumental — 0% through the track…")
        try await separator.renderInstrumental(source: source, destination: destination, modelURL: modelURL) { done, total in
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
