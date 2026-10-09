import Foundation
import Observation
import PixlLibrary
import PixlModel
import SwiftUI

/// Album-art theming (Android `ThemeStateHolder`): tracks the current song's artwork scheme and resolves which
/// scheme themes the app chrome and which themes the player (`player_theme_preference_v2`). The app chrome's own
/// scheme is the accent (Settings › Appearance › Accent Color, iOS-only): PixlAudio's violet by default, where
/// Android uses the system's dynamic colours.
@Observable
final class ThemeStore {
    /// The current song's scheme pair (nil while extracting, or when the song has no artwork).
    private(set) var albumPair: ColorRolesPair?

    private let extractor: ColorExtractor
    private let appearance: AppearanceSettings
    @ObservationIgnored private var requestedKey: String?
    /// The last accent built, keyed by its stored value: one scheme pair per change, never per body.
    @ObservationIgnored private var accentCache: (hex: String, pair: ColorRolesPair)?

    init(extractor: ColorExtractor, appearance: AppearanceSettings) {
        self.extractor = extractor
        self.appearance = appearance
    }

    /// The forced colour scheme from `app_theme_mode` (nil = follow the system).
    var preferredColorScheme: ColorScheme? {
        switch appearance.appThemeMode {
        case .followSystem: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// The accent scheme pair (`appearance.accentColor`; `ArtworkTheme.brandPair` for the default). Reading it observes
    /// the setting, so every view that themes itself from `colors(for:)` re-renders live when the accent changes.
    var accentPair: ColorRolesPair {
        let hex = appearance.accentColor
        if let cached = accentCache, cached.hex == hex { return cached.pair }
        let pair = AccentPalette.pair(hex: hex)
        accentCache = (hex: hex, pair: pair)
        return pair
    }

    /// The app chrome's and the player's colours for the effective light/dark scheme. The chrome takes the accent;
    /// the player takes the album colours (Player Theme "Album Art", the default) or the accent too ("Accent Color",
    /// stored as Android's `dynamic`).
    func colors(for colorScheme: ColorScheme) -> (app: ThemeColors, player: ThemeColors) {
        let isDark = colorScheme == .dark
        let accent = ThemeColors(roles: accentPair.roles(dark: isDark), isDark: isDark)
        guard let pair = albumPair else { return (accent, accent) }
        let album = ThemeColors(roles: pair.roles(dark: isDark), isDark: isDark)
        switch appearance.playerTheme {
        case .albumArt: return (accent, album)
        case .global: return (album, album)
        case .default, .dynamic: return (accent, accent)
        }
    }

    /// Launch: themes the song the queue is about to restore from what is already stored (never extracts), before the
    /// song appears, so the mini player's first frame has its album colours instead of the accent followed by a 0.45 s
    /// re-theme. `update(for:)` then finds the key requested and has nothing to do.
    func seed(for song: Song?) async {
        guard albumPair == nil, requestedKey == nil, let song, let source = ArtworkSource(song: song) else { return }
        let style = appearance.paletteStyle
        let accuracy = appearance.colorAccuracy
        let key = source.cacheKey + "|" + ArtworkTheme.paletteCacheKey(style: style, accuracyLevel: accuracy)
        guard let pair = await extractor.storedPair(for: source, style: style, accuracyLevel: accuracy),
              albumPair == nil, requestedKey == nil else { return }
        requestedKey = key
        albumPair = pair
    }

    /// Call when the current song changes (the shell does, from `.task(id:)`). Extraction runs off the main thread.
    func update(for song: Song?) async {
        guard let song, let source = ArtworkSource(song: song) else {
            requestedKey = nil
            if albumPair != nil { albumPair = nil }
            return
        }
        let style = appearance.paletteStyle
        let accuracy = appearance.colorAccuracy
        let key = source.cacheKey + "|" + ArtworkTheme.paletteCacheKey(style: style, accuracyLevel: accuracy)
        guard key != requestedKey else { return }
        requestedKey = key
        // The warmed mirror answers at once: no hop through the extractor, so a mirror hit re-themes in the same frame.
        if let hit = extractor.peek(source, style: style, accuracyLevel: accuracy) {
            if hit != albumPair { albumPair = hit }
            return
        }
        let pair = await extractor.schemePair(for: source, style: style, accuracyLevel: accuracy)
        guard requestedKey == key else { return }
        if pair != albumPair { albumPair = pair }
    }
}
