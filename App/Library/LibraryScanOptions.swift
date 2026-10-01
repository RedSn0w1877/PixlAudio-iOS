import Foundation
import PixlLibrary

/// iOS-only preference keys of the library import (no Android counterpart). Android's keys live in
/// `PreferenceKeys` (Stores/SettingsStore.swift); these stay here so stage 7d's settings edits never collide with
/// stage 6. Stage 7d's folder screen reads and writes them through `LocalLibraryImporter`.
nonisolated enum LibraryImportPreferenceKeys {
    /// Include the device music library (DRM-free items) — on by default; it only takes effect once the user has
    /// granted media-library access.
    static let includeMediaLibrary = "ios_library_include_media_library"
}

/// Everything a scan reads from the user's settings, snapshotted once per scan (Android reads the same values from
/// `UserPreferencesRepository` at the start of `SyncWorker.doWork`).
nonisolated struct LibraryScanOptions: Sendable, Equatable {
    var artistDelimiters: [String]
    var artistWordDelimiters: [String]
    var extractArtistsFromTitle: Bool
    var groupByAlbumArtist: Bool
    /// Android `min_song_duration_ms` (default 10 000): shorter files are not imported.
    var minSongDurationMs: Int
    /// Android `allowed_directories` / `blocked_directories`, as library paths (`/<folder name>/<sub folder>`).
    var allowedDirectories: Set<String>
    var blockedDirectories: Set<String>
    var includeMediaLibrary: Bool

    static let `default` = LibraryScanOptions(
        artistDelimiters: ArtistParsing.defaultArtistDelimiters,
        artistWordDelimiters: ArtistParsing.defaultWordDelimiters,
        extractArtistsFromTitle: true, groupByAlbumArtist: false, minSongDurationMs: 10_000,
        allowedDirectories: [], blockedDirectories: [], includeMediaLibrary: true)

    /// Reads the options under the Android keys. Delimiter lists are stored as a JSON string array (Android
    /// `json.encodeToString(delimiters)`), string sets as `[String]`; Android's legacy default delimiter list is
    /// normalised to the current default like `artistDelimitersFlow` does.
    static func current(defaults: UserDefaults = .standard) -> LibraryScanOptions {
        var options = LibraryScanOptions.default
        if let delimiters = stringList(defaults, PreferenceKeys.artistDelimiters) {
            options.artistDelimiters = ArtistParsing.normalizeLegacyDefaultArtistDelimiters(delimiters)
        }
        if let words = stringList(defaults, PreferenceKeys.artistWordDelimiters) {
            options.artistWordDelimiters = words
        }
        options.extractArtistsFromTitle = defaults.bool(PreferenceKeys.extractArtistsFromTitle, default: true)
        options.groupByAlbumArtist = defaults.bool(PreferenceKeys.groupByAlbumArtist, default: false)
        options.minSongDurationMs = max(0, defaults.int(PreferenceKeys.minSongDurationMs, default: 10_000))
        options.allowedDirectories = Set(stringList(defaults, PreferenceKeys.allowedDirectories) ?? [])
        options.blockedDirectories = Set(stringList(defaults, PreferenceKeys.blockedDirectories) ?? [])
        options.includeMediaLibrary = defaults.bool(LibraryImportPreferenceKeys.includeMediaLibrary, default: true)
        return options
    }

    /// A `[String]`, or a JSON array encoded as a string (Android's DataStore format after a backup restore).
    private static func stringList(_ defaults: UserDefaults, _ key: String) -> [String]? {
        if let array = defaults.stringArray(forKey: key) { return array }
        if let json = defaults.string(forKey: key), let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            return decoded
        }
        return nil
    }

    /// The options that decide which files make it into the library. When they change, the next incremental scan
    /// re-reads everything (Android: `directoryRulesChanged` / `artistSettingsRescanRequired` force a full fetch).
    var filterFingerprint: String {
        "\(minSongDurationMs)|\(allowedDirectories.sorted().joined(separator: "\u{1}"))|"
            + blockedDirectories.sorted().joined(separator: "\u{1}")
    }
}
