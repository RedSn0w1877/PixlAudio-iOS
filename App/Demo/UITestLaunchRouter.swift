import Foundation
import SwiftUI

/// Every screen reachable straight from launch arguments (`-screen <id>`), for UI and screenshot tests. One case
/// per `AppRoute`, `AppSheet` and `AppCover`, plus the tab roots and shell states. Ids are stable — tests use them.
nonisolated enum DemoScreen: String, Sendable, CaseIterable {
    // Tab roots and shell states
    case home
    case search
    case searchResults
    case library
    /// Library with a vivid song playing, so the album-tinted mini player shows.
    case miniPlayer
    /// A pushed screen: bottom bar hidden, mini player alone at the bottom (32 pt corners).
    case miniPlayerAlone

    // Pushed routes
    case albumDetail, artistDetail, genreDetail, playlistDetail, playlistEditor, folderExplorer
    case dailyMix, yourMix, recentlyPlayed, stats
    case settings
    case settingsLibrary = "settingsCategory.library"
    case settingsAppearance = "settingsCategory.appearance"
    case settingsPlayback = "settingsCategory.playback"
    case settingsEqualizer = "settingsCategory.equalizer"
    case settingsBehavior = "settingsCategory.behavior"
    case settingsAI = "settingsCategory.ai"
    case settingsBackupRestore = "settingsCategory.backup_restore"
    case settingsDeveloper = "settingsCategory.developer"
    case settingsDeviceCapabilities = "settingsCategory.device_capabilities"
    case settingsAbout = "settingsCategory.about"
    case paletteStyle, experimental, artistSettings, delimiterConfig, wordDelimiterConfig, equalizer, editTransition
    case deviceCapabilities, about, openSourceLicenses, easterEgg, quickFill, diagnostics
    case accounts, spotifyDashboard, spotifyBrowse, youTubeLogin

    // Sheets
    case queue, songInfo, sleepTimer, lyricsOptions, changelog, betaInfo, jobs

    // Full-screen covers
    case nowPlaying, lyrics, lyricsSync, setup

    // Stage 7a: Library tabs, sheets and selection; playlist and genre detail states
    case libraryAlbums, libraryAlbumsList, libraryArtists, libraryPlaylists, libraryFolders, libraryLiked
    case librarySelection, librarySort, libraryReorderTabs, libraryMultiSelection, libraryCreatePlaylist
    case libraryAddToPlaylist, songOptionsInfo
    case playlistEdit, playlistAddSongs, playlistOptions, playlistReorder, genreSort

    /// The accessibility identifier present once the screen is up (`screen.<id>`).
    var readyIdentifier: String {
        switch self {
        case .home: return "screen.home"
        case .search, .searchResults: return "screen.search"
        case .library, .miniPlayer: return "screen.library"
        case .libraryAlbums, .libraryAlbumsList, .libraryArtists, .libraryPlaylists, .libraryFolders, .libraryLiked,
             .librarySelection, .librarySort, .libraryReorderTabs, .libraryMultiSelection, .libraryCreatePlaylist,
             .libraryAddToPlaylist:
            return "screen.library"
        case .songOptionsInfo: return "screen.songInfo"
        case .miniPlayerAlone: return "screen.albumDetail"
        default:
            if let route { return "screen.\(route.screenID)" }
            if let sheet { return "screen.\(sheet.id.split(separator: ".").first ?? "")" }
            if let cover { return "screen.\(cover.id.split(separator: ".").first ?? "")" }
            return "screen.home"
        }
    }

    /// The route this screen pushes (on the tab that owns it), if any.
    var route: AppRoute? {
        let demo = DemoLibrary.snapshot
        switch self {
        case .home, .search, .searchResults, .library, .miniPlayer: return nil
        case .libraryAlbums, .libraryAlbumsList, .libraryArtists, .libraryPlaylists, .libraryFolders, .libraryLiked,
             .librarySelection, .librarySort, .libraryReorderTabs, .libraryMultiSelection, .libraryCreatePlaylist,
             .libraryAddToPlaylist, .songOptionsInfo:
            return nil
        case .playlistEdit: return .playlistEditor(playlistId: demo.playlists.first?.id)
        case .playlistAddSongs, .playlistOptions, .playlistReorder:
            return .playlistDetail(playlistId: demo.playlists.first?.id ?? "")
        case .genreSort: return .genreDetail(genreId: "Indie")
        case .miniPlayerAlone, .albumDetail: return .albumDetail(albumId: demo.albums.first?.id ?? 1)
        case .artistDetail: return .artistDetail(artistId: demo.artists.first?.id ?? 1)
        case .genreDetail: return .genreDetail(genreId: "Indie")
        case .playlistDetail: return .playlistDetail(playlistId: demo.playlists.first?.id ?? "")
        case .playlistEditor: return .playlistEditor(playlistId: nil)
        case .folderExplorer: return .folderExplorer(path: nil)
        case .dailyMix: return .dailyMix
        case .yourMix: return .yourMix
        case .recentlyPlayed: return .recentlyPlayed
        case .stats: return .stats
        case .settings: return .settings
        case .settingsLibrary: return .settingsCategory(.library)
        case .settingsAppearance: return .settingsCategory(.appearance)
        case .settingsPlayback: return .settingsCategory(.playback)
        case .settingsEqualizer: return .settingsCategory(.equalizer)
        case .settingsBehavior: return .settingsCategory(.behavior)
        case .settingsAI: return .settingsCategory(.ai)
        case .settingsBackupRestore: return .settingsCategory(.backupRestore)
        case .settingsDeveloper: return .settingsCategory(.developer)
        case .settingsDeviceCapabilities: return .settingsCategory(.deviceCapabilities)
        case .settingsAbout: return .settingsCategory(.about)
        case .paletteStyle: return .paletteStyle
        case .experimental: return .experimental
        case .artistSettings: return .artistSettings
        case .delimiterConfig: return .delimiterConfig
        case .wordDelimiterConfig: return .wordDelimiterConfig
        case .equalizer: return .equalizer
        case .editTransition: return .editTransition(playlistId: nil)
        case .deviceCapabilities: return .deviceCapabilities
        case .about: return .about
        case .openSourceLicenses: return .openSourceLicenses
        case .easterEgg: return .easterEgg
        case .quickFill: return .quickFill
        case .diagnostics: return .diagnostics
        case .accounts: return .accounts
        case .spotifyDashboard: return .spotifyDashboard
        case .spotifyBrowse: return .spotifyBrowse(query: "")
        case .youTubeLogin: return .youTubeLogin
        case .queue, .songInfo, .sleepTimer, .lyricsOptions, .changelog, .betaInfo, .jobs,
             .nowPlaying, .lyrics, .lyricsSync, .setup:
            return nil
        }
    }

    /// The tab whose stack holds `route` (settings and home screens from Home, details from Library).
    var tab: RootTab {
        switch self {
        case .search, .searchResults: .search
        case .library, .miniPlayer, .miniPlayerAlone, .albumDetail, .artistDetail, .genreDetail, .playlistDetail,
             .playlistEditor, .folderExplorer:
            .library
        case .libraryAlbums, .libraryAlbumsList, .libraryArtists, .libraryPlaylists, .libraryFolders, .libraryLiked,
             .librarySelection, .librarySort, .libraryReorderTabs, .libraryMultiSelection, .libraryCreatePlaylist,
             .libraryAddToPlaylist, .songOptionsInfo, .playlistEdit, .playlistAddSongs, .playlistOptions,
             .playlistReorder, .genreSort:
            .library
        default: .home
        }
    }

    var sheet: AppSheet? {
        let songId = DemoLibrary.songs.first?.id ?? ""
        switch self {
        case .queue: return .queue
        case .songInfo, .songOptionsInfo: return .songInfo(songId: songId)
        case .sleepTimer: return .sleepTimer
        case .lyricsOptions: return .lyricsOptions(songId: songId)
        case .changelog: return .changelog
        case .betaInfo: return .betaInfo
        case .jobs: return .jobs
        default: return nil
        }
    }

    var cover: AppCover? {
        switch self {
        case .nowPlaying: .nowPlaying
        case .lyrics: .lyrics
        case .lyricsSync: .lyricsSync(songId: DemoLibrary.songs.first?.id ?? "")
        case .setup: .setup
        default: nil
        }
    }
}

/// Parsed launch arguments.
///
///     -uiTest                      demo data, in-memory store, no side effects (no audio, no network)
///     -screen <DemoScreen>         route straight to a screen
///     -appearance light|dark       force the colour scheme
///     -searchQuery <text>          prefill the search query (searchResults uses a default)
///     -song <index>                the demo song that is current (default 0; miniPlayer uses a vivid one)
///     -paused                      start paused (default: playing)
///     -noSong                      nothing playing (no mini player)
nonisolated struct LaunchConfiguration: Equatable, Sendable {
    nonisolated enum Appearance: String, Sendable {
        case system, light, dark
    }

    var isUITest: Bool
    var screen: DemoScreen?
    var appearance: Appearance
    var searchQuery: String?
    var songIndex: Int
    var startsPlaying: Bool
    var hasSong: Bool

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
        let vivid = screen == .miniPlayer || screen == .miniPlayerAlone
        songIndex = value(after: "-song").flatMap(Int.init) ?? (vivid ? UITestLaunchRouter.vividSongIndex : 0)
        startsPlaying = !arguments.contains("-paused")
        hasSong = !arguments.contains("-noSong")
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
        var homePath: [AppRoute] = []
        var searchPath: [AppRoute] = []
        var libraryPath: [AppRoute] = []
        var sheet: AppSheet?
        var cover: AppCover?
        var searchText: String = ""
    }

    static let defaultSearchQuery = "Luma"
    /// A demo song whose generated art is strongly coloured (the album-tint screenshot).
    static let vividSongIndex = 2

    /// Settings screens open on top of Settings (and the account screens on top of Accounts), as when navigated.
    private static let underSettings: Set<String> = [
        "paletteStyle", "experimental", "artistSettings", "delimiterConfig", "wordDelimiterConfig", "equalizer",
        "editTransition", "deviceCapabilities", "about", "openSourceLicenses", "easterEgg", "quickFill",
        "diagnostics", "accounts",
    ]
    private static let underAccounts: Set<String> = ["spotifyDashboard", "spotifyBrowse", "youTubeLogin"]

    static func initialState(for launch: LaunchConfiguration) -> InitialState {
        var state = InitialState()
        state.searchText = launch.searchQuery ?? ""
        guard let screen = launch.screen else { return state }
        state.tab = screen.tab
        if screen == .searchResults, state.searchText.isEmpty { state.searchText = defaultSearchQuery }
        if let route = screen.route {
            var path: [AppRoute] = []
            if case .settingsCategory = route { path.append(.settings) }
            if underSettings.contains(route.screenID) { path.append(.settings) }
            if underAccounts.contains(route.screenID) { path.append(contentsOf: [.settings, .accounts]) }
            path.append(route)
            switch screen.tab {
            case .home: state.homePath = path
            case .search: state.searchPath = path
            case .library: state.libraryPath = path
            }
        }
        state.sheet = screen.sheet
        state.cover = screen.cover
        return state
    }
}
