import Foundation

// The first-run setup's strings. Short, plain and friendly: the app is Spotify-only, so nothing here talks about
// files on the phone. English only for now (docs/design.md, owner decision 12).
extension L10n {
    // Welcome
    static let setupLetsGo = String(localized: "setup_lets_go", defaultValue: "Let's go")
    static func setupStepFormat(_ a1: Int, _ a2: Int) -> String {
        String(format: String(localized: "setup_step_format", defaultValue: "Step %1$lld of %2$lld"), a1, a2)
    }
    static let setupWelcomePrefix = String(localized: "setup_welcome_prefix", defaultValue: "Welcome to")
    static let setupBetaSymbol = String(localized: "setup_beta_symbol", defaultValue: "β")
    static let setupBetaLabel = String(localized: "setup_beta_label", defaultValue: "Beta")
    static let setupIntroBody = String(localized: "setup_intro_body", defaultValue: "Your Spotify music, your way. Setup takes about a minute.")

    // Navigation
    static let setupSkipForNow = String(localized: "setup_skip_for_now", defaultValue: "Skip for now")
    static let setupContinue = String(localized: "setup_continue", defaultValue: "Continue")
    static let setupStartListening = String(localized: "setup_start_listening", defaultValue: "Start listening")
    static let setupBack = String(localized: "setup_back", defaultValue: "Back")

    // Spotify
    static let setupSpotifyTitle = String(localized: "setup_spotify_title", defaultValue: "Connect Spotify")
    static let setupSpotifyDescription = String(localized: "setup_spotify_description", defaultValue: "Sign in and your music shows up here, ready to play.")
    static let setupSpotifyPerkLiked = String(localized: "setup_spotify_perk_liked", defaultValue: "Your liked songs")
    static let setupSpotifyPerkPlaylists = String(localized: "setup_spotify_perk_playlists", defaultValue: "Your playlists")
    static let setupSpotifyPerkMixes = String(localized: "setup_spotify_perk_mixes", defaultValue: "Mixes made from what you play")
    static let setupSpotifyButton = String(localized: "setup_spotify_button", defaultValue: "Sign in with Spotify")
    static let setupSpotifyConnected = String(localized: "setup_spotify_connected", defaultValue: "Spotify connected")
    static let setupSpotifyLater = String(localized: "setup_spotify_later", defaultValue: "No rush, you can do this later in Settings.")

    // Backup
    static let setupBackupHaveTitle = String(localized: "setup_backup_have_title", defaultValue: "Have a backup?")
    static let setupBackupHaveDescription = String(localized: "setup_backup_have_description", defaultValue: "Got a PixlAudio backup? Bring everything back in one go and we'll skip the rest.")
    static let setupImportBackup = String(localized: "setup_import_backup", defaultValue: "Import backup")
    static let setupInspectingBackup = String(localized: "setup_inspecting_backup", defaultValue: "Checking backup")
    static let setupCheckingBackup = String(localized: "setup_checking_backup", defaultValue: "Taking a look at your backup…")
    static let setupRestoringBackup = String(localized: "setup_restoring_backup", defaultValue: "Restoring backup")
    static let setupBackupChipPlaylists = String(localized: "setup_backup_chip_playlists", defaultValue: "Playlists")
    static let setupBackupChipSettings = String(localized: "setup_backup_chip_settings", defaultValue: "Settings")
    static let setupBackupChipLyrics = String(localized: "setup_backup_chip_lyrics", defaultValue: "Lyrics")
    static let setupBackupChipStats = String(localized: "setup_backup_chip_stats", defaultValue: "Stats")

    // Theme
    static let setupThemeTitle = String(localized: "setup_theme_title", defaultValue: "Pick your look")
    static let setupThemeSubtitle = String(localized: "setup_theme_subtitle", defaultValue: "Tap one. The app changes right away.")
    static let setupThemeDarkTitle = String(localized: "setup_theme_dark_title", defaultValue: "Dark")
    static let setupThemeDarkDescription = String(localized: "setup_theme_dark_description", defaultValue: "Easy on the eyes, great at night.")
    static let setupThemeLightTitle = String(localized: "setup_theme_light_title", defaultValue: "Light")
    static let setupThemeLightDescription = String(localized: "setup_theme_light_description", defaultValue: "Bright, clean and crisp.")
    static let setupThemeFollowTitle = String(localized: "setup_theme_follow_title", defaultValue: "Match my phone")
    static let setupThemeFollowDescription = String(localized: "setup_theme_follow_description", defaultValue: "Switches when your phone does.")
    static let setupRecommended = String(localized: "setup_recommended", defaultValue: "Our pick")
    static let setupThemeFooter = String(localized: "setup_theme_footer", defaultValue: "You can change this any time in Settings > Appearance.")

    // Library layout
    static let setupLibraryLayoutTitle = String(localized: "setup_library_layout_title", defaultValue: "Shape your library")
    static let setupLibraryLayoutSubtitle = String(localized: "setup_library_layout_subtitle", defaultValue: "Pick how you move around your songs.")
    static let setupPreviewSongsLabel = String(localized: "setup_preview_songs_label", defaultValue: "Songs")
    static let setupLayoutTabs = String(localized: "setup_layout_tabs", defaultValue: "Tabs")
    static let setupLayoutPill = String(localized: "setup_layout_pill", defaultValue: "Pill")
    static let setupCompactModePillHint = String(localized: "setup_compact_mode_pill_hint", defaultValue: "One small button that opens the menu.")
    static let setupCompactModeTabHint = String(localized: "setup_compact_mode_tab_hint", defaultValue: "Songs, Albums and Artists in a row at the top.")
    static let setupTabSongs = String(localized: "setup_tab_songs", defaultValue: "SONGS")
    static let setupTabAlbums = String(localized: "setup_tab_albums", defaultValue: "ALBUMS")
    static let setupTabArtists = String(localized: "setup_tab_artists", defaultValue: "ARTISTS")
    static let setupLibraryLayoutFooter = String(localized: "setup_library_layout_footer", defaultValue: "You can change this any time in Settings > Appearance.")

    // Finish
    static let setupAllSetTitle = String(localized: "setup_all_set_title", defaultValue: "You're all set")
    static let setupAllSetBody = String(localized: "setup_all_set_body", defaultValue: "Smart picks and lyrics are already on. You can tweak anything in Settings.")
    static let setupRecapSpotify = String(localized: "setup_recap_spotify", defaultValue: "Spotify")
    static let setupRecapConnected = String(localized: "setup_recap_connected", defaultValue: "Connected")
    static let setupRecapNotYet = String(localized: "setup_recap_not_yet", defaultValue: "Not yet")
    static let setupRecapLook = String(localized: "setup_recap_look", defaultValue: "Look")
    static let setupRecapLibrary = String(localized: "setup_recap_library", defaultValue: "Library")

    static let commonNext = String(localized: "common_next", defaultValue: "Next")
    static let commonFinish = String(localized: "common_finish", defaultValue: "Finish")
}
