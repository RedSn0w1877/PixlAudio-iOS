import Foundation
import PixlModel

/// Where the cloud side of Spatial audio is put together: the local store of verified renders,
/// the shared library in R2, the jobs that fill it, the background queue and the caps (cloud audio spec 6.2 and 6.4).
/// `AppEnvironment` calls `make` once, while the app is assembled.
///
/// Until that side exists this returns the no-op library: nothing on the phone, and nothing ever leaves it. The cloud
/// work replaces the body (and owns this file from then on); in UI tests (`context.launch.isUITest`, the demo Cloud
/// Studio) it keeps returning something that touches neither the network nor the person's files.
enum SpatialLibraryFactory {
    static func make(_ context: SpatialAudioContext) -> any SpatialLibrary {
        NoopSpatialLibrary()
    }
}
