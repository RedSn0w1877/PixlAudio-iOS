import SwiftUI

/// Artist detail (Android `ArtistDetailScreen`) — stage 7a.
struct ArtistDetailView: View {
    let artistId: Int64

    var body: some View {
        PlaceholderScreen(title: "Artist", systemImage: "music.mic", owner: "Stage 7a — Library & details", screenID: "artistDetail")
    }
}
