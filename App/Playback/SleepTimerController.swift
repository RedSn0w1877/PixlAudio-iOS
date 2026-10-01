import Foundation
import Observation
import PixlAudioCore
import PixlModel

/// What the sleep timer drives (`DualDeckEngine`; a fake in tests).
protocol SleepTimerTarget: AnyObject {
    var currentSongId: String? { get }
    var stopAfterCurrentItem: Bool { get set }
    func pause()
    func seek(toMs positionMs: Int64)
    func setRepeatMode(_ mode: RepeatMode)
}

extension DualDeckEngine: SleepTimerTarget {
    var currentSongId: String? { queue.current?.song.id }
}

/// The sleep timer (time / end of track / counted plays): PixlAudioCore's `SleepTimer` state machine fed with the
/// engine's events, its effects carried out on the engine. Observable for the timer sheet (stage 8); the countdown
/// itself is one sleeping task, never a ticking timer.
@Observable
final class SleepTimerController {
    private(set) var state = SleepTimer()
    /// The latest toast (Android `Toast`), already worded; the UI shows it once and clears it.
    private(set) var toastMessage: String?

    @ObservationIgnored private weak var engine: (any SleepTimerTarget)?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    /// Epoch milliseconds (tests inject a clock).
    @ObservationIgnored var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    /// Song titles for the toasts.
    @ObservationIgnored var titleForSongId: (String) -> String? = { _ in nil }

    init(engine: (any SleepTimerTarget)?) {
        self.engine = engine
    }

    /// Milliseconds left on a duration timer.
    var remainingMs: Int64? { state.remainingMs(nowMs: now()) }

    // MARK: Commands (the timer sheet)

    func setDuration(minutes: Int) { apply(state.setDuration(minutes: minutes, nowMs: now())) }

    func setEndOfTrack(_ enabled: Bool) {
        apply(state.setEndOfTrack(enabled, currentSongId: engine?.currentSongId))
    }

    func cancel() { apply(state.cancel()) }

    func startCountedPlay(_ count: Int) {
        apply(state.startCountedPlay(count, currentSongId: engine?.currentSongId))
    }

    func cancelCountedPlay() { apply(state.cancelCountedPlay()) }

    func clearToast() { toastMessage = nil }

    // MARK: Engine events (PlaybackServices forwards them)

    func itemTransition(new: Song?, previous: Song?, automatic: Bool) {
        var effects: [SleepTimer.Effect] = []
        if automatic { effects += state.onAutoTransitionDiscontinuity() }
        effects += state.onMediaItemTransition(newSongId: new?.id, previousSongId: previous?.id, isAutomatic: automatic)
        apply(effects)
    }

    /// The same song started again on its own (repeat-one).
    func repeatLoop() { apply(state.onAutoTransitionDiscontinuity()) }

    func queueEnded() { apply(state.onPlaybackEnded()) }

    func repeatModeChanged(_ mode: RepeatMode) {
        apply(state.onRepeatModeChanged(TransitionRepeatMode(rawValue: mode.rawValue) ?? .off))
    }

    /// Re-checks the clock (app returned to the foreground; the wake-up task may have been suspended).
    func checkClock() { apply(state.tick(nowMs: now())) }

    // MARK: Effects

    private func apply(_ effects: [SleepTimer.Effect]) {
        for effect in effects {
            switch effect {
            case .pause:
                engine?.pause()
            case .seekToStart:
                engine?.seek(toMs: 0)
            case .setRepeatMode(let mode):
                engine?.setRepeatMode(RepeatMode(rawValue: mode.rawValue) ?? .off)
            case .scheduleWakeUp(let atMs):
                scheduleWakeUp(atMs: atMs)
            case .cancelWakeUp:
                wakeTask?.cancel()
                wakeTask = nil
            case .toast(let toast):
                toastMessage = message(for: toast)
            }
        }
        engine?.stopAfterCurrentItem = state.isEndOfTrackActive
    }

    private func scheduleWakeUp(atMs: Int64) {
        wakeTask?.cancel()
        let delay = max(atMs - now(), 0)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.wakeTask = nil
            self.checkClock()
        }
    }

    /// Android's toast strings (`strings_player.xml`).
    func message(for toast: SleepTimer.Toast) -> String {
        switch toast {
        case .setForMinutes(let minutes):
            return String(localized: "Timer set for \(minutes) minutes.")
        case .cancelled:
            return String(localized: "Timer cancelled.")
        case .endOfTrackSet:
            return String(localized: "Playback will stop at end of track.")
        case .endOfTrackNoSong:
            return String(localized: "Cannot enable end of track: no active song.")
        case .endOfTrackSongChanged(let from, let to):
            let fromTitle = titleForSongId(from) ?? from
            let toTitle = titleForSongId(to) ?? to
            return String(localized: "End of track timer deactivated: song changed from \(fromTitle) to \(toTitle).")
        case .stoppedAtEndOfTrack(let songId):
            let title = titleForSongId(songId) ?? songId
            return String(localized: "Playback stopped: \(title) finished (End of Track).")
        case .custom(let text):
            return text
        }
    }
}
