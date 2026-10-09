import Foundation
import Observation
import PixlModel
import PixlNet

/// Home's "Active jobs" (Android `JobsStateHolder`, which watches every tagged WorkManager job): one place that knows
/// what is running in the app, fed by the services that already track it, so Home depends on this and not on each
/// service. Nothing here owns state or does work; every row is derived from a source's own observable properties:
///
/// - library scan: `LibraryStore.lastImportProgress`
/// - Spotify import and audio matching: `SpotifyService`
/// - offline downloads and model downloads: `DownloadManager`, `ModelManager`
/// - lyric sync, instrumentals: `TaisStudio` (one row per kind, so a 200-song playlist is one line)
/// - Cloud Studio: `CloudStudio` (one row per batch, `CloudActiveJobMapper`)
///
/// Two readers, two costs. The button needs only a count, so `badgeCount` / `isWorking` are stored and written only
/// when they change (the button's view re-runs on a real change, not on every progress tick of every source). The
/// sheet reads `active` / `recent`, which are refreshed (every source followed) only while it is on screen. Either way
/// a burst of changes is re-read at most four times a second (`UpdateCoalescer`), never once per progress tick.
@Observable
final class ActiveJobs {
    /// What the services hold. Owned by `AppEnvironment`; the aggregator never outlives them.
    struct Sources {
        let library: LibraryStore
        let spotify: SpotifyService
        let downloads: DownloadManager
        let models: ModelManager
        let studio: TaisStudio
        let cloud: CloudStudio
    }

    /// Queued or running jobs: the Home button's badge (0 hides the button).
    private(set) var badgeCount = 0
    /// Something is running (not just waiting): the button's symbol animates.
    private(set) var isWorking = false
    /// The sheet's two lists. Refreshed only while the sheet is up (`setSheetVisible`), at most four times a second,
    /// and written only when they differ, so a row view re-runs for a real change and not for every source's tick.
    private(set) var active: [ActiveJob] = []
    private(set) var recent: [ActiveJob] = []

    @ObservationIgnored private let sources: Sources?
    @ObservationIgnored private let demoRows: [ActiveJob]
    @ObservationIgnored private let nowMs: () -> Int64
    /// When a finished row was first seen finished (the sources that keep no time of their own).
    @ObservationIgnored private var finishedAt: [String: Int64] = [:]
    @ObservationIgnored private var isTracking = false
    @ObservationIgnored private var sheetVisible = false
    /// Bumped on every re-arm: a tracking registration that fires after a newer one was made is ignored, so the
    /// registrations never multiply.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var coalescer = UpdateCoalescer(minIntervalMs: 250)
    @ObservationIgnored private var pendingRearm: Task<Void, Never>?

    init(sources: Sources, nowMs: @escaping () -> Int64 = { currentTimeMillis() }) {
        self.sources = sources
        demoRows = []
        self.nowMs = nowMs
    }

    /// UI tests: fixed rows, no sources.
    init(demo rows: [ActiveJob], nowMs: Int64) {
        sources = nil
        demoRows = rows
        self.nowMs = { nowMs }
        show(count: ActiveJobBoard.badgeCount(rows), working: ActiveJobBoard.isWorking(rows))
        publish(rows)
    }

    /// Starts following the sources (once, at launch; cheap: one pass over a few small collections).
    func start() {
        guard sources != nil, !isTracking else { return }
        isTracking = true
        track()
    }

    // MARK: Readers

    /// The sheet's two lists (what it last published).
    func snapshot() -> (active: [ActiveJob], recent: [ActiveJob]) {
        (active, recent)
    }

    /// The sheet came up or went away. While it is up the aggregator follows every property a row shows (at most four
    /// times a second); otherwise only the few the button needs.
    func setSheetVisible(_ visible: Bool) {
        guard sheetVisible != visible else { return }
        sheetVisible = visible
        guard sources != nil, isTracking else { return }
        pendingRearm?.cancel()
        pendingRearm = nil
        track()
    }

    // MARK: Following the sources

    /// Reads the sources and re-arms the observation. One registration is live at a time (`generation`).
    private func track() {
        guard let sources else { return }
        generation &+= 1
        let mine = generation
        let visible = sheetVisible
        var rows: [ActiveJob]?
        let summary = withObservationTracking { () -> (count: Int, working: Bool) in
            if visible {
                let all = allRows()
                rows = all
                return (count: ActiveJobBoard.badgeCount(all), working: ActiveJobBoard.isWorking(all))
            }
            return Self.summary(sources)
        } onChange: { [weak self] in
            Task { @MainActor in self?.sourceChanged(generation: mine) }
        }
        coalescer.ran(nowMs: nowMs())
        show(count: summary.count, working: summary.working)
        if let rows { publish(rows) } else if !active.isEmpty || !recent.isEmpty, !visible {
            // The sheet is gone: drop its rows so a closed sheet holds nothing.
            active = []
            recent = []
        }
    }

    /// A source changed. Progress arrives in bursts (a model download, a scan, a cloud upload, a lyric sync all report
    /// many times a second): the first change after a quiet moment is handled at once, the rest wait out the interval and
    /// are served by one re-read, because `track()` reads the current values.
    private func sourceChanged(generation changed: Int) {
        guard changed == generation else { return }
        let delay = coalescer.delayMs(nowMs: nowMs())
        if delay == 0 {
            track()
            return
        }
        pendingRearm?.cancel()
        pendingRearm = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.pendingRearm = nil
            self.track()
        }
    }

    private func publish(_ rows: [ActiveJob]) {
        let newActive = ActiveJobBoard.active(rows)
        let newRecent = ActiveJobBoard.recent(rows, nowMs: nowMs())
        if active != newActive { active = newActive }
        if recent != newRecent { recent = newRecent }
    }

    private func show(count: Int, working: Bool) {
        if badgeCount != count { badgeCount = count }
        if isWorking != working { isWorking = working }
    }

    /// The button's two numbers straight from the sources, without building a row or a string: this runs after every
    /// change of every source (a scan's progress included), so it stays a few comparisons. It counts what `snapshot()`
    /// lists as active (one per library scan, Spotify step, download, model, studio kind and cloud batch).
    private static func summary(_ sources: Sources) -> (count: Int, working: Bool) {
        var count = 0
        var working = false
        func add(running: Bool) {
            count += 1
            if running { working = true }
        }
        if let progress = sources.library.lastImportProgress, progress.total > 0, progress.completed < progress.total {
            add(running: true)
        }
        if sources.spotify.isSyncing { add(running: true) }
        if sources.spotify.isMatching { add(running: true) }
        for state in sources.downloads.states.values {
            if case .downloading = state { add(running: true) }
        }
        for descriptor in ModelCatalog.all where sources.models.state(descriptor.id).isBusy { add(running: true) }
        for kind in TaisStudio.JobKind.allCases {
            let active = sources.studio.jobs.filter { $0.key.kind == kind && $0.value.isActive }
            if !active.isEmpty { add(running: active.contains { $0.value.phase == .running && !$0.value.waiting }) }
        }
        let cloud = CloudActiveJobMapper.activeSummary(sources.cloud.jobs)
        count += cloud.count
        if cloud.working { working = true }
        return (count, working)
    }

    // MARK: Rows

    /// Every source's rows, active and finished, with their progress.
    private func allRows() -> [ActiveJob] {
        guard let sources else { return demoRows }
        var rows: [ActiveJob] = []
        rows += libraryRows(sources.library)
        rows += spotifyRows(sources.spotify)
        rows += downloadRows(sources.downloads)
        rows += modelRows(sources.models)
        rows += studioRows(sources.studio, library: sources.library)
        rows += CloudActiveJobMapper.rows(sources.cloud.jobs, transfer: sources.cloud.transferProgress)
        stampFinished(rows)
        return rows.map { stamped($0) }
    }

    private func libraryRows(_ library: LibraryStore) -> [ActiveJob] {
        guard let progress = library.lastImportProgress, progress.total > 0, progress.completed < progress.total else {
            return []
        }
        return [ActiveJob(id: "library", kind: .libraryScan, subtitle: progress.phase,
                          percent: ActiveJobBoard.percent(completed: progress.completed, total: progress.total),
                          state: .running)]
    }

    private func spotifyRows(_ spotify: SpotifyService) -> [ActiveJob] {
        var rows: [ActiveJob] = []
        if spotify.isSyncing {
            rows.append(ActiveJob(id: "spotify.sync", kind: .spotifyImport,
                                  subtitle: spotify.syncStatus.map { "Importing \($0)…" } ?? "Importing your library",
                                  state: .running))
        }
        if spotify.isMatching {
            let total = spotify.totalSongs
            let done = max(total - spotify.pendingMatchCount, 0)
            rows.append(ActiveJob(id: "spotify.match", kind: .spotifyMatch,
                                  subtitle: total > 0 ? "\(done) of \(total) songs" : nil,
                                  percent: ActiveJobBoard.percent(completed: done, total: total), state: .running))
        }
        return rows
    }

    private func downloadRows(_ downloads: DownloadManager) -> [ActiveJob] {
        downloads.states.compactMap { videoId, state -> ActiveJob? in
            guard case .downloading(let percent) = state else { return nil }
            return ActiveJob(id: "download.\(videoId)", kind: .songDownload,
                             subtitle: downloads.titles[videoId] ?? "Song", percent: percent, state: .running)
        }
        .sorted { $0.id < $1.id }
    }

    private func modelRows(_ models: ModelManager) -> [ActiveJob] {
        ModelCatalog.all.compactMap { descriptor -> ActiveJob? in
            switch models.state(descriptor.id) {
            case .downloading(let fraction):
                return ActiveJob(id: "model.\(descriptor.id.rawValue)", kind: .modelDownload, subtitle: descriptor.title,
                                 percent: ActiveJobBoard.percent(fraction: fraction), state: .running)
            case .installing:
                let waiting = models.isWaitingToInstall(descriptor.id)
                return ActiveJob(id: "model.\(descriptor.id.rawValue)", kind: .modelDownload,
                                 subtitle: waiting ? "Waiting for other work to finish…"
                                     : "Installing the \(descriptor.title.lowercased())…",
                                 state: waiting ? .queued : .running)
            default:
                return nil
            }
        }
    }

    /// One row per kind of studio job: the running song (with its own percentage) and how many wait behind it; the
    /// finished ones as individual "recent" rows.
    private func studioRows(_ studio: TaisStudio, library: LibraryStore) -> [ActiveJob] {
        var rows: [ActiveJob] = []
        let kinds: [(TaisStudio.JobKind, ActiveJob.Kind)] = [(.lyrics, .lyricsSync), (.instrumental, .instrumental),
                                                              (.roformer, .roformer)]
        func title(_ songId: String) -> String { library.song(id: songId)?.title ?? "Song" }
        for (studioKind, kind) in kinds {
            let jobs = studio.jobs.filter { $0.key.kind == studioKind }
                .sorted { $0.key.songId < $1.key.songId }
            let active = jobs.filter { $0.value.isActive }
            if !active.isEmpty {
                let running = active.first { $0.value.phase == .running && !$0.value.waiting }
                let blocked = active.first { $0.value.waiting }
                let waiting = active.count - (running == nil ? 0 : 1)
                var subtitle = running.map { entry -> String in
                    var line = title(entry.key.songId)
                    if let detail = entry.value.detail, !detail.isEmpty { line += " · \(detail)" }
                    return line
                } ?? blocked.map { "\(title($0.key.songId)) · Waiting for other work to finish" }
                    ?? "\(waiting) \(waiting == 1 ? "song" : "songs") waiting"
                if running != nil, waiting > 0 { subtitle += " · \(waiting) waiting" }
                let percent = running.flatMap { $0.value.indeterminate ? nil : $0.value.percent }
                rows.append(ActiveJob(id: "tais.\(kind.rawValue)", kind: kind, subtitle: subtitle, percent: percent,
                                      state: running == nil ? .queued : .running))
            }
            for (key, state) in jobs {
                switch state.phase {
                case .succeeded:
                    rows.append(ActiveJob(id: "tais.done.\(kind.rawValue).\(key.songId)", kind: kind,
                                          subtitle: title(key.songId), percent: 100, state: .done))
                case .failed(let message):
                    rows.append(ActiveJob(id: "tais.failed.\(kind.rawValue).\(key.songId)", kind: kind,
                                          subtitle: "\(title(key.songId)) · \(message.prefix(80))", state: .failed))
                case .queued, .running, .cancelled:
                    break
                }
            }
        }
        return rows
    }

    // MARK: Finished rows' time

    /// Notes when a finished row first appeared, for the sources that keep no time (the studio's jobs), and forgets
    /// rows that went away.
    private func stampFinished(_ rows: [ActiveJob]) {
        let now = nowMs()
        var seen = Set<String>()
        for row in rows where !row.isActive && row.updatedAtMs == 0 {
            seen.insert(row.id)
            if finishedAt[row.id] == nil { finishedAt[row.id] = now }
        }
        if finishedAt.count > seen.count { finishedAt = finishedAt.filter { seen.contains($0.key) } }
    }

    private func stamped(_ row: ActiveJob) -> ActiveJob {
        guard row.updatedAtMs == 0, !row.isActive, let at = finishedAt[row.id] else { return row }
        var copy = row
        copy.updatedAtMs = at
        return copy
    }
}
