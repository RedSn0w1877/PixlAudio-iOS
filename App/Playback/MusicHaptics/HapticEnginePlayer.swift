import CoreHaptics
import Foundation
import PixlAudioCore

/// The CoreHaptics half of Music Haptics. Everything CoreHaptics (the engine, the players) lives on one serial utility
/// queue, never the main thread and never the audio render thread: a 50 Hz timer reads the tap's `HapticSignalBus`,
/// turns onsets into transient taps (intensity and sharpness from the detector, capped at 25 events a second) and the
/// smoothed bass level into the intensity of one looping continuous "rumble" event.
///
/// Created when playback should be felt and torn down when it should not, so nothing runs (no timer, no engine) while
/// paused, in the background or switched off. Failures go to `DiagnosticsLog`.
nonisolated final class HapticEnginePlayer: @unchecked Sendable {
    /// What the controller needs to hear back. Called on the haptics queue.
    struct Reporter: Sendable {
        var failed: @Sendable (String) -> Void
    }

    private struct Settings {
        var mode: MusicHapticsMode
        var strengthPercent: Int
        /// Seconds the sound is behind the tap's analysis (the output route's latency): haptics are scheduled this
        /// far ahead so they land with the sound.
        var latency: Double
    }

    private let bus: HapticSignalBus
    private let reporter: Reporter
    private let queue = DispatchQueue(label: "io.github.redsn0w1877.pixlaudio.music-haptics", qos: .userInitiated)

    // Confined to `queue`.
    private var engine: CHHapticEngine?
    private var rumblePlayer: (any CHHapticAdvancedPatternPlayer)?
    private var timer: DispatchSourceTimer?
    private var settings = Settings(mode: .everything, strengthPercent: 100, latency: 0)
    private var limiter = HapticRateLimiter(maxPerSecond: 25)
    private var lastSequence = 0
    private var smoothedRumble: Float = 0
    private var lastSentRumble: Float = -1
    private var lastRumbleSend = 0.0
    private var engineStarted = false
    private var failures = 0

    init(bus: HapticSignalBus, reporter: Reporter) {
        self.bus = bus
        self.reporter = reporter
    }

    /// Whether this device has a Taptic Engine CoreHaptics can drive (false on iPad and in the Simulator).
    static var hardwareSupportsHaptics: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    // MARK: Control (any thread)

    func start(mode: MusicHapticsMode, strengthPercent: Int, latency: Double) {
        queue.async { [self] in
            settings = Settings(mode: mode, strengthPercent: strengthPercent, latency: min(max(latency, 0), 0.4))
            guard timer == nil else { return }
            guard startEngine() else { return }
            lastSequence = bus.onsetSequence
            limiter.reset()
            smoothedRumble = 0
            lastSentRumble = -1
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    func update(mode: MusicHapticsMode, strengthPercent: Int, latency: Double) {
        queue.async { [self] in
            settings = Settings(mode: mode, strengthPercent: strengthPercent, latency: min(max(latency, 0), 0.4))
        }
    }

    /// Stops the timer, the rumble and the engine. `completion` runs on the haptics queue when it is all down.
    func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            try? rumblePlayer?.stop(atTime: CHHapticTimeImmediate)
            rumblePlayer = nil
            if let engine {
                engine.stoppedHandler = { _ in }
                engine.resetHandler = {}
                engine.stop(completionHandler: { _ in })
            }
            engine = nil
            engineStarted = false
            completion?()
        }
    }

    // MARK: Engine (queue)

    private func startEngine() -> Bool {
        do {
            let engine = try CHHapticEngine()
            // Haptics only: the engine must never play audio or take the audio session from the music.
            engine.playsHapticsOnly = true
            engine.stoppedHandler = { [weak self] reason in
                guard let self else { return }
                queue.async {
                    self.engineStarted = false
                    self.reporter.failed("engine stopped (\(reason.rawValue))")
                }
            }
            engine.resetHandler = { [weak self] in
                guard let self else { return }
                queue.async {
                    self.rumblePlayer = nil
                    self.lastSentRumble = -1
                    do {
                        try self.engine?.start()
                        self.engineStarted = true
                    } catch {
                        self.engineStarted = false
                        self.reporter.failed("restart after reset failed")
                    }
                }
            }
            try engine.start()
            self.engine = engine
            engineStarted = true
            failures = 0
            return true
        } catch {
            engine = nil
            reporter.failed("engine start failed (\(type(of: error)))")
            return false
        }
    }

    private func tick() {
        guard let engine else { return }
        if !engineStarted {
            // After a system stop: one restart attempt per tick, a few times, then give up quietly until stopped.
            guard failures < 25 else { return }
            do {
                try engine.start()
                engineStarted = true
                failures = 0
            } catch {
                failures += 1
                if failures == 25 { reporter.failed("could not restart the engine") }
                return
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        // Onset -> one transient tap.
        let sequence = bus.onsetSequence
        if sequence != lastSequence {
            lastSequence = sequence
            if let event = MusicHapticsMapper.tap(for: bus.latestOnset, mode: settings.mode,
                                                  strengthPercent: settings.strengthPercent),
               limiter.allow(at: now) {
                playTap(event, on: engine)
            }
        }
        // Bass -> rumble intensity, smoothed, about 20 updates a second.
        let target = MusicHapticsMapper.rumble(bassLevel: bus.bassLevel, mode: settings.mode,
                                               strengthPercent: settings.strengthPercent)?.intensity ?? 0
        smoothedRumble += (target - smoothedRumble) * (target > smoothedRumble ? 0.5 : 0.25)
        if smoothedRumble < 0.02 { smoothedRumble = 0 }
        if abs(smoothedRumble - lastSentRumble) >= 0.03 || (smoothedRumble == 0 && lastSentRumble != 0),
           now - lastRumbleSend >= 0.05 {
            sendRumble(smoothedRumble, on: engine)
            lastSentRumble = smoothedRumble
            lastRumbleSend = now
        }
    }

    private func playTap(_ event: MusicHapticEvent, on engine: CHHapticEngine) {
        do {
            let haptic = CHHapticEvent(eventType: .hapticTransient,
                                       parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: event.intensity),
                                                    CHHapticEventParameter(parameterID: .hapticSharpness, value: event.sharpness)],
                                       relativeTime: 0)
            let pattern = try CHHapticPattern(events: [haptic], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: engine.currentTime + settings.latency)
        } catch {
            // A missed tap is not worth a log line each; the stopped / reset handlers report real trouble.
        }
    }

    private func sendRumble(_ level: Float, on engine: CHHapticEngine) {
        do {
            if rumblePlayer == nil {
                guard level > 0 else { return }
                // One long continuous event at full base intensity; its loudness is the dynamic intensity control.
                let rumble = CHHapticEvent(eventType: .hapticContinuous,
                                           parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1)],
                                           relativeTime: 0, duration: 30)
                let pattern = try CHHapticPattern(events: [rumble], parameters: [])
                let player = try engine.makeAdvancedPlayer(with: pattern)
                player.loopEnabled = true
                try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: level,
                                                                    relativeTime: 0)],
                                          atTime: CHHapticTimeImmediate)
                try player.start(atTime: CHHapticTimeImmediate)
                rumblePlayer = player
                return
            }
            try rumblePlayer?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: level,
                                                                       relativeTime: 0)],
                                             atTime: engine.currentTime + settings.latency)
        } catch {
            rumblePlayer = nil
            lastSentRumble = -1
        }
    }
}
