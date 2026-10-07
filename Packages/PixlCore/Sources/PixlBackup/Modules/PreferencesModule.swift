// The preference modules (global settings, QuickFill, equalizer — and the legacy playlists array): Android's
// DataStore entries (`PreferenceBackupEntry`), the value coercions of `importPreferencesFromBackup`, which keys each
// handler clears, and a catalogue of the Android keys saying which PixlAudio keeps. PixlAudio's settings store uses
// the Android key names, so a portable entry is applied as-is; Android-only and per-device keys are skipped and
// reported.

import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel

/// A typed preference value (`importPreferencesFromBackup`'s `when (entry.type)`).
public enum PreferenceValue: Sendable, Hashable {
    case string(String)
    case int(Int32)
    case long(Int64)
    case bool(Bool)
    case float(Float)
    case double(Double)
    case stringSet([String])

    /// The `type` string Android writes.
    public var typeName: String {
        switch self {
        case .string: "string"
        case .int: "int"
        case .long: "long"
        case .bool: "boolean"
        case .float: "float"
        case .double: "double"
        case .stringSet: "string_set"
        }
    }

    public var entry: (String) -> AndroidBackup.PreferenceBackupEntry {
        { key in
            switch self {
            case .string(let v): .string(key, v)
            case .int(let v): .int(key, v)
            case .long(let v): .long(key, v)
            case .bool(let v): .boolean(key, v)
            case .float(let v): .float(key, v)
            case .double(let v): .double(key, v)
            case .stringSet(let v): .stringSet(key, v)
            }
        }
    }
}

extension AndroidBackup.PreferenceBackupEntry {
    /// The value Android stores: `int` falls back to `doubleValue.toInt()` then `longValue.toInt()`, `long` to
    /// `doubleValue.toLong()` then `intValue`, `float` to `doubleValue`, `double` to `floatValue`; nil when the type
    /// is unknown or no usable field is set.
    public var resolvedValue: PreferenceValue? {
        switch type {
        case "string": return stringValue.map { .string($0) }
        case "int":
            if let v = intValue { return .int(v) }
            if let d = doubleValue { return .int(KotlinMath.toInt(d)) }
            if let l = longValue { return .int(Int32(truncatingIfNeeded: l)) }
            return nil
        case "long":
            if let v = longValue { return .long(v) }
            if let d = doubleValue { return .long(KotlinMath.toLong(d)) }
            if let i = intValue { return .long(Int64(i)) }
            return nil
        case "boolean": return booleanValue.map { .bool($0) }
        case "float":
            if let f = floatValue { return .float(f) }
            if let d = doubleValue { return .float(Float(d)) }
            return nil
        case "double":
            if let d = doubleValue { return .double(d) }
            if let f = floatValue { return .double(Double(f)) }
            return nil
        case "string_set":
            // A Kotlin Set<String> holding a null (Gson allows it) would fail inside DataStore; keep the strings.
            return stringSetValue.map { .stringSet($0.compactMap { $0 }) }
        default: return nil
        }
    }
}

/// How PixlAudio treats an Android preference key.
public enum AndroidPreferenceKind: String, Sendable, Hashable {
    /// A setting PixlAudio has with the same meaning: restored under the same key.
    case portable
    /// Android-only (Material styling, file-system paths, Android audio effects, Cast …): skipped and reported.
    case androidOnly
    /// Per-device state (caches, last-seen markers, timestamps): skipped and reported.
    case deviceState
    /// Keyed by Android song ids or drawable resource ids, which mean nothing here: skipped and reported.
    case deviceIds
}

/// The catalogue of Android preference keys (`UserPreferencesRepository`, `ThemePreferencesRepository`,
/// `EqualizerPreferencesRepository`, `AiPreferencesRepository`, the lyrics sheet and appearance prefs), plus the few
/// settings only the iOS app has (`iosOnly`), which travel in the same global-settings module.
public enum AndroidPreferenceCatalog {
    /// Settings only the iOS app has (owner requests), backed up and restored by name like the portable keys.
    /// Android's `importPreferencesFromBackup` writes every entry whatever its key, so they survive an
    /// iOS → Android → iOS round trip untouched. A backup without them (older iOS backups, Android backups) restores
    /// cleanly: the global-settings restore clears them like every portable key, so the iOS default comes back.
    /// - `accent_color_v1`: Settings › Appearance › Accent Color, a `"#RRGGBB"` string (`""` = PixlAudio's violet).
    public static let iosOnly: [String] = ["accent_color_v1"]

    /// Never exported or imported (`backupExcludedKeyNames`).
    public static let backupExcludedKeys: Set<String> = ["initial_setup_done"]

    static let portable: [String] = [
        // behaviour, library, sorting
        "automatic_lyrics", "automatic_instrumentals", "app_theme_mode", "player_theme_preference_v2",
        "songs_sort_option", "albums_sort_option", "artists_sort_option", "playlists_sort_option", "folders_sort_option",
        "liked_songs_sort_option", "last_storage_filter", "carousel_style", "library_navigation_mode", "launch_tab",
        "global_transition_settings_json", "library_tabs_order", "is_folders_playlist_view", "is_crossfade_enabled",
        "crossfade_duration", "custom_genres", "repeat_mode", "is_shuffle_on", "persistent_shuffle_enabled",
        "resume_on_headset_reconnect", "show_queue_history", "full_player_show_file_info", "artist_delimiters",
        "artist_word_delimiters", "extract_artists_from_title", "group_by_album_artist", "is_genre_grid_view",
        "is_albums_list_view", "collage_pattern", "collage_auto_rotate", "min_song_duration_ms", "min_tracks_per_album",
        "replaygain_enabled", "replaygain_use_album_gain", "pause_on_volume_zero", "show_scrollbar", "haptics_enabled",
        "tap_background_closes_player", "player_ambient_style", "audio_quality", "album_art_quality",
        "tais_vocal_attenuation", "tais_roformer_base_url", "tais_roformer_api_name", "tais_roformer_api_key",
        "tais_roformer_extra_arg", "tais_roformer_backend_type",
        // lyrics
        "lyrics_source_preference", "auto_scan_lrc_files", "lyrics_tap_offset_speaker_ms", "lyrics_tap_offset_bluetooth_ms",
        "lyrics_sync_default_speed", "lyrics_sync_haptics", "immersive_lyrics_enabled", "immersive_lyrics_timeout",
        "animated_lyrics_blur_enabled", "animated_lyrics_blur_strength", "disable_blur_all_over", "keep_screen_on_lyrics",
        "lyrics_alignment", "show_lyrics_translation", "show_lyrics_romanization",
        // equalizer
        "equalizer_enabled", "equalizer_preset", "equalizer_custom_bands", "bass_boost_strength", "virtualizer_strength",
        "bass_boost_enabled", "virtualizer_enabled", "equalizer_view_mode", "is_graph_view", "custom_presets_json",
        "pinned_presets_json",
        // AI (provider-specific keys are matched by suffix below)
        "ai_provider", "safe_token_limit", "ai_temperature", "ai_top_p", "ai_top_k", "ai_max_tokens", "ai_presence_penalty",
        "ai_frequency_penalty", "ai_sample_size", "ai_digest_mode", "ai_include_extended_fields",
        // playlists module
        "user_playlists_json_v1", "playlist_song_order_modes",
    ]

    static let androidOnly: [String] = [
        "allowed_directories", "blocked_directories", "album_art_palette_style_v1", "album_art_color_accuracy_v1",
        "nav_bar_corner_radius", "nav_bar_style", "nav_bar_compact_mode", "use_smooth_corners", "hi_fi_mode_enabled",
        "disable_cast_autoplay", "keep_playing_in_background", "mock_genres_enabled", "use_player_sheet_v2",
        "full_player_delay_album", "full_player_delay_metadata", "full_player_delay_progress", "full_player_delay_controls",
        "full_player_placeholders", "full_player_placeholder_transparent", "full_player_placeholders_on_close",
        "full_player_switch_on_drag_release", "full_player_delay_threshold_percent", "full_player_close_threshold_percent",
        "folders_source", "hide_local_media", "is_folder_filter_active", "folder_back_gesture_navigation",
        "loudness_enhancer_enabled", "loudness_enhancer_strength", "liquid_glass_intensity", "app_ui_style",
        "album_art_cache_limit_mb",
    ]

    static let deviceState: [String] = [
        "initial_setup_done", "app_rebrand_dialog_shown", "beta_05_clean_install_disclaimer_dismissed",
        "songs_sort_option_migrated_v2", "last_library_tab_index", "last_daily_mix_update", "playback_queue_snapshot_v1",
        "last_sync_timestamp", "directory_rules_version", "last_applied_directory_rules_version", "home_greeting_text",
        "home_greeting_date", "advanced_performance_diagnostics_enabled",
        "advanced_performance_diagnostics_started_at_epoch_ms", "advanced_performance_diagnostics_expires_at_epoch_ms",
        "last_playlist_id", "last_playlist_name", "artist_settings_rescan_required", "lyrics_sync_intro_seen_count",
        "backup_info_dismissed", "bass_boost_dismissed", "virtualizer_dismissed", "loudness_dismissed",
    ]

    static let deviceIds: [String] = [
        "favorite_song_ids", "daily_mix_song_ids", "your_mix_song_ids", "lyrics_sync_offsets_json",
        "lyrics_sync_chip_dismissed_song_ids", "custom_genre_icons",
    ]

    static let table: [String: AndroidPreferenceKind] = {
        var t: [String: AndroidPreferenceKind] = [:]
        for k in portable { t[k] = .portable }
        for k in androidOnly { t[k] = .androidOnly }
        for k in deviceState { t[k] = .deviceState }
        for k in deviceIds { t[k] = .deviceIds }
        for k in iosOnly { t[k] = .portable }
        return t
    }()

    /// AI provider keys: `<provider>_api_key`, `_model`, `_system_prompt`, `_base_url` (`AiPreferencesRepository`).
    static let aiProviderSuffixes = ["_api_key", "_model", "_system_prompt", "_base_url"]

    /// The kind of a key; nil for keys this catalogue does not know.
    public static func kind(of key: String) -> AndroidPreferenceKind? {
        if let kind = table[key] { return kind }
        if aiProviderSuffixes.contains(where: { key.hasSuffixBytes($0) }) && key.utf8.count > 4 { return .portable }
        return nil
    }
}

/// Which stored keys a preference restore removes before writing (`clearPreferencesExceptKeys` /
/// `clearPreferencesByKeys`); the excluded keys are never touched either way.
public enum PreferenceClearScope: Sendable, Hashable {
    case allExcept(Set<String>)
    case only(Set<String>)
}

/// A preference module's restore: what to clear and what to write, with the skipped keys reported.
public struct PreferenceRestore: Sendable, Hashable {
    public var clear: PreferenceClearScope
    /// Portable entries in payload order (a later duplicate key overwrites the earlier one, as in DataStore).
    public var values: [(key: String, value: PreferenceValue)]
    public var skippedAndroidOnly: [String]
    public var skippedDeviceState: [String]
    public var skippedDeviceIds: [String]
    /// Keys the catalogue does not know (skipped).
    public var unknownKeys: [String]
    /// Entries Android would ignore too (unknown type, no value, excluded key, null key).
    public var ignored: [String]

    public static func == (lhs: PreferenceRestore, rhs: PreferenceRestore) -> Bool {
        lhs.clear == rhs.clear && lhs.values.map(\.key) == rhs.values.map(\.key) && lhs.values.map(\.value) == rhs.values.map(\.value)
            && lhs.skippedAndroidOnly == rhs.skippedAndroidOnly && lhs.skippedDeviceState == rhs.skippedDeviceState
            && lhs.skippedDeviceIds == rhs.skippedDeviceIds && lhs.unknownKeys == rhs.unknownKeys && lhs.ignored == rhs.ignored
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(clear)
        for v in values { hasher.combine(v.key); hasher.combine(v.value) }
    }

    /// Every skipped key (Android-only, per-device, id-keyed, unknown) for the import report.
    public var skippedKeys: [String] { skippedAndroidOnly + skippedDeviceState + skippedDeviceIds + unknownKeys }
}

public enum PreferencesModule {
    public static let quickFillKeys: Set<String> = ["custom_genres", "custom_genre_icons"]
    public static let equalizerKeys: Set<String> = ["custom_presets_json", "pinned_presets_json"]
    /// Keys owned by dedicated modules, excluded from global settings (`GlobalSettingsModuleHandler.EXCLUDED_KEYS`).
    public static let globalExcludedKeys: Set<String> = PlaylistsModule.playlistKeys.union(quickFillKeys).union(equalizerKeys)

    /// `gson.fromJson(payload, List<PreferenceBackupEntry>)`; an empty payload or a null entry fails.
    public static func decode(payload: String) throws(BackupError) -> [AndroidBackup.PreferenceBackupEntry] {
        try decodeRequiredList(payload, AndroidBackup.PreferenceBackupEntry.self, module: .globalSettings).map(\.0)
    }

    /// The restore of `section` (global settings, QuickFill or equalizer): Android clears the keys the handler owns
    /// and imports every entry (whatever its key); PixlAudio writes the portable ones.
    public static func restore(_ section: BackupSection, payload: String) throws(BackupError) -> PreferenceRestore {
        let entries = try decode(payload: payload)
        let clear: PreferenceClearScope
        switch section {
        case .quickFill: clear = .only(quickFillKeys)
        case .equalizer: clear = .only(equalizerKeys)
        default: clear = .allExcept(globalExcludedKeys)
        }
        return plan(entries, clear: clear)
    }

    static func plan(_ entries: [AndroidBackup.PreferenceBackupEntry], clear: PreferenceClearScope) -> PreferenceRestore {
        var result = PreferenceRestore(clear: clear, values: [], skippedAndroidOnly: [], skippedDeviceState: [],
                                       skippedDeviceIds: [], unknownKeys: [], ignored: [])
        for entry in entries {
            guard let key = entry.key else {
                result.ignored.append("null")
                continue
            }
            if AndroidPreferenceCatalog.backupExcludedKeys.contains(key) {
                result.ignored.append(key)
                continue
            }
            guard let value = entry.resolvedValue else {
                result.ignored.append(key)
                continue
            }
            switch AndroidPreferenceCatalog.kind(of: key) {
            case .portable:
                if let i = result.values.firstIndex(where: { KotlinText.equals($0.key, key) }) {
                    result.values[i].value = value
                } else {
                    result.values.append((key, value))
                }
            case .androidOnly: result.skippedAndroidOnly.append(key)
            case .deviceState: result.skippedDeviceState.append(key)
            case .deviceIds: result.skippedDeviceIds.append(key)
            case nil: result.unknownKeys.append(key)
            }
        }
        return result
    }

    /// The payload a handler writes: entries filtered to the keys the module owns (global settings: everything but
    /// the dedicated modules' keys and the excluded key).
    public static func export(_ section: BackupSection, values: [(key: String, value: PreferenceValue)]) -> String {
        let owned = values.filter { pair in
            if AndroidPreferenceCatalog.backupExcludedKeys.contains(pair.key) { return false }
            switch section {
            case .quickFill: return quickFillKeys.contains(pair.key)
            case .equalizer: return equalizerKeys.contains(pair.key)
            default: return !globalExcludedKeys.contains(pair.key)
            }
        }
        return AndroidBackup.PreferenceBackupEntry.encodeList(owned.map { $0.value.entry($0.key) })
    }

    // MARK: Typed views of module values

    /// The equalizer module's custom presets (`custom_presets_json`, kotlinx JSON of `List<EqualizerPreset>`).
    public static func customPresets(from restore: PreferenceRestore) -> [EqualizerPreset] {
        guard let raw = stringValue("custom_presets_json", in: restore), let data = raw.data(using: .utf8),
              let presets = try? JSONDecoder().decode([EqualizerPreset].self, from: data) else { return [] }
        return presets
    }

    /// The pinned preset names (`pinned_presets_json`); Android falls back to all built-ins when unreadable.
    public static func pinnedPresets(from restore: PreferenceRestore) -> [String]? {
        guard let raw = stringValue("pinned_presets_json", in: restore) else { return nil }
        guard let data = raw.data(using: .utf8), let names = try? JSONDecoder().decode([String].self, from: data) else {
            return EqualizerPreset.allPresets.map(\.name)
        }
        return names
    }

    /// QuickFill's custom genres (`custom_genres`).
    public static func customGenres(from restore: PreferenceRestore) -> [String] {
        for pair in restore.values where pair.key == "custom_genres" {
            if case .stringSet(let genres) = pair.value { return genres }
        }
        return []
    }

    static func stringValue(_ key: String, in restore: PreferenceRestore) -> String? {
        for pair in restore.values where pair.key == key {
            if case .string(let s) = pair.value { return s }
        }
        return nil
    }
}
