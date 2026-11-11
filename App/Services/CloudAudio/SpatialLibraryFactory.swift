import Foundation
import PixlModel
import UIKit

/// Where the cloud side of Spatial audio is put together (cloud audio spec 6.2 and 6.4): the local store of verified
/// renders (`CloudAudioStore`), the library that follows Cloud Studio's library jobs and answers the player and the
/// screens (`SpatialCloudLibrary`), and the background queue (`CloudAudioPrepareAhead`). `AppEnvironment` calls `make`
/// once, while the app is put together (a background relaunch too: Cloud Studio may need the store to put a render
/// that came down while PixlAudio was closed).
///
/// In UI tests (`context.launch.isUITest`, the demo Cloud Studio) it returns the no-op library: nothing touches the
/// network or the person's files.
enum SpatialLibraryFactory {
    static func make(_ context: SpatialAudioContext) -> any SpatialLibrary {
        guard !context.launch.isUITest, !context.cloud.isDemo, let directory = CloudAudioStore.defaultDirectory() else {
            return NoopSpatialLibrary()
        }
        let cloud = context.cloud
        let settings = context.settingsNow
        let library = SpatialCloudLibrary(cloud: cloud, store: CloudAudioStore(directory: directory),
                                          defaults: context.defaults, settings: settings)
        let songs = context.library, home = context.home, taste = context.musicTaste, blocked = context.settings.blocked
        let imported = context.importedHistory, adjustments = context.tasteAdjustments
        let ahead = CloudAudioPrepareAhead(cloud: cloud, library: library, settings: settings, sources: CloudAudioPrepareAhead.Sources(
            songs: { songs.songs },
            playlists: { songs.playlists },
            events: { home.history.events },
            signals: { taste.learnedSignals },
            blocked: { blocked.matcher },
            isAppActive: { UIApplication.shared.applicationState == .active },
            imported: { imported.aggregate },
            adjustments: { adjustments.activeSet(nowMs: currentTimeMillis()) }))
        library.ahead = ahead
        // Cloud Studio hands every verified render to the library's store.
        cloud.renderInstaller = library
        library.start()
        ahead.start()
        return library
    }
}
