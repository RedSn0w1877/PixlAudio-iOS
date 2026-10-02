import SwiftUI

/// Hands a row whether its song is the current one and playing, reading the playback store itself — so the screen
/// around the row doesn't: a song change or play/pause re-runs these small views for the visible rows instead of the
/// whole page (and the pages of hidden tabs). Only the current row reads `isPlaying`.
struct PlaybackRowState<Content: View>: View {
    let songId: String
    @ViewBuilder let content: (_ isCurrent: Bool, _ isPlaying: Bool) -> Content

    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        let isCurrent = playback.currentSongId == songId
        content(isCurrent, isCurrent && playback.isPlaying)
    }
}

/// The current song's id for a section that highlights it (Home's shelves): read here, not by the screen that hosts
/// the section.
struct CurrentSongState<Content: View>: View {
    @ViewBuilder let content: (_ currentSongId: String?) -> Content

    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        content(playback.currentSongId)
    }
}

/// The current song's id, play state and shuffle for a section with transport (Your Mix): read here, not by the
/// screen that hosts the section.
struct PlaybackState<Content: View>: View {
    @ViewBuilder let content: (_ currentSongId: String?, _ isPlaying: Bool, _ isShuffleEnabled: Bool) -> Content

    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        content(playback.currentSongId, playback.isPlaying, playback.isShuffleEnabled)
    }
}
