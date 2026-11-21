import Foundation
import PixlModel

/// Song Drop (Android `SongDropViewModel`): a song's options (the big button panel, the player's menu, a row's context menu) can
/// share that song with a phone nearby. The song becomes what Song Tap offers (instead of the one that plays), any sheet that is up
/// goes away, and the Song Tap screen opens on Send with its list of phones nearby. When Song Tap is off, that screen shows its
/// "Turn on Song Tap" card.
@MainActor
enum SongDrop {
    static func start(_ song: Song, env: AppEnvironment, router: Router) {
        env.songTap.beginSongDrop(song)
        let hadSheet = router.sheet != nil
        router.dismissSheet()
        guard hadSheet else {
            router.present(AppCover.songTap)
            return
        }
        // A cover cannot come up while a sheet is still going down.
        Task { @MainActor [router] in
            try? await Task.sleep(for: .milliseconds(450))
            router.present(AppCover.songTap)
        }
    }
}
