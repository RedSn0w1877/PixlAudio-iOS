import Foundation

// The setup's strings (Android `setup_*`). Where the iOS step means the same thing the English is Android's (brand
// name aside), so the String Catalog carries Android's translations; strings that changed meaning on iOS (the music
// library instead of storage, music folders instead of excluded folders, no Material wording) keep their key but
// get iOS English, and the catalog leaves them untranslated rather than show a wrong translation.
extension L10n {
    static let setupLetsGo = String(localized: "setup_lets_go", defaultValue: "Let's Go!")
    static func setupStepFormat(_ a1: Int, _ a2: Int) -> String {
        String(format: String(localized: "setup_step_format", defaultValue: "Step %1$lld of %2$lld"), a1, a2)
    }
    static let setupWelcomePrefix = String(localized: "setup_welcome_prefix", defaultValue: "Welcome to ")
    static let setupBetaSymbol = String(localized: "setup_beta_symbol", defaultValue: "β")
    static let setupBetaLabel = String(localized: "setup_beta_label", defaultValue: "Beta")
    static let setupIntroBody = String(localized: "setup_intro_body", defaultValue: "Let's get everything set up for you.")

    static let setupPermissionMediaTitle = String(localized: "setup_permission_media_title", defaultValue: "Media Permission")
    static let setupPermissionMediaDescription = String(localized: "setup_permission_media_description", defaultValue: "PixlAudio can play the downloaded, DRM-free songs in your music library. Allow access to add them to your library.")
    static let setupPermissionGranted = String(localized: "setup_permission_granted", defaultValue: "Permission Granted")
    static let setupGrantMediaPermission = String(localized: "setup_grant_media_permission", defaultValue: "Grant Media Permission")
    static let setupPermissionDeniedHint = String(localized: "setup_permission_media_denied_hint", defaultValue: "Access was declined. You can allow it later in the Settings app; your music folders work without it.")

    static let setupMusicFoldersTitle = String(localized: "setup_music_folders_title", defaultValue: "Music folders")
    static let setupMusicFoldersDescription = String(localized: "setup_music_folders_description", defaultValue: "PixlAudio reads the music in its own folder (Files › On My iPhone › PixlAudio). Add any other folders that hold your music.")
    static let setupChooseFolders = String(localized: "setup_choose_folders", defaultValue: "Choose folders")
    static func setupFoldersAdded(_ a1: Int) -> String {
        String(format: String(localized: "setup_folders_added", defaultValue: "%1$lld folders added"), a1)
    }
    static let setupSkipForNow = String(localized: "setup_skip_for_now", defaultValue: "Skip / Not now")

    static let setupBackupHaveTitle = String(localized: "setup_backup_have_title", defaultValue: "Do you have a backup?")
    static let setupBackupHaveDescription = String(localized: "setup_backup_have_description", defaultValue: "If you already have a PixlAudio backup, restore it now and skip most of the remaining setup on this device.")
    static let setupImportBackup = String(localized: "setup_import_backup", defaultValue: "Import backup")
    static let setupInspectingBackup = String(localized: "setup_inspecting_backup", defaultValue: "Inspecting backup")
    static let setupCheckingBackup = String(localized: "setup_checking_backup", defaultValue: "Checking backup package…")
    static let setupRestoringBackup = String(localized: "setup_restoring_backup", defaultValue: "Restoring backup")
    static let setupScanningLibrary = String(localized: "setup_scanning_library", defaultValue: "Reading your library first, so the backup's songs can be matched…")

    static let setupThemeTitle = String(localized: "setup_theme_title", defaultValue: "App Theme")
    static let setupThemeSubtitle = String(localized: "setup_theme_subtitle", defaultValue: "Pick the look you want before you start exploring your library.")
    static let setupThemeDarkTitle = String(localized: "setup_theme_dark_title", defaultValue: "Dark")
    static let setupThemeDarkDescription = String(localized: "setup_theme_dark_description", defaultValue: "The default dark look for PixlAudio.")
    static let setupThemeLightTitle = String(localized: "setup_theme_light_title", defaultValue: "Light")
    static let setupThemeLightDescription = String(localized: "setup_theme_light_description", defaultValue: "A brighter look across the app.")
    static let setupThemeFollowTitle = String(localized: "setup_theme_follow_title", defaultValue: "Follow system")
    static let setupThemeFollowDescription = String(localized: "setup_theme_follow_description", defaultValue: "Match your phone's current appearance setting.")
    static let setupRecommended = String(localized: "setup_recommended", defaultValue: "Recommended")
    static let setupThemeFooter = String(localized: "setup_theme_footer", defaultValue: "You can change this later in Settings > Appearance > App Theme.")

    static let setupLibraryLayoutTitle = String(localized: "setup_library_layout_title", defaultValue: "Library Layout")
    static let setupLibraryLayoutSubtitle = String(localized: "setup_library_layout_subtitle", defaultValue: "Choose your preferred way to navigate your library.")
    static let setupPreviewSongsLabel = String(localized: "setup_preview_songs_label", defaultValue: "Songs")
    static let setupCompactMode = String(localized: "setup_compact_mode", defaultValue: "Compact Mode")
    static let setupCompactModePillHint = String(localized: "setup_compact_mode_pill_hint", defaultValue: "Using minimal pill navigation")
    static let setupCompactModeTabHint = String(localized: "setup_compact_mode_tab_hint", defaultValue: "Using standard tab row")
    static let setupTabSongs = String(localized: "setup_tab_songs", defaultValue: "SONGS")
    static let setupTabAlbums = String(localized: "setup_tab_albums", defaultValue: "ALBUMS")
    static let setupTabArtists = String(localized: "setup_tab_artists", defaultValue: "ARTISTS")
    static let setupLibraryLayoutFooter = String(localized: "setup_library_layout_footer", defaultValue: "You can change this later in Settings > Appearance > Library Navigation.")

    static let setupSpotifyTitle = String(localized: "setup_spotify_title", defaultValue: "Spotify users, listen up!")
    static let setupSpotifyDescription = String(localized: "setup_spotify_description", defaultValue: "Please sign in with Spotify right here. Your liked songs and playlists come straight into PixlAudio.")
    static let setupSpotifyButton = String(localized: "setup_spotify_button", defaultValue: "Sign in with Spotify")
    static let setupSpotifyConnected = String(localized: "setup_spotify_connected", defaultValue: "Spotify connected")
    static let setupSpotifyReachOut = String(localized: "setup_spotify_reach_out", defaultValue: "Once you're signed in, reach out to me with your Name and Email!")
    static let setupSpotifyArrowHint = String(localized: "setup_spotify_arrow_hint", defaultValue: "Tap the button below")
    static let setupSpotifyCdArrow = String(localized: "setup_spotify_cd_arrow", defaultValue: "Arrow pointing at the sign-in button")

    static let setupAllSetTitle = String(localized: "setup_all_set_title", defaultValue: "All Set!")
    static let setupAllSetBody = String(localized: "setup_all_set_body", defaultValue: "You're ready to enjoy your music.")

    static let commonNext = String(localized: "common_next", defaultValue: "Next")
    static let commonFinish = String(localized: "common_finish", defaultValue: "Finish")
}
