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
    /// Counts the search field's submits (the keyboard's search key). The field lives in the bottom bar (split pill,
    /// 2026-11-16) and the Search page records the query in its history when this changes.
    private(set) var searchSubmission = 0
    /// The bar's search field has the keyboard (set by the shell from its focus state). Search swaps the genre grid for
    /// the recent searches while this is on and the field is blank.
    private(set) var isSearchFieldFocused = false
    /// Counts the times a screen asked the field to give up the keyboard (a tap on a recent search); the shell owns the
    /// focus state and drops it when this changes.
    private(set) var searchBlurRequests = 0
    /// The tab bar is minimized because a tab root scrolled down (`MinimizesTabBarOnScroll`). It stays minimized across
    /// tab switches and pushes; scrolling up, or tapping the selected tab, clears it.
    private(set) var isTabBarMinimized = false

    /// Sets `isTabBarMinimized`, writing only on a change (each write re-runs the shell's bottom bars).
    func setTabBarMinimized(_ minimized: Bool) {
        guard minimized != isTabBarMinimized else { return }
        isTabBarMinimized = minimized
    }

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
            // A page too short to scroll can't scroll the bar back: tapping the selected tab expands it.
            setTabBarMinimized(false)
            switch tab {
            case .home: homePath.removeAll()
            case .search: searchPath.removeAll()
            case .library: libraryPath.removeAll()
            }
        } else {
            selection = tab
        }
    }

    /// The bar's search field was submitted (see `searchSubmission`).
    func submitSearch() { searchSubmission &+= 1 }

    /// Writes `isSearchFieldFocused` only on a change (each write re-runs the Search page).
    func setSearchFieldFocused(_ focused: Bool) {
        guard focused != isSearchFieldFocused else { return }
        isSearchFieldFocused = focused
    }

    /// Asks the bar's field to give up the keyboard (see `searchBlurRequests`).
    func requestSearchBlur() { searchBlurRequests &+= 1 }

    func present(_ sheet: AppSheet) { self.sheet = sheet }
    func present(_ cover: AppCover) { self.cover = cover }
    func dismissSheet() { sheet = nil }
    func dismissCover() { cover = nil }
}
