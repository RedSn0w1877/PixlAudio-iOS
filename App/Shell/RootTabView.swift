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
            }
        }
        // On the TabView (WWDC25 "Build a SwiftUI app with the new design"), paired with the search-role tab.
        .searchable(text: $router.searchText, isPresented: $router.isSearchPresented, prompt: "Songs, artists, albums")
        .onChange(of: router.selection) { _, selection in
            // iOS 27 shows the (glass) search field only while search is active: activate it with the tab.
            if selection == .search { router.isSearchPresented = true }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: playback.hasItem) {
            MiniPlayerAccessory()
        }
    }
}

