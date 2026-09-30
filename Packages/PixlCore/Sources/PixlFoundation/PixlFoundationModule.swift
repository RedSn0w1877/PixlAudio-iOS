// PixlFoundation — Spring solver matching Compose FloatSpringSpec, CubicBezier, ExponentialDecay, grapheme/word segmentation, CJK/RTL detection.
// Placeholder from stage 0. Keep the `PixlFoundationModule` enum: the app's Diagnostics screen lists it.

/// Identity of the `PixlFoundation` module.
public enum PixlFoundationModule {
    /// The module name, used by the app to show which PixlCore modules are linked.
    public static let name = "PixlFoundation"

    /// Names of the PixlCore modules this module depends on.
    public static let dependencies: [String] = []
}
