import SwiftUI

/// Genre detail (Android `GenreDetailScreen`) — stage 7a.
struct GenreDetailView: View {
    let genreId: String

    var body: some View {
        PlaceholderScreen(title: "Genre", systemImage: "guitars", owner: "Stage 7a — Library & details", screenID: "genreDetail")
    }
}
