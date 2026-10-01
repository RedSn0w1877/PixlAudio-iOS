import Observation
import SwiftUI

/// Navigation state for the whole shell: the selected tab, one stack per tab, and the presented sheet / cover.
/// Feature code navigates through these methods (or `@Bindable` paths); it never owns navigation state itself.
@Observable
final class Router {
    var selection: RootTab
    var homePath: [AppRoute]
    var searchPath: [AppRoute]
    var libraryPath: [AppRoute]
    var sheet: AppSheet?
    var cover: AppCover?
    /// The Search screen's query (stage 7c owns the field; kept here so deep links and UI tests can prefill it).
    var searchText: String

    init(launch: LaunchConfiguration) {
        let start = UITestLaunchRouter.initialState(for: launch)
        selection = start.tab
        homePath = start.homePath
        searchPath = start.searchPath
        libraryPath = start.libraryPath
        sheet = start.sheet
        cover = start.cover
        searchText = start.searchText
    }

    /// The path of the selected tab.
    var currentPath: [AppRoute] {
        switch selection {
        case .home: homePath
        case .search: searchPath
        case .library: libraryPath
        }
    }

    /// Android shows the bottom bar only at a tab's root (MainActivity `routesWithHiddenNavigationBar`).
    var isNavigationBarVisible: Bool {
        guard let top = currentPath.last else { return true }
        return !top.hidesNavigationBar
    }

    /// Pushes onto the selected tab's stack.
    func push(_ route: AppRoute) {
        switch selection {
        case .home: homePath.append(route)
        case .search: searchPath.append(route)
        case .library: libraryPath.append(route)
        }
    }

    /// Pops the selected tab's top route.
    func pop() {
        switch selection {
        case .home: if !homePath.isEmpty { homePath.removeLast() }
        case .search: if !searchPath.isEmpty { searchPath.removeLast() }
        case .library: if !libraryPath.isEmpty { libraryPath.removeLast() }
        }
    }

    /// Bottom-bar tap: switches tab; tapping the selected tab pops it to its root (Android `navigateToTopLevelSafely`).
    func select(_ tab: RootTab) {
        if tab == selection {
            switch tab {
            case .home: homePath.removeAll()
            case .search: searchPath.removeAll()
            case .library: libraryPath.removeAll()
            }
        } else {
            selection = tab
        }
    }

    func present(_ sheet: AppSheet) { self.sheet = sheet }
    func present(_ cover: AppCover) { self.cover = cover }
    func dismissSheet() { sheet = nil }
    func dismissCover() { cover = nil }
}
