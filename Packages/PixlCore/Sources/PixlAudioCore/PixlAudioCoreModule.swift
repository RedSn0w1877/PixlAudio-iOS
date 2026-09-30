// PixlAudioCore — Transition rules/curves/gain(t), crossfade scheduler, ReplayGain, RBJ biquad design, EQ response curve, sleep-timer state machine, FFT, CtcAlignmentCore, mid/side math.
// Placeholder from stage 0. Keep the `PixlAudioCoreModule` enum: the app's Diagnostics screen lists it.

import PixlFoundation
import PixlModel

/// Identity of the `PixlAudioCore` module.
public enum PixlAudioCoreModule {
    /// The module name, used by the app to show which PixlCore modules are linked.
    public static let name = "PixlAudioCore"

    /// Names of the PixlCore modules this module depends on.
    public static let dependencies: [String] = [PixlFoundationModule.name, PixlModelModule.name]
}
