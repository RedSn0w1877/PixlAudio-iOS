import Foundation
import PixlModel

/// Where the player's side of Spatial audio and Enhanced audio is put together: the on-device stage in the
/// processing tap, which audio a song plays from, the in-song switch to a render, the route rule and the level rule
/// (cloud audio spec 6.3 and 7). `AppEnvironment` calls `make` once, while the app is assembled.
///
/// Until that side exists this returns the no-op player: plain stereo, and nothing asks the cloud for anything.
/// The engine work replaces the body (and owns this file from then on); in UI tests (`context.launch.isUITest`,
/// `context.playbackServices == nil`) it keeps returning something that touches no audio.
enum SpatialPlaybackFactory {
    /// `library`: the cloud side, for local files (`localRendition`) and for renders that land (`events()`).
    static func make(_ context: SpatialAudioContext, library: any SpatialLibrary) -> any SpatialPlayback {
        NoopSpatialPlayback()
    }
}
