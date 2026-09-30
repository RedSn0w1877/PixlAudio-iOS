import SwiftUI

/// The Liquid Glass shell: a system `TabView` (glass tab bar that minimizes on scroll), a search tab,
/// and the mini player as the tab view's bottom accessory (the system supplies its glass).
struct RootTabView: View {
    @Environment(Router.self) private var router
    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selection) {
            Tab("Home", systemImage: "house.fill", value: RootTab.home) {
                NavigationStack(path: $router.homePath) {
                    HomeView()
                        .withRouteDestinations()
                }
            }

            Tab("Library", systemImage: "square.stack.fill", value: RootTab.library) {
                NavigationStack(path: $router.libraryPath) {
                    LibraryView()
                        .withRouteDestinations()
                }
            }

            Tab(value: RootTab.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView()
                        .withRouteDestinations()
                }
                .searchable(text: $router.searchText, prompt: "Songs, artists, albums")
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: playback.hasItem) {
            MiniPlayerAccessory()
        }
    }
}
