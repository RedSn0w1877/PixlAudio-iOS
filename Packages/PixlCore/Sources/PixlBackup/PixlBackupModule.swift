// PixlBackup — Android .pxpl manifest/modules, validators, sanitizer, zip/gzip containers (inflate injected).
// Placeholder from stage 0. Keep the `PixlBackupModule` enum: the app's Diagnostics screen lists it.

import PixlFoundation
import PixlModel
import PixlLibrary
import PixlLyrics

/// Identity of the `PixlBackup` module.
public enum PixlBackupModule {
    /// The module name, used by the app to show which PixlCore modules are linked.
    public static let name = "PixlBackup"

    /// Names of the PixlCore modules this module depends on.
    public static let dependencies: [String] = [PixlFoundationModule.name, PixlModelModule.name, PixlLibraryModule.name, PixlLyricsModule.name]
}
