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

    // Stage 7d (settings screens) — appended, Android names and types.
    static let disableBlurAllOver = "disable_blur_all_over"
    static let navBarStyle = "nav_bar_style"
    static let navBarCompactMode = "nav_bar_compact_mode"
    static let folderBackGestureNavigationKey = "folder_back_gesture_navigation"
    static let lyricsSourcePreferenceKey = "lyrics_source_preference"
    static let backupInfoDismissed = "backup_info_dismissed"
    static let advancedPerformanceDiagnosticsStartedAt = "advanced_performance_diagnostics_started_at_epoch_ms"
    static let advancedPerformanceDiagnosticsExpiresAt = "advanced_performance_diagnostics_expires_at_epoch_ms"
    static let bassBoostDismissed = "bass_boost_dismissed"
    static let virtualizerDismissed = "virtualizer_dismissed"
    static let loudnessDismissed = "loudness_dismissed"
    static let aiPresencePenalty = "ai_presence_penalty"
    static let aiFrequencyPenalty = "ai_frequency_penalty"
    static let aiSampleSize = "ai_sample_size"
    static let aiDigestMode = "ai_digest_mode"
    static let aiIncludeExtendedFields = "ai_include_extended_fields"
    /// Per-provider AI keys (Android `AiPreferencesRepository.Keys.get…`): `<provider lowercased>_model` etc.
    /// API keys themselves live in the Keychain under `<provider lowercased>_api_key`.
    static func aiModel(_ providerName: String) -> String { "\(providerName.lowercased())_model" }
    static func aiSystemPrompt(_ providerName: String) -> String { "\(providerName.lowercased())_system_prompt" }
    static func aiBaseUrl(_ providerName: String) -> String { "\(providerName.lowercased())_base_url" }
    static func aiApiKeyAccount(_ providerName: String) -> String { "\(providerName.lowercased())_api_key" }
    static let fullPlayerDelayAlbum = "full_player_delay_album"
    static let fullPlayerDelayMetadata = "full_player_delay_metadata"
    static let fullPlayerDelayProgress = "full_player_delay_progress"
    static let fullPlayerDelayControls = "full_player_delay_controls"
    static let fullPlayerPlaceholders = "full_player_placeholders"
    static let fullPlayerPlaceholderTransparent = "full_player_placeholder_transparent"
    static let fullPlayerPlaceholdersOnClose = "full_player_placeholders_on_close"
    static let fullPlayerSwitchOnDragRelease = "full_player_switch_on_drag_release"
    static let fullPlayerDelayThreshold = "full_player_delay_threshold_percent"
    static let fullPlayerCloseThreshold = "full_player_close_threshold_percent"
    static let taisRoformerBaseUrl = "tais_roformer_base_url"
    static let taisRoformerApiName = "tais_roformer_api_name"
    static let taisRoformerApiKey = "tais_roformer_api_key"
    static let taisRoformerExtraArg = "tais_roformer_extra_arg"
    static let taisRoformerBackendType = "tais_roformer_backend_type"
    /// Android `MusicTasteRepository` (its own DataStore): learning, discovery, exploration fraction.
    static let musicLearningEnabled = "learning_enabled"
    static let musicDiscoveryEnabled = "discovery_enabled"
    static let musicExplorationFraction = "exploration_fraction"
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
    /// Stage 7d: AI settings (Android `AiPreferencesRepository`).
    let ai: AISettings
    /// Stage 7d: Developer › Experimental (full-player loading tweaks, TAIS tools) and diagnostics.
    let experimental: ExperimentalSettings

    init(defaults: UserDefaults = .standard) {
        appearance = AppearanceSettings(defaults: defaults)
        behavior = BehaviorSettings(defaults: defaults)
        playback = PlaybackSettings(defaults: defaults)
        library = LibrarySettings(defaults: defaults)
        lyrics = LyricsSettings(defaults: defaults)
        equalizer = EqualizerPreferences(defaults: defaults)
        ai = AISettings(defaults: defaults)
        experimental = ExperimentalSettings(defaults: defaults)
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
    var disableBlurAllOver: Bool {
        didSet { defaults.set(disableBlurAllOver, forKey: PreferenceKeys.disableBlurAllOver) }
    }
    /// Android `CarouselStyle` (`no_peek` default, `one_peek`, `two_peek`).
    var carouselStyle: String { didSet { defaults.set(carouselStyle, forKey: PreferenceKeys.carouselStyle) } }
    /// Android `NavBarStyle` (`default`, `full_width`).
    var navBarStyle: String { didSet { defaults.set(navBarStyle, forKey: PreferenceKeys.navBarStyle) } }
    var navBarCompactMode: Bool { didSet { defaults.set(navBarCompactMode, forKey: PreferenceKeys.navBarCompactMode) } }
    /// Android `CollagePattern.storageKey` (`cosmic_swirl` default).
    var collagePattern: String { didSet { defaults.set(collagePattern, forKey: PreferenceKeys.collagePattern) } }
    var collageAutoRotate: Bool { didSet { defaults.set(collageAutoRotate, forKey: PreferenceKeys.collageAutoRotate) } }
    /// Android `LibraryNavigationMode` (`tab_row` default, `compact_pill`).
    var libraryNavigationMode: String {
        didSet { defaults.set(libraryNavigationMode, forKey: PreferenceKeys.libraryNavigationMode) }
    }
    var fullPlayerShowFileInfo: Bool {
        didSet { defaults.set(fullPlayerShowFileInfo, forKey: PreferenceKeys.fullPlayerShowFileInfo) }
    }
    /// Android `AlbumArtQuality.name` (`MEDIUM` default).
    var albumArtQuality: String {
        didSet {
            defaults.set(albumArtQuality, forKey: PreferenceKeys.albumArtQuality)
            ArtworkPipeline.applyAlbumArtQuality(albumArtQuality)
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        disableBlurAllOver = defaults.bool(PreferenceKeys.disableBlurAllOver, default: false)
        carouselStyle = defaults.string(PreferenceKeys.carouselStyle, default: "no_peek")
        navBarStyle = defaults.string(PreferenceKeys.navBarStyle, default: "default")
        navBarCompactMode = defaults.bool(PreferenceKeys.navBarCompactMode, default: false)
        collagePattern = defaults.string(PreferenceKeys.collagePattern, default: "cosmic_swirl")
        collageAutoRotate = defaults.bool(PreferenceKeys.collageAutoRotate, default: false)
        libraryNavigationMode = defaults.string(PreferenceKeys.libraryNavigationMode, default: "tab_row")
        fullPlayerShowFileInfo = defaults.bool(PreferenceKeys.fullPlayerShowFileInfo, default: true)
        albumArtQuality = defaults.string(PreferenceKeys.albumArtQuality, default: "MEDIUM")
        ArtworkPipeline.applyAlbumArtQuality(albumArtQuality)
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

    var hapticsEnabled: Bool {
        didSet {
            defaults.set(hapticsEnabled, forKey: PreferenceKeys.hapticsEnabled)
            HapticsPreference.isEnabled = hapticsEnabled
        }
    }
    var tapBackgroundClosesPlayer: Bool {
        didSet { defaults.set(tapBackgroundClosesPlayer, forKey: PreferenceKeys.tapBackgroundClosesPlayer) }
    }
    /// Android `LaunchTab` (`"Home"` default).
    var launchTab: RootTab { didSet { defaults.set(launchTab.launchTabKey, forKey: PreferenceKeys.launchTab) } }
    var initialSetupDone: Bool { didSet { defaults.set(initialSetupDone, forKey: PreferenceKeys.initialSetupDone) } }
    var folderBackGestureNavigation: Bool {
        didSet { defaults.set(folderBackGestureNavigation, forKey: PreferenceKeys.folderBackGestureNavigationKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        folderBackGestureNavigation = defaults.bool(PreferenceKeys.folderBackGestureNavigationKey, default: true)
        hapticsEnabled = defaults.bool(PreferenceKeys.hapticsEnabled, default: true)
        HapticsPreference.isEnabled = hapticsEnabled
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
    var hiFiModeEnabled: Bool { didSet { defaults.set(hiFiModeEnabled, forKey: PreferenceKeys.hiFiModeEnabled) } }
    /// Android `AudioQuality.name` (`ULTRASOUND` default = no bitrate cap).
    var audioQuality: String { didSet { defaults.set(audioQuality, forKey: PreferenceKeys.audioQuality) } }
    /// Android `PlayerAmbientStyle.name` (`BLENDED_COVER` default).
    var playerAmbientStyle: String {
        didSet { defaults.set(playerAmbientStyle, forKey: PreferenceKeys.playerAmbientStyle) }
    }
    /// Stage 7d: Android `global_transition_settings_json` (TransitionSettings JSON; its duration comes from
    /// `crossfade_duration`, clamped to 1…12 s — Android `globalTransitionSettingsFlow`).
    var globalTransitionSettingsJSON: String? {
        didSet { defaults.set(globalTransitionSettingsJSON, forKey: PreferenceKeys.globalTransitionSettings) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        globalTransitionSettingsJSON = defaults.string(forKey: PreferenceKeys.globalTransitionSettings)
        hiFiModeEnabled = defaults.bool(PreferenceKeys.hiFiModeEnabled, default: false)
        audioQuality = defaults.string(PreferenceKeys.audioQuality, default: "ULTRASOUND")
        playerAmbientStyle = defaults.string(PreferenceKeys.playerAmbientStyle, default: "BLENDED_COVER")
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
    /// Android `album_art_cache_limit_mb` (default 200, 50…1500).
    var albumArtCacheLimitMb: Int {
        didSet {
            defaults.set(albumArtCacheLimitMb, forKey: PreferenceKeys.albumArtCacheLimitMb)
            let limit = Int64(albumArtCacheLimitMb) * 1_048_576
            Task.detached(priority: .background) { ArtworkPipeline.trimDiskCache(limitBytes: limit) }
        }
    }
    /// Character delimiters, stored as Android does: a JSON string array (`json.encodeToString`).
    var artistDelimiters: [String] {
        didSet { defaults.set(Self.encodeJSON(artistDelimiters), forKey: PreferenceKeys.artistDelimiters) }
    }
    var artistWordDelimiters: [String] {
        didSet { defaults.set(Self.encodeJSON(artistWordDelimiters), forKey: PreferenceKeys.artistWordDelimiters) }
    }
    var artistSettingsRescanRequired: Bool {
        didSet { defaults.set(artistSettingsRescanRequired, forKey: PreferenceKeys.artistSettingsRescanRequired) }
    }
    /// Android `allowed_directories` / `blocked_directories` (string sets) as library paths `/<folder>/<sub>`.
    var allowedDirectories: [String] {
        didSet { defaults.set(allowedDirectories, forKey: PreferenceKeys.allowedDirectories) }
    }
    var blockedDirectories: [String] {
        didSet { defaults.set(blockedDirectories, forKey: PreferenceKeys.blockedDirectories) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        albumArtCacheLimitMb = defaults.int(PreferenceKeys.albumArtCacheLimitMb, default: 200)
        artistDelimiters = ArtistParsing.normalizeLegacyDefaultArtistDelimiters(
            Self.stringList(defaults, PreferenceKeys.artistDelimiters) ?? ArtistParsing.defaultArtistDelimiters)
        artistWordDelimiters = Self.stringList(defaults, PreferenceKeys.artistWordDelimiters)
            ?? ArtistParsing.defaultWordDelimiters
        artistSettingsRescanRequired = defaults.bool(PreferenceKeys.artistSettingsRescanRequired, default: false)
        allowedDirectories = Self.stringList(defaults, PreferenceKeys.allowedDirectories) ?? []
        blockedDirectories = Self.stringList(defaults, PreferenceKeys.blockedDirectories) ?? []
        minSongDurationMs = defaults.int(PreferenceKeys.minSongDurationMs, default: 10_000)
        minTracksPerAlbum = defaults.int(PreferenceKeys.minTracksPerAlbum, default: 1)
        extractArtistsFromTitle = defaults.bool(PreferenceKeys.extractArtistsFromTitle, default: true)
        groupByAlbumArtist = defaults.bool(PreferenceKeys.groupByAlbumArtist, default: false)
        lastLibraryTabIndex = defaults.int(PreferenceKeys.lastLibraryTabIndex, default: 0)
        isAlbumsListView = defaults.bool(PreferenceKeys.isAlbumsListView, default: false)
        isGenreGridView = defaults.bool(PreferenceKeys.isGenreGridView, default: true)
        hideLocalMedia = defaults.bool(PreferenceKeys.hideLocalMedia, default: false)
    }

    /// A `[String]`, or a JSON array encoded as a string (Android's DataStore format, also after a backup restore).
    nonisolated static func stringList(_ defaults: UserDefaults, _ key: String) -> [String]? {
        if let array = defaults.stringArray(forKey: key) { return array }
        if let json = defaults.string(forKey: key), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            return decoded
        }
        return nil
    }

    nonisolated static func encodeJSON(_ list: [String]) -> String {
        (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
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
    /// Android `LyricsSourcePreference.name` (`EMBEDDED_FIRST` default, `API_FIRST`, `LOCAL_FIRST`).
    var sourcePreference: String {
        didSet { defaults.set(sourcePreference, forKey: PreferenceKeys.lyricsSourcePreferenceKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        sourcePreference = defaults.string(PreferenceKeys.lyricsSourcePreferenceKey, default: "EMBEDDED_FIRST")
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
    /// The "custom" band levels (Android `equalizer_custom_bands`, a JSON int list).
    var customBands: [Int] {
        didSet { defaults.set(Self.encodeInts(customBands), forKey: PreferenceKeys.equalizerCustomBands) }
    }
    var loudnessEnhancerEnabled: Bool {
        didSet { defaults.set(loudnessEnhancerEnabled, forKey: PreferenceKeys.loudnessEnhancerEnabled) }
    }
    var loudnessEnhancerStrength: Int {
        didSet { defaults.set(loudnessEnhancerStrength, forKey: PreferenceKeys.loudnessEnhancerStrength) }
    }
    var bassBoostDismissed: Bool { didSet { defaults.set(bassBoostDismissed, forKey: PreferenceKeys.bassBoostDismissed) } }
    var virtualizerDismissed: Bool {
        didSet { defaults.set(virtualizerDismissed, forKey: PreferenceKeys.virtualizerDismissed) }
    }
    var loudnessDismissed: Bool { didSet { defaults.set(loudnessDismissed, forKey: PreferenceKeys.loudnessDismissed) } }
    /// Android `EqualizerViewMode.name` (`SLIDERS` default, `GRAPH`, `HYBRID`).
    var viewMode: String { didSet { defaults.set(viewMode, forKey: PreferenceKeys.equalizerViewMode) } }
    /// Android `custom_presets_json` (a JSON list of `EqualizerPreset`), kept raw; the equalizer screen decodes it.
    var customPresetsJSON: String? { didSet { defaults.set(customPresetsJSON, forKey: PreferenceKeys.customPresets) } }
    /// Android `pinned_presets_json` (a JSON list of preset names); nil = every built-in preset.
    var pinnedPresetsJSON: String? { didSet { defaults.set(pinnedPresetsJSON, forKey: PreferenceKeys.pinnedPresets) } }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        customBands = Self.decodeInts(defaults.string(forKey: PreferenceKeys.equalizerCustomBands))
        loudnessEnhancerEnabled = defaults.bool(PreferenceKeys.loudnessEnhancerEnabled, default: false)
        loudnessEnhancerStrength = min(max(defaults.int(PreferenceKeys.loudnessEnhancerStrength, default: 0), 0), 1000)
        bassBoostDismissed = defaults.bool(PreferenceKeys.bassBoostDismissed, default: false)
        virtualizerDismissed = defaults.bool(PreferenceKeys.virtualizerDismissed, default: false)
        loudnessDismissed = defaults.bool(PreferenceKeys.loudnessDismissed, default: false)
        viewMode = defaults.string(PreferenceKeys.equalizerViewMode, default: "SLIDERS")
        customPresetsJSON = defaults.string(forKey: PreferenceKeys.customPresets)
        pinnedPresetsJSON = defaults.string(forKey: PreferenceKeys.pinnedPresets)
        isEnabled = defaults.bool(PreferenceKeys.equalizerEnabled, default: false)
        presetName = defaults.string(PreferenceKeys.equalizerPreset, default: "flat")
        bassBoostEnabled = defaults.bool(PreferenceKeys.bassBoostEnabled, default: false)
        bassBoostStrength = defaults.int(PreferenceKeys.bassBoostStrength, default: 0)
        virtualizerEnabled = defaults.bool(PreferenceKeys.virtualizerEnabled, default: false)
        virtualizerStrength = defaults.int(PreferenceKeys.virtualizerStrength, default: 0)
    }
}

// MARK: - Stage 7d helpers and categories

extension EqualizerPreferences {
    /// Android `setEqualizerCustomBands` normalises to 10 levels clamped to −15…15.
    nonisolated static func encodeInts(_ bands: [Int]) -> String {
        let normalized = (0..<10).map { i in i < bands.count ? min(max(bands[i], -15), 15) : 0 }
        return "[" + normalized.map(String.init).joined(separator: ",") + "]"
    }

    nonisolated static func decodeInts(_ json: String?) -> [Int] {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Int].self, from: data), decoded.count == 10 else {
            return Array(repeating: 0, count: 10)
        }
        return decoded
    }
}

/// Android `AiPreferencesRepository`: provider, safety limit, generation parameters and per-provider model, prompt
/// and base URL (API keys go to the Keychain). Defaults are Android's.
@Observable
final class AISettings {
    private let defaults: UserDefaults

    /// `AiProvider.name` (`GEMINI` default).
    var provider: String { didSet { defaults.set(provider, forKey: PreferenceKeys.aiProvider) } }
    var safeTokenLimit: Bool { didSet { defaults.set(safeTokenLimit, forKey: PreferenceKeys.safeTokenLimit) } }
    var temperature: Double { didSet { defaults.set(temperature, forKey: PreferenceKeys.aiTemperature) } }
    var topP: Double { didSet { defaults.set(topP, forKey: PreferenceKeys.aiTopP) } }
    var topK: Int { didSet { defaults.set(topK, forKey: PreferenceKeys.aiTopK) } }
    var maxTokens: Int { didSet { defaults.set(maxTokens, forKey: PreferenceKeys.aiMaxTokens) } }
    var presencePenalty: Double { didSet { defaults.set(presencePenalty, forKey: PreferenceKeys.aiPresencePenalty) } }
    var frequencyPenalty: Double { didSet { defaults.set(frequencyPenalty, forKey: PreferenceKeys.aiFrequencyPenalty) } }
    var sampleSize: Int { didSet { defaults.set(sampleSize, forKey: PreferenceKeys.aiSampleSize) } }
    /// `safe` (default) or `full`.
    var digestMode: String { didSet { defaults.set(digestMode, forKey: PreferenceKeys.aiDigestMode) } }
    var includeExtendedFields: Bool {
        didSet { defaults.set(includeExtendedFields, forKey: PreferenceKeys.aiIncludeExtendedFields) }
    }
    var musicLearningEnabled: Bool {
        didSet { defaults.set(musicLearningEnabled, forKey: PreferenceKeys.musicLearningEnabled) }
    }
    var musicDiscoveryEnabled: Bool {
        didSet { defaults.set(musicDiscoveryEnabled, forKey: PreferenceKeys.musicDiscoveryEnabled) }
    }
    /// 0…0.6 (Android `exploration_fraction`).
    var musicExploration: Double {
        didSet { defaults.set(musicExploration, forKey: PreferenceKeys.musicExplorationFraction) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        provider = defaults.string(PreferenceKeys.aiProvider, default: "GEMINI")
        safeTokenLimit = defaults.bool(PreferenceKeys.safeTokenLimit, default: true)
        temperature = defaults.double(PreferenceKeys.aiTemperature, default: 0.7)
        topP = defaults.double(PreferenceKeys.aiTopP, default: 0.95)
        topK = defaults.int(PreferenceKeys.aiTopK, default: 64)
        maxTokens = defaults.int(PreferenceKeys.aiMaxTokens, default: 4096)
        presencePenalty = defaults.double(PreferenceKeys.aiPresencePenalty, default: 0)
        frequencyPenalty = defaults.double(PreferenceKeys.aiFrequencyPenalty, default: 0)
        sampleSize = defaults.int(PreferenceKeys.aiSampleSize, default: 40)
        digestMode = defaults.string(PreferenceKeys.aiDigestMode, default: "safe")
        includeExtendedFields = defaults.bool(PreferenceKeys.aiIncludeExtendedFields, default: false)
        musicLearningEnabled = defaults.bool(PreferenceKeys.musicLearningEnabled, default: true)
        musicDiscoveryEnabled = defaults.bool(PreferenceKeys.musicDiscoveryEnabled, default: true)
        musicExploration = defaults.double(PreferenceKeys.musicExplorationFraction, default: 0.25)
    }

    func model(for providerName: String) -> String { defaults.string(PreferenceKeys.aiModel(providerName), default: "") }

    func setModel(_ model: String, for providerName: String) {
        defaults.set(model, forKey: PreferenceKeys.aiModel(providerName))
    }

    /// nil = the default prompt (Android falls back to `DEFAULT_SYSTEM_PROMPT`).
    func systemPrompt(for providerName: String) -> String? {
        defaults.string(forKey: PreferenceKeys.aiSystemPrompt(providerName))
    }

    func setSystemPrompt(_ prompt: String?, for providerName: String) {
        defaults.set(prompt, forKey: PreferenceKeys.aiSystemPrompt(providerName))
    }

    func baseUrl(for providerName: String) -> String { defaults.string(PreferenceKeys.aiBaseUrl(providerName), default: "") }

    func setBaseUrl(_ url: String, for providerName: String) {
        defaults.set(url, forKey: PreferenceKeys.aiBaseUrl(providerName))
    }
}

/// Developer › Experimental (Android `FullPlayerLoadingTweaks`, TAIS tools) plus the diagnostics session and the
/// backup notice. Defaults are Android's.
@Observable
final class ExperimentalSettings {
    private let defaults: UserDefaults

    var delayAlbumCarousel: Bool { didSet { defaults.set(delayAlbumCarousel, forKey: PreferenceKeys.fullPlayerDelayAlbum) } }
    var delaySongMetadata: Bool { didSet { defaults.set(delaySongMetadata, forKey: PreferenceKeys.fullPlayerDelayMetadata) } }
    var delayProgressBar: Bool { didSet { defaults.set(delayProgressBar, forKey: PreferenceKeys.fullPlayerDelayProgress) } }
    var delayControls: Bool { didSet { defaults.set(delayControls, forKey: PreferenceKeys.fullPlayerDelayControls) } }
    var showPlaceholders: Bool { didSet { defaults.set(showPlaceholders, forKey: PreferenceKeys.fullPlayerPlaceholders) } }
    var transparentPlaceholders: Bool {
        didSet { defaults.set(transparentPlaceholders, forKey: PreferenceKeys.fullPlayerPlaceholderTransparent) }
    }
    var applyPlaceholdersOnClose: Bool {
        didSet { defaults.set(applyPlaceholdersOnClose, forKey: PreferenceKeys.fullPlayerPlaceholdersOnClose) }
    }
    var switchOnDragRelease: Bool {
        didSet { defaults.set(switchOnDragRelease, forKey: PreferenceKeys.fullPlayerSwitchOnDragRelease) }
    }
    var appearThresholdPercent: Int {
        didSet { defaults.set(appearThresholdPercent, forKey: PreferenceKeys.fullPlayerDelayThreshold) }
    }
    var closeThresholdPercent: Int {
        didSet { defaults.set(closeThresholdPercent, forKey: PreferenceKeys.fullPlayerCloseThreshold) }
    }
    /// 0…1 (Android `tais_vocal_attenuation`).
    var vocalAttenuation: Double { didSet { defaults.set(vocalAttenuation, forKey: PreferenceKeys.taisVocalAttenuation) } }
    var roformerBaseUrl: String { didSet { defaults.set(roformerBaseUrl, forKey: PreferenceKeys.taisRoformerBaseUrl) } }
    var roformerApiName: String { didSet { defaults.set(roformerApiName, forKey: PreferenceKeys.taisRoformerApiName) } }
    /// The BS-RoFormer backend's API key: a secret, so it lives in the Keychain (account `tais_roformer_api_key`),
    /// like the AI providers' keys. It is read on first use (`loadSecretsIfNeeded`), not at launch. Stores on another
    /// defaults suite (tests, UI tests) keep it in that suite instead.
    var roformerApiKey: String {
        didSet {
            guard !isLoadingSecrets else { return }
            if usesKeychain {
                _ = SettingsBackup.setKeychainString(PreferenceKeys.taisRoformerApiKey, roformerApiKey)
            } else {
                defaults.set(roformerApiKey, forKey: PreferenceKeys.taisRoformerApiKey)
            }
        }
    }
    /// Secrets go to the Keychain only for the app's own settings (`UserDefaults.standard`).
    let usesKeychain: Bool
    @ObservationIgnored private var secretsLoaded = false
    @ObservationIgnored private var isLoadingSecrets = false
    var roformerExtraArg: String { didSet { defaults.set(roformerExtraArg, forKey: PreferenceKeys.taisRoformerExtraArg) } }
    /// `GRADIO_SPACE` (default) or `DIRECT_POST`.
    var roformerBackendType: String {
        didSet { defaults.set(roformerBackendType, forKey: PreferenceKeys.taisRoformerBackendType) }
    }
    var backupInfoDismissed: Bool { didSet { defaults.set(backupInfoDismissed, forKey: PreferenceKeys.backupInfoDismissed) } }
    private(set) var advancedDiagnosticsEnabled: Bool
    private(set) var advancedDiagnosticsExpiresAtMs: Int64?

    /// Android `delayAll` = every part delayed.
    var delayAll: Bool { delayAlbumCarousel && delaySongMetadata && delayProgressBar && delayControls }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        delayAlbumCarousel = defaults.bool(PreferenceKeys.fullPlayerDelayAlbum, default: true)
        delaySongMetadata = defaults.bool(PreferenceKeys.fullPlayerDelayMetadata, default: true)
        delayProgressBar = defaults.bool(PreferenceKeys.fullPlayerDelayProgress, default: true)
        delayControls = defaults.bool(PreferenceKeys.fullPlayerDelayControls, default: true)
        showPlaceholders = defaults.bool(PreferenceKeys.fullPlayerPlaceholders, default: true)
        transparentPlaceholders = defaults.bool(PreferenceKeys.fullPlayerPlaceholderTransparent, default: false)
        applyPlaceholdersOnClose = defaults.bool(PreferenceKeys.fullPlayerPlaceholdersOnClose, default: false)
        switchOnDragRelease = defaults.bool(PreferenceKeys.fullPlayerSwitchOnDragRelease, default: true)
        appearThresholdPercent = defaults.int(PreferenceKeys.fullPlayerDelayThreshold, default: 98)
        closeThresholdPercent = defaults.int(PreferenceKeys.fullPlayerCloseThreshold, default: 0)
        vocalAttenuation = min(max(defaults.double(PreferenceKeys.taisVocalAttenuation, default: 0), 0), 1)
        roformerBaseUrl = defaults.string(PreferenceKeys.taisRoformerBaseUrl, default: "")
        roformerApiName = defaults.string(PreferenceKeys.taisRoformerApiName, default: "")
        usesKeychain = defaults === UserDefaults.standard
        roformerApiKey = usesKeychain ? "" : defaults.string(PreferenceKeys.taisRoformerApiKey, default: "")
        roformerExtraArg = defaults.string(PreferenceKeys.taisRoformerExtraArg, default: "")
        roformerBackendType = defaults.string(PreferenceKeys.taisRoformerBackendType, default: "GRADIO_SPACE")
        backupInfoDismissed = defaults.bool(PreferenceKeys.backupInfoDismissed, default: false)
        advancedDiagnosticsEnabled = defaults.bool(PreferenceKeys.advancedPerformanceDiagnosticsEnabled, default: false)
        advancedDiagnosticsExpiresAtMs = (defaults.object(forKey: PreferenceKeys.advancedPerformanceDiagnosticsExpiresAt)
            as? NSNumber)?.int64Value
    }

    /// Reads the Keychain secrets once (the Experimental screen and the BS-RoFormer job call it before using the
    /// key). A key an older build left in `UserDefaults` moves into the Keychain here.
    func loadSecretsIfNeeded() {
        guard usesKeychain, !secretsLoaded else { return }
        secretsLoaded = true
        let account = PreferenceKeys.taisRoformerApiKey
        var key = SettingsBackup.keychainString(account) ?? ""
        if let legacy = defaults.string(forKey: account) {
            if key.isEmpty, !legacy.isEmpty, SettingsBackup.setKeychainString(account, legacy) { key = legacy }
            defaults.removeObject(forKey: account)
        }
        isLoadingSecrets = true
        roformerApiKey = key
        isLoadingSecrets = false
    }

    /// After a settings restore: the Keychain may hold a new key.
    func reloadSecrets() {
        secretsLoaded = false
        loadSecretsIfNeeded()
    }

    /// Android `setDelayAllFullPlayerContent`.
    func setDelayAll(_ enabled: Bool) {
        delayAlbumCarousel = enabled
        delaySongMetadata = enabled
        delayProgressBar = enabled
        delayControls = enabled
    }

    /// Android `setAdvancedPerformanceDiagnosticsEnabled`: a 24-hour session.
    func setAdvancedDiagnostics(_ enabled: Bool, nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        advancedDiagnosticsEnabled = enabled
        defaults.set(enabled, forKey: PreferenceKeys.advancedPerformanceDiagnosticsEnabled)
        if enabled {
            let expires = nowMs + 24 * 60 * 60 * 1000
            advancedDiagnosticsExpiresAtMs = expires
            defaults.set(nowMs, forKey: PreferenceKeys.advancedPerformanceDiagnosticsStartedAt)
            defaults.set(expires, forKey: PreferenceKeys.advancedPerformanceDiagnosticsExpiresAt)
        } else {
            advancedDiagnosticsExpiresAtMs = nil
            defaults.removeObject(forKey: PreferenceKeys.advancedPerformanceDiagnosticsStartedAt)
            defaults.removeObject(forKey: PreferenceKeys.advancedPerformanceDiagnosticsExpiresAt)
        }
    }
}
