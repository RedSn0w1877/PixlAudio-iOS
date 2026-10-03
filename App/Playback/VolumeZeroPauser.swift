import AVFoundation

/// Settings › Playback › Pause when volume reaches zero (Android `MusicService` `pauseOnVolumeZero`): when the
/// system output volume is turned all the way down while a song plays, playback pauses. Observes the audio session's
/// `outputVolume` (key-value observed; it changes only when the user moves a volume control).
@MainActor
final class VolumeZeroPauser {
    private var observation: NSKeyValueObservation?
    private var isEnabled: () -> Bool = { false }
    private var pauseIfPlaying: () -> Void = {}

    func start(isEnabled: @escaping () -> Bool, pauseIfPlaying: @escaping () -> Void) {
        guard observation == nil else { return }
        self.isEnabled = isEnabled
        self.pauseIfPlaying = pauseIfPlaying
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new],
                                                              changeHandler: Self.handler { [weak self] volume in
            Task { @MainActor in self?.volumeChanged(volume) }
        })
    }

    private func volumeChanged(_ volume: Float) {
        guard volume <= 0.0001, isEnabled() else { return }
        pauseIfPlaying()
    }

    /// KVO may call back on any thread: the handler is built outside the main actor and hops back explicitly
    /// (as `SystemVolumeObserver` does).
    nonisolated private static func handler(_ sink: @escaping @Sendable (Float) -> Void)
        -> (AVAudioSession, NSKeyValueObservedChange<Float>) -> Void {
        { _, change in
            if let value = change.newValue { sink(value) }
        }
    }
}
