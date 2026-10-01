// PixlTags — ID3v2.2/2.3/2.4 read and 2.3/2.4 write (incl. SYLT, unsynchronisation, extended headers, padding
// reuse), ID3v1, FLAC Vorbis comments/PICTURE read/write, MP4 `ilst` read, and the ports of Android's
// AudioMetadataReader / ReplayGainManager / SongMetadataEditor tag logic. Pure Swift on `Data`.
// Keep the `PixlTagsModule` enum: the app's Diagnostics screen lists it.

import PixlFoundation
import PixlModel

/// Identity of the `PixlTags` module.
public enum PixlTagsModule {
    /// The module name, used by the app to show which PixlCore modules are linked.
    public static let name = "PixlTags"

    /// Names of the PixlCore modules this module depends on.
    public static let dependencies: [String] = [PixlFoundationModule.name, PixlModelModule.name]
}
