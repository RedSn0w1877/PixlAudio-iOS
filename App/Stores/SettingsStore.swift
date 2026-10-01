import Foundation
import Observation
import PixlLibrary

/// Android preference keys (`data/preferences/UserPreferencesRepository.kt` `PreferencesKeys`,
/// `ThemePreferencesRepository`, `EqualizerPreferencesRepository`, `AiPreferencesRepository`). The iOS app stores
/// the same keys in `UserDefaults` so an Android backup's preferences restore by name (PixlBackup
/// `PreferencesModule`). Add new keys here, never inline.
nonisolated enum PreferenceKeys {
    // Theme / appearance
    static let appThemeMode = "app_theme_mode"
    static let playerThemePreference = "player_theme_preference_v2"
    static let albumArtPaletteStyle = "album_art_palette_style_v1"
    static let albumArtColorAccuracy = "album_art_color_accuracy_v1"
    static let showScrollbar = "show_scrollbar"
    static let carouselStyle = "carousel_style"
    static let playerAmbientStyle = "player_ambient_style"
    static let albumArtQuality = "album_art_quality"
    static let albumArtCacheLimitMb = "album_art_cache_limit_mb"
    static let collagePattern = "collage_pattern"
    static let collageAutoRotate = "collage_auto_rotate"
    // Behaviour
    static let hapticsEnabled = "haptics_enabled"
    static let tapBackgroundClosesPlayer = "tap_background_closes_player"
    static let launchTab = "launch_tab"
    static let initialSetupDone = "initial_setup_done"
    static let appRebrandDialogShown = "app_rebrand_dialog_shown"
    // Playback
    static let keepPlayingInBackground = "keep_playing_in_background"
    static let isCrossfadeEnabled = "is_crossfade_enabled"
    static let crossfadeDuration = "crossfade_duration"
    static let globalTransitionSettings = "global_transition_settings_json"
    static let repeatMode = "repeat_mode"
    static let isShuffleOn = "is_shuffle_on"
    static let persistentShuffleEnabled = "persistent_shuffle_enabled"
    static let resumeOnHeadsetReconnect = "resume_on_headset_reconnect"
    static let showQueueHistory = "show_queue_history"
    static let playbackQueueSnapshot = "playback_queue_snapshot_v1"
    static let replayGainEnabled = "replaygain_enabled"
    static let replayGainUseAlbumGain = "replaygain_use_album_gain"
    static let pauseOnVolumeZero = "pause_on_volume_zero"
    static let audioQuality = "audio_quality"
    static let hiFiModeEnabled = "hi_fi_mode_enabled"
    static let automaticInstrumentals = "automatic_instrumentals"
    static let taisVocalAttenuation = "tais_vocal_attenuation"
    // Full player
    static let fullPlayerShowFileInfo = "full_player_show_file_info"
    // Library
    static let allowedDirectories = "allowed_directories"
    static let blockedDirectories = "blocked_directories"
    static let minSongDurationMs = "min_song_duration_ms"
    static let minTracksPerAlbum = "min_tracks_per_album"
    static let artistDelimiters = "artist_delimiters"
    static let artistWordDelimiters = "artist_word_delimiters"
    static let extractArtistsFromTitle = "extract_artists_from_title"
    static let groupByAlbumArtist = "group_by_album_artist"
    static let artistSettingsRescanRequired = "artist_settings_rescan_required"
    static let songsSortOption = "songs_sort_option"
    static let albumsSortOption = "albums_sort_option"
    static let artistsSortOption = "artists_sort_option"
    static let playlistsSortOption = "playlists_sort_option"
    static let foldersSortOption = "folders_sort_option"
    static let likedSongsSortOption = "liked_songs_sort_option"
    static let lastLibraryTabIndex = "last_library_tab_index"
    static let libraryTabsOrder = "library_tabs_order"
    static let libraryNavigationMode = "library_navigation_mode"
    static let isAlbumsListView = "is_albums_list_view"
    static let isGenreGridView = "is_genre_grid_view"
    static let isFoldersPlaylistView = "is_folders_playlist_view"
    static let isFolderFilterActive = "is_folder_filter_active"
    static let hideLocalMedia = "hide_local_media"
    static let foldersSource = "folders_source"
    static let folderBackGestureNavigation = "folder_back_gesture_navigation"
    static let lastStorageFilter = "last_storage_filter"
    static let customGenres = "custom_genres"
    static let customGenreIcons = "custom_genre_icons"
    static let lastSyncTimestamp = "last_sync_timestamp"
    // Home
    static let dailyMixSongIds = "daily_mix_song_ids"
    static let yourMixSongIds = "your_mix_song_ids"
    static let lastDailyMixUpdate = "last_daily_mix_update"
    static let homeGreetingText = "home_greeting_text"
    static let homeGreetingDate = "home_greeting_date"
    // Lyrics
    static let automaticLyrics = "automatic_lyrics"
    static let lyricsSourcePreference = "lyrics_source_preference"
    static let autoScanLrcFiles = "auto_scan_lrc_files"
    static let lyricsSyncOffsets = "lyrics_sync_offsets_json"
    static let lyricsTapOffsetSpeakerMs = "lyrics_tap_offset_speaker_ms"
    static let lyricsTapOffsetBluetoothMs = "lyrics_tap_offset_bluetooth_ms"
    static let lyricsSyncDefaultSpeed = "lyrics_sync_default_speed"
    static let lyricsSyncHaptics = "lyrics_sync_haptics"
    static let lyricsSyncIntroSeenCount = "lyrics_sync_intro_seen_count"
    static let immersiveLyricsEnabled = "immersive_lyrics_enabled"
    static let immersiveLyricsTimeout = "immersive_lyrics_timeout"
    static let animatedLyricsBlurEnabled = "animated_lyrics_blur_enabled"
    static let animatedLyricsBlurStrength = "animated_lyrics_blur_strength"
    // Equalizer
    static let equalizerEnabled = "equalizer_enabled"
    static let equalizerPreset = "equalizer_preset"
    static let equalizerCustomBands = "equalizer_custom_bands"
    static let bassBoostEnabled = "bass_boost_enabled"
    static let bassBoostStrength = "bass_boost_strength"
    static let virtualizerEnabled = "virtualizer_enabled"
    static let virtualizerStrength = "virtualizer_strength"
    static let loudnessEnhancerEnabled = "loudness_enhancer_enabled"
    static let loudnessEnhancerStrength = "loudness_enhancer_strength"
    static let equalizerViewMode = "equalizer_view_mode"
    static let customPresets = "custom_presets_json"
    static let pinnedPresets = "pinned_presets_json"
    // AI
    static let aiProvider = "ai_provider"
    static let aiTemperature = "ai_temperature"
    static let aiTopP = "ai_top_p"
    static let aiTopK = "ai_top_k"
    static let aiMaxTokens = "ai_max_tokens"
    static let safeTokenLimit = "safe_token_limit"
    // Developer
    static let advancedPerformanceDiagnosticsEnabled = "advanced_performance_diagnostics_enabled"
}

/// Android `AppThemeMode`.
nonisolated enum AppThemeMode: String, Sendable, CaseIterable {
    case followSystem = "follow_system"
    case light = "light"
    case dark = "dark"
}

/// Android `ThemePreference` (`player_theme_preference_v2`): which scheme themes the player — and, for `global`,
/// the whole app. `dynamic` (Material You wallpaper colours) has no iOS source and behaves like `default`.
nonisolated enum PlayerThemePreference: String, Sendable, CaseIterable {
    case `default` = "default"
    case dynamic = "dynamic"
    case albumArt = "album_art"
    case global = "global"
}

/// Settings, one small `@Observable` object per category so a screen only observes what it shows. Values live in
/// `UserDefaults` under the Android keys, with Android's defaults. Stage 7d (settings screens) extends these.
@Observable
final class SettingsStore {
    let appearance: AppearanceSettings
    let behavior: BehaviorSettings
    let playback: PlaybackSettings
    let library: LibrarySettings
    let lyrics: LyricsSettings
    let equalizer: EqualizerPreferences

    init(defaults: UserDefaults = .standard) {
        appearance = AppearanceSettings(defaults: defaults)
        behavior = BehaviorSettings(defaults: defaults)
        playback = PlaybackSettings(defaults: defaults)
        library = LibrarySettings(defaults: defaults)
        lyrics = LyricsSettings(defaults: defaults)
        equalizer = EqualizerPreferences(defaults: defaults)
    }

    /// An isolated store for UI tests and previews (its own suite, wiped on creation).
    static func ephemeral() -> SettingsStore {
        let name = "pixlaudio.uitest"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return SettingsStore(defaults: defaults)
    }
}

// MARK: - Reading helpers (missing key → Android default)

nonisolated extension UserDefaults {
    func bool(_ key: String, default value: Bool) -> Bool { object(forKey: key) == nil ? value : bool(forKey: key) }
    func int(_ key: String, default value: Int) -> Int { object(forKey: key) == nil ? value : integer(forKey: key) }
    func double(_ key: String, default value: Double) -> Double { object(forKey: key) == nil ? value : double(forKey: key) }
    func string(_ key: String, default value: String) -> String { string(forKey: key) ?? value }
}

@Observable
final class AppearanceSettings {
    private let defaults: UserDefaults

    var appThemeMode: AppThemeMode { didSet { defaults.set(appThemeMode.rawValue, forKey: PreferenceKeys.appThemeMode) } }
    var playerTheme: PlayerThemePreference {
        didSet { defaults.set(playerTheme.rawValue, forKey: PreferenceKeys.playerThemePreference) }
    }
    var paletteStyle: ArtworkPaletteStyle {
        didSet { defaults.set(paletteStyle.storageKey, forKey: PreferenceKeys.albumArtPaletteStyle) }
    }
    var colorAccuracy: Int {
        didSet { defaults.set(ArtworkColorAccuracy.clamp(colorAccuracy), forKey: PreferenceKeys.albumArtColorAccuracy) }
    }
    var showScrollbar: Bool { didSet { defaults.set(showScrollbar, forKey: PreferenceKeys.showScrollbar) } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        appThemeMode = AppThemeMode(rawValue: defaults.string(PreferenceKeys.appThemeMode, default: "")) ?? .followSystem
        playerTheme = PlayerThemePreference(rawValue: defaults.string(PreferenceKeys.playerThemePreference, default: ""))
            ?? .albumArt
        paletteStyle = ArtworkPaletteStyle.fromStorageKey(defaults.string(forKey: PreferenceKeys.albumArtPaletteStyle))
        colorAccuracy = ArtworkColorAccuracy.clamp(defaults.int(PreferenceKeys.albumArtColorAccuracy,
                                                                default: ArtworkColorAccuracy.default))
        showScrollbar = defaults.bool(PreferenceKeys.showScrollbar, default: true)
    }
}

@Observable
final class BehaviorSettings {
    private let defaults: UserDefaults

    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: PreferenceKeys.hapticsEnabled) } }
    var tapBackgroundClosesPlayer: Bool {
        didSet { defaults.set(tapBackgroundClosesPlayer, forKey: PreferenceKeys.tapBackgroundClosesPlayer) }
    }
    /// Android `LaunchTab` (`"Home"` default).
    var launchTab: RootTab { didSet { defaults.set(launchTab.launchTabKey, forKey: PreferenceKeys.launchTab) } }
    var initialSetupDone: Bool { didSet { defaults.set(initialSetupDone, forKey: PreferenceKeys.initialSetupDone) } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        hapticsEnabled = defaults.bool(PreferenceKeys.hapticsEnabled, default: true)
        tapBackgroundClosesPlayer = defaults.bool(PreferenceKeys.tapBackgroundClosesPlayer, default: false)
        let tab = defaults.string(PreferenceKeys.launchTab, default: "Home")
        launchTab = RootTab.allCases.first { $0.launchTabKey.caseInsensitiveCompare(tab) == .orderedSame } ?? .home
        initialSetupDone = defaults.bool(PreferenceKeys.initialSetupDone, default: false)
    }
}

@Observable
final class PlaybackSettings {
    private let defaults: UserDefaults

    var keepPlayingInBackground: Bool {
        didSet { defaults.set(keepPlayingInBackground, forKey: PreferenceKeys.keepPlayingInBackground) }
    }
    var isCrossfadeEnabled: Bool { didSet { defaults.set(isCrossfadeEnabled, forKey: PreferenceKeys.isCrossfadeEnabled) } }
    /// Milliseconds (Android default 2000).
    var crossfadeDurationMs: Int { didSet { defaults.set(crossfadeDurationMs, forKey: PreferenceKeys.crossfadeDuration) } }
    var repeatMode: RepeatMode { didSet { defaults.set(repeatMode.rawValue, forKey: PreferenceKeys.repeatMode) } }
    var isShuffleOn: Bool { didSet { defaults.set(isShuffleOn, forKey: PreferenceKeys.isShuffleOn) } }
    var persistentShuffleEnabled: Bool {
        didSet { defaults.set(persistentShuffleEnabled, forKey: PreferenceKeys.persistentShuffleEnabled) }
    }
    var resumeOnHeadsetReconnect: Bool {
        didSet { defaults.set(resumeOnHeadsetReconnect, forKey: PreferenceKeys.resumeOnHeadsetReconnect) }
    }
    var showQueueHistory: Bool { didSet { defaults.set(showQueueHistory, forKey: PreferenceKeys.showQueueHistory) } }
    var replayGainEnabled: Bool { didSet { defaults.set(replayGainEnabled, forKey: PreferenceKeys.replayGainEnabled) } }
    var replayGainUseAlbumGain: Bool {
        didSet { defaults.set(replayGainUseAlbumGain, forKey: PreferenceKeys.replayGainUseAlbumGain) }
    }
    var pauseOnVolumeZero: Bool { didSet { defaults.set(pauseOnVolumeZero, forKey: PreferenceKeys.pauseOnVolumeZero) } }
    var automaticInstrumentals: Bool {
        didSet { defaults.set(automaticInstrumentals, forKey: PreferenceKeys.automaticInstrumentals) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        keepPlayingInBackground = defaults.bool(PreferenceKeys.keepPlayingInBackground, default: true)
        isCrossfadeEnabled = defaults.bool(PreferenceKeys.isCrossfadeEnabled, default: false)
        crossfadeDurationMs = defaults.int(PreferenceKeys.crossfadeDuration, default: 2000)
        repeatMode = RepeatMode(rawValue: defaults.int(PreferenceKeys.repeatMode, default: 0)) ?? .off
        isShuffleOn = defaults.bool(PreferenceKeys.isShuffleOn, default: false)
        persistentShuffleEnabled = defaults.bool(PreferenceKeys.persistentShuffleEnabled, default: false)
        resumeOnHeadsetReconnect = defaults.bool(PreferenceKeys.resumeOnHeadsetReconnect, default: false)
        showQueueHistory = defaults.bool(PreferenceKeys.showQueueHistory, default: false)
        replayGainEnabled = defaults.bool(PreferenceKeys.replayGainEnabled, default: false)
        replayGainUseAlbumGain = defaults.bool(PreferenceKeys.replayGainUseAlbumGain, default: false)
        pauseOnVolumeZero = defaults.bool(PreferenceKeys.pauseOnVolumeZero, default: false)
        automaticInstrumentals = defaults.bool(PreferenceKeys.automaticInstrumentals, default: true)
    }
}

@Observable
final class LibrarySettings {
    private let defaults: UserDefaults

    /// Milliseconds (Android default 10 000).
    var minSongDurationMs: Int { didSet { defaults.set(minSongDurationMs, forKey: PreferenceKeys.minSongDurationMs) } }
    var minTracksPerAlbum: Int { didSet { defaults.set(minTracksPerAlbum, forKey: PreferenceKeys.minTracksPerAlbum) } }
    var extractArtistsFromTitle: Bool {
        didSet { defaults.set(extractArtistsFromTitle, forKey: PreferenceKeys.extractArtistsFromTitle) }
    }
    var groupByAlbumArtist: Bool { didSet { defaults.set(groupByAlbumArtist, forKey: PreferenceKeys.groupByAlbumArtist) } }
    var lastLibraryTabIndex: Int {
        didSet { defaults.set(lastLibraryTabIndex, forKey: PreferenceKeys.lastLibraryTabIndex) }
    }
    var isAlbumsListView: Bool { didSet { defaults.set(isAlbumsListView, forKey: PreferenceKeys.isAlbumsListView) } }
    var isGenreGridView: Bool { didSet { defaults.set(isGenreGridView, forKey: PreferenceKeys.isGenreGridView) } }
    var hideLocalMedia: Bool { didSet { defaults.set(hideLocalMedia, forKey: PreferenceKeys.hideLocalMedia) } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        minSongDurationMs = defaults.int(PreferenceKeys.minSongDurationMs, default: 10_000)
        minTracksPerAlbum = defaults.int(PreferenceKeys.minTracksPerAlbum, default: 1)
        extractArtistsFromTitle = defaults.bool(PreferenceKeys.extractArtistsFromTitle, default: true)
        groupByAlbumArtist = defaults.bool(PreferenceKeys.groupByAlbumArtist, default: false)
        lastLibraryTabIndex = defaults.int(PreferenceKeys.lastLibraryTabIndex, default: 0)
        isAlbumsListView = defaults.bool(PreferenceKeys.isAlbumsListView, default: false)
        isGenreGridView = defaults.bool(PreferenceKeys.isGenreGridView, default: true)
        hideLocalMedia = defaults.bool(PreferenceKeys.hideLocalMedia, default: false)
    }
}

@Observable
final class LyricsSettings {
    private let defaults: UserDefaults

    var automaticLyrics: Bool { didSet { defaults.set(automaticLyrics, forKey: PreferenceKeys.automaticLyrics) } }
    var autoScanLrcFiles: Bool { didSet { defaults.set(autoScanLrcFiles, forKey: PreferenceKeys.autoScanLrcFiles) } }
    var immersiveLyricsEnabled: Bool {
        didSet { defaults.set(immersiveLyricsEnabled, forKey: PreferenceKeys.immersiveLyricsEnabled) }
    }
    /// Milliseconds (Android default 4000).
    var immersiveLyricsTimeoutMs: Int {
        didSet { defaults.set(immersiveLyricsTimeoutMs, forKey: PreferenceKeys.immersiveLyricsTimeout) }
    }
    var animatedBlurEnabled: Bool {
        didSet { defaults.set(animatedBlurEnabled, forKey: PreferenceKeys.animatedLyricsBlurEnabled) }
    }
    var animatedBlurStrength: Double {
        didSet { defaults.set(animatedBlurStrength, forKey: PreferenceKeys.animatedLyricsBlurStrength) }
    }
    var tapOffsetSpeakerMs: Int {
        didSet { defaults.set(tapOffsetSpeakerMs, forKey: PreferenceKeys.lyricsTapOffsetSpeakerMs) }
    }
    var tapOffsetBluetoothMs: Int {
        didSet { defaults.set(tapOffsetBluetoothMs, forKey: PreferenceKeys.lyricsTapOffsetBluetoothMs) }
    }
    var syncDefaultSpeed: Double {
        didSet { defaults.set(syncDefaultSpeed, forKey: PreferenceKeys.lyricsSyncDefaultSpeed) }
    }
    var syncHaptics: Bool { didSet { defaults.set(syncHaptics, forKey: PreferenceKeys.lyricsSyncHaptics) } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        automaticLyrics = defaults.bool(PreferenceKeys.automaticLyrics, default: true)
        autoScanLrcFiles = defaults.bool(PreferenceKeys.autoScanLrcFiles, default: false)
        immersiveLyricsEnabled = defaults.bool(PreferenceKeys.immersiveLyricsEnabled, default: false)
        immersiveLyricsTimeoutMs = defaults.int(PreferenceKeys.immersiveLyricsTimeout, default: 4000)
        animatedBlurEnabled = defaults.bool(PreferenceKeys.animatedLyricsBlurEnabled, default: true)
        animatedBlurStrength = defaults.double(PreferenceKeys.animatedLyricsBlurStrength, default: 1.2)
        tapOffsetSpeakerMs = defaults.int(PreferenceKeys.lyricsTapOffsetSpeakerMs, default: 100)
        tapOffsetBluetoothMs = defaults.int(PreferenceKeys.lyricsTapOffsetBluetoothMs, default: 180)
        syncDefaultSpeed = defaults.double(PreferenceKeys.lyricsSyncDefaultSpeed, default: 1)
        syncHaptics = defaults.bool(PreferenceKeys.lyricsSyncHaptics, default: true)
    }
}

/// Named `EqualizerPreferences` (PixlAudioCore already has an `EqualizerSettings` value type).
@Observable
final class EqualizerPreferences {
    private let defaults: UserDefaults

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: PreferenceKeys.equalizerEnabled) } }
    var presetName: String { didSet { defaults.set(presetName, forKey: PreferenceKeys.equalizerPreset) } }
    var bassBoostEnabled: Bool { didSet { defaults.set(bassBoostEnabled, forKey: PreferenceKeys.bassBoostEnabled) } }
    var bassBoostStrength: Int { didSet { defaults.set(bassBoostStrength, forKey: PreferenceKeys.bassBoostStrength) } }
    var virtualizerEnabled: Bool { didSet { defaults.set(virtualizerEnabled, forKey: PreferenceKeys.virtualizerEnabled) } }
    var virtualizerStrength: Int {
        didSet { defaults.set(virtualizerStrength, forKey: PreferenceKeys.virtualizerStrength) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isEnabled = defaults.bool(PreferenceKeys.equalizerEnabled, default: false)
        presetName = defaults.string(PreferenceKeys.equalizerPreset, default: "flat")
        bassBoostEnabled = defaults.bool(PreferenceKeys.bassBoostEnabled, default: false)
        bassBoostStrength = defaults.int(PreferenceKeys.bassBoostStrength, default: 0)
        virtualizerEnabled = defaults.bool(PreferenceKeys.virtualizerEnabled, default: false)
        virtualizerStrength = defaults.int(PreferenceKeys.virtualizerStrength, default: 0)
    }
}
