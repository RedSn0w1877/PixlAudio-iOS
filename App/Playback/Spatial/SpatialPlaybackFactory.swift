import Foundation
import PixlLyrics
import PixlModel

/// Where the player's side of Spatial audio is put together: the on-device stage in the processing tap, which audio a
/// song plays from, the in-song switch to a render, the route rule and the level rule (cloud audio spec 6.3 and 7).
/// `AppEnvironment` calls `make` once, while the app is assembled.
///
/// Real launches get `SpatialPlaybackController` on the real engine. UI tests (`context.launch.isUITest`, no
/// `context.playbackServices`) keep the no-op player: plain stereo, nothing that touches audio.
enum SpatialPlaybackFactory {
    /// `library`: the cloud side, for local files (`localRendition`) and for renders that land (`events()`).
    static func make(_ context: SpatialAudioContext, library: any SpatialLibrary) -> any SpatialPlayback {
        guard !context.launch.isUITest, let services = context.playbackServices else { return NoopSpatialPlayback() }
        let playback = context.playback
        let instrumental = context.tais.instrumental
        let lyrics = context.lyricsController
        let inputs = SpatialPlaybackController.Inputs(
            remoteDevicePlays: { playback.remoteOutputName != nil },
            sing: { (on: instrumental.isActive, switching: instrumental.isSwitching) },
            gaps: { songId in
                let offset = Int64(lyrics.store.offsetMs)
                guard lyrics.preparedSongId == songId, let prepared = lyrics.prepared else {
                    return (index: nil, offsetMs: offset)
                }
                return (index: SingGapIndex(prepared), offsetMs: offset)
            })
        // `settingsNow`: the stored settings, so the first song after launch starts right before `apply` arrives.
        return SpatialPlaybackController(engine: services.engine, library: library, settings: context.settingsNow,
                                         inputs: inputs)
    }
}
