import Foundation
import SwiftUI

/// Screens reachable directly from launch arguments (`-screen <id>`), used by UI screenshot tests.
nonisolated enum DemoScreen: String, Sendable, CaseIterable {
    case home
    case library
    case search
    case searchResults
    case miniPlayer
    case settings
    case diagnostics
}

/// Parsed launch arguments.
///
///     -uiTest                      run with demo data, no side effects (no audio, no network)
///     -screen <DemoScreen>         route straight to a screen
///     -appearance light|dark       force the colour scheme
///     -searchQuery <text>          prefill the search field (the searchResults screen uses a default)
nonisolated struct LaunchConfiguration: Equatable, Sendable {
    nonisolated enum Appearance: String, Sendable {
        case system, light, dark
    }

    var isUITest: Bool
    var screen: DemoScreen?
    var appearance: Appearance
    var searchQuery: String?
    /// Experiment flags (UI tests only): attach `.searchable` to the search tab's stack instead of the
    /// TabView, and hide the bottom accessory.
    var searchOnStack: Bool
    var hideAccessory: Bool
    var presentSearch: Bool

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }
        isUITest = arguments.contains("-uiTest")
        screen = value(after: "-screen").flatMap(DemoScreen.init(rawValue:))
        appearance = value(after: "-appearance").flatMap(Appearance.init(rawValue:)) ?? .system
        searchQuery = value(after: "-searchQuery")
        searchOnStack = arguments.contains("-searchOnStack")
        hideAccessory = arguments.contains("-hideAccessory")
        presentSearch = arguments.contains("-presentSearch")
    }

    /// The configuration of this process.
    static let current = LaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)

    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Maps a launch configuration to the shell's initial navigation state.
nonisolated enum UITestLaunchRouter {
    nonisolated struct InitialState: Equatable, Sendable {
        var tab: RootTab = .home
        var homePath: [Route] = []
        var libraryPath: [Route] = []
        var searchText: String = ""
    }

    static let defaultSearchQuery = "Luma"

    static func initialState(for launch: LaunchConfiguration) -> InitialState {
        var state = InitialState()
        state.searchText = launch.searchQuery ?? ""
        switch launch.screen {
        case nil, .home:
            break
        case .library, .miniPlayer:
            state.tab = .library
        case .search:
            state.tab = .search
        case .searchResults:
            state.tab = .search
            if state.searchText.isEmpty { state.searchText = defaultSearchQuery }
        case .settings:
            state.homePath = [.settings]
        case .diagnostics:
            state.homePath = [.settings, .diagnostics]
        }
        return state
    }
}
