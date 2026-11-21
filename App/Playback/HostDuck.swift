import Foundation
import PixlLibrary

/// Brings the music down while the host of Endless Listening speaks and back up after (the port of Android's `HostDuck`).
///
/// The level is `AudioEffectsParameters.duckGain`, one atomic every tap multiplies in last. It never replaces anything: ReplayGain, the
/// crossfade curves, Spatial audio and Sing keep their own levels, so there is no foreign writer to give way to and nothing to remember
/// (`volumeTaken` of `HostVoice` never happens here). The session is not touched either: a system duck would be a category change, and a
/// category change stops the music.
///
/// The ramp numbers are `HostVoice.ramp` (the same rule as on Android, from `hostvoice.jsonl`): down to 0.35 over 250 ms, up over 400 ms
/// (120 ms when a line was cut short). The main actor writes a step every 24 ms and the tap smooths each step across its buffer, so no zipper
/// noise. `abort` gives the level back at once: a crossfade, a rebuilt deck, an interruption and the end of the app's session call it first.
@MainActor
final class HostDuck {
    private let effects: AudioEffectsParameters
    private var task: Task<Void, Never>?
    private var held = false
    private var level = HostVoice.permilleFull

    /// True from `begin` until the music is back at its level (or the duck was aborted).
    var isActive: Bool { held }

    /// The level now, in thousandths (for tests and the log).
    var permille: Int { level }

    /// Called when the duck ended on its own, not through `end`: "transition", "interruption", or the reason given to `abort`.
    var onEnded: ((String) -> Void)?

    init(effects: AudioEffectsParameters) { self.effects = effects }

    /// Starts bringing the music down. False when it is already held. The caller waits `HostVoice.rampDownMs` before it speaks.
    @discardableResult
    func begin() -> Bool {
        guard !held else { return false }
        held = true
        run(from: HostVoice.permilleFull, to: HostVoice.duckPermille, rampMs: HostVoice.rampDownMs, release: false)
        return true
    }

    /// Brings the music back over `HostVoice.rampUpMs` (`rampUpQuickMs` when `quick`). The duck is over when it lands.
    func end(quick: Bool = false) {
        guard held else { return }
        run(from: level, to: HostVoice.permilleFull, rampMs: quick ? HostVoice.rampUpQuickMs : HostVoice.rampUpMs, release: true)
    }

    /// Gives the level back at once and tells `onEnded` why. Safe to call when the duck is not held.
    func abort(reason: String) {
        guard held else { return }
        task?.cancel()
        task = nil
        write(HostVoice.permilleFull)
        held = false
        onEnded?(reason)
    }

    private func run(from: Int, to: Int, rampMs: Int64, release: Bool) {
        task?.cancel()
        let clock = ContinuousClock()
        let start = clock.now
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = Self.milliseconds(start.duration(to: clock.now))
                self.write(HostVoice.ramp(from, to, elapsedMs: elapsed, rampMs: rampMs))
                if elapsed >= rampMs { break }
                try? await Task.sleep(for: .milliseconds(Self.stepMs))
            }
            guard !Task.isCancelled, let self else { return }
            if release { self.held = false }
        }
    }

    private func write(_ permille: Int) {
        level = permille
        effects.duckGain.store(Float(permille) / Float(HostVoice.permilleFull))
    }

    private static let stepMs: Int = 24

    private static func milliseconds(_ d: Duration) -> Int64 {
        let parts = d.components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
