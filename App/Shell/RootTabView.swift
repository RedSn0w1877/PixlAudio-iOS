import SwiftUI

/// The Liquid Glass shell: a system `TabView` (glass tab bar that minimizes on scroll), a search tab,
/// and the mini player as the tab view's bottom accessory (the system supplies its glass).
struct RootTabView: View {
    @Environment(Router.self) private var router
    @Environment(PlaybackStore.self) private var playback
    @Environment(AppEnvironment.self) private var environment

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
                .modifier(SearchableIf(isOn: environment.launch.searchOnStack, text: $router.searchText))
            }
        }
        // On the TabView (WWDC25 "Build a SwiftUI app with the new design"): with a search-role tab the
        // field moves to the bottom of the screen on iPhone.
        .modifier(SearchableIf(isOn: !environment.launch.searchOnStack, text: $router.searchText))
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: playback.hasItem && !environment.launch.hideAccessory) {
            MiniPlayerAccessory()
        }
    }
}

/// Applies `.searchable` only when `isOn` (lets UI tests compare placements).
private struct SearchableIf: ViewModifier {
    let isOn: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isOn {
            content.searchable(text: $text, prompt: "Songs, artists, albums")
        } else {
            content
        }
    }
}
