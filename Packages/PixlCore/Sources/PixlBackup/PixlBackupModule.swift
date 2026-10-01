// PixlBackup — reads the owner's Android `.pxpl` backups and writes PixlAudio's own: manifest and modules, validators,
// sanitizer, versioning (v1/v2 legacy gzip JSON, v3 ZIP) with a pure-Swift ZIP reader/writer, gzip and inflate, and
// the mapping of every module onto PixlModel/PixlLibrary/PixlLyrics values. Keep the `PixlBackupModule` enum: the
// app's Diagnostics screen lists it.

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
