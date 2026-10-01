// Port of `presentation/lyrics/LyricsAppearancePrefs.kt` and the appearance half of `LyricsView.kt`
// (`KaraokeLyricsAppearance`, `inactiveAlphaFor`, the blend choice and the engine config the view derives).
// iOS always uses the system font, so Android's `fontFamily` field has no counterpart.

import Foundation
import PixlFoundation

/// How the karaoke lyrics look. Everything here changes rarely (a preference, the art, a system setting).
public struct KaraokeLyricsAppearance: Sendable, Hashable {
    /// Multiplier on the 34 pt main size (the user's lyrics text-size setting).
    public var textScale: Float
    public var alignment: KaraokeAlignment
    /// The artwork is bright (§1.2): normal blending, inactive alpha 0.50.
    public var brightArt: Bool
    /// Increased contrast (§1.2): normal blending, inactive 0.55, no gradient, no blur.
    public var highContrast: Bool
    public var blurEnabled: Bool
    /// Multiplier on the §1.3 σ table (1 = the spec's 1.6 / 2.4 / … ).
    public var blurStrength: Float
    public var showTranslation: Bool
    public var showRomanization: Bool

    public init(textScale: Float = 1, alignment: KaraokeAlignment = .start, brightArt: Bool = false,
                highContrast: Bool = false, blurEnabled: Bool = true, blurStrength: Float = 1,
                showTranslation: Bool = true, showRomanization: Bool = true) {
        self.textScale = textScale
        self.alignment = alignment
        self.brightArt = brightArt
        self.highContrast = highContrast
        self.blurEnabled = blurEnabled
        self.blurStrength = blurStrength
        self.showTranslation = showTranslation
        self.showRomanization = showRomanization
    }

    /// Inactive line alpha: 0.55 under increased contrast, 0.50 over bright art, else 0.20.
    public var inactiveAlpha: Float {
        LyricsRenderMetrics.inactiveAlpha(brightArt: brightArt, highContrast: highContrast)
    }

    /// The whole lyrics layer composites additively (Android `BlendMode.Plus`, SwiftUI `.plusLighter`) unless the art
    /// is bright or contrast is increased (normal blending).
    public var usesAdditiveBlend: Bool { !(brightArt || highContrast) }

    /// The engine configuration the view derives from this appearance.
    public func engineConfig(density: Float = 1, blurSupported: Bool = true, reducedMotion: Bool,
                             blurSigmaQuantum: Float = 0.3) -> LyricsEngineConfig {
        LyricsEngineConfig(density: density, blurSupported: blurSupported, blurEnabled: blurEnabled && !highContrast,
                           blurStrength: blurStrength, reducedMotion: reducedMotion, blurSigmaQuantum: blurSigmaQuantum)
    }

    /// Layout metrics for this appearance.
    public func metrics(density: Float = 1, hasDuet: Bool, reducedMotion: Bool) -> LyricsRenderMetrics {
        LyricsRenderMetrics(textScale: textScale, density: density, alignment: alignment, hasDuet: hasDuet,
                            highContrast: highContrast, reducedMotion: reducedMotion, showTranslation: showTranslation,
                            showRomanization: showRomanization)
    }
}

/// The user's lyrics look preferences, shared by the lyrics view and the sync editor's preview.
public struct LyricsAppearancePrefs: Sendable, Hashable, Codable {
    /// The size the lyrics text style is designed at: text scale 1.
    public static let defaultLyricsTextSize: Float = 22
    /// The default "animated lyrics blur strength" (1.2 = the spec's σ table).
    public static let defaultBlurStrengthPref: Float = 1.2

    /// Android DataStore keys (the backup importer maps these).
    public enum Key {
        public static let alignment = "lyrics_alignment"
        public static let showTranslation = "show_lyrics_translation"
        public static let showRomanization = "show_lyrics_romanization"
        public static let animatedBlurEnabled = "animated_lyrics_blur_enabled"
        public static let disableBlurAllOver = "disable_blur_all_over"
        public static let blurStrength = "animated_lyrics_blur_strength"
    }

    /// "left", "center" or "right".
    public var alignment: String
    public var showTranslation: Bool
    public var showRomanization: Bool
    public var animatedBlurEnabled: Bool
    public var disableBlurAllOver: Bool
    /// The "animated lyrics blur strength" preference (default 1.2).
    public var blurStrength: Float
    /// Increased contrast (system setting): §1.2's high-contrast lyrics.
    public var highContrast: Bool

    public init(alignment: String = "left", showTranslation: Bool = true, showRomanization: Bool = true,
                animatedBlurEnabled: Bool = true, disableBlurAllOver: Bool = false,
                blurStrength: Float = LyricsAppearancePrefs.defaultBlurStrengthPref, highContrast: Bool = false) {
        self.alignment = alignment
        self.showTranslation = showTranslation
        self.showRomanization = showRomanization
        self.animatedBlurEnabled = animatedBlurEnabled
        self.disableBlurAllOver = disableBlurAllOver
        self.blurStrength = blurStrength
        self.highContrast = highContrast
    }

    /// `toAppearance`: text scale = text size / 22; "center" → center, "right" → end, else start; blur on only with
    /// the animated-blur preference and without the global "disable blur" switch; strength relative to 1.2.
    ///
    /// - Parameter textSize: the lyrics text-size setting in points, or nil for the default (scale 1).
    public func toAppearance(textSize: Float?, brightArt: Bool) -> KaraokeLyricsAppearance {
        KaraokeLyricsAppearance(
            textScale: textSize.map { $0 / Self.defaultLyricsTextSize } ?? 1,
            alignment: Self.alignment(from: alignment),
            brightArt: brightArt,
            highContrast: highContrast,
            blurEnabled: animatedBlurEnabled && !disableBlurAllOver,
            blurStrength: blurStrength / Self.defaultBlurStrengthPref,
            showTranslation: showTranslation,
            showRomanization: showRomanization
        )
    }

    public static func alignment(from value: String) -> KaraokeAlignment {
        switch value {
        case "center": return .center
        case "right": return .end
        default: return .start
        }
    }
}
