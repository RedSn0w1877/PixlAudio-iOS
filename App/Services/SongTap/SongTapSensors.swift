import CoreMotion
import Foundation
import PixlFoundation
import PixlLibrary

/// The two clocks Song Tap uses: a monotonic one for signal and motion timing (the system's uptime, the same clock CoreMotion
/// stamps its readings with), the wall clock for the timestamp of a signed offer.
@MainActor
final class SongTapSystemClock: SongTapClock {
    func elapsedMs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    func wallMs() -> Int64 { currentTimeMillis() }
}

/// Timers for the Bluetooth route: one housekeeping loop while armed, and one-shot delays.
@MainActor
final class SongTapTaskScheduler: SongTapBleScheduler {
    private var ticker: Task<Void, Never>?

    func startTicking(everyMs: Int64, _ tick: @escaping @MainActor () -> Void) {
        ticker?.cancel()
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(everyMs))
                if Task.isCancelled { return }
                tick()
            }
        }
    }

    func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    func after(ms: Int64, _ action: @escaping @MainActor () -> Void) {
        Task {
            try? await Task.sleep(for: .milliseconds(ms))
            action()
        }
    }
}

/// "The phone was jerked": the accelerometer, read 50 times a second and only between `start` and `stop` (that is, only while
/// Song Tap is armed on screen). The jerk rule itself (a sharp change between two readings, debounced) is
/// `SongTapImpulse` in the core; this converts CoreMotion's g to milli g and hands it over. Android's twin is
/// `SensorImpulseSource`.
@MainActor
final class SongTapMotionSource: SongTapImpulseSource {
    private var motion: SongTapMotion?

    func start(onImpulse: @escaping @MainActor (Int64) -> Void) {
        motion?.stop()
        let made = SongTapMotion { tMs in
            DispatchQueue.main.async { MainActor.assumeIsolated { onImpulse(tMs) } }
        }
        motion = made
        made.start()
    }

    func stop() {
        motion?.stop()
        motion = nil
    }
}

/// CoreMotion on its own queue: the readings never touch the main thread, only a jerk does (a few a second at most).
nonisolated final class SongTapMotion: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let onImpulse: @Sendable (Int64) -> Void
    private var state = SongTapImpulseState.initial

    init(onImpulse: @escaping @Sendable (Int64) -> Void) {
        self.onImpulse = onImpulse
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
    }

    func start() {
        guard manager.isAccelerometerAvailable else { return }
        state = .initial
        manager.accelerometerUpdateInterval = 0.02
        manager.startAccelerometerUpdates(to: queue) { [self] data, _ in
            guard let data else { return }
            let tMs = Int64(data.timestamp * 1000)
            let sample = SongTapAccelSample(tMs: tMs, xMg: Int(data.acceleration.x * 1000), yMg: Int(data.acceleration.y * 1000),
                                            zMg: Int(data.acceleration.z * 1000))
            let step = SongTapImpulse.step(state, sample)
            state = step.state
            if step.impulse { onImpulse(tMs) }
        }
    }

    func stop() {
        manager.stopAccelerometerUpdates()
    }
}
