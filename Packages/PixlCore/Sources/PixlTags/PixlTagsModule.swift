// PixlTags — ID3v2 read/write incl. SYLT, FLAC Vorbis comments/PICTURE read/write, MP4 atom read.
// Placeholder from stage 0. Keep the `PixlTagsModule` enum: the app's Diagnostics screen lists it.

import PixlFoundation
import PixlModel

/// Identity of the `PixlTags` module.
public enum PixlTagsModule {
    /// The module name, used by the app to show which PixlCore modules are linked.
    public static let name = "PixlTags"

    /// Names of the PixlCore modules this module depends on.
    public static let dependencies: [String] = [PixlFoundationModule.name, PixlModelModule.name]
}
