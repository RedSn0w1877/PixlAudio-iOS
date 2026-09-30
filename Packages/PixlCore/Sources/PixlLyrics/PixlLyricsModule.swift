// PixlLyrics — Lyrics parsers, PreparedLyrics(+Builder), LyricsEngine, EmphasisMath, InterludeTimeline, LyricsClock, LyricsTapSync, LyricsExport, ImportSecurity, provider parsers + ranking.
// Placeholder from stage 0. Keep the `PixlLyricsModule` enum: the app's Diagnostics screen lists it.

import PixlFoundation
import PixlModel

/// Identity of the `PixlLyrics` module.
public enum PixlLyricsModule {
    /// The module name, used by the app to show which PixlCore modules are linked.
    public static let name = "PixlLyrics"

    /// Names of the PixlCore modules this module depends on.
    public static let dependencies: [String] = [PixlFoundationModule.name, PixlModelModule.name]
}
