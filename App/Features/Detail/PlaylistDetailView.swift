import SwiftUI

/// Playlist detail (Android `PlaylistDetailScreen`) — stage 7a.
struct PlaylistDetailView: View {
    let playlistId: String

    var body: some View {
        PlaceholderScreen(title: "Playlist", systemImage: "music.note.list", owner: "Stage 7a — Library & details", screenID: "playlistDetail")
    }
}
