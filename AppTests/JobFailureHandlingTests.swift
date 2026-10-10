import Foundation
import PixlModel
import XCTest
@testable import PixlAudio

/// A job that fails must end: a terminal "failed" state with a short reason, nothing left holding the lane, a way to
/// clear it out and to cancel what is still going (docs/handoff/2026-10-09-many-jobs-fix.md). The pure rules (retry
/// budget, stall watchdog, clearing, the badge) are tested in PixlModel; these are the app's services wired to them.
@MainActor
final class JobFailureHandlingTests: XCTestCase {
    // MARK: Studio jobs

    private func makeStudio(audioSource: @escaping @Sendable (Song) async throws -> URL) -> TaisStudio {
        let settings = SettingsStore.ephemeral()
        let controller = LyricsController(store: LyricsStore(), settings: settings, persistence: nil, isUITest: true)
        let dependencies = TaisStudio.Dependencies(settings: settings, lyricsService: nil, lyricsController: controller,
                                                   audioSource: audioSource)
        return TaisStudio(models: ModelManager(isDemo: true), dependencies: dependencies)
    }

    private func waitUntilIdle(_ studio: TaisStudio) async throws {
        for _ in 0..<300 where studio.activeCount > 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAJobWithNoSourceFailsWithAReasonAndTheNextOneStillRuns() async throws {
        let studio = makeStudio { _ in throw TaisStudio.JobFailure(message: "This song has no available audio source") }
        let first = DemoLibrary.songs[0], second = DemoLibrary.songs[1]
        studio.start(.instrumental, song: first, unattended: true)
        studio.start(.instrumental, song: second, unattended: true)
        try await waitUntilIdle(studio)
        for song in [first, second] {
            guard case .failed(let reason)? = studio.state(.instrumental, songId: song.id)?.phase else {
                return XCTFail("\(song.title) did not end as failed")
            }
            XCTAssertEqual(reason, "This song has no available audio source")
        }
        XCTAssertEqual(studio.activeCount, 0, "nothing stays running behind a failure")
        XCTAssertFalse(HeavyJobGovernor.shared.isBusy, "a failure gives the heavy lane back")
    }

    func testAnOfflineFailureIsSaidInPlainWords() async throws {
        let studio = makeStudio { _ in throw URLError(.notConnectedToInternet) }
        let song = DemoLibrary.songs[0]
        studio.start(.instrumental, song: song, unattended: true)
        try await waitUntilIdle(studio)
        guard case .failed(let reason)? = studio.state(.instrumental, songId: song.id)?.phase else {
            return XCTFail("the job did not end as failed")
        }
        XCTAssertEqual(reason, "No internet connection.")
    }

    func testClearFinishedKeepsOnlyWhatIsStillGoing() {
        let studio = makeStudio { _ in throw CancellationError() }
        func state(_ phase: TaisStudio.JobState.Phase) -> TaisStudio.JobState {
            TaisStudio.JobState(phase: phase, percent: 0, detail: nil, indeterminate: false)
        }
        studio.setDemoState(state(.running), kind: .lyrics, songId: "running")
        studio.setDemoState(state(.queued), kind: .lyrics, songId: "queued")
        studio.setDemoState(state(.failed("no source")), kind: .lyrics, songId: "failed")
        studio.setDemoState(state(.succeeded(updated: true)), kind: .instrumental, songId: "done")
        studio.setDemoState(state(.cancelled), kind: .instrumental, songId: "cancelled")
        XCTAssertEqual(studio.activeCount, 2)
        studio.clearFinished()
        XCTAssertEqual(Set(studio.jobs.keys.map(\.songId)), ["running", "queued"])
        XCTAssertEqual(studio.activeCount, 2)
        studio.clearFinished()
        XCTAssertEqual(studio.jobs.count, 2, "clearing again changes nothing")
    }

    func testDismissTakesOneFinishedJobAndNeverARunningOne() {
        let studio = makeStudio { _ in throw CancellationError() }
        studio.setDemoState(TaisStudio.JobState(phase: .failed("x"), percent: 0, detail: nil, indeterminate: false),
                            kind: .lyrics, songId: "a")
        studio.setDemoState(TaisStudio.JobState(phase: .running, percent: 5, detail: nil, indeterminate: false),
                            kind: .lyrics, songId: "b")
        studio.dismiss(.lyrics, songId: "a")
        studio.dismiss(.lyrics, songId: "b")
        XCTAssertNil(studio.state(.lyrics, songId: "a"))
        XCTAssertEqual(studio.state(.lyrics, songId: "b")?.phase, .running)
    }

    func testCancelAllStopsTheRunningJobAndTheWaitingOnesAtOnce() async throws {
        let studio = makeStudio { _ in
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        let first = DemoLibrary.songs[0], second = DemoLibrary.songs[1]
        studio.start(.instrumental, song: first, unattended: true)
        studio.start(.instrumental, song: second, unattended: true)
        XCTAssertEqual(studio.activeCount, 2)
        studio.cancelAll()
        XCTAssertEqual(studio.state(.instrumental, songId: first.id)?.phase, .cancelled, "the row says so at once")
        XCTAssertEqual(studio.state(.instrumental, songId: second.id)?.phase, .cancelled)
        XCTAssertEqual(studio.activeCount, 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(studio.activeCount, 0, "late progress never revives a cancelled job")
        XCTAssertFalse(HeavyJobGovernor.shared.isBusy)
    }

    func testCancellingOneKindLeavesTheOtherAlone() async throws {
        let studio = makeStudio { _ in
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        let song = DemoLibrary.songs[0], other = DemoLibrary.songs[1]
        studio.start(.instrumental, song: song, unattended: true)
        studio.start(.roformer, song: other, unattended: true)
        studio.cancelAll(kind: .roformer)
        XCTAssertEqual(studio.state(.roformer, songId: other.id)?.phase, .cancelled)
        XCTAssertTrue(studio.state(.instrumental, songId: song.id)?.isActive == true)
        studio.cancelAll()
        try await waitUntilIdle(studio)
    }

    // MARK: Model downloads

    func testAFailedModelDownloadCanBeResetAndNothingIsLeftBusy() {
        let models = ModelManager(isDemo: true)
        models.setDemoState(.failed(JobFailureText.httpStatus(404)), for: .llm)
        XCTAssertEqual(models.failures.map(\.id), [.llm])
        XCTAssertTrue(models.failures[0].message.contains("nothing to download"))
        XCTAssertFalse(models.state(.llm).isBusy, "a failure is terminal: it never counts as running")
        models.reset(.llm)
        XCTAssertEqual(models.state(.llm), .notInstalled)
        XCTAssertTrue(models.failures.isEmpty)
    }

    func testResetNeverRemovesAnInstalledModel() {
        let models = ModelManager(isDemo: true)
        models.setDemoState(.installed(bytes: 5), for: .wav2vec2)
        models.reset(.wav2vec2)
        XCTAssertEqual(models.state(.wav2vec2), .installed(bytes: 5))
    }

    func testCancelAllStopsDownloadsAndInstallsAndClearFailuresForgetsTheRest() {
        let models = ModelManager(isDemo: true)
        models.setDemoState(.downloading(fraction: 0.4), for: .wav2vec2)
        models.setDemoState(.installing, for: .mdxnet)
        models.setDemoState(.failed("The download stopped."), for: .llm)
        models.cancelAll()
        XCTAssertEqual(models.state(.wav2vec2), .notInstalled)
        XCTAssertEqual(models.state(.mdxnet), .notInstalled)
        XCTAssertEqual(models.state(.llm), .failed("The download stopped."), "cancel leaves a failure for Clear")
        models.clearFailures()
        XCTAssertEqual(models.state(.llm), .notInstalled)
    }

    func testAModelDownloadThatStopsMovingFailsWithAReason() {
        let models = ModelManager(isDemo: true)
        models.setDemoState(.downloading(fraction: 0.1), for: .wav2vec2)
        models.stalls.arm(.wav2vec2)
        models.stalls.note(.wav2vec2, mark: 1_000)
        for _ in 0..<6 { models.stalls.check() }
        XCTAssertTrue(models.state(.wav2vec2).isBusy, "six quiet intervals are not yet a stall")
        models.stalls.check()
        guard case .failed(let reason) = models.state(.wav2vec2) else { return XCTFail("the stalled download did not fail") }
        XCTAssertTrue(reason.contains("no data is arriving"))
        XCTAssertEqual(models.stalls.armedCount, 0, "the watchdog lets go")
    }

    // MARK: Song downloads

    func testAFailedSongDownloadIsDismissedAndASongOnItsWayIsCancelled() {
        let downloads = DownloadManager(service: nil, fetcher: nil)
        downloads.setDemoState(.failed("No internet connection."), videoId: "bad")
        downloads.setDemoState(.downloading(percent: 30), videoId: "going")
        downloads.setDemoState(.downloaded, videoId: "done")
        XCTAssertEqual(downloads.failures.map(\.videoId), ["bad"])
        XCTAssertEqual(downloads.downloadingIds, ["going"])
        downloads.cancelAll()
        XCTAssertNil(downloads.states["going"], "a cancelled download leaves no trace")
        XCTAssertEqual(downloads.states["done"], .downloaded, "finished downloads are never touched")
        downloads.clearFailures()
        XCTAssertNil(downloads.states["bad"])
        XCTAssertTrue(downloads.failures.isEmpty)
    }

    func testASongDownloadThatStopsMovingFails() {
        let downloads = DownloadManager(service: nil, fetcher: nil)
        downloads.setDemoState(.downloading(percent: nil), videoId: "v1")
        downloads.stalls.arm("v1")
        for _ in 0..<7 { downloads.stalls.check() }
        guard case .failed(let reason)? = downloads.states["v1"] else { return XCTFail("the download did not fail") }
        XCTAssertTrue(reason.contains("no data is arriving"))
    }

    // MARK: The stall monitor

    func testOnlyATransferThatStopsIsReportedAndOnlyOnce() {
        let monitor = StallMonitor<String>(interval: .seconds(3600), limitTicks: 3)
        var stalled: [String] = []
        monitor.onStall = { stalled.append($0) }
        monitor.arm("moving")
        monitor.arm("stuck")
        for step in 1...8 {
            monitor.note("moving", mark: Int64(step) * 100)
            monitor.check()
        }
        XCTAssertEqual(stalled, ["stuck"])
        XCTAssertEqual(monitor.armedCount, 1)
        XCTAssertTrue(monitor.isArmed("moving"))
        monitor.check()
        XCTAssertEqual(stalled, ["stuck"], "a transfer is reported once")
        monitor.disarmAll()
        XCTAssertEqual(monitor.armedCount, 0)
    }

    // MARK: Library scans

    private struct FailingImporter: LibraryImporting {
        func importLibrary(mode: LibraryImportMode,
                           progress: @escaping @Sendable (LibraryImportProgress) -> Void) async throws -> LibraryImportSummary {
            progress(LibraryImportProgress(phase: "Scanning", completed: 40, total: 100))
            throw URLError(.notConnectedToInternet)
        }
    }

    private struct SlowImporter: LibraryImporting {
        func importLibrary(mode: LibraryImportMode,
                           progress: @escaping @Sendable (LibraryImportProgress) -> Void) async throws -> LibraryImportSummary {
            progress(LibraryImportProgress(phase: "Scanning", completed: 10, total: 100))
            try await Task.sleep(for: .seconds(60))
            return LibraryImportSummary(added: 0, updated: 0, removed: 0)
        }
    }

    private func makeStore(importer: any LibraryImporting) throws -> LibraryStore {
        let persistence = PersistenceActor(modelContainer: try PersistenceActor.makeContainer(inMemory: true))
        return LibraryStore(loader: SnapshotLoader(persistence: persistence, cacheURL: nil), importer: importer)
    }

    func testAScanThatFailsLeavesNoProgressBehindAndSaysWhy() async throws {
        let store = try makeStore(importer: FailingImporter())
        do {
            try await store.refresh()
            XCTFail("the scan should have thrown")
        } catch {}
        XCTAssertNil(store.lastImportProgress, "a failed scan used to leave 40 % behind and the jobs button lit")
        XCTAssertEqual(store.scanFailure, "No internet connection.")
        XCTAssertFalse(store.isScanning)
        store.dismissScanFailure()
        XCTAssertNil(store.scanFailure)
    }

    func testCancellingAScanStopsItAndClearsItsProgress() async throws {
        let store = try makeStore(importer: SlowImporter())
        let scan = Task { try await store.refresh() }
        while !store.isScanning { await Task.yield() }
        store.cancelScans()
        XCTAssertNil(store.lastImportProgress, "the row goes at once")
        do {
            try await scan.value
            XCTFail("a cancelled scan throws")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertFalse(store.isScanning)
        XCTAssertNil(store.lastImportProgress)
        XCTAssertNil(store.scanFailure, "a cancel is not a failure")
    }

    // MARK: Active jobs

    private func jobs(_ fixture: ActiveJobsDemo.Fixture) -> ActiveJobs {
        ActiveJobs(demo: ActiveJobsDemo.rows(fixture), nowMs: ActiveJobsDemo.now)
    }

    func testFailedRowsDoNotLightTheButtonAndClearFinishedEmptiesTheList() {
        let sheet = jobs(.failures)
        XCTAssertEqual(sheet.badgeCount, 3, "only what runs counts")
        XCTAssertEqual(sheet.finishedCount, 6)
        XCTAssertEqual(sheet.snapshot().recent.count, ActiveJobBoard.recentLimit)
        sheet.clearFinished()
        XCTAssertTrue(sheet.snapshot().recent.isEmpty)
        XCTAssertEqual(sheet.finishedCount, 0)
        XCTAssertEqual(sheet.badgeCount, 3, "clearing never touches running work")
        XCTAssertEqual(sheet.snapshot().active.count, 3)
    }

    func testCancelAllRemovesEveryRunningAndWaitingRowAndKeepsTheFinishedOnes() {
        let sheet = jobs(.failures)
        sheet.cancelAll()
        XCTAssertEqual(sheet.badgeCount, 0, "nothing running: the button goes")
        XCTAssertFalse(sheet.isWorking)
        XCTAssertTrue(sheet.snapshot().active.isEmpty)
        XCTAssertEqual(sheet.finishedCount, 6)
    }

    func testDismissTakesOneFinishedRowAndRetryQueuesAFailedOne() throws {
        let sheet = jobs(.failures)
        let failed = try XCTUnwrap(sheet.snapshot().recent.first { $0.id == "download.failed.demo1" })
        XCTAssertTrue(failed.canRetry)
        sheet.retry(failed)
        XCTAssertEqual(sheet.badgeCount, 4, "a retried job is waiting again")
        XCTAssertEqual(sheet.snapshot().active.last?.id, "download.failed.demo1")
        let model = try XCTUnwrap(sheet.snapshot().recent.first { $0.id == "model.failed.llm" })
        sheet.dismiss(model)
        XCTAssertNil(sheet.snapshot().recent.first { $0.id == "model.failed.llm" })
        XCTAssertEqual(sheet.finishedCount, 4)
        // A running row is not dismissed, only cancelled.
        let running = try XCTUnwrap(sheet.snapshot().active.first { $0.id == "library" })
        sheet.dismiss(running)
        XCTAssertNotNil(sheet.snapshot().active.first { $0.id == "library" })
        sheet.cancel(running)
        XCTAssertNil(sheet.snapshot().active.first { $0.id == "library" })
    }

    func testEveryRowIdTheAggregatorBuildsPointsBackAtItsSource() {
        typealias Handle = ActiveJobs.Handle
        XCTAssertEqual(Handle(id: "library"), .library)
        XCTAssertEqual(Handle(id: "library.failed"), .libraryFailure)
        XCTAssertEqual(Handle(id: "spotify.sync"), .spotifySync)
        XCTAssertEqual(Handle(id: "spotify.sync.failed"), .spotifySyncFailure)
        XCTAssertEqual(Handle(id: "spotify.match"), .spotifyMatch)
        XCTAssertEqual(Handle(id: "spotify.match.failed"), .spotifyMatchFailure)
        XCTAssertEqual(Handle(id: "download.abc_DEF-123"), .download(videoId: "abc_DEF-123"))
        XCTAssertEqual(Handle(id: "download.failed.abc_DEF-123"), .downloadFailure(videoId: "abc_DEF-123"))
        XCTAssertEqual(Handle(id: "model.llm"), .model("llm"))
        XCTAssertEqual(Handle(id: "model.failed.llm"), .modelFailure("llm"))
        XCTAssertEqual(Handle(id: "tais.lyricsSync"), .studioKind(.lyricsSync))
        XCTAssertEqual(Handle(id: "tais.failed.lyricsSync.root/a.b.mp3"),
                       .studioSong(kind: .lyricsSync, songId: "root/a.b.mp3", failed: true))
        XCTAssertEqual(Handle(id: "tais.done.instrumental.s1"), .studioSong(kind: .instrumental, songId: "s1", failed: false))
        XCTAssertEqual(Handle(id: "cloud.batch-7"), .cloud(batchId: "batch-7"))
        XCTAssertNil(Handle(id: "bogus"))
        XCTAssertNil(Handle(id: "tais.bogus"))
        XCTAssertNil(Handle(id: "tais.failed.bogus.s1"))
    }
}
