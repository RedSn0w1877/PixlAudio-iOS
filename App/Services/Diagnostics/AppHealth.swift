import Foundation
import Observation
import PixlModel
import SwiftUI
import UIKit

/// What the app knows about its own health (docs/handoff/2026-10-10-crash-diagnostics.md):
///
/// - **Safe mode.** At launch it decides how the previous run ended (a clean-exit marker file, written when the app goes
///   to the background with nothing heavy running or is told to terminate, deleted when the app becomes active; plus
///   MetricKit crash payloads), applies `SafeModePolicy`, and tells `HeavyWorkGate` so nothing heavy starts by itself.
///   What was running (the in-flight journal) becomes "Interrupted" rows with a Retry in Active jobs.
/// - **Being a good citizen.** Scene phase, thermal state, Low Power Mode and memory pressure go to `HeavyWorkGate`;
///   a memory warning releases what can be released.
/// - **The event log** (`DiagnosticsLog`) for every one of those decisions, and the report that Share logs sends.
@MainActor
@Observable
final class AppHealth {
    /// Safe mode as the policy decided for this run (stored in `UserDefaults`).
    private(set) var safeMode: SafeModeState
    /// What the previous run left in flight when it ended abnormally (empty after a clean end).
    private(set) var interrupted: [InFlightEntry]
    /// The previous run ended abnormally (this launch's verdict; the banner reads `safeMode.showsBanner`).
    private(set) var previousRunWasAbnormal = false
    /// The previous run died with the downloaded AI model in flight: "Use downloaded AI model" was turned off (the owner of
    /// `AppEnvironment` does that) and Home's banner says so until dismissed.
    private(set) var localModelBlamed = false
    private(set) var scenePhase: ScenePhase = .active
    private(set) var thermal: ThermalLevel = .nominal
    private(set) var lowPowerMode = false
    private(set) var lastMemoryWarningAt: Date?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log: DiagnosticsLog
    @ObservationIgnored private let telemetry: JobTelemetry
    @ObservationIgnored private let gate: HeavyWorkGate
    @ObservationIgnored private let markerURL: URL?
    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var memorySource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var markerWatcher: Task<Void, Never>?
    @ObservationIgnored private var metricKitCountedThisLaunch = false
    /// This run has been the foreground app at least once (the first `.active` scene phase).
    @ObservationIgnored private var runWasForeground = false
    /// `reachedActiveKey` is currently set in the defaults (it is cleared with every clean-exit marker, so every return
    /// to the front sets it again: a crash in a second stretch in front must still count).
    @ObservationIgnored private var reachedActiveMarked = false

    /// Wired by `AppEnvironment`: a memory warning (release what is idle, stop what is automatic) and a critical
    /// memory event (stop all heavy work, saying why).
    @ObservationIgnored var onMemoryWarning: (() -> Void)?
    @ObservationIgnored var onMemoryCritical: (() -> Void)?
    /// Wired by `AppEnvironment`: nothing heavy is running (the marker may be written).
    @ObservationIgnored var isHeavyWorkIdle: () -> Bool = { true }

    private static let stateKey = "diagnostics.safeMode.v1"
    private static let hasRunKey = "diagnostics.hasRun.v1"
    /// Set on the first `.active` of a run, cleared when the clean-exit marker is written: a run that dies with it set
    /// was in front and did not end cleanly.
    private static let reachedActiveKey = "diagnostics.reachedActive.v1"
    private static let foregroundMarker = "clean-fg"

    /// `demo`: a fixed state for UI tests (no files, no observers).
    init(defaults: UserDefaults = .standard, log: DiagnosticsLog = .shared, telemetry: JobTelemetry = .shared,
         gate: HeavyWorkGate = .shared, markerURL: URL? = DiagnosticsFiles.cleanExitMarker, demo: SafeModeState? = nil,
         demoInterrupted: [InFlightEntry] = []) {
        self.defaults = defaults
        self.log = log
        self.telemetry = telemetry
        self.gate = gate
        self.markerURL = markerURL
        isDemo = demo != nil
        safeMode = demo ?? SafeModeState()
        interrupted = demoInterrupted
        previousRunWasAbnormal = demo?.isActive ?? false
    }

    // MARK: Launch

    /// First thing at launch: how did the last run end, and what does that mean for this one.
    func launch(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        guard !isDemo else { return }
        let stored = defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(SafeModeState.self, from: $0) }
            ?? SafeModeState()
        let hasRun = defaults.bool(forKey: Self.hasRunKey)
        let markerData = markerURL.flatMap { try? Data(contentsOf: $0) }
        let reachedActive = defaults.bool(forKey: Self.reachedActiveKey)
        defaults.set(true, forKey: Self.hasRunKey)
        defaults.set(false, forKey: Self.reachedActiveKey)
        // From here on, until the app is backgrounded idle, a kill while in front counts as abnormal.
        if let markerURL { try? FileManager.default.removeItem(at: markerURL) }
        let left = telemetry.entries()
        let end = SafeModePolicy.classify(PreviousRunFacts(
            hasRunBefore: hasRun, cleanMarkerPresent: markerData != nil,
            markerWasForeground: markerData.map { String(decoding: $0, as: UTF8.self) != "clean-bg" } ?? false,
            reachedActive: reachedActive, heavyJobsInFlight: left.count))
        let next = SafeModePolicy.launch(previous: stored, end: end, nowMs: nowMs)
        if case .abnormal = end {
            previousRunWasAbnormal = true
            metricKitCountedThisLaunch = true
            interrupted = left
            localModelBlamed = SafeModePolicy.blamesLocalModel(left)
            log.log("health", "previous run ended abnormally; in flight: \(left.map(\.kind).joined(separator: ","))")
        } else {
            interrupted = []
            if case .ignored = end {
                log.log("health", "previous run not counted (never in front, or ended without heavy work); in flight: \(left.count)")
            } else if !left.isEmpty { log.log("health", "cleared \(left.count) stale in-flight entries after a clean end") }
        }
        telemetry.clearJournal()
        gate.setUserLiftHandler { [weak self] in
            Task { @MainActor in self?.userRetried() }
        }
        apply(next, reason: "launch (\(Self.words(end)))")
        log.log("lifecycle", "launch \(BuildIdentity.summary)")
        observeSystem()
    }

    private static func words(_ end: PreviousRunEnd) -> String {
        switch end {
        case .firstLaunch: "first launch"
        case .clean: "clean end"
        case .abnormal(let source): "abnormal end: \(source.rawValue)"
        case .ignored: "not counted"
        }
    }

    // MARK: Scene phase

    /// From `PixlAudioApp`'s `onChange(of: scenePhase)`.
    func scenePhaseChanged(_ phase: ScenePhase) {
        if !isDemo { LagMonitor.sceneChanged(phase) }
        if phase == .active, !isDemo {
            // The app is in front: from now on a death with heavy work in flight is abnormal. Set again after every
            // clean background (`writeMarker` clears it), not only the first time.
            runWasForeground = true
            if !reachedActiveMarked {
                reachedActiveMarked = true
                defaults.set(true, forKey: Self.reachedActiveKey)
            }
        }
        guard phase != scenePhase else { return }
        let before = scenePhase
        scenePhase = phase
        guard !isDemo else { return }
        switch phase {
        case .active:
            gate.setForeground(true)
            markerWatcher?.cancel()
            markerWatcher = nil
            if let markerURL { try? FileManager.default.removeItem(at: markerURL) }
            log.log("lifecycle", "active")
        case .inactive:
            // Heavy work yields as soon as the app stops being the one in front (a snapshot may be taken now).
            gate.setForeground(false)
            if before == .active { log.log("lifecycle", "inactive") }
        case .background:
            gate.setForeground(false)
            log.log("lifecycle", "background; heavy work idle: \(isHeavyWorkIdle())")
            writeMarkerWhenIdle()
        @unknown default:
            break
        }
    }

    /// Clean-exit marker: written when the app is out of the foreground and nothing heavy is in flight, and again when it
    /// is told to terminate. While heavy work is still finishing in a granted window it is checked every few seconds.
    private func writeMarkerWhenIdle() {
        if isHeavyWorkIdle() {
            writeMarker()
            return
        }
        markerWatcher?.cancel()
        markerWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.scenePhase != .active else { return }
                if self.isHeavyWorkIdle() {
                    self.writeMarker()
                    return
                }
            }
        }
    }

    private func writeMarker() {
        guard let markerURL else { return }
        defaults.set(false, forKey: Self.reachedActiveKey)
        reachedActiveMarked = false
        try? Data((runWasForeground ? Self.foregroundMarker : "clean-bg").utf8).write(to: markerURL, options: .atomic)
        log.log("health", "clean-exit marker written")
        log.flush()
    }

    // MARK: Safe mode

    private func apply(_ state: SafeModeState, reason: String) {
        let changed = state != safeMode
        safeMode = state
        gate.setAutomaticStartsBlocked(state.isActive)
        if !isDemo, let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) }
        if changed || reason.hasPrefix("launch") {
            log.log("safemode", "\(state.isActive ? "on" : "off") (\(reason)); abnormal in a row: \(state.consecutiveAbnormal)")
        }
    }

    /// Retry (an interrupted row, the banner): heavy work may run now.
    func userRetried() {
        apply(SafeModePolicy.userRetried(safeMode), reason: "user retried")
    }

    func dismissBanner() {
        localModelBlamed = false
        apply(SafeModePolicy.bannerDismissed(safeMode), reason: "banner dismissed")
    }

    /// Settings: the Safe mode switch.
    func setSafeMode(_ on: Bool) {
        apply(SafeModePolicy.setByUser(safeMode, on: on), reason: on ? "user turned it on" : "user turned it off")
        if !on { interrupted = [] }
    }

    func dismissInterrupted(_ entry: InFlightEntry) {
        interrupted.removeAll { $0 == entry }
    }

    func clearInterrupted() {
        interrupted = []
    }

    /// MetricKit delivered a crash / hang / exception diagnostic.
    func metricKitReported(crashLike: Bool) {
        guard crashLike else { return }
        let next = SafeModePolicy.metricKitCrash(safeMode, alreadyCounted: metricKitCountedThisLaunch,
                                                 nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        metricKitCountedThisLaunch = true
        if next != safeMode { apply(next, reason: "MetricKit diagnostic") }
    }

    // MARK: System conditions

    private func observeSystem() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        refreshSystemConditions(logChanges: false)
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemConditions(logChanges: true) }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemConditions(logChanges: true) }
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.memoryWarning(source: "memory warning") }
        })
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log.log("lifecycle", "will terminate")
                self?.writeMarker()
            }
        })
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let critical = source?.data.contains(.critical) ?? false
            MainActor.assumeIsolated { self?.memoryWarning(source: critical ? "memory pressure: critical" : "memory pressure: warning", critical: critical) }
        }
        source.resume()
        memorySource = source
    }

    private func refreshSystemConditions(logChanges: Bool) {
        let level = Self.level(ProcessInfo.processInfo.thermalState)
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if logChanges, level != thermal { log.log("system", "thermal state \(Self.name(level))") }
        if logChanges, lowPower != lowPowerMode { log.log("system", "Low Power Mode \(lowPower ? "on" : "off")") }
        thermal = level
        lowPowerMode = lowPower
        gate.setSystem(thermal: level, lowPower: lowPower)
    }

    private func memoryWarning(source: String, critical: Bool = false) {
        lastMemoryWarningAt = Date()
        gate.noteMemoryPressure()
        log.log("memory", "\(source); footprint \(Self.footprintText())")
        if critical {
            gate.abortHeavyWork()
            onMemoryCritical?()
        }
        onMemoryWarning?()
    }

    nonisolated static func level(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .fair
        }
    }

    nonisolated static func name(_ level: ThermalLevel) -> String {
        switch level {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        }
    }

    // MARK: Status and report

    /// The app's physical memory footprint (the number the system's memory limit is measured on).
    nonisolated static func memoryFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    nonisolated static func footprintText() -> String {
        guard let bytes = memoryFootprintBytes() else { return "unknown" }
        return "\(bytes / 1_048_576) MB"
    }

    /// The live status rows (Diagnostics screen and the shared report).
    func statusRows(running: Int, waiting: Int) -> [(String, String)] {
        [
            ("Memory footprint", Self.footprintText()),
            ("Physical memory", "\(ProcessInfo.processInfo.physicalMemory / 1_048_576) MB"),
            ("Thermal state", Self.name(thermal)),
            ("Low Power Mode", lowPowerMode ? "on" : "off"),
            ("Heavy jobs running", "\(running)"),
            ("Heavy jobs waiting", "\(waiting)"),
            ("Scene", Self.sceneName(scenePhase)),
            ("Last memory warning", lastMemoryWarningAt.map { "\(Int(Date().timeIntervalSince($0))) s ago" } ?? "none this run"),
            ("Previous run", previousRunWasAbnormal ? "ended unexpectedly" : "ended normally"),
            ("Device", Self.deviceIdentifier()),
            ("iOS", UIDevice.current.systemVersion),
        ] + LagMonitor.statusRows()
    }

    private static func sceneName(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    nonisolated static func deviceIdentifier() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    var safeModeDescription: String {
        guard safeMode.isActive else { return safeMode.liftedByUser ? "off for this run (retried)" : "off" }
        if safeMode.manual { return "ON (turned on by hand; stays until turned off)" }
        if safeMode.metricKitConfirmed { return "ON (MetricKit confirmed a crash; ends after two clean sessions in front)" }
        return "ON (\(safeMode.consecutiveAbnormal) abnormal end(s); ends after one clean session in front)"
    }

    /// The text Share logs sends: build identity, status, event log, MetricKit payload summaries.
    func report(running: Int, waiting: Int) -> String {
        DiagnosticReport.assemble(identity: BuildIdentity.summary, status: statusRows(running: running, waiting: waiting),
                                  safeMode: safeModeDescription, log: log.snapshot(),
                                  metricKit: MetricKitCollector.storedSummaries())
    }

    /// The report written to a temporary file for the share sheet (a `.txt` the owner can send).
    func reportFile(running: Int, waiting: Int) -> URL? {
        let text = report(running: running, waiting: waiting)
        let stamp = BuildIdentity.fileStamp
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PixlAudio-diagnostics-\(stamp).txt")
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
