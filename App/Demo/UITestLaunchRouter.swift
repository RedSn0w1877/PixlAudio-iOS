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
    /// AI features with a cloud assistant switched on (Gemini, the demo key): the optional "Cloud assistants" rows.
    case settingsAICloud = "settingsCategory.ai.cloud"
    case settingsBackupRestore = "settingsCategory.backup_restore"
    case settingsDeveloper = "settingsCategory.developer"
    case settingsDeviceCapabilities = "settingsCategory.device_capabilities"
    case settingsAbout = "settingsCategory.about"
    case paletteStyle, experimental, artistSettings, delimiterConfig, wordDelimiterConfig, equalizer, editTransition
    case deviceCapabilities, about, openSourceLicenses, easterEgg, quickFill, diagnostics
    case accounts, spotifyDashboard, spotifyBrowse, youTubeLogin
    // Stage 11: YouTube sign-in states and the playback test
    case youTubeLoginCode, youTubeLoginCookie, youTubeLoginSignedIn, playbackDiagnostics, playbackDiagnosticsFailed
    /// Streaming speed (R12): the playback test with the Stream start timings card open (demo starts).
    case playbackDiagnosticsTimings

    // Sheets
    case queue, songInfo, sleepTimer, lyricsOptions, changelog, betaInfo, jobs

    // Full-screen covers
    case nowPlaying, lyrics, lyricsSync, setup

    // Stage 7a: Library tabs, sheets and selection; playlist and genre detail states
    case libraryAlbums, libraryAlbumsList, libraryArtists, libraryPlaylists, libraryFolders, libraryLiked
    case librarySelection, librarySort, libraryReorderTabs, libraryMultiSelection, libraryCreatePlaylist
    case libraryAddToPlaylist, songOptionsInfo
    /// The creation sheet when the selected on-device model can't answer (its system switch is off).
    case libraryCreatePlaylistOnDeviceOff = "libraryCreatePlaylist.onDeviceOff"
    /// Library Navigation › Compact pill & grid (final review).
    case libraryCompactNav
    case playlistEdit, playlistAddSongs, playlistOptions, playlistReorder, genreSort

    // Stage 8: the player's sheets (presented over the expanded player) and the song editor
    case devices, artistPicker, editSong

    // Glass expansion (2026-10-07): the queue's Save as playlist cover (opened by the queue once it's up) and the
    // genre page's Quick Fill cover (opened by the page), for their floating glass bars
    case queueSaveAsPlaylist = "queue.saveAsPlaylist"
    case genreQuickFill = "genre.quickFill"

    // Spotify Connect output: the devices sheet on its DEVICES page with demo devices (idle, playing on the Echo,
    // linked before Connect's scopes, no devices), and the "Playing on" chip in the full and the mini player
    case devicesSpotifyConnect = "devices.spotifyConnect"
    case devicesSpotifyPlaying = "devices.spotifyPlaying"
    case devicesSpotifyReconnect = "devices.spotifyReconnect"
    case devicesSpotifyEmpty = "devices.spotifyEmpty"
    case nowPlayingSpotifyConnect = "nowPlaying.spotifyConnect"
    case miniPlayerSpotifyConnect = "miniPlayer.spotifyConnect"
    /// The full player playing to Bluetooth headphones ("AirPods Pro", `AudioRouteMonitor`'s demo route): the output
    /// pill shows the device's name (the simulator itself always plays to its speaker).
    case nowPlayingBluetooth = "nowPlaying.bluetooth"

    // Stage 12: account screens signed in with demo data (plain ids are signed out), dashboard with a playback test
    // report, browse drill-downs (search results, an artist, an album)
    case accountsSignedIn = "accounts.signedIn"
    case spotifyDashboardSignedIn = "spotifyDashboard.signedIn"
    case spotifyDashboardTested = "spotifyDashboard.tested"
    case spotifyBrowseResults = "spotifyBrowse.results"
    case spotifyBrowseArtist = "spotifyBrowse.artist"
    case spotifyBrowseAlbum = "spotifyBrowse.album"

    // Stage 13: AI playlist sheet (from Daily Mix), TAIS DJ chat (empty, and a scripted conversation), AI Playlist Lab
    case aiPlaylist, taisChat, taisChatConversation, aiPlaylistLab

    // Stage 15: the setup pages (cover `setup` opened on a page) and the backup restore steps (cover `backupImport`)
    case setupPermission, setupFolders, setupBackup, setupTheme, setupLibraryLayout, setupSpotify, setupFinish
    case backupRestorePlan, backupImportReport

    // Stage 14: TAIS Studio — Experimental's Remaster Song card and on-device models panel, the song sheet's card,
    // and the lyrics screen's instrumental UI (`TaisDemo` sets the job / model states)
    case taisStudio = "tais.studio", taisModels = "tais.models", taisSongSheet = "tais.songSheet"
    case taisInstrumental = "tais.instrumental", taisInstrumentalRendering = "tais.instrumentalRendering"
    case taisInstrumentalActive = "tais.instrumentalActive"

    /// The accessibility identifier present once the screen is up (`screen.<id>`).
    var readyIdentifier: String {
        switch self {
        case .home: return "screen.home"
        case .search, .searchResults: return "screen.search"
        case .library, .miniPlayer, .miniPlayerSpotifyConnect: return "screen.library"
        case .libraryAlbums, .libraryAlbumsList, .libraryArtists, .libraryPlaylists, .libraryFolders, .libraryLiked,
             .librarySelection, .librarySort, .libraryReorderTabs, .libraryMultiSelection, .libraryCreatePlaylist,
             .libraryAddToPlaylist, .libraryCompactNav, .libraryCreatePlaylistOnDeviceOff:
            return "screen.library"
        case .songOptionsInfo: return "screen.songInfo"
        case .miniPlayerAlone: return "screen.albumDetail"
        case .aiPlaylist: return "screen.aiPlaylist"
        case .taisChat, .taisChatConversation: return "screen.taisChat"
        case .aiPlaylistLab: return "screen.aiPlaylistLab"
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
        case .home, .search, .searchResults, .library, .miniPlayer, .miniPlayerSpotifyConnect: return nil
        case .devicesSpotifyConnect, .devicesSpotifyPlaying, .devicesSpotifyReconnect, .devicesSpotifyEmpty,
             .nowPlayingSpotifyConnect, .nowPlayingBluetooth:
            return nil
        case .libraryAlbums, .libraryAlbumsList, .libraryArtists, .libraryPlaylists, .libraryFolders, .libraryLiked,
             .librarySelection, .librarySort, .libraryReorderTabs, .libraryMultiSelection, .libraryCreatePlaylist,
             .libraryAddToPlaylist, .songOptionsInfo, .libraryCompactNav, .libraryCreatePlaylistOnDeviceOff:
            return nil
        case .playlistEdit: return .playlistEditor(playlistId: demo.playlists.first?.id)
        case .playlistAddSongs, .playlistOptions, .playlistReorder:
            return .playlistDetail(playlistId: demo.playlists.first?.id ?? "")
        case .genreSort, .genreQuickFill: return .genreDetail(genreId: "Indie")
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
        case .settingsAI, .settingsAICloud: return .settingsCategory(.ai)
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
        case .accounts, .accountsSignedIn: return .accounts
        case .spotifyDashboard, .spotifyDashboardSignedIn, .spotifyDashboardTested: return .spotifyDashboard
        case .spotifyBrowseResults: return .spotifyBrowse(query: "Luma")
        case .spotifyBrowseArtist, .spotifyBrowseAlbum: return .spotifyBrowse(query: "")
        case .spotifyBrowse: return .spotifyBrowse(query: "")
        case .youTubeLogin, .youTubeLoginCode, .youTubeLoginCookie, .youTubeLoginSignedIn: return .youTubeLogin
        case .playbackDiagnostics, .playbackDiagnosticsFailed, .playbackDiagnosticsTimings: return .playbackDiagnostics
        case .queue, .songInfo, .sleepTimer, .lyricsOptions, .changelog, .betaInfo, .jobs,
             .nowPlaying, .lyrics, .lyricsSync, .setup, .devices, .artistPicker, .editSong, .queueSaveAsPlaylist:
            return nil
        case .aiPlaylist, .taisChat, .taisChatConversation, .aiPlaylistLab: return nil
        case .setupPermission, .setupFolders, .setupBackup, .setupTheme, .setupLibraryLayout, .setupSpotify, .setupFinish:
            return nil
        // A full-screen cover: nothing needs to be pushed underneath (one destination per demo screen).
        case .backupRestorePlan, .backupImportReport: return nil
        case .taisStudio, .taisModels: return .experimental
        case .taisSongSheet, .taisInstrumental, .taisInstrumentalRendering, .taisInstrumentalActive: return nil
        }
    }

    /// The tab whose stack holds `route` (settings and home screens from Home, details from Library).
    var tab: RootTab {
        switch self {
        case .search, .searchResults: .search
        case .library, .miniPlayer, .miniPlayerAlone, .albumDetail, .artistDetail, .genreDetail, .playlistDetail,
             .playlistEditor, .folderExplorer, .miniPlayerSpotifyConnect:
            .library
        case .libraryAlbums, .libraryAlbumsList, .libraryArtists, .libraryPlaylists, .libraryFolders, .libraryLiked,
             .librarySelection, .librarySort, .libraryReorderTabs, .libraryMultiSelection, .libraryCreatePlaylist,
             .libraryAddToPlaylist, .songOptionsInfo, .playlistEdit, .playlistAddSongs, .playlistOptions,
             .playlistReorder, .genreSort, .libraryCompactNav, .libraryCreatePlaylistOnDeviceOff, .genreQuickFill:
            .library
        default: .home
        }
    }

    var sheet: AppSheet? {
        let songId = DemoLibrary.songs.first?.id ?? ""
        switch self {
        case .queue, .queueSaveAsPlaylist: return .queue
        case .songInfo, .songOptionsInfo, .taisSongSheet: return .songInfo(songId: songId)
        case .sleepTimer: return .sleepTimer
        case .lyricsOptions: return .lyricsOptions(songId: songId)
        case .changelog: return .changelog
        case .betaInfo: return .betaInfo
        case .jobs: return .jobs
        case .devices, .devicesSpotifyConnect, .devicesSpotifyPlaying, .devicesSpotifyReconnect, .devicesSpotifyEmpty:
            return .devices
        case .artistPicker: return .artistPicker(songId: DemoLibrary.songs[DemoLibrary.featuredSongIndex].id)
        case .aiPlaylist: return .aiPlaylist
        case .taisChat, .taisChatConversation: return .taisChat
        default: return nil
        }
    }

    /// Stage 8: the player's sheets open over the expanded player, as on Android (`AppEnvironment` expands it).
    var opensOverPlayer: Bool {
        switch self {
        case .queue, .queueSaveAsPlaylist, .sleepTimer, .devices, .artistPicker: true
        case .devicesSpotifyConnect, .devicesSpotifyPlaying, .devicesSpotifyReconnect, .devicesSpotifyEmpty: true
        default: false
        }
    }

    /// The devices sheet opens on its DEVICES page (where the Spotify Connect section is).
    var opensDevicesList: Bool {
        switch self {
        case .devicesSpotifyConnect, .devicesSpotifyPlaying, .devicesSpotifyReconnect, .devicesSpotifyEmpty: true
        default: false
        }
    }

    /// A demo Spotify Connect session plays on the Echo ("Playing on Kitchen Echo Show").
    var startsSpotifyConnectSession: Bool {
        switch self {
        case .devicesSpotifyPlaying, .nowPlayingSpotifyConnect, .miniPlayerSpotifyConnect: true
        default: false
        }
    }

    var cover: AppCover? {
        switch self {
        case .nowPlaying, .nowPlayingSpotifyConnect, .nowPlayingBluetooth: .nowPlaying
        case .editSong: .editSong(songId: DemoLibrary.songs.first?.id ?? "")
        case .lyrics, .taisInstrumental, .taisInstrumentalRendering, .taisInstrumentalActive: .lyrics
        case .lyricsSync: .lyricsSync(songId: DemoLibrary.songs.first?.id ?? "")
        case .setup, .setupPermission, .setupFolders, .setupBackup, .setupTheme, .setupLibraryLayout, .setupSpotify,
             .setupFinish:
            .setup
        case .aiPlaylistLab: .aiPlaylistLab
        case .backupRestorePlan, .backupImportReport: .backupImport
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
///     -demoScale <n>               repeat the demo library n times (performance tests: a library of real size)
///     -accent RRGGBB               UI tests only: start with this accent colour (Settings › Appearance › Accent Color)
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
    /// How many copies of the demo library to load (1 = the screenshot library).
    var demoScale: Int
    /// `-cloudFilter`: the song picker shows its LOCAL / CLOUD switch although the demo library has no streamed songs.
    var forcesCloudFilter: Bool
    /// `-accent RRGGBB` (UI tests only, `#` optional): the accent the ephemeral settings start with, for the accent
    /// screenshots. The raw value; `AppEnvironment` normalises it (and ignores anything unreadable).
    var accentHex: String?

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
        let vivid = screen == .miniPlayer || screen == .miniPlayerAlone || screen == .miniPlayerSpotifyConnect
        let defaultSong = screen == .artistPicker ? DemoLibrary.featuredSongIndex
            : (vivid ? UITestLaunchRouter.vividSongIndex : 0)
        songIndex = value(after: "-song").flatMap(Int.init) ?? defaultSong
        startsPlaying = !arguments.contains("-paused")
        hasSong = !arguments.contains("-noSong")
        demoScale = min(max(value(after: "-demoScale").flatMap(Int.init) ?? 1, 1), 400)
        forcesCloudFilter = isUITest && arguments.contains("-cloudFilter")
        accentHex = isUITest ? value(after: "-accent") : nil
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
    private static let underAccounts: Set<String> = ["spotifyDashboard", "spotifyBrowse", "youTubeLogin", "playbackDiagnostics"]

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
