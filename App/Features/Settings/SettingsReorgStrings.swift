import Foundation

// Strings of the 2026-10-22 settings reorganisation (developer mode, the Lyrics and Sing categories, plain-English
// titles and subtitles; the Android app got the same texts). `SettingsStrings.swift` is generated from Android and never
// hand-edited, and a String Catalog value for an old key would override an edited default, so every changed text here is
// a NEW key. Nothing a person sees outside developer mode says codec, bitrate, API, token, GPU or the like.
nonisolated extension L10n {
    // MARK: Main list (title / subtitle)

    static let settingsMainAccountsSubtitle = String(localized: "settings_main_accounts_subtitle",
                                                     defaultValue: "Connect Spotify and sync your playlists")
    static let settingsMainAppearanceSubtitle = String(localized: "settings_main_appearance_subtitle",
                                                       defaultValue: "Theme, colors and layout")
    static let settingsMainPlaybackSubtitle = String(localized: "settings_main_playback_subtitle",
                                                     defaultValue: "Crossfade, sound quality and headphones")
    static let settingsMainEqualizerSubtitle = String(localized: "settings_main_equalizer_subtitle",
                                                      defaultValue: "Bass, treble and sound presets")
    static let settingsMainLyricsTitle = String(localized: "settings_main_lyrics_title", defaultValue: "Lyrics")
    static let settingsMainLyricsSubtitle = String(localized: "settings_main_lyrics_subtitle",
                                                   defaultValue: "How lyrics look while you listen")
    static let settingsMainSingTitle = String(localized: "settings_main_sing_title", defaultValue: "Sing")
    static let settingsMainSingSubtitle = String(localized: "settings_main_sing_subtitle",
                                                 defaultValue: "Make instrumentals to sing along")
    /// The `behavior` category (id and key unchanged).
    static let settingsMainBehaviorTitle = String(localized: "settings_main_behavior_title",
                                                  defaultValue: "Gestures & haptics")
    static let settingsMainBehaviorSubtitle = String(localized: "settings_main_behavior_subtitle",
                                                     defaultValue: "Swipes, taps and vibration")
    /// The `library` category (id and key unchanged).
    static let settingsMainLibraryTitle = String(localized: "settings_main_library_title",
                                                 defaultValue: "Library & storage")
    static let settingsMainLibrarySubtitle = String(localized: "settings_main_library_subtitle",
                                                    defaultValue: "Blocked artists and downloads")
    static let settingsMainAiSubtitle = String(localized: "settings_main_ai_subtitle",
                                               defaultValue: "Smart mixes that learn your taste")
    static let settingsMainBackupSubtitle = String(localized: "settings_main_backup_subtitle",
                                                   defaultValue: "Save or restore your playlists and settings")
    static let settingsMainAboutSubtitle = String(localized: "settings_main_about_subtitle",
                                                  defaultValue: "Version, updates and credits")
    static let settingsMainDeveloperModeTitle = String(localized: "settings_main_developer_mode_title",
                                                       defaultValue: "Developer mode")
    static let settingsMainDeveloperModeSubtitle = String(localized: "settings_main_developer_mode_subtitle",
                                                          defaultValue: "Show advanced settings and testing tools")
    static let settingsMainDeveloperTitle = String(localized: "settings_main_developer_title", defaultValue: "Developer")
    static let settingsMainDeveloperSubtitle = String(localized: "settings_main_developer_subtitle",
                                                      defaultValue: "Experiments and debugging tools")
    static let settingsMainDeviceCapabilitiesTitle = String(localized: "settings_main_device_capabilities_title",
                                                            defaultValue: "Device capabilities")
    static let settingsMainDeviceCapabilitiesSubtitle = String(localized: "settings_main_device_capabilities_subtitle",
                                                               defaultValue: "Audio specs, codecs and decoder info")

    // MARK: Sections

    /// The block developer mode adds at the bottom of a category.
    static let settingsSectionAdvanced = String(localized: "settings_section_advanced", defaultValue: "Advanced")
    static let settingsSectionTheme = String(localized: "settings_section_theme", defaultValue: "Theme")
    static let settingsSectionNowPlaying = String(localized: "settings_section_now_playing_v2", defaultValue: "Now playing")
    static let settingsSectionHome = String(localized: "settings_section_home", defaultValue: "Home")
    static let settingsSectionNavigation = String(localized: "settings_section_navigation", defaultValue: "Navigation")
    static let settingsSectionQueueTransitions = String(localized: "settings_section_queue_transitions_v2",
                                                        defaultValue: "Queue and transitions")
    static let settingsSectionSound = String(localized: "settings_section_sound", defaultValue: "Sound")
    static let settingsSectionHeadphonesVolume = String(localized: "settings_section_headphones_volume",
                                                        defaultValue: "Headphones and volume")
    static let settingsSectionLyricsScreen = String(localized: "settings_section_lyrics_screen_v2",
                                                    defaultValue: "Lyrics screen")
    static let settingsSectionReady = String(localized: "settings_section_ready", defaultValue: "Ready when you play")
    static let settingsSectionCloud = String(localized: "settings_section_cloud", defaultValue: "Cloud")
    static let settingsSectionFullPlayer = String(localized: "settings_section_full_player", defaultValue: "Full player")
    static let settingsSectionMiniPlayer = String(localized: "settings_section_mini_player", defaultValue: "Mini player")
    static let settingsSectionSongLists = String(localized: "settings_section_song_lists", defaultValue: "Song lists")
    static let settingsSectionBlockedArtists = String(localized: "settings_section_blocked_artists",
                                                      defaultValue: "Blocked artists")

    // MARK: Appearance

    static let settingsRowShowScrollbarSubtitle = String(localized: "settings_row_show_scrollbar_subtitle_v2",
                                                         defaultValue: "Show a scrollbar on long lists for quick scrolling")
    static let settingsRowCompactModeSubtitle = String(localized: "settings_row_compact_mode_subtitle_v2",
                                                       defaultValue: "Show only icons and make the navigation bar shorter.")
    static let settingsRowPlayerBackgroundTitle = String(localized: "settings_row_player_background_title",
                                                         defaultValue: "Player background")
    static let settingsRowAlbumArtResolutionSubtitle = String(localized: "settings_row_album_art_resolution_subtitle",
                                                              defaultValue: "Sharper art looks better and uses more memory.")

    // MARK: Playback

    static let settingsRowAudioQualityTitle = String(localized: "settings_row_audio_quality_title", defaultValue: "Audio quality")
    static let settingsRowAudioQualitySubtitle = String(localized: "settings_row_audio_quality_subtitle",
                                                        defaultValue: "Higher quality sounds better and uses more mobile data.")

    // MARK: Lyrics

    static let settingsRowLyricsBlurSubtitle = String(localized: "settings_row_lyrics_blur_subtitle",
                                                      defaultValue: "Blur the lines that aren't being sung.")

    // MARK: Sing

    static let settingsSingReadyBody = String(localized: "settings_sing_ready_body",
                                              defaultValue: "Prepare instrumentals quietly while PixlAudio is open.")
    static let settingsSingAutomaticTitle = String(localized: "settings_sing_automatic_title",
                                                   defaultValue: "Automatic instrumentals")
    static let settingsSingAutomaticSubtitle = String(localized: "settings_sing_automatic_subtitle",
                                                      defaultValue: "Makes instrumentals in the background while the app is open, one song at a time.")
    static let settingsSingManualNote = String(localized: "settings_sing_manual_note",
                                               defaultValue: "You can also make one yourself from a song's menu.")
    static let settingsSingCloudTitle = String(localized: "settings_sing_cloud_title", defaultValue: "Cloud processing")
    static let settingsSingCloudOn = String(localized: "settings_sing_cloud_on",
                                            defaultValue: "On — songs you pick are processed in the cloud")
    static let settingsSingCloudOff = String(localized: "settings_sing_cloud_off", defaultValue: "Off")
    static let settingsSingQueueTitle = String(localized: "settings_sing_queue_title", defaultValue: "Cloud queue")
    static let settingsSingQueueFallback = String(localized: "settings_sing_queue_fallback",
                                                  defaultValue: "Songs you sent to the cloud")

    // MARK: Gestures & haptics

    static let settingsRowTapBackgroundSubtitle = String(localized: "settings_row_tap_background_subtitle_v2",
                                                         defaultValue: "Tap the blurred background to close the player.")
    static let settingsGestureCoverSwipeTitle = String(localized: "settings_gesture_cover_swipe_title",
                                                       defaultValue: "Swipe the cover to change song")
    static let settingsGestureCoverSwipeSubtitle = String(localized: "settings_gesture_cover_swipe_subtitle",
                                                          defaultValue: "Swipe the cover left for the next song, right for the previous one.")
    static let settingsGestureCoverLikeTitle = String(localized: "settings_gesture_cover_like_title",
                                                      defaultValue: "Double-tap the cover to like")
    static let settingsGestureCoverLikeSubtitle = String(localized: "settings_gesture_cover_like_subtitle",
                                                         defaultValue: "Double-tap the cover to like or unlike the song.")
    static let settingsGestureCoverActionsTitle = String(localized: "settings_gesture_cover_actions_title",
                                                         defaultValue: "Long-press the cover for actions")
    static let settingsGestureActionsSubtitle = String(localized: "settings_gesture_actions_subtitle",
                                                       defaultValue: "Add to playlist, share or go to the artist.")
    static let settingsGestureMiniSkipTitle = String(localized: "settings_gesture_mini_skip_title",
                                                     defaultValue: "Swipe the mini player to skip")
    static let settingsGestureMiniSkipSubtitle = String(localized: "settings_gesture_mini_skip_subtitle",
                                                        defaultValue: "Swipe the mini player left for the next song, right for the previous one.")
    static let settingsGestureMiniUpTitle = String(localized: "settings_gesture_mini_up_title",
                                                   defaultValue: "Swipe the mini player up")
    static let settingsGestureMiniUpSubtitle = String(localized: "settings_gesture_mini_up_subtitle",
                                                      defaultValue: "Drag the mini player up to open the full player.")
    static let settingsGestureMiniActionsTitle = String(localized: "settings_gesture_mini_actions_title",
                                                        defaultValue: "Long-press the mini player for actions")
    static let settingsGestureRowTitle = String(localized: "settings_gesture_row_title", defaultValue: "Swipe a song row")
    static let settingsGestureRowSubtitle = String(localized: "settings_gesture_row_subtitle",
                                                   defaultValue: "Swipe a song right to play it next, left to add it to the queue.")
    static let settingsGestureFooter = String(localized: "settings_gesture_footer",
                                              defaultValue: "The queue keeps its own swipe and reorder gestures. With VoiceOver on, these gestures are turned off and the same actions are in each item's actions menu.")
    static let settingsMusicHapticsTitle = String(localized: "settings_music_haptics_title_v2",
                                                  defaultValue: "Vibrate with the music")
    static let settingsMusicHapticsSubtitle = String(localized: "settings_music_haptics_subtitle_v2",
                                                     defaultValue: "The phone vibrates along with the beat.")

    // MARK: Library & storage

    static let settingsBlockedArtistsNone = String(localized: "settings_blocked_artists_none", defaultValue: "No blocked artists")
    static let settingsBlockedArtistsOne = String(localized: "settings_blocked_artists_one", defaultValue: "1 blocked artist")
    static func settingsBlockedArtistsMany(_ count: Int) -> String {
        String(format: String(localized: "settings_blocked_artists_many", defaultValue: "%1$lld blocked artists"), count)
    }

    // MARK: AI features

    static let settingsAiAdvancedDisclosure = String(localized: "settings_ai_advanced_disclosure",
                                                     defaultValue: "Generation and usage")
}
