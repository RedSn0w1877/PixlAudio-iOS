import SwiftUI

/// Create / edit a playlist (Android `CreatePlaylistScreen` and the playlist dialogs) — stage 7a.
struct PlaylistEditorView: View {
    /// nil = create a new playlist.
    let playlistId: String?

    var body: some View {
        PlaceholderScreen(title: "Playlist", systemImage: "text.badge.plus", owner: "Stage 7a — Library & details", screenID: "playlistEditor")
    }
}
