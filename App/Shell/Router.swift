import Observation
import SwiftUI

/// The root tabs.
nonisolated enum RootTab: String, Hashable, Sendable, CaseIterable {
    case home
    case library
    case search
}

/// Pushed destinations inside a tab's `NavigationStack`.
nonisolated enum Route: Hashable, Sendable {
    case settings
    case diagnostics
    case category(LibraryCategory)
}

/// Navigation state for the whole shell: selected tab, one path per tab, the search query.
@Observable
final class Router {
    var selection: RootTab
    var homePath: [Route]
    var libraryPath: [Route]
    var searchPath: [Route]
    var searchText: String
    /// Whether search is active. Bound to `.searchable(isPresented:)`. On iOS 27 a search-role tab shows
    /// no idle search field (verified on the iOS 27.0 simulator), so selecting the Search tab activates
    /// search — see `RootTabView`.
    var isSearchPresented: Bool

    init(launch: LaunchConfiguration) {
        let start = UITestLaunchRouter.initialState(for: launch)
        selection = start.tab
        homePath = start.homePath
        libraryPath = start.libraryPath
        searchPath = []
        searchText = start.searchText
        isSearchPresented = start.tab == .search
    }
}

extension View {
    /// Registers every `Route` destination. Apply once at the root of each tab's `NavigationStack`.
    func withRouteDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .settings:
                SettingsView()
            case .diagnostics:
                DiagnosticsView()
            case .category(let category):
                LibraryCategoryView(category: category)
            }
        }
    }
}
