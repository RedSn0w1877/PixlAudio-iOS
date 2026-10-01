// PixlLibrary — ArtistParsing, AlbumGrouping (+ LibraryAssembler), FolderTree, SearchIndex, LibrarySorting, smart
// playlists, M3U, QueueUtils, recommendations/Daily Mix/Home planner, playback stats + playback_history.json codec,
// k-means palette. Ported from the Android app (stage 3a); golden vectors in Tests/PixlLibraryTests/Fixtures.
// Keep the `PixlLibraryModule` enum: the app's Diagnostics screen lists it.

import PixlFoundation
import PixlModel

/// Identity of the `PixlLibrary` module.
public enum PixlLibraryModule {
    /// The module name, used by the app to show which PixlCore modules are linked.
    public static let name = "PixlLibrary"

    /// Names of the PixlCore modules this module depends on.
    public static let dependencies: [String] = [PixlFoundationModule.name, PixlModelModule.name]
}
