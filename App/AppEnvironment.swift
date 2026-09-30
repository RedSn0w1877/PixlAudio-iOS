import Observation
import SwiftUI

/// The app's dependency container, created once in `PixlAudioApp`.
///
/// Holds small, fine-grained `@Observable` stores. Stage 0 wires demo data only; later stages replace
/// `DemoLibrary` with the real `LibraryStore` and plug the real playback engine into `PlaybackStore`.
@Observable
final class AppEnvironment {
    let launch: LaunchConfiguration
    let library: DemoLibrary
    let playback: PlaybackStore
    let router: Router

    init(launch: LaunchConfiguration) {
        self.launch = launch
        let library = DemoLibrary()
        self.library = library
        self.playback = PlaybackStore(demoQueue: library.songs)
        self.router = Router(launch: launch)
    }
}
