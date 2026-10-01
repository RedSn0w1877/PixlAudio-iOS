// Tonal palettes, contrast, and the dynamic-colour role rules: a Swift port of Google's colour utilities (Apache-2.0;
// `palettes/TonalPalette`, `contrast/Contrast`, `dislike/DislikeAnalyzer`, `dynamiccolor/*`, `scheme/Scheme*`), the
// version Android ships in com.google.android.material:material 1.14.0 (it matches upstream commit 03336bf6de,
// June 2024: on-container tones 30 in light). See THIRD_PARTY_NOTICES.md. Names avoid the upstream class names
// (`SchemeRoleRules` is upstream's role table) but every rule and constant is unchanged.

import Foundation
import PixlFoundation

// MARK: - TonalPalette

struct TonalPalette: Sendable {
    let hue: Double
    let chroma: Double
    let keyColor: Hct

    static func fromInt(_ argb: ARGB) -> TonalPalette { fromHct(Hct.fromInt(argb)) }

    static func fromHct(_ hct: Hct) -> TonalPalette { TonalPalette(hue: hct.hue, chroma: hct.chroma, keyColor: hct) }

    static func fromHueAndChroma(_ hue: Double, _ chroma: Double) -> TonalPalette {
        TonalPalette(hue: hue, chroma: chroma, keyColor: KeyColor(hue: hue, requestedChroma: chroma).create())
    }

    func tone(_ tone: Int) -> ARGB { Hct.from(hue, chroma, Double(tone)).toInt() }

    func hct(_ tone: Double) -> Hct { Hct.from(hue, chroma, tone) }

    /// Upstream `TonalPalette.KeyColor`: the colour of the requested hue and chroma closest to tone 50.
    private struct KeyColor {
        let hue: Double
        let requestedChroma: Double
        private static let maxChromaValue = 200.0

        func create() -> Hct {
            let pivotTone = 50
            let toneStepSize = 1
            let epsilon = 0.01
            var cache = [Int: Double]()
            func maxChroma(_ tone: Int) -> Double {
                if let c = cache[tone] { return c }
                let c = Hct.from(hue, KeyColor.maxChromaValue, Double(tone)).chroma
                cache[tone] = c
                return c
            }
            var lowerTone = 0
            var upperTone = 100
            while lowerTone < upperTone {
                let midTone = (lowerTone + upperTone) / 2
                let isAscending = maxChroma(midTone) < maxChroma(midTone + toneStepSize)
                let sufficientChroma = maxChroma(midTone) >= requestedChroma - epsilon
                if sufficientChroma {
                    if abs(lowerTone - pivotTone) < abs(upperTone - pivotTone) {
                        upperTone = midTone
                    } else {
                        if lowerTone == midTone {
                            return Hct.from(hue, requestedChroma, Double(lowerTone))
                        }
                        lowerTone = midTone
                    }
                } else {
                    if isAscending {
                        lowerTone = midTone + toneStepSize
                    } else {
                        upperTone = midTone
                    }
                }
            }
            return Hct.from(hue, requestedChroma, Double(lowerTone))
        }
    }
}

// MARK: - Contrast

enum Contrast {
    private static let contrastRatioEpsilon = 0.04
    private static let luminanceGamutMapTolerance = 0.4

    static func ratioOfYs(_ y1: Double, _ y2: Double) -> Double {
        let lighter = max(y1, y2)
        let darker = lighter == y2 ? y1 : y2
        return (lighter + 5.0) / (darker + 5.0)
    }

    static func ratioOfTones(_ t1: Double, _ t2: Double) -> Double {
        ratioOfYs(ColorUtils.yFromLstar(t1), ColorUtils.yFromLstar(t2))
    }

    static func lighter(_ tone: Double, _ ratio: Double) -> Double {
        if tone < 0.0 || tone > 100.0 { return -1.0 }
        let darkY = ColorUtils.yFromLstar(tone)
        let lightY = ratio * (darkY + 5.0) - 5.0
        if lightY < 0.0 || lightY > 100.0 { return -1.0 }
        let realContrast = ratioOfYs(lightY, darkY)
        let delta = abs(realContrast - ratio)
        if realContrast < ratio && delta > contrastRatioEpsilon { return -1.0 }
        let value = ColorUtils.lstarFromY(lightY) + luminanceGamutMapTolerance
        if value < 0 || value > 100 { return -1.0 }
        return value
    }

    static func lighterUnsafe(_ tone: Double, _ ratio: Double) -> Double {
        let safe = lighter(tone, ratio)
        return safe < 0.0 ? 100.0 : safe
    }

    static func darker(_ tone: Double, _ ratio: Double) -> Double {
        if tone < 0.0 || tone > 100.0 { return -1.0 }
        let lightY = ColorUtils.yFromLstar(tone)
        let darkY = (lightY + 5.0) / ratio - 5.0
        if darkY < 0.0 || darkY > 100.0 { return -1.0 }
        let realContrast = ratioOfYs(lightY, darkY)
        let delta = abs(realContrast - ratio)
        if realContrast < ratio && delta > contrastRatioEpsilon { return -1.0 }
        let value = ColorUtils.lstarFromY(darkY) - luminanceGamutMapTolerance
        if value < 0 || value > 100 { return -1.0 }
        return value
    }

    static func darkerUnsafe(_ tone: Double, _ ratio: Double) -> Double { max(0.0, darker(tone, ratio)) }
}

// MARK: - DislikeAnalyzer

enum DislikeAnalyzer {
    static func isDisliked(_ hct: Hct) -> Bool {
        let huePasses = ColorMath.jround(hct.hue) >= 90.0 && ColorMath.jround(hct.hue) <= 111.0
        let chromaPasses = ColorMath.jround(hct.chroma) > 16.0
        let tonePasses = ColorMath.jround(hct.tone) < 65.0
        return huePasses && chromaPasses && tonePasses
    }

    static func fixIfDisliked(_ hct: Hct) -> Hct {
        isDisliked(hct) ? Hct.from(hct.hue, hct.chroma, 70.0) : hct
    }
}

// MARK: - DynamicColor

struct ContrastCurve {
    let low: Double, normal: Double, medium: Double, high: Double

    init(_ low: Double, _ normal: Double, _ medium: Double, _ high: Double) {
        self.low = low; self.normal = normal; self.medium = medium; self.high = high
    }

    func get(_ contrastLevel: Double) -> Double {
        if contrastLevel <= -1.0 { return low }
        if contrastLevel < 0.0 { return ColorMath.lerp(low, normal, (contrastLevel - -1) / 1) }
        if contrastLevel < 0.5 { return ColorMath.lerp(normal, medium, (contrastLevel - 0) / 0.5) }
        if contrastLevel < 1.0 { return ColorMath.lerp(medium, high, (contrastLevel - 0.5) / 0.5) }
        return high
    }
}

enum TonePolarity { case darker, lighter, nearer, farther }

struct ToneDeltaPair {
    let roleA: DynamicColor
    let roleB: DynamicColor
    let delta: Double
    let polarity: TonePolarity
    let stayTogether: Bool
}

enum SchemeVariant { case monochrome, neutral, tonalSpot, vibrant, expressive, fidelity, content, rainbow, fruitSalad }

final class DynamicColor {
    let name: String
    let palette: (DynamicScheme) -> TonalPalette
    let tone: (DynamicScheme) -> Double
    let isBackground: Bool
    let background: ((DynamicScheme) -> DynamicColor)?
    let secondBackground: ((DynamicScheme) -> DynamicColor)?
    let contrastCurve: ContrastCurve?
    let toneDeltaPair: ((DynamicScheme) -> ToneDeltaPair)?
    let opacity: ((DynamicScheme) -> Double)?

    init(name: String, palette: @escaping (DynamicScheme) -> TonalPalette, tone: @escaping (DynamicScheme) -> Double,
         isBackground: Bool, background: ((DynamicScheme) -> DynamicColor)?,
         secondBackground: ((DynamicScheme) -> DynamicColor)?, contrastCurve: ContrastCurve?,
         toneDeltaPair: ((DynamicScheme) -> ToneDeltaPair)?, opacity: ((DynamicScheme) -> Double)? = nil) {
        self.name = name
        self.palette = palette
        self.tone = tone
        self.isBackground = isBackground
        self.background = background
        self.secondBackground = secondBackground
        self.contrastCurve = contrastCurve
        self.toneDeltaPair = toneDeltaPair
        self.opacity = opacity
    }

    static func fromPalette(_ name: String, _ palette: @escaping (DynamicScheme) -> TonalPalette,
                            _ tone: @escaping (DynamicScheme) -> Double, isBackground: Bool = false) -> DynamicColor {
        DynamicColor(name: name, palette: palette, tone: tone, isBackground: isBackground, background: nil,
                     secondBackground: nil, contrastCurve: nil, toneDeltaPair: nil)
    }

    func argb(_ scheme: DynamicScheme) -> ARGB {
        let argb = hct(scheme).toInt()
        guard let opacity else { return argb }
        let alpha = ColorMath.clampInt(0, 255, Int(KotlinMath.roundToLong(opacity(scheme) * 255)))
        return (argb & 0x00FF_FFFF) | ARGB(alpha) << 24
    }

    func hct(_ scheme: DynamicScheme) -> Hct { palette(scheme).hct(getTone(scheme)) }

    func getTone(_ scheme: DynamicScheme) -> Double {
        let decreasingContrast = scheme.contrastLevel < 0
        if let toneDeltaPair {
            let pair = toneDeltaPair(scheme)
            let roleA = pair.roleA, roleB = pair.roleB
            let delta = pair.delta
            let polarity = pair.polarity
            let stayTogether = pair.stayTogether
            let bg = background!(scheme)
            let bgTone = bg.getTone(scheme)
            let aIsNearer = polarity == .nearer || (polarity == .lighter && !scheme.isDark)
                || (polarity == .darker && scheme.isDark)
            let nearer = aIsNearer ? roleA : roleB
            let farther = aIsNearer ? roleB : roleA
            let amNearer = name == nearer.name
            let expansionDir: Double = scheme.isDark ? 1 : -1
            let nContrast = nearer.contrastCurve!.get(scheme.contrastLevel)
            let fContrast = farther.contrastCurve!.get(scheme.contrastLevel)
            let nInitialTone = nearer.tone(scheme)
            var nTone = Contrast.ratioOfTones(bgTone, nInitialTone) >= nContrast
                ? nInitialTone : DynamicColor.foregroundTone(bgTone, nContrast)
            let fInitialTone = farther.tone(scheme)
            var fTone = Contrast.ratioOfTones(bgTone, fInitialTone) >= fContrast
                ? fInitialTone : DynamicColor.foregroundTone(bgTone, fContrast)
            if decreasingContrast {
                nTone = DynamicColor.foregroundTone(bgTone, nContrast)
                fTone = DynamicColor.foregroundTone(bgTone, fContrast)
            }
            if (fTone - nTone) * expansionDir < delta {
                fTone = ColorMath.clampDouble(0, 100, nTone + delta * expansionDir)
                if (fTone - nTone) * expansionDir < delta {
                    nTone = ColorMath.clampDouble(0, 100, fTone - delta * expansionDir)
                }
            }
            if 50 <= nTone && nTone < 60 {
                if expansionDir > 0 {
                    nTone = 60
                    fTone = max(fTone, nTone + delta * expansionDir)
                } else {
                    nTone = 49
                    fTone = min(fTone, nTone + delta * expansionDir)
                }
            } else if 50 <= fTone && fTone < 60 {
                if stayTogether {
                    if expansionDir > 0 {
                        nTone = 60
                        fTone = max(fTone, nTone + delta * expansionDir)
                    } else {
                        nTone = 49
                        fTone = min(fTone, nTone + delta * expansionDir)
                    }
                } else {
                    fTone = expansionDir > 0 ? 60 : 49
                }
            }
            return amNearer ? nTone : fTone
        }

        var answer = tone(scheme)
        guard let background else { return answer }
        let bgTone = background(scheme).getTone(scheme)
        let desiredRatio = contrastCurve!.get(scheme.contrastLevel)
        if Contrast.ratioOfTones(bgTone, answer) < desiredRatio {
            answer = DynamicColor.foregroundTone(bgTone, desiredRatio)
        }
        if decreasingContrast {
            answer = DynamicColor.foregroundTone(bgTone, desiredRatio)
        }
        if isBackground && 50 <= answer && answer < 60 {
            answer = Contrast.ratioOfTones(49, bgTone) >= desiredRatio ? 49 : 60
        }
        if let secondBackground {
            let bgTone1 = background(scheme).getTone(scheme)
            let bgTone2 = secondBackground(scheme).getTone(scheme)
            let upper = max(bgTone1, bgTone2)
            let lower = min(bgTone1, bgTone2)
            if Contrast.ratioOfTones(upper, answer) >= desiredRatio
                && Contrast.ratioOfTones(lower, answer) >= desiredRatio {
                return answer
            }
            let lightOption = Contrast.lighter(upper, desiredRatio)
            let darkOption = Contrast.darker(lower, desiredRatio)
            var availables = [Double]()
            if lightOption != -1 { availables.append(lightOption) }
            if darkOption != -1 { availables.append(darkOption) }
            let prefersLight = DynamicColor.tonePrefersLightForeground(bgTone1)
                || DynamicColor.tonePrefersLightForeground(bgTone2)
            if prefersLight { return lightOption == -1 ? 100 : lightOption }
            if availables.count == 1 { return availables[0] }
            return darkOption == -1 ? 0 : darkOption
        }
        return answer
    }

    static func foregroundTone(_ bgTone: Double, _ ratio: Double) -> Double {
        let lighterTone = Contrast.lighterUnsafe(bgTone, ratio)
        let darkerTone = Contrast.darkerUnsafe(bgTone, ratio)
        let lighterRatio = Contrast.ratioOfTones(lighterTone, bgTone)
        let darkerRatio = Contrast.ratioOfTones(darkerTone, bgTone)
        if tonePrefersLightForeground(bgTone) {
            let negligibleDifference = abs(lighterRatio - darkerRatio) < 0.1 && lighterRatio < ratio
                && darkerRatio < ratio
            return lighterRatio >= ratio || lighterRatio >= darkerRatio || negligibleDifference
                ? lighterTone : darkerTone
        }
        return darkerRatio >= ratio || darkerRatio >= lighterRatio ? darkerTone : lighterTone
    }

    static func tonePrefersLightForeground(_ tone: Double) -> Bool { ColorMath.jround(tone) < 60 }
    static func toneAllowsLightForeground(_ tone: Double) -> Bool { ColorMath.jround(tone) <= 49 }
}

// MARK: - DynamicScheme

struct DynamicScheme {
    let sourceColorHct: Hct
    let variant: SchemeVariant
    let isDark: Bool
    let contrastLevel: Double
    let primaryPalette: TonalPalette
    let secondaryPalette: TonalPalette
    let tertiaryPalette: TonalPalette
    let neutralPalette: TonalPalette
    let neutralVariantPalette: TonalPalette
    let errorPalette: TonalPalette

    init(source: Hct, variant: SchemeVariant, isDark: Bool, contrastLevel: Double, primary: TonalPalette,
         secondary: TonalPalette, tertiary: TonalPalette, neutral: TonalPalette, neutralVariant: TonalPalette) {
        sourceColorHct = source
        self.variant = variant
        self.isDark = isDark
        self.contrastLevel = contrastLevel
        primaryPalette = primary
        secondaryPalette = secondary
        tertiaryPalette = tertiary
        neutralPalette = neutral
        neutralVariantPalette = neutralVariant
        errorPalette = TonalPalette.fromHueAndChroma(25.0, 84.0)
    }

    static func rotatedHue(_ source: Hct, hues: [Double], rotations: [Double]) -> Double {
        let sourceHue = source.hue
        if rotations.count == 1 { return ColorMath.sanitizeDegreesDouble(sourceHue + rotations[0]) }
        let size = hues.count
        var i = 0
        while i <= size - 2 {
            let thisHue = hues[i], nextHue = hues[i + 1]
            if thisHue < sourceHue && sourceHue < nextHue {
                return ColorMath.sanitizeDegreesDouble(sourceHue + rotations[i])
            }
            i += 1
        }
        return sourceHue
    }

    // Upstream `SchemeTonalSpot`, `SchemeVibrant`, `SchemeExpressive`, `SchemeFruitSalad`, `SchemeMonochrome`.

    static func tonalSpot(_ s: Hct, isDark: Bool, contrastLevel: Double = 0) -> DynamicScheme {
        DynamicScheme(source: s, variant: .tonalSpot, isDark: isDark, contrastLevel: contrastLevel,
                      primary: .fromHueAndChroma(s.hue, 36.0),
                      secondary: .fromHueAndChroma(s.hue, 16.0),
                      tertiary: .fromHueAndChroma(ColorMath.sanitizeDegreesDouble(s.hue + 60.0), 24.0),
                      neutral: .fromHueAndChroma(s.hue, 6.0),
                      neutralVariant: .fromHueAndChroma(s.hue, 8.0))
    }

    static func vibrant(_ s: Hct, isDark: Bool, contrastLevel: Double = 0) -> DynamicScheme {
        let hues: [Double] = [0, 41, 61, 101, 131, 181, 251, 301, 360]
        let secondaryRotations: [Double] = [18, 15, 10, 12, 15, 18, 15, 12, 12]
        let tertiaryRotations: [Double] = [35, 30, 20, 25, 30, 35, 30, 25, 25]
        return DynamicScheme(source: s, variant: .vibrant, isDark: isDark, contrastLevel: contrastLevel,
                             primary: .fromHueAndChroma(s.hue, 200.0),
                             secondary: .fromHueAndChroma(rotatedHue(s, hues: hues, rotations: secondaryRotations), 24.0),
                             tertiary: .fromHueAndChroma(rotatedHue(s, hues: hues, rotations: tertiaryRotations), 32.0),
                             neutral: .fromHueAndChroma(s.hue, 10.0),
                             neutralVariant: .fromHueAndChroma(s.hue, 12.0))
    }

    static func expressive(_ s: Hct, isDark: Bool, contrastLevel: Double = 0) -> DynamicScheme {
        let hues: [Double] = [0, 21, 51, 121, 151, 191, 271, 321, 360]
        let secondaryRotations: [Double] = [45, 95, 45, 20, 45, 90, 45, 45, 45]
        let tertiaryRotations: [Double] = [120, 120, 20, 45, 20, 15, 20, 120, 120]
        return DynamicScheme(source: s, variant: .expressive, isDark: isDark, contrastLevel: contrastLevel,
                             primary: .fromHueAndChroma(ColorMath.sanitizeDegreesDouble(s.hue + 240.0), 40.0),
                             secondary: .fromHueAndChroma(rotatedHue(s, hues: hues, rotations: secondaryRotations), 24.0),
                             tertiary: .fromHueAndChroma(rotatedHue(s, hues: hues, rotations: tertiaryRotations), 32.0),
                             neutral: .fromHueAndChroma(ColorMath.sanitizeDegreesDouble(s.hue + 15.0), 8.0),
                             neutralVariant: .fromHueAndChroma(ColorMath.sanitizeDegreesDouble(s.hue + 15.0), 12.0))
    }

    static func fruitSalad(_ s: Hct, isDark: Bool, contrastLevel: Double = 0) -> DynamicScheme {
        DynamicScheme(source: s, variant: .fruitSalad, isDark: isDark, contrastLevel: contrastLevel,
                      primary: .fromHueAndChroma(ColorMath.sanitizeDegreesDouble(s.hue - 50.0), 48.0),
                      secondary: .fromHueAndChroma(ColorMath.sanitizeDegreesDouble(s.hue - 50.0), 36.0),
                      tertiary: .fromHueAndChroma(s.hue, 36.0),
                      neutral: .fromHueAndChroma(s.hue, 10.0),
                      neutralVariant: .fromHueAndChroma(s.hue, 16.0))
    }

    static func monochrome(_ s: Hct, isDark: Bool, contrastLevel: Double = 0) -> DynamicScheme {
        DynamicScheme(source: s, variant: .monochrome, isDark: isDark, contrastLevel: contrastLevel,
                      primary: .fromHueAndChroma(s.hue, 0.0), secondary: .fromHueAndChroma(s.hue, 0.0),
                      tertiary: .fromHueAndChroma(s.hue, 0.0), neutral: .fromHueAndChroma(s.hue, 0.0),
                      neutralVariant: .fromHueAndChroma(s.hue, 0.0))
    }

    /// Every role the app stores, in `ColorRoles.roleNames` order (upstream `DynamicScheme` getters, which use a
    /// default `MaterialDynamicColors()` — not extended fidelity).
    func colorRoles() -> ColorRoles {
        let r = SchemeRoleRules()
        let roles: [DynamicColor] = [
            r.primary(), r.onPrimary(), r.primaryContainer(), r.onPrimaryContainer(), r.inversePrimary(),
            r.secondary(), r.onSecondary(), r.secondaryContainer(), r.onSecondaryContainer(),
            r.tertiary(), r.onTertiary(), r.tertiaryContainer(), r.onTertiaryContainer(),
            r.background(), r.onBackground(), r.surface(), r.onSurface(), r.surfaceVariant(), r.onSurfaceVariant(),
            r.surfaceTint(), r.inverseSurface(), r.inverseOnSurface(), r.error(), r.onError(), r.errorContainer(),
            r.onErrorContainer(), r.outline(), r.outlineVariant(), r.scrim(), r.surfaceBright(), r.surfaceDim(),
            r.surfaceContainer(), r.surfaceContainerHigh(), r.surfaceContainerHighest(), r.surfaceContainerLow(),
            r.surfaceContainerLowest(), r.primaryFixed(), r.primaryFixedDim(), r.onPrimaryFixed(),
            r.onPrimaryFixedVariant(), r.secondaryFixed(), r.secondaryFixedDim(), r.onSecondaryFixed(),
            r.onSecondaryFixedVariant(), r.tertiaryFixed(), r.tertiaryFixedDim(), r.onTertiaryFixed(),
            r.onTertiaryFixedVariant(),
        ]
        return ColorRoles(values: roles.map { $0.argb(self) })!
    }
}

// MARK: - Role rules (upstream `MaterialDynamicColors`)

struct SchemeRoleRules {
    var isExtendedFidelity = false

    func highestSurface(_ s: DynamicScheme) -> DynamicColor { s.isDark ? surfaceBright() : surfaceDim() }

    private func isFidelity(_ s: DynamicScheme) -> Bool {
        if isExtendedFidelity && s.variant != .monochrome && s.variant != .neutral { return true }
        return s.variant == .fidelity || s.variant == .content
    }

    private static func isMonochrome(_ s: DynamicScheme) -> Bool { s.variant == .monochrome }

    private func bg(_ s: DynamicScheme) -> DynamicColor { highestSurface(s) }

    private func make(_ name: String, _ palette: @escaping (DynamicScheme) -> TonalPalette,
                      _ tone: @escaping (DynamicScheme) -> Double, isBackground: Bool,
                      background: ((DynamicScheme) -> DynamicColor)? = nil,
                      secondBackground: ((DynamicScheme) -> DynamicColor)? = nil,
                      curve: ContrastCurve? = nil, pair: ((DynamicScheme) -> ToneDeltaPair)? = nil,
                      opacity: ((DynamicScheme) -> Double)? = nil) -> DynamicColor {
        DynamicColor(name: name, palette: palette, tone: tone, isBackground: isBackground, background: background,
                     secondBackground: secondBackground, contrastCurve: curve, toneDeltaPair: pair, opacity: opacity)
    }

    func background() -> DynamicColor {
        make("background", { $0.neutralPalette }, { $0.isDark ? 6.0 : 98.0 }, isBackground: true)
    }

    func onBackground() -> DynamicColor {
        make("on_background", { $0.neutralPalette }, { $0.isDark ? 90.0 : 10.0 }, isBackground: false,
             background: { _ in self.background() }, curve: ContrastCurve(3.0, 3.0, 4.5, 7.0))
    }

    func surface() -> DynamicColor {
        make("surface", { $0.neutralPalette }, { $0.isDark ? 6.0 : 98.0 }, isBackground: true)
    }

    func surfaceDim() -> DynamicColor {
        make("surface_dim", { $0.neutralPalette },
             { $0.isDark ? 6.0 : ContrastCurve(87.0, 87.0, 80.0, 75.0).get($0.contrastLevel) }, isBackground: true)
    }

    func surfaceBright() -> DynamicColor {
        make("surface_bright", { $0.neutralPalette },
             { $0.isDark ? ContrastCurve(24.0, 24.0, 29.0, 34.0).get($0.contrastLevel) : 98.0 }, isBackground: true)
    }

    func surfaceContainerLowest() -> DynamicColor {
        make("surface_container_lowest", { $0.neutralPalette },
             { $0.isDark ? ContrastCurve(4.0, 4.0, 2.0, 0.0).get($0.contrastLevel) : 100.0 }, isBackground: true)
    }

    func surfaceContainerLow() -> DynamicColor {
        make("surface_container_low", { $0.neutralPalette }, {
            $0.isDark ? ContrastCurve(10.0, 10.0, 11.0, 12.0).get($0.contrastLevel)
                : ContrastCurve(96.0, 96.0, 96.0, 95.0).get($0.contrastLevel)
        }, isBackground: true)
    }

    func surfaceContainer() -> DynamicColor {
        make("surface_container", { $0.neutralPalette }, {
            $0.isDark ? ContrastCurve(12.0, 12.0, 16.0, 20.0).get($0.contrastLevel)
                : ContrastCurve(94.0, 94.0, 92.0, 90.0).get($0.contrastLevel)
        }, isBackground: true)
    }

    func surfaceContainerHigh() -> DynamicColor {
        make("surface_container_high", { $0.neutralPalette }, {
            $0.isDark ? ContrastCurve(17.0, 17.0, 21.0, 25.0).get($0.contrastLevel)
                : ContrastCurve(92.0, 92.0, 88.0, 85.0).get($0.contrastLevel)
        }, isBackground: true)
    }

    func surfaceContainerHighest() -> DynamicColor {
        make("surface_container_highest", { $0.neutralPalette }, {
            $0.isDark ? ContrastCurve(22.0, 22.0, 26.0, 30.0).get($0.contrastLevel)
                : ContrastCurve(90.0, 90.0, 84.0, 80.0).get($0.contrastLevel)
        }, isBackground: true)
    }

    func onSurface() -> DynamicColor {
        make("on_surface", { $0.neutralPalette }, { $0.isDark ? 90.0 : 10.0 }, isBackground: false,
             background: { self.bg($0) }, curve: ContrastCurve(4.5, 7.0, 11.0, 21.0))
    }

    func surfaceVariant() -> DynamicColor {
        make("surface_variant", { $0.neutralVariantPalette }, { $0.isDark ? 30.0 : 90.0 }, isBackground: true)
    }

    func onSurfaceVariant() -> DynamicColor {
        make("on_surface_variant", { $0.neutralVariantPalette }, { $0.isDark ? 80.0 : 30.0 }, isBackground: false,
             background: { self.bg($0) }, curve: ContrastCurve(3.0, 4.5, 7.0, 11.0))
    }

    func inverseSurface() -> DynamicColor {
        make("inverse_surface", { $0.neutralPalette }, { $0.isDark ? 90.0 : 20.0 }, isBackground: false)
    }

    func inverseOnSurface() -> DynamicColor {
        make("inverse_on_surface", { $0.neutralPalette }, { $0.isDark ? 20.0 : 95.0 }, isBackground: false,
             background: { _ in self.inverseSurface() }, curve: ContrastCurve(4.5, 7.0, 11.0, 21.0))
    }

    func outline() -> DynamicColor {
        make("outline", { $0.neutralVariantPalette }, { $0.isDark ? 60.0 : 50.0 }, isBackground: false,
             background: { self.bg($0) }, curve: ContrastCurve(1.5, 3.0, 4.5, 7.0))
    }

    func outlineVariant() -> DynamicColor {
        make("outline_variant", { $0.neutralVariantPalette }, { $0.isDark ? 30.0 : 80.0 }, isBackground: false,
             background: { self.bg($0) }, curve: ContrastCurve(1.0, 1.0, 3.0, 4.5))
    }

    func shadow() -> DynamicColor { make("shadow", { $0.neutralPalette }, { _ in 0.0 }, isBackground: false) }

    func scrim() -> DynamicColor { make("scrim", { $0.neutralPalette }, { _ in 0.0 }, isBackground: false) }

    func surfaceTint() -> DynamicColor {
        make("surface_tint", { $0.primaryPalette }, { $0.isDark ? 80.0 : 40.0 }, isBackground: true)
    }

    func primary() -> DynamicColor {
        make("primary", { $0.primaryPalette }, { s in
            if SchemeRoleRules.isMonochrome(s) { return s.isDark ? 100.0 : 0.0 }
            return s.isDark ? 80.0 : 40.0
        }, isBackground: true, background: { self.bg($0) }, curve: ContrastCurve(3.0, 4.5, 7.0, 7.0),
             pair: { _ in ToneDeltaPair(roleA: self.primaryContainer(), roleB: self.primary(), delta: 10.0,
                                        polarity: .nearer, stayTogether: false) })
    }

    func onPrimary() -> DynamicColor {
        make("on_primary", { $0.primaryPalette }, { s in
            if SchemeRoleRules.isMonochrome(s) { return s.isDark ? 10.0 : 90.0 }
            return s.isDark ? 20.0 : 100.0
        }, isBackground: false, background: { _ in self.primary() }, curve: ContrastCurve(4.5, 7.0, 11.0, 21.0))
    }

    func primaryContainer() -> DynamicColor {
        make("primary_container", { $0.primaryPalette }, { s in
            if self.isFidelity(s) { return s.sourceColorHct.tone }
            if SchemeRoleRules.isMonochrome(s) { return s.isDark ? 85.0 : 25.0 }
            return s.isDark ? 30.0 : 90.0
        }, isBackground: true, background: { self.bg($0) }, curve: ContrastCurve(1.0, 1.0, 3.0, 4.5),
             pair: { _ in ToneDeltaPair(roleA: self.primaryContainer(), roleB: self.primary(), delta: 10.0,
                                        polarity: .nearer, stayTogether: false) })
    }

    func onPrimaryContainer() -> DynamicColor {
        make("on_primary_container", { $0.primaryPalette }, { s in
            if self.isFidelity(s) { return DynamicColor.foregroundTone(self.primaryContainer().tone(s), 4.5) }
            if SchemeRoleRules.isMonochrome(s) { return s.isDark ? 0.0 : 100.0 }
            return s.isDark ? 90.0 : 30.0
        }, isBackground: false, background: { _ in self.primaryContainer() },
             curve: ContrastCurve(3.0, 4.5, 7.0, 11.0))
    }

    func inversePrimary() -> DynamicColor {
        make("inverse_primary", { $0.primaryPalette }, { $0.isDark ? 40.0 : 80.0 }, isBackground: false,
             background: { _ in self.inverseSurface() }, curve: ContrastCurve(3.0, 4.5, 7.0, 7.0))
    }

    func secondary() -> DynamicColor {
        make("secondary", { $0.secondaryPalette }, { $0.isDark ? 80.0 : 40.0 }, isBackground: true,
             background: { self.bg($0) }, curve: ContrastCurve(3.0, 4.5, 7.0, 7.0),
             pair: { _ in ToneDeltaPair(roleA: self.secondaryContainer(), roleB: self.secondary(), delta: 10.0,
                                        polarity: .nearer, stayTogether: false) })
    }

    func onSecondary() -> DynamicColor {
        make("on_secondary", { $0.secondaryPalette }, { s in
            if SchemeRoleRules.isMonochrome(s) { return s.isDark ? 10.0 : 100.0 }
            return s.isDark ? 20.0 : 100.0
        }, isBackground: false, background: { _ in self.secondary() }, curve: ContrastCurve(4.5, 7.0, 11.0, 21.0))
    }

    func secondaryContainer() -> DynamicColor {
        make("secondary_container", { $0.secondaryPalette }, { s in
            let initialTone = s.isDark ? 30.0 : 90.0
            if SchemeRoleRules.isMonochrome(s) { return s.isDark ? 30.0 : 85.0 }
            if !self.isFidelity(s) { return initialTone }
            return SchemeRoleRules.findDesiredChromaByTone(s.secondaryPalette.hue, s.secondaryPalette.chroma,
                                                           initialTone, !s.isDark)
        }, isBackground: true, background: { self.bg($0) }, curve: ContrastCurve(1.0, 1.0, 3.0, 4.5),
             pair: { _ in ToneDeltaPair(roleA: self.secondaryContainer(), roleB: self.secondary(), delta: 10.0,
                                        polarity: .nearer, stayTogether: false) })
    }

    func onSecondaryContainer() -> DynamicColor {
        make("on_secondary_container", { $0.secondaryPalette }, { s in
            if SchemeRoleRules.isMonochrome(s) { return s.isDark ? 90.0 : 10.0 }
            if !self.isFidelity(s) { return s.isDark ? 90.0 : 30.0 }
            return DynamicColor.foregroundTone(self.secondaryContainer().tone(s), 4.5)
        }, isBackground: false, background: { _ in self.secondaryContainer() },
             curve: ContrastCurve(3.0, 4.5, 7.0, 11.0))
    }

    func tertiary() -> DynamicColor {
        make("tertiary", { $0.tertiaryPalette }, { s in
            if SchemeRoleRules.isMonochrome(s) { return s.isDark ? 90.0 : 25.0 }
            return s.isDark ? 80.0 : 40.0
        }, isBackground: true, background: { self.bg($0) }, curve: ContrastCurve(3.0, 4.5, 7.0, 7.0),
             pair: { _ in ToneDeltaPair(roleA: self.tertiaryContainer(), roleB: self.tertiary(), delta: 10.0,
                                        polarity: .nearer, stayTogether: false) })
    }

    func onTertiary() -> DynamicColor {
        make("on_tertiary", { $0.tertiaryPalette }, { s in
            if SchemeRoleRules.isMonochrome(s) { return s.isDark ? 10.0 : 90.0 }
            return s.isDark ? 20.0 : 100.0
        }, isBackground: false, background: { _ in self.tertiary() }, curve: ContrastCurve(4.5, 7.0, 11.0, 21.0))
    }

    func tertiaryContainer() -> DynamicColor {
        make("tertiary_container", { $0.tertiaryPalette }, { s in
            if SchemeRoleRules.isMonochrome(s) { return s.isDark ? 60.0 : 49.0 }
            if !self.isFidelity(s) { return s.isDark ? 30.0 : 90.0 }
            let proposed = s.tertiaryPalette.hct(s.sourceColorHct.tone)
            return DislikeAnalyzer.fixIfDisliked(proposed).tone
        }, isBackground: true, background: { self.bg($0) }, curve: ContrastCurve(1.0, 1.0, 3.0, 4.5),
             pair: { _ in ToneDeltaPair(roleA: self.tertiaryContainer(), roleB: self.tertiary(), delta: 10.0,
                                        polarity: .nearer, stayTogether: false) })
    }

    func onTertiaryContainer() -> DynamicColor {
        make("on_tertiary_container", { $0.tertiaryPalette }, { s in
            if SchemeRoleRules.isMonochrome(s) { return s.isDark ? 0.0 : 100.0 }
            if !self.isFidelity(s) { return s.isDark ? 90.0 : 30.0 }
            return DynamicColor.foregroundTone(self.tertiaryContainer().tone(s), 4.5)
        }, isBackground: false, background: { _ in self.tertiaryContainer() },
             curve: ContrastCurve(3.0, 4.5, 7.0, 11.0))
    }

    func error() -> DynamicColor {
        make("error", { $0.errorPalette }, { $0.isDark ? 80.0 : 40.0 }, isBackground: true,
             background: { self.bg($0) }, curve: ContrastCurve(3.0, 4.5, 7.0, 7.0),
             pair: { _ in ToneDeltaPair(roleA: self.errorContainer(), roleB: self.error(), delta: 10.0,
                                        polarity: .nearer, stayTogether: false) })
    }

    func onError() -> DynamicColor {
        make("on_error", { $0.errorPalette }, { $0.isDark ? 20.0 : 100.0 }, isBackground: false,
             background: { _ in self.error() }, curve: ContrastCurve(4.5, 7.0, 11.0, 21.0))
    }

    func errorContainer() -> DynamicColor {
        make("error_container", { $0.errorPalette }, { $0.isDark ? 30.0 : 90.0 }, isBackground: true,
             background: { self.bg($0) }, curve: ContrastCurve(1.0, 1.0, 3.0, 4.5),
             pair: { _ in ToneDeltaPair(roleA: self.errorContainer(), roleB: self.error(), delta: 10.0,
                                        polarity: .nearer, stayTogether: false) })
    }

    func onErrorContainer() -> DynamicColor {
        make("on_error_container", { $0.errorPalette }, { s in
            if SchemeRoleRules.isMonochrome(s) { return s.isDark ? 90.0 : 10.0 }
            return s.isDark ? 90.0 : 30.0
        }, isBackground: false, background: { _ in self.errorContainer() }, curve: ContrastCurve(3.0, 4.5, 7.0, 11.0))
    }

    func primaryFixed() -> DynamicColor {
        make("primary_fixed", { $0.primaryPalette }, { SchemeRoleRules.isMonochrome($0) ? 40.0 : 90.0 },
             isBackground: true, background: { self.bg($0) }, curve: ContrastCurve(1.0, 1.0, 3.0, 4.5),
             pair: { _ in ToneDeltaPair(roleA: self.primaryFixed(), roleB: self.primaryFixedDim(), delta: 10.0,
                                        polarity: .lighter, stayTogether: true) })
    }

    func primaryFixedDim() -> DynamicColor {
        make("primary_fixed_dim", { $0.primaryPalette }, { SchemeRoleRules.isMonochrome($0) ? 30.0 : 80.0 },
             isBackground: true, background: { self.bg($0) }, curve: ContrastCurve(1.0, 1.0, 3.0, 4.5),
             pair: { _ in ToneDeltaPair(roleA: self.primaryFixed(), roleB: self.primaryFixedDim(), delta: 10.0,
                                        polarity: .lighter, stayTogether: true) })
    }

    func onPrimaryFixed() -> DynamicColor {
        make("on_primary_fixed", { $0.primaryPalette }, { SchemeRoleRules.isMonochrome($0) ? 100.0 : 10.0 },
             isBackground: false, background: { _ in self.primaryFixedDim() },
             secondBackground: { _ in self.primaryFixed() }, curve: ContrastCurve(4.5, 7.0, 11.0, 21.0))
    }

    func onPrimaryFixedVariant() -> DynamicColor {
        make("on_primary_fixed_variant", { $0.primaryPalette }, { SchemeRoleRules.isMonochrome($0) ? 90.0 : 30.0 },
             isBackground: false, background: { _ in self.primaryFixedDim() },
             secondBackground: { _ in self.primaryFixed() }, curve: ContrastCurve(3.0, 4.5, 7.0, 11.0))
    }

    func secondaryFixed() -> DynamicColor {
        make("secondary_fixed", { $0.secondaryPalette }, { SchemeRoleRules.isMonochrome($0) ? 80.0 : 90.0 },
             isBackground: true, background: { self.bg($0) }, curve: ContrastCurve(1.0, 1.0, 3.0, 4.5),
             pair: { _ in ToneDeltaPair(roleA: self.secondaryFixed(), roleB: self.secondaryFixedDim(), delta: 10.0,
                                        polarity: .lighter, stayTogether: true) })
    }

    func secondaryFixedDim() -> DynamicColor {
        make("secondary_fixed_dim", { $0.secondaryPalette }, { SchemeRoleRules.isMonochrome($0) ? 70.0 : 80.0 },
             isBackground: true, background: { self.bg($0) }, curve: ContrastCurve(1.0, 1.0, 3.0, 4.5),
             pair: { _ in ToneDeltaPair(roleA: self.secondaryFixed(), roleB: self.secondaryFixedDim(), delta: 10.0,
                                        polarity: .lighter, stayTogether: true) })
    }

    func onSecondaryFixed() -> DynamicColor {
        make("on_secondary_fixed", { $0.secondaryPalette }, { _ in 10.0 }, isBackground: false,
             background: { _ in self.secondaryFixedDim() }, secondBackground: { _ in self.secondaryFixed() },
             curve: ContrastCurve(4.5, 7.0, 11.0, 21.0))
    }

    func onSecondaryFixedVariant() -> DynamicColor {
        make("on_secondary_fixed_variant", { $0.secondaryPalette }, { SchemeRoleRules.isMonochrome($0) ? 25.0 : 30.0 },
             isBackground: false, background: { _ in self.secondaryFixedDim() },
             secondBackground: { _ in self.secondaryFixed() }, curve: ContrastCurve(3.0, 4.5, 7.0, 11.0))
    }

    func tertiaryFixed() -> DynamicColor {
        make("tertiary_fixed", { $0.tertiaryPalette }, { SchemeRoleRules.isMonochrome($0) ? 40.0 : 90.0 },
             isBackground: true, background: { self.bg($0) }, curve: ContrastCurve(1.0, 1.0, 3.0, 4.5),
             pair: { _ in ToneDeltaPair(roleA: self.tertiaryFixed(), roleB: self.tertiaryFixedDim(), delta: 10.0,
                                        polarity: .lighter, stayTogether: true) })
    }

    func tertiaryFixedDim() -> DynamicColor {
        make("tertiary_fixed_dim", { $0.tertiaryPalette }, { SchemeRoleRules.isMonochrome($0) ? 30.0 : 80.0 },
             isBackground: true, background: { self.bg($0) }, curve: ContrastCurve(1.0, 1.0, 3.0, 4.5),
             pair: { _ in ToneDeltaPair(roleA: self.tertiaryFixed(), roleB: self.tertiaryFixedDim(), delta: 10.0,
                                        polarity: .lighter, stayTogether: true) })
    }

    func onTertiaryFixed() -> DynamicColor {
        make("on_tertiary_fixed", { $0.tertiaryPalette }, { SchemeRoleRules.isMonochrome($0) ? 100.0 : 10.0 },
             isBackground: false, background: { _ in self.tertiaryFixedDim() },
             secondBackground: { _ in self.tertiaryFixed() }, curve: ContrastCurve(4.5, 7.0, 11.0, 21.0))
    }

    func onTertiaryFixedVariant() -> DynamicColor {
        make("on_tertiary_fixed_variant", { $0.tertiaryPalette }, { SchemeRoleRules.isMonochrome($0) ? 90.0 : 30.0 },
             isBackground: false, background: { _ in self.tertiaryFixedDim() },
             secondBackground: { _ in self.tertiaryFixed() }, curve: ContrastCurve(3.0, 4.5, 7.0, 11.0))
    }

    static func findDesiredChromaByTone(_ hue: Double, _ chroma: Double, _ tone: Double,
                                        _ byDecreasingTone: Bool) -> Double {
        var answer = tone
        var closestToChroma = Hct.from(hue, chroma, tone)
        if closestToChroma.chroma < chroma {
            var chromaPeak = closestToChroma.chroma
            while closestToChroma.chroma < chroma {
                answer += byDecreasingTone ? -1.0 : 1.0
                let potential = Hct.from(hue, chroma, answer)
                if chromaPeak > potential.chroma { break }
                if abs(potential.chroma - chroma) < 0.4 { break }
                let potentialDelta = abs(potential.chroma - chroma)
                let currentDelta = abs(closestToChroma.chroma - chroma)
                if potentialDelta < currentDelta { closestToChroma = potential }
                chromaPeak = max(chromaPeak, potential.chroma)
            }
        }
        return answer
    }
}
