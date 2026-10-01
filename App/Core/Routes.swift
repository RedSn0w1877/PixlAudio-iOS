import Foundation

// Every destination of the app, mirroring Android's `presentation/navigation/Screen.kt` plus the sheets and full-screen
// players Android opens without a nav route. The router (`Shell/Router.swift`) pushes `AppRoute`s on the current tab's
// stack and presents `AppSheet` / `AppCover`; `Shell/RouteDestinations.swift` maps each case to the view that owns it.
// Parallel stages replace those views' bodies — they never need to edit these enums.

/// The three tabs of PixlAudio's bottom bar, in Android order (Home, Search, Library).
nonisolated enum RootTab: String, Hashable, Sendable, CaseIterable, Identifiable {
    case home
    case search
    case library

    var id: String { rawValue }

    /// Android `BottomNavItem` label (used for accessibility; the bar shows icons only).
    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .library: "Library"
        }
    }

    /// SF Symbols matching Android's `rounded_home_24` / `rounded_search_24` / `rounded_library_music_24`
    /// (outline) and their filled selected variants.
    var systemImage: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .library: "music.note.square.stack"
        }
    }

    var selectedSystemImage: String {
        switch self {
        case .home: "house.fill"
        case .search: "magnifyingglass"
        case .library: "music.note.square.stack.fill"
        }
    }

    /// Android `LaunchTab` storage values (`launch_tab` preference).
    var launchTabKey: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .library: "Library"
        }
    }
}

/// Settings categories (Android `presentation/model/SettingsCategory.kt`, same ids and order).
nonisolated enum SettingsCategory: String, Hashable, Sendable, CaseIterable, Identifiable {
    case library = "library"
    case appearance = "appearance"
    case playback = "playback"
    case equalizer = "equalizer"
    case behavior = "behavior"
    case ai = "ai"
    case backupRestore = "backup_restore"
    case developer = "developer"
    case deviceCapabilities = "device_capabilities"
    case about = "about"

    var id: String { rawValue }

    /// Android `settings_category_*_title`.
    var title: String {
        switch self {
        case .library: "Music Management"
        case .appearance: "Appearance"
        case .playback: "Playback"
        case .equalizer: "Equalizer"
        case .behavior: "Behavior"
        case .ai: "AI features"
        case .backupRestore: "Backup & Restore"
        case .developer: "Developer Options"
        case .deviceCapabilities: "Device Capabilities"
        case .about: "About"
        }
    }

    /// SF Symbols for Android's category icons (LibraryMusic, Palette, MusicNote, GraphicEq, touch_app, …).
    var systemImage: String {
        switch self {
        case .library: "music.note.house"
        case .appearance: "paintpalette"
        case .playback: "music.note"
        case .equalizer: "waveform"
        case .behavior: "hand.tap"
        case .ai: "sparkles"
        case .backupRestore: "externaldrive"
        case .developer: "hammer"
        case .deviceCapabilities: "iphone.gen3"
        case .about: "info.circle"
        }
    }
}

/// A pushed destination (Android `Screen` routes). Values are `nonisolated` so `Hashable` isn't main-actor isolated.
nonisolated enum AppRoute: Hashable, Sendable {
    // Library and details
    case albumDetail(albumId: Int64)
    case artistDetail(artistId: Int64)
    case genreDetail(genreId: String)
    case playlistDetail(playlistId: String)
    /// Create (`nil`) or edit a playlist (Android `CreatePlaylistScreen` / playlist dialogs).
    case playlistEditor(playlistId: String?)
    /// Folder browser (Android `FolderExplorerScreen`), at a folder path (`nil` = roots).
    case folderExplorer(path: String?)

    // Home
    case dailyMix
    case yourMix
    case recentlyPlayed
    case stats

    // Settings
    case settings
    case settingsCategory(SettingsCategory)
    case paletteStyle
    case experimental
    case artistSettings
    case delimiterConfig
    case wordDelimiterConfig
    case equalizer
    /// Transition rules (Android `edit_transition?playlistId=`), global when `nil`.
    case editTransition(playlistId: String?)
    case deviceCapabilities
    case about
    case openSourceLicenses
    case easterEgg
    case quickFill
    case diagnostics

    // Accounts
    case accounts
    case spotifyDashboard
    case spotifyBrowse(query: String)
    case youTubeLogin
    /// The YouTube playback test (Android: the Spotify dashboard's "Test playback" card).
    case playbackDiagnostics

    /// Android hides the bottom bar on almost every pushed screen (`routesWithHiddenNavigationBar` in
    /// MainActivity); the iOS shell does the same for every pushed route. The mini player stays.
    var hidesNavigationBar: Bool { true }

    /// A stable identifier (UI tests, logs).
    var screenID: String {
        switch self {
        case .albumDetail: "albumDetail"
        case .artistDetail: "artistDetail"
        case .genreDetail: "genreDetail"
        case .playlistDetail: "playlistDetail"
        case .playlistEditor: "playlistEditor"
        case .folderExplorer: "folderExplorer"
        case .dailyMix: "dailyMix"
        case .yourMix: "yourMix"
        case .recentlyPlayed: "recentlyPlayed"
        case .stats: "stats"
        case .settings: "settings"
        case .settingsCategory(let c): "settingsCategory.\(c.rawValue)"
        case .paletteStyle: "paletteStyle"
        case .experimental: "experimental"
        case .artistSettings: "artistSettings"
        case .delimiterConfig: "delimiterConfig"
        case .wordDelimiterConfig: "wordDelimiterConfig"
        case .equalizer: "equalizer"
        case .editTransition: "editTransition"
        case .deviceCapabilities: "deviceCapabilities"
        case .about: "about"
        case .openSourceLicenses: "openSourceLicenses"
        case .easterEgg: "easterEgg"
        case .quickFill: "quickFill"
        case .diagnostics: "diagnostics"
        case .accounts: "accounts"
        case .spotifyDashboard: "spotifyDashboard"
        case .spotifyBrowse: "spotifyBrowse"
        case .youTubeLogin: "youTubeLogin"
        case .playbackDiagnostics: "playbackDiagnostics"
        }
    }
}

/// A bottom sheet (Android `ModalBottomSheet`s): presented with the system sheet, PixlAudio's layout inside.
nonisolated enum AppSheet: Hashable, Sendable, Identifiable {
    case queue
    case songInfo(songId: String)
    case sleepTimer
    case lyricsOptions(songId: String)
    case changelog
    case betaInfo
    case jobs
    /// Stage 8: "AirPlay & devices" from the player's output pill (Android `CastBottomSheet`).
    case devices
    /// Stage 8: "Pick an Artist" from the player's artist line (Android `PlayerArtistPickerBottomSheet`).
    case artistPicker(songId: String)

    /// Stage 13: the AI playlist sheet (Android `AiPlaylistSheet`, Daily Mix's sparkle button).
    case aiPlaylist
    /// Stage 13: the TAIS DJ chat (Android `TaisChatSheet`) — from the player's sparkles circle and Experimental.
    case taisChat

    var id: String {
        switch self {
        case .queue: "queue"
        case .songInfo(let id): "songInfo.\(id)"
        case .sleepTimer: "sleepTimer"
        case .lyricsOptions(let id): "lyricsOptions.\(id)"
        case .changelog: "changelog"
        case .betaInfo: "betaInfo"
        case .jobs: "jobs"
        case .devices: "devices"
        case .artistPicker(let id): "artistPicker.\(id)"
        case .aiPlaylist: "aiPlaylist"
        case .taisChat: "taisChat"
        }
    }
}

/// A full-screen presentation (the expanded player sheet, the karaoke lyrics, the sync editor, first-run setup).
/// `.nowPlaying` is a request: the player sheet (stage 8, `PlayerSheetHost`) takes it and expands in place.
nonisolated enum AppCover: Hashable, Sendable, Identifiable {
    case nowPlaying
    case lyrics
    case lyricsSync(songId: String)
    case setup
    /// Stage 8: "Edit song" (Android `EditSongSheet`, a full-screen dialog).
    case editSong(songId: String)

    /// Stage 13: AI Playlist Lab (Android `CreateAiPlaylistDialog`, a full-screen dialog).
    case aiPlaylistLab

    /// Stage 15: the restore and export flows of Settings › Backup & Restore, presented from the root.
    case backupImport
    case backupExport

    var id: String {
        switch self {
        case .nowPlaying: "nowPlaying"
        case .lyrics: "lyrics"
        case .lyricsSync(let id): "lyricsSync.\(id)"
        case .setup: "setup"
        case .editSong(let id): "editSong.\(id)"
        case .aiPlaylistLab: "aiPlaylistLab"
        case .backupImport: "backupImport"
        case .backupExport: "backupExport"
        }
    }
}
