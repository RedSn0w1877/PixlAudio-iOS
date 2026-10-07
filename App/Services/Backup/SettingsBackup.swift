import Foundation
import PixlBackup
import PixlNet

/// The settings modules of a backup (global settings, QuickFill, equalizer) against `UserDefaults`.
///
/// PixlAudio stores its settings under the Android DataStore key names (`PreferenceKeys`), so a portable Android
/// entry restores by name. Exports write each value with the type Android declares for the key
/// (`stringPreferencesKey`, `intPreferencesKey`, …) so an iOS backup restores on Android too. AI API keys live in
/// the Keychain on iOS (`<provider>_api_key` accounts) and travel in the global-settings module, as on Android.
nonisolated enum SettingsBackup {
    nonisolated enum Kind: Sendable { case string, int, long, bool, float, double, stringSet }

    /// Android's declared type per DataStore key (every `*PreferencesKey("…")` in the Android app).
    static let androidTypes: [String: Kind] = [
        "advanced_performance_diagnostics_enabled": .bool,
        "advanced_performance_diagnostics_expires_at_epoch_ms": .long,
        "advanced_performance_diagnostics_started_at_epoch_ms": .long,
        "ai_digest_mode": .string,
        "ai_frequency_penalty": .float,
        "ai_include_extended_fields": .bool,
        "ai_max_tokens": .int,
        "ai_presence_penalty": .float,
        "ai_provider": .string,
        "ai_sample_size": .int,
        "ai_temperature": .float,
        "ai_top_k": .int,
        "ai_top_p": .float,
        "album_art_cache_limit_mb": .int,
        "album_art_color_accuracy_v1": .int,
        "album_art_palette_style_v1": .string,
        "album_art_quality": .string,
        "albums_sort_option": .string,
        "allowed_directories": .stringSet,
        "animated_lyrics_blur_enabled": .bool,
        "animated_lyrics_blur_strength": .float,
        "app_rebrand_dialog_shown": .bool,
        "app_theme_mode": .string,
        "app_ui_style": .string,
        "artist_delimiters": .string,
        "artist_settings_rescan_required": .bool,
        "artist_word_delimiters": .string,
        "artists_sort_option": .string,
        "audio_quality": .string,
        "auto_scan_lrc_files": .bool,
        "automatic_instrumentals": .bool,
        "automatic_lyrics": .bool,
        "backup_history_json": .string,
        "backup_info_dismissed": .bool,
        "bass_boost_dismissed": .bool,
        "bass_boost_enabled": .bool,
        "bass_boost_strength": .int,
        "beta_05_clean_install_disclaimer_dismissed": .bool,
        "blocked_directories": .stringSet,
        "carousel_style": .string,
        "collage_auto_rotate": .bool,
        "collage_pattern": .string,
        "crossfade_duration": .int,
        "custom_genre_icons": .string,
        "custom_genres": .stringSet,
        "custom_presets_json": .string,
        "daily_mix_song_ids": .string,
        "directory_rules_version": .int,
        "disable_blur_all_over": .bool,
        "disable_cast_autoplay": .bool,
        "discovery_enabled": .bool,
        "equalizer_custom_bands": .string,
        "equalizer_enabled": .bool,
        "equalizer_preset": .string,
        "equalizer_view_mode": .string,
        "exploration_fraction": .float,
        "extract_artists_from_title": .bool,
        "favorite_song_ids": .stringSet,
        "feedback_v1": .string,
        "folder_back_gesture_navigation": .bool,
        "folders_sort_option": .string,
        "folders_source": .string,
        "full_player_close_threshold_percent": .int,
        "full_player_delay_album": .bool,
        "full_player_delay_controls": .bool,
        "full_player_delay_metadata": .bool,
        "full_player_delay_progress": .bool,
        "full_player_delay_threshold_percent": .int,
        "full_player_placeholder_transparent": .bool,
        "full_player_placeholders": .bool,
        "full_player_placeholders_on_close": .bool,
        "full_player_show_file_info": .bool,
        "full_player_switch_on_drag_release": .bool,
        "global_transition_settings_json": .string,
        "group_by_album_artist": .bool,
        "haptics_enabled": .bool,
        "hi_fi_mode_enabled": .bool,
        "hide_local_media": .bool,
        "home_greeting_date": .string,
        "home_greeting_text": .string,
        "immersive_lyrics_enabled": .bool,
        "immersive_lyrics_timeout": .long,
        "initial_setup_done": .bool,
        "is_albums_list_view": .bool,
        "is_crossfade_enabled": .bool,
        "is_folder_filter_active": .bool,
        "is_folders_playlist_view": .bool,
        "is_genre_grid_view": .bool,
        "is_graph_view": .bool,
        "is_shuffle_on": .bool,
        "keep_playing_in_background": .bool,
        // Android-only since 2026-10-07 (the lyrics screen always keeps the screen on); kept so the table mirrors Android.
        "keep_screen_on_lyrics": .bool,
        "last_applied_directory_rules_version": .int,
        "last_daily_mix_update": .long,
        "last_library_tab_index": .int,
        "last_playlist_id": .string,
        "last_playlist_name": .string,
        "last_report": .string,
        "last_storage_filter": .string,
        "last_sync_timestamp": .long,
        "launch_tab": .string,
        "learning_enabled": .bool,
        "library_navigation_mode": .string,
        "library_tabs_order": .string,
        "liked_songs_sort_option": .string,
        "liquid_glass_intensity": .float,
        "loudness_dismissed": .bool,
        "loudness_enhancer_enabled": .bool,
        "loudness_enhancer_strength": .int,
        "lyrics_alignment": .string,
        "lyrics_source_preference": .string,
        "lyrics_sync_chip_dismissed_song_ids": .stringSet,
        "lyrics_sync_default_speed": .float,
        "lyrics_sync_haptics": .bool,
        "lyrics_sync_intro_seen_count": .int,
        "lyrics_sync_offsets_json": .string,
        "lyrics_tap_offset_bluetooth_ms": .int,
        "lyrics_tap_offset_speaker_ms": .int,
        "min_song_duration_ms": .int,
        "min_tracks_per_album": .int,
        "mock_genres_enabled": .bool,
        "nav_bar_compact_mode": .bool,
        "nav_bar_corner_radius": .int,
        "nav_bar_style": .string,
        "pause_on_volume_zero": .bool,
        "persistent_shuffle_enabled": .bool,
        "pinned_presets_json": .string,
        "playback_queue_snapshot_v1": .string,
        "player_ambient_style": .string,
        "player_theme_preference_v2": .string,
        "playlist_song_order_modes": .string,
        "playlists_sort_option": .string,
        "repeat_mode": .int,
        "replaygain_enabled": .bool,
        "replaygain_use_album_gain": .bool,
        "resume_on_headset_reconnect": .bool,
        "safe_token_limit": .bool,
        "show_lyrics_romanization": .bool,
        "show_lyrics_translation": .bool,
        "show_queue_history": .bool,
        "show_scrollbar": .bool,
        "songs_sort_option": .string,
        "songs_sort_option_migrated_v2": .bool,
        "tais_roformer_api_key": .string,
        "tais_roformer_api_name": .string,
        "tais_roformer_backend_type": .string,
        "tais_roformer_base_url": .string,
        "tais_roformer_extra_arg": .string,
        "tais_vocal_attenuation": .float,
        "tap_background_closes_player": .bool,
        "use_player_sheet_v2": .bool,
        "use_smooth_corners": .bool,
        "user_playlists_json_v1": .string,
        "virtualizer_dismissed": .bool,
        "virtualizer_enabled": .bool,
        "virtualizer_strength": .int,
        "your_mix_song_ids": .string
    ]

    /// The type Android uses for `key`; per-provider AI keys (`<provider>_model`, …) are strings.
    static func kind(of key: String) -> Kind? {
        if let kind = androidTypes[key] { return kind }
        return AndroidPreferenceCatalog.kind(of: key) == .portable ? .string : nil
    }

    /// API keys stored in the Keychain rather than `UserDefaults` (`AISettingsSection`, and the BS-RoFormer key of
    /// Developer › Experimental).
    static func isKeychainKey(_ key: String) -> Bool {
        key == PreferenceKeys.taisRoformerApiKey || (androidTypes[key] == nil && key.hasSuffix("_api_key"))
    }

    // MARK: Export

    /// Every portable setting currently stored, typed as Android stores it, sorted by key. Keys that were never
    /// written are left out (Android's DataStore holds only written keys too).
    static func exportValues(defaults: UserDefaults,
                             keychain: (String) -> String? = Self.keychainString) -> [(key: String, value: PreferenceValue)] {
        var out: [(key: String, value: PreferenceValue)] = []
        let stored = defaults.dictionaryRepresentation()
        for key in stored.keys.sorted() {
            guard AndroidPreferenceCatalog.kind(of: key) == .portable, !isKeychainKey(key),
                  let kind = kind(of: key), let raw = stored[key],
                  let value = value(raw, as: kind) else { continue }
            out.append((key, value))
        }
        for provider in AiProvider.allCases {
            let account = PreferenceKeys.aiApiKeyAccount(provider.rawValue)
            if let secret = keychain(account), !secret.isEmpty { out.append((account, .string(secret))) }
        }
        let roformer = PreferenceKeys.taisRoformerApiKey
        if let secret = keychain(roformer), !secret.isEmpty { out.append((roformer, .string(secret))) }
        return out
    }

    /// Converts a stored `UserDefaults` object to Android's type for the key; nil when it can't be represented.
    static func value(_ raw: Any, as kind: Kind) -> PreferenceValue? {
        switch kind {
        case .string:
            if let s = raw as? String { return .string(s) }
            if let list = raw as? [String] { return .string(LibrarySettings.encodeJSON(list)) }
            if let n = raw as? NSNumber { return .string(n.stringValue) }
            return nil
        case .int:
            guard let n = number(raw) else { return nil }
            return .int(Int32(clamping: n.int64Value))
        case .long:
            guard let n = number(raw) else { return nil }
            return .long(n.int64Value)
        case .bool:
            if let n = raw as? NSNumber { return .bool(n.boolValue) }
            if let s = raw as? String, let b = Bool(s) { return .bool(b) }
            return nil
        case .float:
            guard let n = number(raw) else { return nil }
            return .float(Float(n.doubleValue))
        case .double:
            guard let n = number(raw) else { return nil }
            return .double(n.doubleValue)
        case .stringSet:
            if let list = raw as? [String] { return .stringSet(list) }
            if let s = raw as? String, let data = s.data(using: .utf8),
               let list = try? JSONDecoder().decode([String].self, from: data) {
                return .stringSet(list)
            }
            return nil
        }
    }

    private static func number(_ raw: Any) -> NSNumber? {
        if let n = raw as? NSNumber { return n }
        if let s = raw as? String, let d = Double(s) { return NSNumber(value: d) }
        return nil
    }

    // MARK: Restore

    /// What applying a settings module did.
    nonisolated struct ApplyResult: Sendable, Equatable {
        var applied = 0
        var keychain = 0
    }

    /// Applies a preference module like Android's `importPreferencesFromBackup`: clears the keys the module owns
    /// (only Android-named portable keys — iOS-only state such as folder bookmarks is never touched), then writes
    /// every portable entry. API keys go to the Keychain and are never cleared.
    @discardableResult
    static func apply(_ restore: PreferenceRestore, defaults: UserDefaults,
                      keychainSet: (String, String) -> Bool = Self.setKeychainString) -> ApplyResult {
        switch restore.clear {
        case .allExcept(let keep):
            for key in defaults.dictionaryRepresentation().keys
            where AndroidPreferenceCatalog.kind(of: key) == .portable && !keep.contains(key) && !isKeychainKey(key)
                && !AndroidPreferenceCatalog.backupExcludedKeys.contains(key) {
                defaults.removeObject(forKey: key)
            }
        case .only(let keys):
            for key in keys where !AndroidPreferenceCatalog.backupExcludedKeys.contains(key) {
                defaults.removeObject(forKey: key)
            }
        }
        var result = ApplyResult()
        for (key, value) in restore.values {
            if isKeychainKey(key) {
                if case .string(let secret) = value, keychainSet(key, secret) { result.keychain += 1 }
                continue
            }
            switch value {
            case .string(let s): defaults.set(s, forKey: key)
            case .int(let v): defaults.set(Int(v), forKey: key)
            case .long(let v): defaults.set(Int(v), forKey: key)
            case .bool(let b): defaults.set(b, forKey: key)
            // Through the decimal text, so 0.7f reads back as 0.7 rather than 0.699999988.
            case .float(let f): defaults.set(Double(String(f)) ?? Double(f), forKey: key)
            case .double(let d): defaults.set(d, forKey: key)
            case .stringSet(let list): defaults.set(list, forKey: key)
            }
            result.applied += 1
        }
        return result
    }

    // MARK: Keychain

    static func keychainString(_ account: String) -> String? {
        guard let data = try? KeychainStore.data(for: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setKeychainString(_ account: String, _ value: String) -> Bool {
        if value.isEmpty { return (try? KeychainStore.delete(account: account)) != nil }
        return (try? KeychainStore.set(Data(value.utf8), for: account)) != nil
    }
}
