import Foundation
import PixlModel

/// UI tests: the Spatial audio states the screenshots show. `SpatialAudioModel.make` calls `apply` on UI-test
/// launches only, right after the model is built (both of its halves are the no-ops there, and the settings start
/// from an emptied suite). Nothing is seeded yet: the screens' work adds a case per `DemoScreen` here, picking a
/// profile with `model.select(_:)` and pinning what plays with `model.setDemo(snapshot:libraryState:usage:)`.
enum SpatialDemo {
    static func apply(launch: LaunchConfiguration, to model: SpatialAudioModel) {}
}
