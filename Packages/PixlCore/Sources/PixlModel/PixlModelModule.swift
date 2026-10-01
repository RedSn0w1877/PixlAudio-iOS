// PixlModel — Codable domain models mirroring the Android app (Song/Album/Artist/Playlist + smart rules, Lyrics,
// LyricsDoc + the exact Android JSON codec, transitions, SortOption, library tabs, EQ presets, queue snapshot).
// Keep the `PixlModelModule` enum: the app's Diagnostics screen lists it.

import PixlFoundation

/// Identity of the `PixlModel` module.
public enum PixlModelModule {
    /// The module name, used by the app to show which PixlCore modules are linked.
    public static let name = "PixlModel"

    /// Names of the PixlCore modules this module depends on.
    public static let dependencies: [String] = [PixlFoundationModule.name]
}
