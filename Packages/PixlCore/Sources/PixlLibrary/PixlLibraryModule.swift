// PixlLibrary — ArtistParsing, AlbumGrouping, FolderTree, SearchIndex, sort/filter, smart rules, M3U, QueueUtils, recommendations/Daily Mix, stats aggregation, playback-history codec, k-means palette.
// Placeholder from stage 0. Keep the `PixlLibraryModule` enum: the app's Diagnostics screen lists it.

import PixlFoundation
import PixlModel

/// Identity of the `PixlLibrary` module.
public enum PixlLibraryModule {
    /// The module name, used by the app to show which PixlCore modules are linked.
    public static let name = "PixlLibrary"

    /// Names of the PixlCore modules this module depends on.
    public static let dependencies: [String] = [PixlFoundationModule.name, PixlModelModule.name]
}
