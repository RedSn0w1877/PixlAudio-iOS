import SwiftUI

/// Album detail (Android `AlbumDetailScreen`) — stage 7a.
struct AlbumDetailView: View {
    let albumId: Int64

    var body: some View {
        PlaceholderScreen(title: "Album", systemImage: "square.stack", owner: "Stage 7a — Library & details", screenID: "albumDetail")
    }
}
