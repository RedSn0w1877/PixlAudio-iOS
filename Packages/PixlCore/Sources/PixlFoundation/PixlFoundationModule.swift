// PixlFoundation — Compose-exact motion maths (FloatSpringSpec/SpringSimulation, CubicBezierEasing,
// FloatExponentialDecaySpec), Kotlin numeric semantics, grapheme/word segmentation, CJK/RTL detection and a
// kotlinx-compatible JSON reader/writer. Keep the `PixlFoundationModule` enum: the app's Diagnostics screen lists it.

/// Identity of the `PixlFoundation` module.
public enum PixlFoundationModule {
    /// The module name, used by the app to show which PixlCore modules are linked.
    public static let name = "PixlFoundation"

    /// Names of the PixlCore modules this module depends on.
    public static let dependencies: [String] = []
}
