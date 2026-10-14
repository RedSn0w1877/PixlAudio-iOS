import Foundation
import PixlModel
import QuartzCore
import SwiftUI
import Synchronization
import UIKit

// Where the app measures its own lag (docs/handoff/2026-10-12-lag.md), so a shared log says where it happens:
//
// - `MainThreadWatchdog`: a timer on a utility queue pings the main queue about every 100 ms; a stall of 250 ms or more
//   is logged (`hang` lines, ring-buffer file, written off the main thread) with the screen, scene, running job kinds,
//   thermal state and memory footprint captured *while* it was happening, and the last five go in the status block.
// - `HitchMeter`: one `CADisplayLink` while the app is active counts frames that took over 1.5x the frame time, per
//   screen and per minute, and logs the count and the worst gap only when something hitched.
// - `LongRunning`: a registry of what keeps running (timelines, display links, polling tasks), printed in the status.
//
// Overhead: the watchdog is 10 timer wakeups a second with a lock and one `async` hop to main; the meter is one small
// callback per frame with no allocation; nothing here touches a file on the main thread, and nothing pings while the app
// is not active. The rules (thresholds, summing) are PixlModel's `LagPolicy` / `HitchWindow`, tested there.

nonisolated struct HangRecord: Sendable, Equatable {
    let at: Date
    let milliseconds: Int
    let screen: String
    let scene: String
    let jobs: String
    let thermal: String
    let memoryMB: Int
    /// Still going when it was logged (the main thread had not answered yet).
    let ongoing: Bool

    var line: String {
        "\(ongoing ? "still blocked after" : "hang") \(milliseconds) ms; screen \(screen); scene \(scene); jobs \(jobs); "
            + "thermal \(thermal); memory \(memoryMB) MB"
    }
}

/// The values the watchdog thread reads about the app. Written on the main thread when they change.
nonisolated final class LagContext: Sendable {
    static let shared = LagContext()

    private struct State {
        var screen = "launch"
        var scene = "inactive"
        var active = false
    }

    private let state = Mutex(State())

    func setScreen(_ screen: String) { state.withLock { $0.screen = screen } }

    /// Stores the scene; returns whether "active" changed.
    func setScene(_ name: String, active: Bool) -> Bool {
        state.withLock { s in
            let changed = s.active != active
            s.scene = name
            s.active = active
            return changed
        }
    }

    var screen: String { state.withLock { $0.screen } }
    var scene: String { state.withLock { $0.scene } }
}

nonisolated final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private struct State {
        var started = false
        var active = false
        /// Bumped on every change of activity: a ping sent before it says nothing about the app after it.
        var epoch = 0
        var outstanding = false
        var sentNs: UInt64 = 0
        /// How long the last answered ping took, nil when none is waiting to be judged.
        var answeredMs: Int?
        /// What the app looked like when the current stall passed the threshold.
        var context: HangRecord?
        var loggedOngoing = false
        var hangs: [HangRecord] = []
        var total = 0
        var worstMs = 0
    }

    private enum Action {
        case none
        case ping(epoch: Int)
        case capture(waitedMs: Int)
        case stillBlocked(waitedMs: Int)
        case report(ms: Int, context: HangRecord?, epoch: Int)
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "io.github.redsn0w1877.pixlaudio.lag-watchdog", qos: .utility)
    private let timer = Mutex<(any DispatchSourceTimer)?>(nil)

    func start() {
        let first = state.withLock { s -> Bool in
            let wasStarted = s.started
            s.started = true
            return !wasStarted
        }
        guard first else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(40))
        source.setEventHandler { [self] in step() }
        source.resume()
        timer.withLock { $0 = source }
    }

    /// The app became active or stopped being (called on the main thread).
    func setActive(_ active: Bool) {
        state.withLock { s in
            guard s.active != active else { return }
            s.active = active
            s.epoch &+= 1
            s.outstanding = false
            s.answeredMs = nil
            s.context = nil
            s.loggedOngoing = false
        }
    }

    var recentHangs: [HangRecord] { state.withLock { $0.hangs } }
    var totals: (count: Int, worstMs: Int) { state.withLock { ($0.total, $0.worstMs) } }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// One tick on the utility queue.
    private func step() {
        let now = Self.now()
        let action: Action = state.withLock { s in
            guard s.active else { return .none }
            if s.outstanding {
                let waited = Int((now &- s.sentNs) / 1_000_000)
                if s.context == nil, LagPolicy.isHang(latencyMs: waited) { return .capture(waitedMs: waited) }
                if waited >= LagPolicy.stillBlockedMs, !s.loggedOngoing {
                    s.loggedOngoing = true
                    return .stillBlocked(waitedMs: waited)
                }
                return .none
            }
            let answered = s.answeredMs
            let context = s.context
            s.answeredMs = nil
            s.context = nil
            s.loggedOngoing = false
            s.outstanding = true
            s.sentNs = now
            if let answered, LagPolicy.isHang(latencyMs: answered) { return .report(ms: answered, context: context, epoch: s.epoch) }
            return .ping(epoch: s.epoch)
        }
        switch action {
        case .none:
            break
        case .ping(let epoch):
            ping(epoch: epoch)
        case .capture(let waited):
            let record = capture(milliseconds: waited, ongoing: false)
            state.withLock { $0.context = record }
        case .stillBlocked(let waited):
            DiagnosticsLog.shared.log("hang", capture(milliseconds: waited, ongoing: true).line)
        case .report(let ms, let context, let epoch):
            record(milliseconds: ms, context: context)
            ping(epoch: epoch)
        }
    }

    private func ping(epoch: Int) {
        DispatchQueue.main.async { [self] in
            let answeredAt = Self.now()
            state.withLock { s in
                guard s.epoch == epoch, s.outstanding else { return }
                s.outstanding = false
                s.answeredMs = Int((answeredAt &- s.sentNs) / 1_000_000)
            }
        }
    }

    private func capture(milliseconds: Int, ongoing: Bool) -> HangRecord {
        HangRecord(at: Date(), milliseconds: milliseconds, screen: LagContext.shared.screen, scene: LagContext.shared.scene,
                   jobs: JobTelemetry.shared.runningKinds(),
                   thermal: AppHealth.name(AppHealth.level(ProcessInfo.processInfo.thermalState)),
                   memoryMB: Int((AppHealth.memoryFootprintBytes() ?? 0) / 1_048_576), ongoing: ongoing)
    }

    private func record(milliseconds: Int, context: HangRecord?) {
        // The context was taken during the stall; the full length is only known now.
        let base = context ?? capture(milliseconds: milliseconds, ongoing: false)
        let finished = HangRecord(at: base.at, milliseconds: milliseconds, screen: base.screen, scene: base.scene,
                                  jobs: base.jobs, thermal: base.thermal, memoryMB: base.memoryMB, ongoing: false)
        state.withLock { s in
            s.hangs = LagPolicy.keepingRecent(s.hangs, adding: finished)
            s.total += 1
            s.worstMs = max(s.worstMs, milliseconds)
        }
        DiagnosticsLog.shared.log("hang", finished.line)
    }
}

/// Counts frames that took over 1.5x their time, per screen and per minute (main thread, one display link).
@MainActor
final class HitchMeter: NSObject {
    static let shared = HitchMeter()

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var window = HitchWindow()
    private var screen = "launch"
    private var active = false
    private(set) var totalHitches = 0
    private(set) var totalFrames = 0
    private(set) var worstMs = 0.0

    func setActive(_ isActive: Bool) {
        guard active != isActive else { return }
        if !isActive { flush() }
        active = isActive
        last = 0
        if isActive, link == nil {
            let newLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
            // Never asks the display for more than 60 Hz; the frame time it compares with is the link's own.
            newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            newLink.add(to: .main, forMode: .common)
            link = newLink
            LongRunning.shared.begin("diagnostics.hitchMeter (CADisplayLink, active only)")
        }
        link?.isPaused = !isActive
    }

    func setScreen(_ name: String) {
        guard name != screen else { return }
        flush()
        screen = name
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        guard last > 0 else {
            window.reset(startedAt: now)
            return
        }
        window.record(deltaMs: (now - last) * 1000, expectedMs: (link.targetTimestamp - now) * 1000)
        if window.isDue(nowSeconds: now) { flush(now: now) }
    }

    private func flush(now: CFTimeInterval = CACurrentMediaTime()) {
        if active, let summary = window.summary {
            totalHitches += window.hitches
            worstMs = max(worstMs, window.worstMs)
            DiagnosticsLog.shared.log("hitch", "screen \(screen): \(summary)")
        }
        totalFrames += window.frames
        window.reset(startedAt: now)
    }
}

/// What the app and the status block call.
@MainActor
enum LagMonitor {
    static func start() {
        MainThreadWatchdog.shared.start()
        LongRunning.shared.begin("diagnostics.hangWatchdog (utility timer, 10 Hz)")
    }

    static func sceneChanged(_ phase: ScenePhase) {
        let name: String
        switch phase {
        case .active: name = "active"
        case .inactive: name = "inactive"
        case .background: name = "background"
        @unknown default: name = "unknown"
        }
        let active = phase == .active
        guard LagContext.shared.setScene(name, active: active) else { return }
        MainThreadWatchdog.shared.setActive(active)
        HitchMeter.shared.setActive(active)
    }

    static func screenChanged(_ name: String) {
        LagContext.shared.setScreen(name)
        HitchMeter.shared.setScreen(name)
    }

    /// Rows for the Diagnostics status block and the shared report.
    static func statusRows() -> [(String, String)] {
        var rows: [(String, String)] = []
        let totals = MainThreadWatchdog.shared.totals
        rows.append(("Main-thread hangs this run", totals.count == 0 ? "none" : "\(totals.count), worst \(totals.worstMs) ms"))
        let meter = HitchMeter.shared
        rows.append(("Frame hitches this run",
                     meter.totalHitches == 0 ? "none logged" : "\(meter.totalHitches), worst \(Int(meter.worstMs.rounded())) ms"))
        for (index, hang) in MainThreadWatchdog.shared.recentHangs.enumerated() {
            rows.append(("Hang \(index + 1)", "\(hang.at.formatted(date: .omitted, time: .standard)) · \(hang.milliseconds) ms · "
                + "\(hang.screen) · jobs \(hang.jobs) · \(hang.thermal) · \(hang.memoryMB) MB"))
        }
        rows.append(("Long-running", LongRunning.shared.summary()))
        return rows
    }
}

/// Tells the monitor which screen is up (tab, the route on top of its stack, a sheet, a cover, the full player), as a
/// short label without ids: it re-evaluates only when navigation changes, and lives outside the shell's own body.
struct LagContextReporter: View {
    @Environment(Router.self) private var router
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let label = Self.label(router: router, playerExpanded: environment.playerSheet.isExpanded)
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: label, initial: true) { _, new in LagMonitor.screenChanged(new) }
    }

    private static func caseName<T>(_ value: T) -> String {
        let text = String(describing: value)
        return String(text.prefix { $0 != "(" })
    }

    static func label(router: Router, playerExpanded: Bool) -> String {
        var parts = [router.selection.rawValue]
        if let top = router.currentPath.last { parts.append(caseName(top)) }
        if let sheet = router.sheet { parts.append("sheet:" + caseName(sheet)) }
        if let cover = router.cover { parts.append("cover:" + caseName(cover)) }
        if playerExpanded { parts.append("fullPlayer") }
        return parts.joined(separator: ">")
    }
}
