import AVFoundation
import Foundation
import PixlAudioCore

/// Owns the `AVAudioSession`: category `.playback` with the long-form-audio route-sharing policy, activation, and the
/// three system events a music player must handle — interruptions (resumed by PixlAudioCore's port of Android's
/// `AudioFocusResumePolicy`), route changes (pause when headphones are unplugged, Android's "becoming noisy"; optional
/// resume on reconnect) and media-services resets (rebuild everything).
@MainActor
final class AudioSessionController {
    /// What the engine must do in response to a session event.
    enum Command: Equatable {
        /// Apply these focus actions (pause/resume master and auxiliary decks).
        case focus(AudioFocusActions)
        /// The output device went away (headphones unplugged, Bluetooth lost): pause.
        case pauseForRouteLoss
        /// A headset came back and the user asked to resume on reconnect.
        case resumeForRouteReturn
        /// The media server restarted: every player and tap is invalid; rebuild.
        case rebuildAfterReset
        /// The output route changed (sample rate / AirPlay); refresh route-dependent state.
        case routeChanged
    }

    /// Mirrors `AudioFocusResumeState`; exposed for tests.
    private(set) var focus = AudioFocusResumeState()
    private(set) var isActive = false
    /// Android `resume_on_headset_reconnect`.
    var resumeOnHeadsetReconnect = false
    /// Set when a route loss paused playback (so a reconnect may resume it).
    private(set) var pausedByRouteLoss = false

    /// The engine supplies a snapshot of both decks when an interruption begins.
    var deckSnapshot: () -> DeckPlaybackSnapshot = { DeckPlaybackSnapshot(masterPlayWhenReady: false,
                                                                          masterIsPlaying: false,
                                                                          transitionRunning: false) }
    /// Whether a crossfade is running when the interruption ends.
    var isTransitionRunning: () -> Bool = { false }
    var onCommand: ((Command) -> Void)?

    private var observers: [any NSObjectProtocol] = []
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { @Sendable [weak self] note in
            let info = AudioSessionController.interruptionInfo(note)
            MainActor.assumeIsolated { self?.handleInterruption(began: info.began, shouldResume: info.shouldResume) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session,
                                            queue: .main) { @Sendable [weak self] note in
            let reason = AudioSessionController.routeChangeReason(note)
            MainActor.assumeIsolated { self?.handleRouteChange(reason: reason) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: session, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
    }

    // MARK: Configuration

    /// `.playback` + long-form audio (the route picker treats us like a music app). Falls back to the default policy
    /// if the long-form one is refused.
    func configure() {
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        } catch {
            try? session.setCategory(.playback, mode: .default, options: [])
        }
    }

    /// Activates the session before playback starts. Returns false when the system refused (e.g. a call is active).
    @discardableResult
    func activate() -> Bool {
        if isActive { return true }
        do {
            try session.setActive(true)
            isActive = true
        } catch {
            isActive = false
        }
        return isActive
    }

    /// An activation started off the main actor, while the item loads (`prepareActivation`).
    private var preparing: Task<Void, Never>?
    /// `deactivate()` came while that activation was under way.
    private var deactivateAfterPreparing = false

    /// Starts activating the session off the main actor (`setActive(true)` is a call to the audio server), so the
    /// first play after launch doesn't make it on the main thread while the mini player appears: `activate()` then
    /// usually finds the session active. If it runs first, it activates as before (activating twice is harmless).
    func prepareActivation() {
        guard !isActive, preparing == nil else { return }
        deactivateAfterPreparing = false
        preparing = Task { [weak self] in
            let activated = await Self.activateSharedSession()
            guard let self else { return }
            self.preparing = nil
            if self.deactivateAfterPreparing {
                self.deactivateAfterPreparing = false
                if activated { try? self.session.setActive(false, options: .notifyOthersOnDeactivation) }
                self.isActive = false
                return
            }
            if activated { self.isActive = true }
        }
    }

    /// Under approachable concurrency a plain `nonisolated async` function would run on the caller's actor.
    @concurrent
    nonisolated private static func activateSharedSession() async -> Bool {
        (try? AVAudioSession.sharedInstance().setActive(true)) != nil
    }

    /// Deactivates after a permanent stop so other apps can resume.
    func deactivate() {
        if preparing != nil { deactivateAfterPreparing = true }
        guard isActive else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
    }

    /// The output sample rate (for EQ coefficient design).
    var outputSampleRate: Double { session.sampleRate > 0 ? session.sampleRate : 44_100 }

    /// Human-readable output route (Device capabilities screen).
    var routeDescription: String {
        session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
    }

    // MARK: Events (internal so tests can drive them without posting system notifications)

    func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            // iOS has already paused us; record whether to resume (AUDIOFOCUS_LOSS_TRANSIENT).
            let actions = focus.transientLoss(deckSnapshot())
            isActive = false
            onCommand?(.focus(actions))
        } else {
            let actions = focus.interruptionEnded(shouldResume: shouldResume, transitionRunning: isTransitionRunning())
            if actions.contains(.resumeMaster) { activate() }
            if !actions.isEmpty { onCommand?(.focus(actions)) }
        }
    }

    func handleRouteChange(reason: AVAudioSession.RouteChangeReason?) {
        switch reason {
        case .oldDeviceUnavailable:
            let snapshot = deckSnapshot()
            if snapshot.masterIsPlaying || snapshot.masterPlayWhenReady {
                pausedByRouteLoss = true
                onCommand?(.pauseForRouteLoss)
            }
        case .newDeviceAvailable:
            if pausedByRouteLoss && resumeOnHeadsetReconnect {
                pausedByRouteLoss = false
                activate()
                onCommand?(.resumeForRouteReturn)
            }
            onCommand?(.routeChanged)
        default:
            onCommand?(.routeChanged)
        }
    }

    /// The user resumed or stopped by hand: a later reconnect must not resume.
    func clearRouteLossPause() { pausedByRouteLoss = false }

    func handleMediaServicesReset() {
        isActive = false
        focus = AudioFocusResumeState()
        configure()
        onCommand?(.rebuildAfterReset)
    }

    /// A permanent loss (another app took over for good): pause both decks and forget any pending resume.
    func handlePermanentLoss() {
        let actions = focus.permanentLoss()
        onCommand?(.focus(actions))
    }

    // MARK: Notification parsing

    nonisolated static func interruptionInfo(_ note: Notification) -> (began: Bool, shouldResume: Bool) {
        let info = note.userInfo ?? [:]
        let typeValue = (info[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
        let type = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        let optionsValue = (info[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        return (type == .began, options.contains(.shouldResume))
    }

    nonisolated static func routeChangeReason(_ note: Notification) -> AVAudioSession.RouteChangeReason? {
        let value = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
        return value.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
    }
}
