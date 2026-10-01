// PixlAudioCore — the pure audio logic of PixlAudio: transition rules, crossfade scheduling and gain curves,
// ReplayGain, RBJ biquads and the 10-band equalizer (with its response curve), the sleep-timer state machine, the
// audio-interruption resume rule, the TAIS FFT, CTC forced-alignment core and the mid/side vocal reducer.
// Everything here is Foundation-only (builds and tests on Windows and macOS). Per-buffer functions never allocate:
// they process into caller-provided buffers, so the app can call them from an audio render callback.
// Keep the `PixlAudioCoreModule` enum: the app's Diagnostics screen lists it.

import PixlFoundation
import PixlModel

/// Identity of the `PixlAudioCore` module.
public enum PixlAudioCoreModule {
    /// The module name, used by the app to show which PixlCore modules are linked.
    public static let name = "PixlAudioCore"

    /// Names of the PixlCore modules this module depends on.
    public static let dependencies: [String] = [PixlFoundationModule.name, PixlModelModule.name]
}
