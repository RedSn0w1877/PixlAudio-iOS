import SwiftUI

/// Search — placeholder until stage 7c ports PixlAudio's Search (`SearchScreen.kt`: the search bar, source chips
/// for library / Spotify / YouTube Music, history, genre grid, results). Providers come through `SearchProviding`.
struct SearchView: View {
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            LargeHeader("Search")
            PlaceholderScreen(title: "Search", systemImage: "magnifyingglass", owner: "Stage 7c — Search",
                              screenID: "searchPlaceholder")
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("screen.search")
    }
}
