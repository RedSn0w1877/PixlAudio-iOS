// PixlModel — Song/Album/Artist/Playlist/LyricsDoc(+Codec)/Transition/SmartRule/SortOption/EQPreset value types (Codable keys match Android JSON).
// Placeholder from stage 0. Keep the `PixlModelModule` enum: the app's Diagnostics screen lists it.

import PixlFoundation

/// Identity of the `PixlModel` module.
public enum PixlModelModule {
    /// The module name, used by the app to show which PixlCore modules are linked.
    public static let name = "PixlModel"

    /// Names of the PixlCore modules this module depends on.
    public static let dependencies: [String] = [PixlFoundationModule.name]
}
