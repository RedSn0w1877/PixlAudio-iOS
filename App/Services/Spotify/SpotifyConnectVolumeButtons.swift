import AVFoundation
import MediaPlayer
import Observation
import PixlNet
import UIKit

/// The phone's volume buttons drive the Spotify Connect device while PixlAudio is open (owner request 2026-10-07;
/// Android gets the same from Media3's remote `DeviceInfo`). iOS has no API for button presses, so this is the
/// technique the forums describe, with its limits written down in docs/api-notes.md › Connect volume buttons:
///
/// - the audio session stays active (`AudioSessionController.holdForVolumeButtons`), so the buttons change the media
///   volume and `outputVolume` reports it;
/// - a 1×1 pt, almost transparent `MPVolumeView` in a corner of the key window keeps the system volume pop-up away
///   (undocumented; PixlAudio shows its own glass pop-up instead);
/// - each one-step `outputVolume` change is ±1 press (`SpotifyConnectVolumeKeys.classify`);
/// - **re-centre:** the phone's volume is set back to a centre value through the hidden view's slider, so presses
///   keep coming at any level. Apple says this "generally doesn't work" (DTS, 2020), so it is checked on every
///   reset: when the volume doesn't come back within 500 ms the session falls back to
/// - **relative:** presses still count, but the phone's volume moves with them; at full or silent no more changes
///   arrive and `onEndReached` points to the slider.
///
/// Only in the foreground (`applicationState == .active`): Control Center and the background never count, and the
/// phone's own volume is put back on the way out. Never when another app plays audio (activating the session would
/// stop it). Diagnostics shows `status` so the mode can be read on the phone.
@Observable
final class SpotifyConnectVolumeButtons {
    nonisolated enum Mode: String, Sendable {
        /// Not listening (no Connect device that takes volume, the app in the background, other audio playing).
        case off
        /// Presses are counted and the phone's volume is set back after each one.
        case recentre
        /// Setting the volume back didn't work: presses are counted until the phone's volume reaches an end.
        case relative
    }

    nonisolated struct Status: Equatable, Sendable {
        var mode: Mode = .off
        /// Why it is off or relative (Diagnostics).
        var note: String?
        /// The last `outputVolume` change counted as a press.
        var lastDelta: Float?
        var presses = 0
    }

    /// Read by Diagnostics only.
    private(set) var status = Status()

    /// A press: +n up, −n down.
    @ObservationIgnored var onPress: ((Int) -> Void)?
    /// Relative mode reached full or silent (once per session).
    @ObservationIgnored var onEndReached: (() -> Void)?

    @ObservationIgnored private let session: AudioSessionController
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var isRunning = false
    /// The app resigned active (Control Center, the app switcher, an alert): changes are not presses.
    @ObservationIgnored private var isPaused = false
    /// Waiting for the volume to settle after a start, a route change or a return to the app.
    @ObservationIgnored private var isSettling = false
    /// A call, an alarm or Siri took the audio: the buttons belong to it until it ends.
    @ObservationIgnored private var isInterrupted = false
    @ObservationIgnored private var volumeView: MPVolumeView?
    @ObservationIgnored private var slider: UISlider?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var lastVolume: Float = 0
    /// The user's own phone volume, put back on the way out.
    @ObservationIgnored private var original: Float = 0.5
    @ObservationIgnored private var centre: Float = 0.5
    /// The phone's volume was moved to the centre (and must be put back).
    @ObservationIgnored private var hasCentred = false
    @ObservationIgnored private var awaitingEcho = false
    @ObservationIgnored private var endReachedShown = false
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var echoTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    /// How long a start, a route change or a return to the app waits before reading the volume (the hidden view needs
    /// a layout pass before its slider holds the system volume).
    static let settleDelay: Duration = .milliseconds(350)
    /// How long a reset may take to show up in `outputVolume` before re-centring counts as not working.
    static let echoTimeout: Duration = .milliseconds(500)

    init(session: AudioSessionController) {
        self.session = session
        observeLifecycle()
    }

    /// Whether a Connect device that takes volume commands plays (`SpotifyConnectController`). Listening starts when
    /// the app is active too. `handingOverToLocalPlayback`: the session ends because this phone plays again, so the
    /// audio session is kept for it instead of given back and taken again.
    func setWanted(_ wanted: Bool, handingOverToLocalPlayback: Bool = false) {
        guard wanted != self.wanted else { return }
        self.wanted = wanted
        if wanted {
            evaluate()
        } else {
            stop(keepingSession: handingOverToLocalPlayback)
        }
    }

    // MARK: Starting and stopping

    private func evaluate() {
        guard wanted, !isRunning else { return }
        guard UIApplication.shared.applicationState == .active else { return } // starts on didBecomeActive
        // Activating PixlAudio's (non-mixable) session would stop audio another app plays.
        if !session.isActive, AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint {
            setStatus(.off, note: "Waiting: another app is playing audio")
            return
        }
        guard let window = Self.hostWindow() else {
            setStatus(.off, note: "No window to hold the volume view")
            return
        }
        isRunning = true
        isPaused = false
        hasCentred = false
        awaitingEcho = false
        endReachedShown = false
        slider = nil
        session.holdForVolumeButtons()
        // 1×1 pt in the screen's top-left corner (rounded off on the display), clipped, 1 % opaque, never touchable or
        // spoken: it only keeps the system pop-up away and holds the slider used to set the volume back. On screen
        // rather than off it, and not hidden or at alpha 0: reports differ on whether the pop-up stays away for a
        // volume view outside the window's bounds, and a hidden one never keeps it away.
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        window.addSubview(view)
        volumeView = view
        let audio = AVAudioSession.sharedInstance()
        lastVolume = audio.outputVolume
        observation = audio.observe(\.outputVolume, options: [.old, .new],
                                    changeHandler: Self.handler { @Sendable [weak self] old, new in
            MainActor.assumeIsolated { self?.volumeChanged(old: old, new: new) }
        })
        setStatus(.recentre, note: nil)
        settle()
    }

    private func stop(keepingSession: Bool = false) {
        settleTask?.cancel()
        echoTask?.cancel()
        guard isRunning else {
            if status.mode != .off || status.note != nil { setStatus(.off, note: nil) }
            return
        }
        let restored = restoreOriginal()
        observation?.invalidate()
        observation = nil
        if let view = volumeView {
            if restored {
                // Let the restore reach the system before the view that made it goes.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    view.removeFromSuperview()
                }
            } else {
                view.removeFromSuperview()
            }
        }
        volumeView = nil
        slider = nil
        isRunning = false
        isPaused = false
        isSettling = false
        isInterrupted = false
        awaitingEcho = false
        session.releaseVolumeButtonsHold(keepingSession: keepingSession)
        setStatus(.off, note: nil)
    }

    // MARK: Anchoring

    /// Re-reads the phone's volume once it has settled, then re-centres.
    private func settle() {
        isSettling = true
        awaitingEcho = false
        echoTask?.cancel()
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self else { return }
            self.isSettling = false
            self.anchor()
        }
    }

    private func anchor() {
        guard isRunning, !isPaused, !isInterrupted else { return }
        if slider == nil, let volumeView { slider = Self.findSlider(in: volumeView) }
        // The slider holds the real volume once laid out; `outputVolume` can read stale or 0 after a session change
        // (iOS 18 reports).
        let current = slider?.value ?? AVAudioSession.sharedInstance().outputVolume
        lastVolume = current
        // A volume still at the centre PixlAudio set is not the user's: keep the one to put back.
        if !hasCentred || abs(current - centre) > SpotifyConnectVolumeKeys.echoTolerance { original = current }
        centre = SpotifyConnectVolumeKeys.centre(for: original)
        guard status.mode == .recentre else { return }
        guard slider != nil else {
            fallBack("No volume slider inside the system volume view")
            return
        }
        if abs(current - centre) > 0.001 { setPhoneVolume(centre) }
    }

    /// Sets the phone's volume through the hidden view's slider, and checks that it took.
    private func setPhoneVolume(_ value: Float) {
        guard let slider else { return }
        hasCentred = true
        awaitingEcho = true
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
        echoTask?.cancel()
        echoTask = Task { [weak self] in
            try? await Task.sleep(for: Self.echoTimeout)
            guard !Task.isCancelled else { return }
            self?.echoTimedOut(target: value)
        }
    }

    private func echoTimedOut(target: Float) {
        guard isRunning, !isPaused, awaitingEcho else { return }
        awaitingEcho = false
        // No change came back: fine if the volume is there anyway (a reset that made no KVO change).
        if abs(AVAudioSession.sharedInstance().outputVolume - target) > SpotifyConnectVolumeKeys.echoTolerance {
            fallBack("Setting the phone volume back didn't work")
        }
    }

    private func fallBack(_ note: String) {
        guard status.mode == .recentre else { return }
        echoTask?.cancel()
        awaitingEcho = false
        setStatus(.relative, note: note)
    }

    /// Puts the user's own phone volume back. True when a change was made.
    @discardableResult
    private func restoreOriginal() -> Bool {
        guard hasCentred, status.mode == .recentre, let slider else { return false }
        hasCentred = false
        awaitingEcho = false
        echoTask?.cancel()
        guard abs(lastVolume - original) > 0.001 else { return false }
        slider.setValue(original, animated: false)
        slider.sendActions(for: .valueChanged)
        return true
    }

    // MARK: Changes

    private func volumeChanged(old: Float?, new: Float?) {
        guard isRunning, let new else { return }
        let previous = old ?? lastVolume
        lastVolume = new
        // Control Center (the app isn't active), a settle in progress, the restore on the way out: not presses.
        guard !isPaused, !isSettling, !isInterrupted, UIApplication.shared.applicationState == .active else { return }
        switch status.mode {
        case .off:
            return
        case .recentre:
            switch SpotifyConnectVolumeKeys.classify(old: previous, new: new, centre: centre, awaitingEcho: awaitingEcho) {
            case .echo(let settled):
                if settled {
                    awaitingEcho = false
                    echoTask?.cancel()
                }
            case .press(let presses):
                record(delta: new - previous, presses: presses)
                onPress?(presses)
                setPhoneVolume(centre)
            case .reanchor:
                settle()
            }
        case .relative:
            guard case .press(let presses) = SpotifyConnectVolumeKeys.classify(old: previous, new: new, centre: centre,
                                                                                 awaitingEcho: false) else { return }
            record(delta: new - previous, presses: presses)
            onPress?(presses)
            if !endReachedShown, SpotifyConnectVolumeKeys.reachedEnd(phoneVolume: new, presses: presses) {
                endReachedShown = true
                onEndReached?()
            }
        }
    }

    private func record(delta: Float, presses: Int) {
        status.lastDelta = delta
        status.presses += abs(presses)
    }

    private func setStatus(_ mode: Mode, note: String?) {
        if status.mode != mode { status.mode = mode }
        if status.note != note { status.note = note }
    }

    // MARK: App and audio session events

    private func observeLifecycle() {
        let center = NotificationCenter.default
        let audio = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                            queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.resignedActive() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        // Headphones, AirPlay, a call ending: the volume belongs to another output or comes back; read it again.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: audio,
                                            queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.audioChanged() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: audio,
                                            queue: .main) { @Sendable [weak self] note in
            let began = AudioSessionController.interruptionInfo(note).began
            MainActor.assumeIsolated { self?.interrupted(began: began) }
        })
        // Another app's audio stopped: the buttons may take over now.
        observers.append(center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: audio,
                                            queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        })
    }

    private func becameActive() {
        if isRunning {
            isPaused = false
            settle()
        } else {
            evaluate()
        }
    }

    /// Control Center, the app switcher, an alert: stop counting and put the phone's own volume back (so Control
    /// Center shows it). The session and the hidden view stay: taking the session down and up again for a Control
    /// Center pull would interrupt other apps again and trip the stale-volume reports seen since iOS 18.
    private func resignedActive() {
        guard isRunning else { return }
        isPaused = true
        settleTask?.cancel()
        isSettling = false
        restoreOriginal()
    }

    private func audioChanged() {
        guard isRunning, !isPaused, !isInterrupted else { return }
        settle()
    }

    private func interrupted(began: Bool) {
        isInterrupted = began
        guard isRunning, !began, !isPaused else { return }
        settle()
    }

    // MARK: Helpers

    /// KVO may call back on any thread: the handler is built outside the main actor and hands each change to the
    /// main queue in order (the echo matching needs them in sequence).
    nonisolated private static func handler(_ sink: @escaping @Sendable (Float?, Float?) -> Void)
        -> (AVAudioSession, NSKeyValueObservedChange<Float>) -> Void {
        { _, change in
            let old = change.oldValue
            let new = change.newValue
            DispatchQueue.main.async { sink(old, new) }
        }
    }

    /// The system view's slider (a private, possibly nested hierarchy: searched, never assumed).
    private static func findSlider(in view: UIView) -> UISlider? {
        for subview in view.subviews {
            if let slider = subview as? UISlider { return slider }
            if let nested = findSlider(in: subview) { return nested }
        }
        return nil
    }

    private static func hostWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first
    }
}
