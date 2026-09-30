import SwiftUI

/// Search tab (placeholder): genre grid when the query is empty, demo matches otherwise.
/// The search field itself comes from `.searchable` on the root `TabView` (system glass).
struct SearchView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        let query = router.searchText
        Group {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(environment.library.genres) { genre in
                            GenreTile(genre: genre)
                        }
                    }
                    .padding(.horizontal, Tokens.Spacing.l)
                    .padding(.vertical, Tokens.Spacing.s)
                }
            } else {
                SearchResultsList(results: environment.library.search(query), query: query)
            }
        }
        .navigationTitle("Search")
        .accessibilityIdentifier("screen.search")
    }
}

private struct SearchResultsList: View {
    let results: [DemoSong]
    let query: String

    var body: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(results) { song in
                SongRow(song: song)
            }
        }
    }
}

/// A genre tile. Content layer — a plain filled shape, never glass.
private struct GenreTile: View {
    let genre: DemoGenre

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: Tokens.Artwork.tileCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hue: genre.hue, saturation: 0.6, brightness: 0.85),
                            Color(hue: genre.hue, saturation: 0.8, brightness: 0.55),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(genre.name)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(Tokens.Spacing.m)
        }
        .frame(height: 96)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
