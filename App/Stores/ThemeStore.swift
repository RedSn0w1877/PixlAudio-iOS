import Foundation
import Observation
import PixlLibrary
import PixlModel
import SwiftUI

/// Album-art theming (Android `ThemeStateHolder`): tracks the current song's artwork scheme and resolves which
/// scheme themes the app chrome and which themes the player (`player_theme_preference_v2`).
@Observable
final class ThemeStore {
    /// The current song's scheme pair (nil while extracting, or when the song has no artwork).
    private(set) var albumPair: ColorRolesPair?

    private let extractor: ColorExtractor
    private let appearance: AppearanceSettings
    @ObservationIgnored private var requestedKey: String?

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

    /// The app chrome's and the player's colours for the effective light/dark scheme.
    func colors(for colorScheme: ColorScheme) -> (app: ThemeColors, player: ThemeColors) {
        let isDark = colorScheme == .dark
        let brand = ThemeColors.brand(colorScheme)
        guard let pair = albumPair else { return (brand, brand) }
        let album = ThemeColors(roles: pair.roles(dark: isDark), isDark: isDark)
        switch appearance.playerTheme {
        case .albumArt: return (brand, album)
        case .global: return (album, album)
        case .default, .dynamic: return (brand, brand)
        }
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
        let pair = await extractor.schemePair(for: source, style: style, accuracyLevel: accuracy)
        guard requestedKey == key else { return }
        if pair != albumPair { albumPair = pair }
    }
}
