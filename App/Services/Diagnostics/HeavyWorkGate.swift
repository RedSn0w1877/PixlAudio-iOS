import Foundation
import PixlModel
import Synchronization

/// One process-wide, thread-safe answer to "may heavy work run right now, and how hard?" (`HeavyWorkPolicy` holds the
/// rules; this holds the facts the system reported: the scene phase, thermal state, Low Power Mode, a recent memory
/// warning, and whether iOS granted a background window).
///
/// Heavy loops (lyric alignment's windows, the separator's chunks, the cloud decode's buffers) call
/// `WorkPacer.checkpoint()` between chunks: it throws when the task was cancelled, waits while the verdict is "pause"
/// (the app is not in the foreground and has no window, or the phone is hot), and sleeps a share of the time otherwise,
/// so the average CPU stays well under half a core's worth. See docs/handoff/2026-10-10-crash-diagnostics.md.
nonisolated final class HeavyWorkGate: Sendable {
    static let shared = HeavyWorkGate()

    private nonisolated struct State {
        var foreground = true
        var windows = 0
        var thermal: ThermalLevel = .nominal
        var lowPower = false
        var memoryPressureUntilMs: Int64 = 0
        var autoBlocked = false
        var autoSuspendedUntilMs: Int64 = 0
        /// Bumped when everything heavy must stop at its next step (a critical memory event).
        var abortEpoch = 0
        var handles: [Int: @Sendable () -> Void] = [:]
        var nextHandle = 0
    }

    private let state = Mutex(State())
    /// The duty cycle's sleeps are for a phone in a person's hand; a unit-test host runs the models at full speed (the
    /// pause rules still apply).
    let pacesDutyCycle = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    private let liftHandler = Mutex<(@Sendable () -> Void)?>(nil)

    private static func nowMs() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    // MARK: Facts

    func setForeground(_ value: Bool) { state.withLock { $0.foreground = value } }

    func setSystem(thermal: ThermalLevel, lowPower: Bool) {
        state.withLock {
            $0.thermal = thermal
            $0.lowPower = lowPower
        }
    }

    /// A memory warning or pressure event: heavy work slows down for 30 s.
    func noteMemoryPressure() { state.withLock { $0.memoryPressureUntilMs = Self.nowMs() + 30_000 } }

    /// iOS gave the app time to finish (a background task assertion, a continued-processing task, a BGTask).
    func windowOpened() { state.withLock { $0.windows += 1 } }

    func windowClosed() { state.withLock { $0.windows = max($0.windows - 1, 0) } }

    /// Safe mode: automatic heavy starts are blocked until the person retries or turns it off.
    func setAutomaticStartsBlocked(_ value: Bool) { state.withLock { $0.autoBlocked = value } }

    /// Who to tell when the person starts heavy work by hand while safe mode is on (`AppHealth` lifts safe mode).
    func setUserLiftHandler(_ handler: (@Sendable () -> Void)?) { liftHandler.withLock { $0 = handler } }

    /// The person started heavy work on purpose (sent songs to the cloud, pressed Retry): safe mode lifts.
    func userStartedHeavyWork() {
        guard automaticStartsBlocked else { return }
        let handler = liftHandler.withLock { $0 }
        handler?()
    }

    /// Emergency stop: automatic starts stay off for a while so nothing begins again behind the person's back.
    func suspendAutomaticStarts(forMs duration: Int64) { state.withLock { $0.autoSuspendedUntilMs = Self.nowMs() + duration } }

    /// A way to stop one piece of running work, whatever rows show. Emergency stop calls every handle.
    func registerCancel(_ handler: @escaping @Sendable () -> Void) -> Int {
        state.withLock { state in
            state.nextHandle += 1
            state.handles[state.nextHandle] = handler
            return state.nextHandle
        }
    }

    func unregisterCancel(_ id: Int) { state.withLock { _ = $0.handles.removeValue(forKey: id) } }

    /// Runs every registered cancel handle; returns how many there were.
    @discardableResult
    func cancelAllHandles() -> Int {
        let handlers = state.withLock { Array($0.handles.values) }
        for handler in handlers { handler() }
        return handlers.count
    }

    /// Everything heavy that is running stops at its next step.
    func abortHeavyWork() { state.withLock { $0.abortEpoch += 1 } }

    // MARK: Questions

    var isForeground: Bool { state.withLock { $0.foreground } }

    var automaticStartsBlocked: Bool { state.withLock { $0.autoBlocked } }

    var abortEpoch: Int { state.withLock { $0.abortEpoch } }

    var hasBackgroundWindow: Bool { state.withLock { $0.windows > 0 } }

    var conditions: HeavyWorkConditions {
        let now = Self.nowMs()
        return state.withLock {
            HeavyWorkConditions(isForeground: $0.foreground, hasBackgroundWindow: $0.windows > 0, thermal: $0.thermal,
                                lowPowerMode: $0.lowPower, recentMemoryPressure: now < $0.memoryPressureUntilMs)
        }
    }

    var verdict: HeavyWorkVerdict { HeavyWorkPolicy.verdict(conditions) }

    /// Automatic work (the automatic studio) may start now: not in safe mode, not after an Emergency stop, and a quiet,
    /// cool foreground phone.
    var allowsAutomaticStart: Bool { allowsLaunchWork && HeavyWorkPolicy.allowsAutomaticStart(conditions) }

    /// Work that starts by itself at launch or when the app opens (the library rescan, the Spotify matcher, Cloud
    /// Studio's preparations): only safe mode, an Emergency stop and a very hot phone hold it back.
    var allowsLaunchWork: Bool {
        let now = Self.nowMs()
        return state.withLock { !$0.autoBlocked && now >= $0.autoSuspendedUntilMs && $0.thermal < .serious }
    }

    /// A model may use the Neural Engine now.
    var prefersNeuralEngine: Bool { HeavyWorkPolicy.prefersNeuralEngine(conditions) }

    func makePacer() -> WorkPacer { WorkPacer(gate: self) }
}

/// One heavy loop's pacing: tracks how long it computed since the last checkpoint and sleeps the share the verdict asks
/// for. Used by one task at a time.
nonisolated final class WorkPacer: @unchecked Sendable {
    private let gate: HeavyWorkGate
    private var markMs: Int64
    private var pausedLogged = false

    /// Shorter stretches are not worth a sleep (a decode loop calls this per buffer).
    private static let minimumBusyMs: Int64 = 120

    fileprivate init(gate: HeavyWorkGate) {
        self.gate = gate
        markMs = Self.now()
    }

    private static func now() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    /// Between two chunks of work: throws `CancellationError` when cancelled, waits while paused, sleeps for the duty
    /// cycle. Blocks the calling thread (heavy loops are synchronous inside their actor or `@concurrent` function).
    func checkpoint() throws {
        try Task.checkCancellation()
        while true {
            switch gate.verdict {
            case .pause(let reason):
                if !pausedLogged {
                    pausedLogged = true
                    DiagnosticsLog.shared.log("pace", "heavy work paused (\(reason.rawValue))")
                }
                Thread.sleep(forTimeInterval: 0.3)
                try Task.checkCancellation()
                markMs = Self.now()
            case .run(let duty):
                if pausedLogged {
                    pausedLogged = false
                    DiagnosticsLog.shared.log("pace", "heavy work resumed")
                }
                let busy = Self.now() - markMs
                guard busy >= Self.minimumBusyMs, gate.pacesDutyCycle else { return }
                var remaining = HeavyWorkPolicy.idleMs(afterBusyMs: busy, dutyCycle: duty)
                while remaining > 0 {
                    let slice = min(remaining, 100)
                    Thread.sleep(forTimeInterval: Double(slice) / 1000)
                    remaining -= slice
                    try Task.checkCancellation()
                    // The conditions may have turned to "pause" while sleeping.
                    if case .pause = gate.verdict { break }
                }
                if case .pause = gate.verdict { continue }
                markMs = Self.now()
                return
            }
        }
    }
}
