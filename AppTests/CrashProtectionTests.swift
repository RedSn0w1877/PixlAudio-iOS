import Foundation
import PixlModel
import SwiftUI
import XCTest
@testable import PixlAudio

/// Crash protection and diagnostics (docs/handoff/2026-10-10-crash-diagnostics.md): the event log's cap and redaction,
/// the in-flight journal, how a launch decides the previous run ended abnormally (and what safe mode then does), the
/// pacing gate, and what Emergency stop leaves behind. The pure rules are tested in PixlModel; these are the app's
/// types wired to them.
@MainActor
final class CrashProtectionTests: XCTestCase {
    private var directories: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        directories = []
        suites = []
        super.tearDown()
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    // MARK: The event log

    func testTheLogStaysUnderItsCapAndKeepsTheNewestLines() throws {
        let directory = makeDirectory()
        let log = DiagnosticsLog(directory: directory, limitBytes: 4_000)
        for index in 0..<300 { log.log("job", "event number \(index) with some words to fill the line") }
        log.flush()
        let size = (try FileManager.default.attributesOfItem(atPath: log.fileURL!.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertLessThanOrEqual(size, 4_000)
        let text = log.snapshot()
        XCTAssertTrue(text.contains("event number 299 "), "the newest line survives")
        XCTAssertFalse(text.contains("event number 0 "), "the oldest lines were dropped")
        XCTAssertTrue(text.hasPrefix("… earlier events dropped"))
    }

    func testTheLogCarriesNoPathsUrlsOrAddresses() {
        let log = DiagnosticsLog(directory: makeDirectory())
        log.log("job", "failed reading /var/mobile/Containers/Data/Application/ABC/Documents/Song.mp3")
        log.log("net", "GET https://cdn.example.com/a/b/c.mp3?X-Amz-Signature=secret failed for me@example.com")
        let text = log.snapshot()
        XCTAssertFalse(text.contains("Containers"))
        XCTAssertFalse(text.contains("X-Amz-Signature"))
        XCTAssertFalse(text.contains("me@example.com"))
        XCTAssertTrue(text.contains("cdn.example.com"), "the host is useful and stays")
    }

    // MARK: The in-flight journal

    func testTheJournalSurvivesARelaunchAndOpaqueIdsHideTheSong() {
        let directory = makeDirectory()
        let log = DiagnosticsLog(directory: directory)
        let journal = directory.appendingPathComponent("in-flight.json")
        let first = JobTelemetry(log: log, journalURL: journal)
        first.started("lyricsSync", id: "song.secret-title-id")
        XCTAssertEqual(first.entries().map(\.kind), ["lyricsSync"])
        // A new process reads what the old one left.
        let second = JobTelemetry(log: log, journalURL: journal)
        XCTAssertEqual(second.entries().map(\.reference), ["song.secret-title-id"])
        second.ended("lyricsSync", id: "song.secret-title-id", .finished)
        XCTAssertTrue(second.entries().isEmpty)
        XCTAssertTrue(JobTelemetry(log: log, journalURL: journal).entries().isEmpty)
        let text = log.snapshot()
        XCTAssertTrue(text.contains("start lyricsSync #"))
        XCTAssertFalse(text.contains("secret-title-id"), "the log holds an opaque tag, not the id")
        XCTAssertTrue(text.contains("finish lyricsSync"))
    }

    func testAFailureAndACancelAreRecordedWithTheirReason() {
        let log = DiagnosticsLog(directory: makeDirectory())
        let telemetry = JobTelemetry(log: log, journalURL: nil)
        telemetry.started("instrumental", id: "a")
        telemetry.ended("instrumental", id: "a", .failed("no source at https://x.example/p?q=1"))
        telemetry.started("libraryScan", id: "b", heavy: false)
        telemetry.ended("libraryScan", id: "b", .cancelled("cancelled"))
        let text = log.snapshot()
        XCTAssertTrue(text.contains("fail (no source at https://x.example/…)"))
        XCTAssertTrue(text.contains("cancel (cancelled) libraryScan"))
        XCTAssertEqual(telemetry.runningCount, 0)
    }

    // MARK: How a launch decides

    private struct Rig {
        let health: AppHealth
        let gate: HeavyWorkGate
        let telemetry: JobTelemetry
    }

    private func makeHealth(defaults: UserDefaults, directory: URL, idle: Bool = true) -> Rig {
        let log = DiagnosticsLog(directory: directory)
        let telemetry = JobTelemetry(log: log, journalURL: directory.appendingPathComponent("in-flight.json"))
        let gate = HeavyWorkGate()
        let health = AppHealth(defaults: defaults, log: log, telemetry: telemetry, gate: gate,
                               markerURL: directory.appendingPathComponent("clean-exit"))
        health.isHeavyWorkIdle = { idle }
        health.launch()
        return Rig(health: health, gate: gate, telemetry: telemetry)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "pixlaudio.crash.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    func testACleanBackgroundThenARelaunchIsNotAnAbnormalEnd() {
        let defaults = makeDefaults(), directory = makeDirectory()
        let first = makeHealth(defaults: defaults, directory: directory)
        XCTAssertFalse(first.health.safeMode.isActive, "the first launch has nothing to compare with")
        first.health.scenePhaseChanged(.inactive)
        first.health.scenePhaseChanged(.background)
        let second = makeHealth(defaults: defaults, directory: directory)
        XCTAssertFalse(second.health.previousRunWasAbnormal)
        XCTAssertFalse(second.health.safeMode.isActive)
        XCTAssertFalse(second.gate.automaticStartsBlocked)
    }

    func testBeingKilledWhileWorkingIsAbnormalAndNothingResumesByItself() {
        let defaults = makeDefaults(), directory = makeDirectory()
        let first = makeHealth(defaults: defaults, directory: directory)
        // A lyric sync is in flight when the process dies: no clean marker, the journal still lists it.
        first.telemetry.started("lyricsSync", id: "song.1")
        let second = makeHealth(defaults: defaults, directory: directory)
        XCTAssertTrue(second.health.previousRunWasAbnormal)
        XCTAssertTrue(second.health.safeMode.isActive)
        XCTAssertTrue(second.health.safeMode.showsBanner)
        XCTAssertTrue(second.gate.automaticStartsBlocked, "automatic heavy starts are blocked")
        XCTAssertFalse(second.gate.allowsLaunchWork)
        XCTAssertFalse(second.gate.allowsAutomaticStart)
        XCTAssertEqual(second.health.interrupted.map(\.kind), ["lyricsSync"])
        XCTAssertTrue(second.telemetry.entries().isEmpty, "the journal starts empty for the new run")
    }

    func testBackgroundingWhileHeavyWorkRunsLeavesNoCleanMarker() {
        let defaults = makeDefaults(), directory = makeDirectory()
        let first = makeHealth(defaults: defaults, directory: directory, idle: false)
        first.health.scenePhaseChanged(.background)
        let second = makeHealth(defaults: defaults, directory: directory)
        XCTAssertTrue(second.health.previousRunWasAbnormal, "work was still running when the app went away")
    }

    func testRetryLiftsSafeModeAndADoubleCrashMakesItStayUntilTurnedOff() {
        let defaults = makeDefaults(), directory = makeDirectory()
        _ = makeHealth(defaults: defaults, directory: directory)
        var rig = makeHealth(defaults: defaults, directory: directory)
        XCTAssertTrue(rig.health.safeMode.isActive)
        rig.health.userRetried()
        XCTAssertFalse(rig.health.safeMode.isActive)
        XCTAssertFalse(rig.gate.automaticStartsBlocked, "Retry is the go-ahead")
        // The retried work killed the app again.
        rig = makeHealth(defaults: defaults, directory: directory)
        XCTAssertTrue(rig.health.safeMode.isSticky)
        // Clean sessions do not clear a sticky safe mode.
        rig.health.scenePhaseChanged(.background)
        rig = makeHealth(defaults: defaults, directory: directory)
        XCTAssertTrue(rig.health.safeMode.isActive)
        XCTAssertTrue(rig.gate.automaticStartsBlocked)
        // Turning it off in Settings does.
        rig.health.setSafeMode(false)
        XCTAssertFalse(rig.health.safeMode.isActive)
        XCTAssertFalse(rig.gate.automaticStartsBlocked)
        rig.health.scenePhaseChanged(.background)
        rig = makeHealth(defaults: defaults, directory: directory)
        XCTAssertFalse(rig.health.safeMode.isActive)
    }

    func testStartingWorkByHandFromTheCloudQueueLiftsSafeMode() async {
        let defaults = makeDefaults(), directory = makeDirectory()
        _ = makeHealth(defaults: defaults, directory: directory)
        let rig = makeHealth(defaults: defaults, directory: directory)
        XCTAssertTrue(rig.gate.automaticStartsBlocked)
        rig.gate.userStartedHeavyWork()
        for _ in 0..<200 where rig.health.safeMode.isActive { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(rig.health.safeMode.isActive)
        XCTAssertFalse(rig.gate.automaticStartsBlocked)
    }

    func testTheReportStartsWithTheBuildAndHoldsTheLog() {
        let defaults = makeDefaults(), directory = makeDirectory()
        let rig = makeHealth(defaults: defaults, directory: directory)
        let text = rig.health.report(running: 1, waiting: 2)
        XCTAssertTrue(text.hasPrefix("PixlAudio diagnostics"))
        XCTAssertTrue(text.contains(BuildIdentity.summary))
        XCTAssertTrue(text.contains("Heavy jobs running: 1"))
        XCTAssertTrue(text.contains("Heavy jobs waiting: 2"))
        XCTAssertTrue(text.contains("Memory footprint:"))
        XCTAssertTrue(text.contains("Safe mode: off"))
        XCTAssertTrue(text.contains("launch"), "the launch is in the event log")
        let file = rig.health.reportFile(running: 0, waiting: 0)
        XCTAssertEqual(file?.pathExtension, "txt")
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    func testTheMemoryFootprintIsReadable() {
        let bytes = AppHealth.memoryFootprintBytes()
        XCTAssertNotNil(bytes)
        XCTAssertGreaterThan(bytes ?? 0, 1_000_000)
    }

    // MARK: The pacing gate

    func testTheGatePausesInTheBackgroundAndRunsInsideAWindow() {
        let gate = HeavyWorkGate()
        XCTAssertEqual(gate.verdict, .run(dutyCycle: HeavyWorkPolicy.baseDutyCycle))
        gate.setForeground(false)
        XCTAssertEqual(gate.verdict, .pause(.background))
        gate.windowOpened()
        XCTAssertEqual(gate.verdict, .run(dutyCycle: HeavyWorkPolicy.baseDutyCycle))
        gate.windowClosed()
        XCTAssertEqual(gate.verdict, .pause(.background))
        gate.setForeground(true)
        gate.setSystem(thermal: .serious, lowPower: false)
        XCTAssertEqual(gate.verdict, .pause(.thermal))
        gate.setSystem(thermal: .nominal, lowPower: true)
        XCTAssertEqual(gate.verdict, .run(dutyCycle: HeavyWorkPolicy.lowPowerDutyCycle))
        gate.noteMemoryPressure()
        XCTAssertEqual(gate.verdict, .run(dutyCycle: HeavyWorkPolicy.memoryPressureDutyCycle))
    }

    func testAPausedCheckpointWaitsAndCancellationEndsIt() async {
        let gate = HeavyWorkGate()
        let pacer = gate.makePacer()
        gate.setForeground(false)
        let task = Task.detached { try pacer.checkpoint() }
        try? await Task.sleep(for: .milliseconds(500))
        task.cancel()
        let result = await task.result
        if case .success = result { XCTFail("a paused checkpoint must not return before the app is back") }
        gate.setForeground(true)
        // In the foreground it returns at once.
        XCTAssertNoThrow(try gate.makePacer().checkpoint())
    }

    func testEmergencyStopAndSafeModeSuspendAutomaticStartsOnly() {
        let gate = HeavyWorkGate()
        XCTAssertTrue(gate.allowsLaunchWork)
        gate.suspendAutomaticStarts(forMs: 60_000)
        XCTAssertFalse(gate.allowsLaunchWork)
        XCTAssertFalse(gate.allowsAutomaticStart)
        XCTAssertEqual(gate.verdict, .run(dutyCycle: HeavyWorkPolicy.baseDutyCycle), "work the person starts still runs")
    }

    func testAGenerationStopsWhenEverythingHeavyIsToldToStop() {
        HeavyWorkGate.shared.setForeground(true)
        let flag = CancelFlag()
        XCTAssertFalse(flag.isSet)
        HeavyWorkGate.shared.abortHeavyWork()
        XCTAssertTrue(flag.isSet)
        XCTAssertFalse(CancelFlag().isSet, "a later request is not affected")
    }

    // MARK: Emergency stop

    func testEmergencyStopEmptiesEveryRowOfTheDemoSheet() {
        let rows = ActiveJobsDemo.rows(.mixed) + ActiveJobsDemo.rows(.interrupted)
        let jobs = ActiveJobs(demo: rows, nowMs: ActiveJobsDemo.now)
        XCTAssertGreaterThan(jobs.badgeCount, 0)
        jobs.emergencyStop()
        XCTAssertEqual(jobs.badgeCount, 0)
        XCTAssertTrue(jobs.active.isEmpty)
        XCTAssertTrue(jobs.recent.isEmpty)
        XCTAssertEqual(jobs.finishedCount, 0)
    }

    private func makeStudio() -> TaisStudio {
        let settings = SettingsStore.ephemeral()
        let controller = LyricsController(store: LyricsStore(), settings: settings, persistence: nil, isUITest: true)
        let dependencies = TaisStudio.Dependencies(settings: settings, lyricsService: nil, lyricsController: controller,
                                                   audioSource: { _ in
                                                       try await Task.sleep(for: .seconds(60))
                                                       throw CancellationError()
                                                   })
        return TaisStudio(models: ModelManager(isDemo: true), dependencies: dependencies)
    }

    func testALowMemoryStopEndsRunningAndWaitingJobsWithAReasonAndFreesTheLane() async throws {
        let studio = makeStudio()
        let first = DemoLibrary.songs[0], second = DemoLibrary.songs[1]
        studio.start(.instrumental, song: first, unattended: true)
        studio.start(.instrumental, song: second, unattended: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(studio.activeCount, 2)
        studio.stopForMemory()
        XCTAssertEqual(studio.activeCount, 0, "the rows say so at once")
        try await Task.sleep(for: .milliseconds(300))
        for song in [first, second] {
            guard case .failed(let reason)? = studio.state(.instrumental, songId: song.id)?.phase else {
                return XCTFail("\(song.title) did not end as failed")
            }
            XCTAssertTrue(reason.contains("low on memory"))
        }
        XCTAssertFalse(HeavyJobGovernor.shared.isBusy)
        studio.clearFinished()
        XCTAssertTrue(studio.jobs.isEmpty, "a stop followed by Clear leaves nothing behind")
    }

    func testCancelAllThenClearFinishedLeavesTheStudioEmpty() async throws {
        let studio = makeStudio()
        for song in DemoLibrary.songs.prefix(3) { studio.start(.lyrics, song: song, unattended: true) }
        try await Task.sleep(for: .milliseconds(150))
        studio.cancelAll()
        XCTAssertEqual(studio.activeCount, 0)
        try await Task.sleep(for: .milliseconds(300))
        studio.clearFinished()
        XCTAssertTrue(studio.jobs.isEmpty)
        studio.releaseModels()
    }

    func testAMemoryWarningStopsTheWorkNobodyAskedFor() async throws {
        let studio = makeStudio()
        let running = DemoLibrary.songs[0], waiting = DemoLibrary.songs[1]
        studio.start(.lyrics, song: running, unattended: true)
        studio.start(.lyrics, song: waiting, unattended: true)
        try await Task.sleep(for: .milliseconds(150))
        studio.handleMemoryWarning()
        XCTAssertEqual(studio.state(.lyrics, songId: waiting.id)?.phase, .cancelled, "a waiting job stops at once")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(studio.activeCount, 0, "the running one stopped too")
        XCTAssertFalse(HeavyJobGovernor.shared.isBusy)
    }
}
