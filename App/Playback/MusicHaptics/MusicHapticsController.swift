import AVFoundation
import CallKit
import Foundation
import Observation
import PixlAudioCore
import PixlModel
import SwiftUI

/// Music Haptics (iOS-first, owner request 2026-10-18): the Taptic Engine plays along with the music, from our own
/// analysis of the audio (`MusicHapticAnalyzer` in the processing tap) — not Apple's Music Haptics.
///
/// This object decides *when*. `MusicHapticsPolicy` (PixlAudioCore, tested) says whether haptics may run: the switch
/// is on, the device has haptics, playback is running with the app in front, and nothing blocks it (Low Power Mode, a
/// serious or critical thermal state, safe mode, a phone call, music playing on another device — AirPlay or Spotify
/// Connect). While it says yes the tap's analysis is switched on and `HapticEnginePlayer` feels it; otherwise the
/// analysis is off (one atomic load per audio buffer), the haptic engine is torn down and no timer runs. Starts, stops
/// and failures go to `DiagnosticsLog`.
///
/// What it reads is observable (settings, `PlaybackStore`, `AppHealth`, `AudioRouteMonitor`), re-armed with
/// `withObservationTracking`; the phone call state is read when something else changes (a call interrupts the audio,
/// which pauses playback and re-evaluates).
@MainActor
@Observable
final class MusicHapticsController {
    /// The Settings row's status line.
    private(set) var status: MusicHapticsStatus = .off
    /// The device can play haptics (hidden otherwise). UI tests pretend it can, for the screenshots.
    let isSupported: Bool

    @ObservationIgnored private let behavior: BehaviorSettings
    @ObservationIgnored private let playback: PlaybackStore
    @ObservationIgnored private let health: AppHealth
    @ObservationIgnored private let bus: HapticSignalBus?
    @ObservationIgnored private let routeMonitor: AudioRouteMonitor
    @ObservationIgnored private let log: DiagnosticsLog
    @ObservationIgnored private let player: HapticEnginePlayer?
    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private var running = false
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private lazy var callObserver = CXCallObserver()

    init(behavior: BehaviorSettings, playback: PlaybackStore, health: AppHealth, bus: HapticSignalBus?,
         isDemo: Bool, log: DiagnosticsLog = .shared) {
        self.behavior = behavior
        self.playback = playback
        self.health = health
        self.bus = bus
        self.isDemo = isDemo
        self.log = log
        routeMonitor = .shared
        if isDemo {
            isSupported = true
            player = nil
        } else {
            isSupported = HapticEnginePlayer.hardwareSupportsHaptics && bus != nil
            if isSupported, let bus {
                let log = log
                player = HapticEnginePlayer(bus: bus, reporter: .init(failed: { message in
                    log.log("haptics", "failed (\(message))")
                }))
            } else {
                player = nil
            }
        }
        status = MusicHapticsPolicy.status(conditions())
    }

    /// Starts watching. Called once from `AppEnvironment.start()`; nothing runs until the person switches it on.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        observeConditions()
        let center = NotificationCenter.default
        // The system conditions that have no observable owner here: a call, the output latency.
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { @Sendable [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        evaluate()
    }

    // MARK: Conditions

    private func conditions() -> MusicHapticsConditions {
        let remote = routeMonitor.kind == .airPlay || playback.remoteOutputName != nil || playback.isRemoteActive
        return MusicHapticsConditions(
            isEnabled: behavior.musicHapticsEnabled, deviceSupportsHaptics: isSupported,
            isPlaying: playback.isPlaying, isForeground: health.scenePhase == .active,
            lowPowerMode: health.lowPowerMode, thermal: health.thermal, safeMode: health.safeMode.isActive,
            inPhoneCall: isInPhoneCall, route: remote ? .remote : .local)
    }

    private var isInPhoneCall: Bool {
        guard !isDemo else { return false }
        return callObserver.calls.contains { !$0.hasEnded }
    }

    /// Re-reads everything the decision depends on, with observation tracking on the observable parts.
    private func observeConditions() {
        withObservationTracking {
            _ = conditions()
            _ = behavior.musicHapticsMode
            _ = behavior.musicHapticsStrength
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.evaluate()
                self?.observeConditions()
            }
        }
    }

    // MARK: Decision

    private func evaluate() {
        let current = conditions()
        let newStatus = MusicHapticsPolicy.status(current)
        if newStatus != status { status = newStatus }
        let shouldRun = MusicHapticsPolicy.shouldRun(current)
        if shouldRun {
            let latency = AVAudioSession.sharedInstance().outputLatency
            if !running {
                running = true
                bus?.isActive.store(true, ordering: .relaxed)
                player?.start(mode: behavior.musicHapticsMode, strengthPercent: behavior.musicHapticsStrength,
                              latency: latency)
                log.log("haptics", "start (\(behavior.musicHapticsMode.rawValue), \(behavior.musicHapticsStrength)%)")
            } else {
                player?.update(mode: behavior.musicHapticsMode, strengthPercent: behavior.musicHapticsStrength,
                               latency: latency)
            }
        } else if running {
            running = false
            bus?.isActive.store(false, ordering: .relaxed)
            bus?.clear()
            player?.stop()
            log.log("haptics", "stop (\(stopReason(current)))")
        }
    }

    private func stopReason(_ c: MusicHapticsConditions) -> String {
        if !c.isEnabled { return "switched off" }
        if let blocker = MusicHapticsPolicy.blocker(c) { return blocker.rawValue.lowercased() }
        if !c.isPlaying { return "paused" }
        if !c.isForeground { return "app not in front" }
        return "conditions changed"
    }

    /// Stops at once (a seek: the detector forgets the old moment).
    func playbackJumped() {
        guard running else { return }
        bus?.clear()
    }
}
