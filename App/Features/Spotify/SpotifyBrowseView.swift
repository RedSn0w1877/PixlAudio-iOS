import SwiftUI

/// Spotify catalogue browse (Android `presentation/spotify/browse`) — stage 12.
struct SpotifyBrowseView: View {
    let query: String

    var body: some View {
        PlaceholderScreen(title: "Browse Spotify", systemImage: "magnifyingglass.circle", owner: "Stage 12 — Spotify", screenID: "spotifyBrowse")
    }
}
