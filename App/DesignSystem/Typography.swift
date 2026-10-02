import SwiftUI

/// PixlAudio's type scale (Android `ui/theme/Type.kt` `Typography`, Google Sans Rounded) rendered in SF Pro at the
/// same point sizes, weights, line heights and tracking (1 sp = 1 pt). Names mirror the Compose type roles so call
/// sites port 1:1: Compose `style = MaterialTheme.typography.bodyLarge` → `.pixlFont(.bodyLarge)`; per-call
/// overrides (`fontWeight = SemiBold`, `fontSize = 15.sp`) → `.pixlFont(.bodyLarge, weight: .semibold)` /
/// `.pixlFont(.custom(size: 15, weight: .semibold))`.
///
/// Text scales with Dynamic Type like Android's sp scales with the font-size setting (`PixlFont` reads
/// `dynamicTypeSize`), capped at 1.6× so PixlAudio's fixed-height bars keep their layout.
nonisolated struct PixlTextStyle: Sendable, Hashable {
    var size: CGFloat
    var weight: Font.Weight
    var lineHeight: CGFloat?
    var tracking: CGFloat

    static func custom(size: CGFloat, weight: Font.Weight = .regular, lineHeight: CGFloat? = nil,
                       tracking: CGFloat = 0) -> PixlTextStyle {
        PixlTextStyle(size: size, weight: weight, lineHeight: lineHeight, tracking: tracking)
    }

    // Android Typography (Type.kt).
    static let displayLarge = PixlTextStyle(size: 48, weight: .bold, lineHeight: 56, tracking: 0)
    static let displayMedium = PixlTextStyle(size: 36, weight: .bold, lineHeight: 44, tracking: 0)
    static let displaySmall = PixlTextStyle(size: 30, weight: .regular, lineHeight: 38, tracking: 0)
    static let headlineLarge = PixlTextStyle(size: 32, weight: .semibold, lineHeight: 40, tracking: 0)
    static let headlineMedium = PixlTextStyle(size: 28, weight: .semibold, lineHeight: 36, tracking: 0)
    static let headlineSmall = PixlTextStyle(size: 24, weight: .semibold, lineHeight: 32, tracking: 0)
    static let titleLarge = PixlTextStyle(size: 22, weight: .regular, lineHeight: 28, tracking: 0)
    static let titleMedium = PixlTextStyle(size: 18, weight: .medium, lineHeight: 24, tracking: 0.15)
    static let titleSmall = PixlTextStyle(size: 14, weight: .medium, lineHeight: 20, tracking: 0.1)
    static let bodyLarge = PixlTextStyle(size: 16, weight: .regular, lineHeight: 24, tracking: 0.5)
    static let bodyMedium = PixlTextStyle(size: 14, weight: .regular, lineHeight: 20, tracking: 0.25)
    static let bodySmall = PixlTextStyle(size: 12, weight: .regular, lineHeight: 16, tracking: 0.4)
    static let labelLarge = PixlTextStyle(size: 16, weight: .medium, lineHeight: 20, tracking: 0.1)
    static let labelMedium = PixlTextStyle(size: 14, weight: .medium, lineHeight: 16, tracking: 0.5)
    static let labelSmall = PixlTextStyle(size: 11, weight: .medium, lineHeight: 16, tracking: 0.5)

    /// The same style with another weight (Compose `fontWeight =` override).
    func weight(_ weight: Font.Weight) -> PixlTextStyle {
        var copy = self
        copy.weight = weight
        return copy
    }

    /// The same style with another size (Compose `fontSize =` override).
    func size(_ size: CGFloat) -> PixlTextStyle {
        var copy = self
        copy.size = size
        return copy
    }

    /// The same style with other tracking (Compose `letterSpacing =` override).
    func tracking(_ tracking: CGFloat) -> PixlTextStyle {
        var copy = self
        copy.tracking = tracking
        return copy
    }
}

/// Dynamic Type multiplier relative to the default size (body 17 pt at `.large`), capped at 1.6.
nonisolated enum DynamicTypeScale {
    static func factor(_ size: DynamicTypeSize) -> CGFloat {
        let body: CGFloat
        switch size {
        case .xSmall: body = 14
        case .small: body = 15
        case .medium: body = 16
        case .large: body = 17
        case .xLarge: body = 19
        case .xxLarge: body = 21
        case .xxxLarge: body = 23
        case .accessibility1: body = 28
        case .accessibility2: body = 33
        case .accessibility3: body = 40
        case .accessibility4: body = 47
        case .accessibility5: body = 53
        @unknown default: body = 17
        }
        return min(body / 17, 1.6)
    }
}

/// SF Pro renders noticeably lighter than PixlAudio's rounded Google Sans at the same nominal weight. Hoa asked
/// (2026-10-01) for the heavier Android look (in the Android screenshots even body text reads as bold), so every
/// PixlAudio text style is drawn two to three steps heavier than its Type.kt weight. Styles keep their Android
/// weights as data; only rendering is boosted, in this one place.
nonisolated enum PixlWeightBoost {
    static func boosted(_ weight: Font.Weight) -> Font.Weight {
        switch weight {
        case .ultraLight, .thin: return .regular
        case .light: return .medium
        case .regular, .medium: return .bold
        case .semibold, .bold: return .heavy
        case .heavy, .black: return .black
        default: return weight
        }
    }
}

private struct PixlFontModifier: ViewModifier {
    let style: PixlTextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let factor = DynamicTypeScale.factor(dynamicTypeSize)
        let size = style.size * factor
        content
            .font(.system(size: size, weight: PixlWeightBoost.boosted(style.weight)))
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing(dynamicTypeSize))
    }
}

extension PixlTextStyle {
    /// The line spacing `pixlFont` applies at a Dynamic Type size: SwiftUI adds line spacing between lines, while
    /// Compose's line height is the full line box.
    func lineSpacing(_ dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let factor = DynamicTypeScale.factor(dynamicTypeSize)
        let natural = size * factor * 1.19
        return max(0, (lineHeight.map { $0 * factor } ?? natural) - natural)
    }
}

extension View {
    /// Applies a PixlAudio text style in SF Pro.
    func pixlFont(_ style: PixlTextStyle) -> some View {
        modifier(PixlFontModifier(style: style))
    }

    /// Applies a PixlAudio text style with a weight override.
    func pixlFont(_ style: PixlTextStyle, weight: Font.Weight) -> some View {
        modifier(PixlFontModifier(style: style.weight(weight)))
    }
}
