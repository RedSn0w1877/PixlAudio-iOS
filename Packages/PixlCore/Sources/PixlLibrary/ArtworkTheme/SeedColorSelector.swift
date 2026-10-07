// Seed-colour selection and scheme generation, ported line for line from the Android app's
// `ui/theme/ColorRoles.kt` (`selectSeedColorArgbFromPixels`, `scoreQuantizedColors`, the representative-colour and
// refinement passes, `generateColorSchemeFromSeed`, `toGrayscaleColorScheme`). Float arithmetic stays Float where
// Kotlin uses Float (`lerpFloat`, `blendArgb`), so the rounding matches.

import Foundation
import PixlFoundation

/// Android `ColorScoringConfig` (defaults).
struct ColorScoringConfig {
    var targetChroma = 48.0
    var weightProportion = 0.7
    var weightChromaAbove = 0.3
    var weightChromaBelow = 0.1
    var cutoffChroma = 5.0
    var cutoffExcitedProportion = 0.01
    var maxColorCount = 4
    var maxHueDifference = 90
    var minHueDifference = 15
}

enum SeedColorSelector {
    // Android ColorRoles.kt constants.
    static let quantizerMaxColors = 128
    static let grayscaleChromaThreshold = 12.0
    static let neutralPixelChromaThreshold = 8.0
    static let highChromaThreshold = 18.0
    static let requiredNeutralPopulation = 0.92
    static let maxHighChromaPopulation = 0.03
    static let maxWeightedChromaForNeutral = 9.0
    static let maxGrayscaleChannelDelta = 10
    static let representativePixelChromaThreshold = 10.0
    static let minRepresentativePixelRatio = 0.04
    static let minRefinementPixelRatio = 0.08
    static let minVisibleRgbSum = 36
    static let minVisiblePixelAlpha = 28
    static let fidelityHueWindow = 90.0
    static let fidelityChromaWindow = 32.0
    static let fidelityToneWindow = 28.0
    static let fidelityHueWeight = 18.0
    static let fidelityChromaWeight = 7.0
    static let fidelityToneWeight = 3.0
    static let accurateFidelityHueWindow = 52.0
    static let accurateFidelityChromaWindow = 18.0
    static let accurateFidelityToneWindow = 18.0
    static let accurateFidelityHueWeight = 28.0
    static let accurateFidelityChromaWeight = 14.0
    static let accurateFidelityToneWeight = 6.0
    static let excessChromaPenaltyStart = 18.0
    static let excessChromaPenaltyWeight = 0.18
    static let accurateExcessChromaPenaltyStart = 8.0
    static let accurateExcessChromaPenaltyWeight = 0.38
    static let localRefinementHueWindow = 32.0
    static let localRefinementBlendRatio: Float = 0.42
    static let accurateLocalRefinementHueWindow = 18.0
    static let accurateLocalRefinementBlendRatio: Float = 0.72
    static let accurateRepresentativeBlendRatio: Float = 0.42
    static let accurateRepresentativePixelChromaThreshold = 6.0
    static let accurateChromaAboveWeight = 0.14
    static let accurateChromaBelowWeight = 0.04
    static let accurateCutoffChroma = 3.5
    static let accurateMaxHueDifference = 64
    static let accurateMinHueDifference = 10

    /// Android `DarkColorScheme.primary` (`PixelPlayPurplePrimary`): the fallback when extraction throws.
    static let fallbackSeed: ARGB = 0xFFAB_47BC

    private struct Representative {
        let argb: ARGB
        let hct: Hct
    }

    /// Android `selectSeedColorArgbFromPixels` (wrapped in `extractSeedColor`'s `runCatching`).
    static func select(pixels: [ARGB], accuracyLevel: Int, scoring: ColorScoringConfig = ColorScoringConfig()) -> ARGB {
        let accuracy = Double(ArtworkColorAccuracy.clamp(accuracyLevel)) / Double(ArtworkColorAccuracy.max)
        let fallback = averageColorArgb(pixels)
        guard let quantized = QuantizerCelebi.quantize(pixels, maxColors: quantizerMaxColors) else {
            return fallbackSeed
        }
        if isMostlyNeutralArtwork(quantized) && isArgbNearGrayscale(fallback) {
            return fallback
        }
        let representative = representativeColor(pixels, accuracy: accuracy)
        let ranked = scoreQuantizedColors(quantized, scoring: scoring, fallback: fallback,
                                          representative: representative, accuracy: accuracy)
        let selected = ranked.first ?? fallback
        return refineSeedColor(candidate: selected, pixels: pixels, representative: representative,
                               cutoffChroma: scoring.cutoffChroma, accuracy: accuracy)
    }

    private static func scoreQuantizedColors(_ colorsToPopulation: ColorPopulation, scoring: ColorScoringConfig,
                                             fallback: ARGB, representative: Representative?,
                                             accuracy: Double) -> [ARGB] {
        if colorsToPopulation.isEmpty { return [fallback] }
        var colorsHct = [Hct]()
        colorsHct.reserveCapacity(colorsToPopulation.count)
        var huePopulation = [Int](repeating: 0, count: 360)
        var populationSum = 0.0
        for (argb, population) in zip(colorsToPopulation.colors, colorsToPopulation.counts) {
            if population <= 0 { continue }
            let hct = Hct.fromInt(argb)
            colorsHct.append(hct)
            let hue = ColorMath.sanitizeDegreesInt(Int(KotlinMath.toInt(hct.hue.rounded(.down))))
            huePopulation[hue] += population
            populationSum += Double(population)
        }
        if populationSum <= 0.0 { return [fallback] }

        let effectiveCutoffChroma = lerp(scoring.cutoffChroma, accurateCutoffChroma, accuracy)
        let effectiveTargetChroma: Double
        if let representative {
            effectiveTargetChroma = lerp(scoring.targetChroma, representative.hct.chroma.coerced(in: 12.0, 72.0),
                                         accuracy * 0.92)
        } else {
            effectiveTargetChroma = scoring.targetChroma
        }
        let chromaAboveWeight = lerp(scoring.weightChromaAbove, accurateChromaAboveWeight, accuracy)
        let chromaBelowWeight = lerp(scoring.weightChromaBelow, accurateChromaBelowWeight, accuracy)

        var hueExcitedProportions = [Double](repeating: 0, count: 360)
        for hue in 0..<360 {
            let proportion = Double(huePopulation[hue]) / populationSum
            for neighbor in (hue - 14)...(hue + 15) {
                hueExcitedProportions[ColorMath.sanitizeDegreesInt(neighbor)] += proportion
            }
        }

        var scored = [(hct: Hct, score: Double)]()
        scored.reserveCapacity(colorsHct.count)
        for hct in colorsHct {
            let hue = ColorMath.sanitizeDegreesInt(Int(KotlinMath.roundToLong(hct.hue)))
            let excitedProportion = hueExcitedProportions[hue]
            if hct.chroma < effectiveCutoffChroma || excitedProportion <= scoring.cutoffExcitedProportion { continue }
            let proportionScore = excitedProportion * 100.0 * scoring.weightProportion
            let chromaWeight = hct.chroma < effectiveTargetChroma ? chromaBelowWeight : chromaAboveWeight
            let chromaScore = (hct.chroma - effectiveTargetChroma) * chromaWeight
            let fidelityScore = representative.map { fidelity(hct, $0.hct, accuracy) } ?? 0.0
            let excessPenalty = representative.map { excessChromaPenalty(hct, $0.hct, accuracy) } ?? 0.0
            scored.append((hct, proportionScore + chromaScore + fidelityScore - excessPenalty))
        }
        if scored.isEmpty { return [fallback] }
        // Kotlin sortByDescending: stable.
        scored = stableSortedDescending(scored)

        let minHueDifference = max(1, Int(KotlinMath.roundToLong(
            lerp(Double(scoring.minHueDifference), Double(accurateMinHueDifference), accuracy))))
        let maxHueDifference = max(minHueDifference, Int(KotlinMath.roundToLong(
            lerp(Double(scoring.maxHueDifference), Double(accurateMaxHueDifference), accuracy))))
        let desiredColorCount = max(1, scoring.maxColorCount)
        var chosen = [Hct]()
        var differenceDegrees = maxHueDifference
        while differenceDegrees >= minHueDifference {
            chosen.removeAll(keepingCapacity: true)
            for candidate in scored {
                let isDuplicateHue = chosen.contains {
                    ColorMath.differenceDegrees(candidate.hct.hue, $0.hue) < Double(differenceDegrees)
                }
                if !isDuplicateHue { chosen.append(candidate.hct) }
                if chosen.count >= desiredColorCount { break }
            }
            if chosen.count >= desiredColorCount { break }
            differenceDegrees -= 1
        }
        if chosen.isEmpty { return [fallback] }
        return chosen.map { $0.toInt() }
    }

    private static func stableSortedDescending(_ items: [(hct: Hct, score: Double)]) -> [(hct: Hct, score: Double)] {
        items.enumerated().sorted { a, b in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            return a.offset < b.offset
        }.map(\.element)
    }

    private static func representativeColor(_ pixels: [ARGB], accuracy: Double) -> Representative? {
        if pixels.isEmpty { return nil }
        var totalRed = 0.0, totalGreen = 0.0, totalBlue = 0.0, totalWeight = 0.0
        var count = 0
        let chromaThreshold = lerp(representativePixelChromaThreshold, accurateRepresentativePixelChromaThreshold,
                                   accuracy)
        let chromaWeightMultiplier = lerp(1.0, 0.42, accuracy)
        for argb in pixels {
            if ColorUtils.alpha(argb) < minVisiblePixelAlpha { continue }
            let red = ColorUtils.red(argb), green = ColorUtils.green(argb), blue = ColorUtils.blue(argb)
            if red + green + blue <= minVisibleRgbSum { continue }
            let hct = Hct.fromInt(argb)
            if hct.chroma < chromaThreshold { continue }
            let weight = 1.0 + ((hct.chroma - chromaThreshold) / 24.0).coerced(atLeast: 0.0) * chromaWeightMultiplier
                + hct.tone / 100.0
            totalRed += Double(red) * weight
            totalGreen += Double(green) * weight
            totalBlue += Double(blue) * weight
            totalWeight += weight
            count += 1
        }
        if totalWeight <= 0.0 { return nil }
        if Double(count) / Double(pixels.count) < minRepresentativePixelRatio { return nil }
        let argb = opaque(totalRed / totalWeight, totalGreen / totalWeight, totalBlue / totalWeight)
        return Representative(argb: argb, hct: Hct.fromInt(argb))
    }

    private static func fidelity(_ candidate: Hct, _ representative: Hct, _ accuracy: Double) -> Double {
        let hueDistance = ColorMath.differenceDegrees(candidate.hue, representative.hue)
        let chromaDistance = abs(candidate.chroma - representative.chroma)
        let toneDistance = abs(candidate.tone - representative.tone)
        let hueWindow = lerp(fidelityHueWindow, accurateFidelityHueWindow, accuracy)
        let chromaWindow = lerp(fidelityChromaWindow, accurateFidelityChromaWindow, accuracy)
        let toneWindow = lerp(fidelityToneWindow, accurateFidelityToneWindow, accuracy)
        let hueWeight = lerp(fidelityHueWeight, accurateFidelityHueWeight, accuracy)
        let chromaWeight = lerp(fidelityChromaWeight, accurateFidelityChromaWeight, accuracy)
        let toneWeight = lerp(fidelityToneWeight, accurateFidelityToneWeight, accuracy)
        let hueScore = ((hueWindow - hueDistance).coerced(atLeast: 0.0) / hueWindow) * hueWeight
        let chromaScore = ((chromaWindow - chromaDistance).coerced(atLeast: 0.0) / chromaWindow) * chromaWeight
        let toneScore = ((toneWindow - toneDistance).coerced(atLeast: 0.0) / toneWindow) * toneWeight
        return hueScore + chromaScore + toneScore
    }

    private static func excessChromaPenalty(_ candidate: Hct, _ representative: Hct, _ accuracy: Double) -> Double {
        let start = lerp(excessChromaPenaltyStart, accurateExcessChromaPenaltyStart, accuracy)
        let weight = lerp(excessChromaPenaltyWeight, accurateExcessChromaPenaltyWeight, accuracy)
        let excess = candidate.chroma - representative.chroma - start
        return excess <= 0.0 ? 0.0 : excess * weight
    }

    private static func refineSeedColor(candidate: ARGB, pixels: [ARGB], representative: Representative?,
                                        cutoffChroma: Double, accuracy: Double) -> ARGB {
        if pixels.isEmpty { return candidate }
        let candidateHct = Hct.fromInt(candidate)
        let effectiveCutoffChroma = lerp(cutoffChroma, accurateCutoffChroma, accuracy)
        let localHueWindow = lerp(localRefinementHueWindow, accurateLocalRefinementHueWindow, accuracy)
        let localBlendRatio = lerpFloat(localRefinementBlendRatio, accurateLocalRefinementBlendRatio, Float(accuracy))
        let representativeBlendRatio = lerpFloat(localRefinementBlendRatio / 2, accurateRepresentativeBlendRatio,
                                                 Float(accuracy))
        var totalRed = 0.0, totalGreen = 0.0, totalBlue = 0.0, totalWeight = 0.0
        var matching = 0
        for argb in pixels {
            if ColorUtils.alpha(argb) < minVisiblePixelAlpha { continue }
            let red = ColorUtils.red(argb), green = ColorUtils.green(argb), blue = ColorUtils.blue(argb)
            if red + green + blue <= minVisibleRgbSum { continue }
            let hct = Hct.fromInt(argb)
            if hct.chroma < effectiveCutoffChroma { continue }
            let hueDistance = ColorMath.differenceDegrees(candidateHct.hue, hct.hue)
            if hueDistance > localHueWindow { continue }
            let weight = 1.0 + (localHueWindow - hueDistance) / localHueWindow
                + ((hct.chroma - effectiveCutoffChroma) / 32.0).coerced(atLeast: 0.0)
            totalRed += Double(red) * weight
            totalGreen += Double(green) * weight
            totalBlue += Double(blue) * weight
            totalWeight += weight
            matching += 1
        }
        if totalWeight <= 0.0 { return candidate }
        if Double(matching) / Double(pixels.count) < minRefinementPixelRatio { return candidate }
        let localAverage = opaque(totalRed / totalWeight, totalGreen / totalWeight, totalBlue / totalWeight)
        let localAverageHct = Hct.fromInt(localAverage)
        if ColorMath.differenceDegrees(candidateHct.hue, localAverageHct.hue) > localHueWindow { return candidate }
        let refined = blendArgb(candidate, localAverage, localBlendRatio)
        guard let representative else { return refined }
        let fidelityHueWindowValue = lerp(fidelityHueWindow, accurateFidelityHueWindow, accuracy)
        if ColorMath.differenceDegrees(localAverageHct.hue, representative.hct.hue) <= fidelityHueWindowValue {
            return blendArgb(refined, representative.argb, representativeBlendRatio)
        }
        return refined
    }

    /// `(0xFF shl 24) or (r.roundToInt().coerceIn(0, 255) shl 16) …` from double channel means.
    private static func opaque(_ r: Double, _ g: Double, _ b: Double) -> ARGB {
        func channel(_ v: Double) -> ARGB { ARGB(Int(KotlinMath.roundToLong(v)).coerced(in: 0, 255)) }
        return 0xFF00_0000 | channel(r) << 16 | channel(g) << 8 | channel(b)
    }

    /// Android `blendArgb` (Float maths, `Float.roundToInt()`).
    static func blendArgb(_ first: ARGB, _ second: ARGB, _ ratio: Float) -> ARGB {
        let clamped = ratio.coerced(in: 0, 1)
        let inverse = 1 - clamped
        func mix(_ shift: ARGB) -> ARGB {
            let a = Float((first >> shift) & 0xFF), b = Float((second >> shift) & 0xFF)
            return ARGB(Int(KotlinMath.roundToInt(a * inverse + b * clamped)).coerced(in: 0, 255))
        }
        return mix(24) << 24 | mix(16) << 16 | mix(8) << 8 | mix(0)
    }

    private static func lerp(_ start: Double, _ stop: Double, _ fraction: Double) -> Double {
        start + (stop - start) * fraction.coerced(in: 0.0, 1.0)
    }

    private static func lerpFloat(_ start: Float, _ stop: Float, _ fraction: Float) -> Float {
        start + (stop - start) * fraction.coerced(in: 0, 1)
    }

    /// Android `averageColorArgb` (Long sums, truncating division).
    static func averageColorArgb(_ pixels: [ARGB]) -> ARGB {
        if pixels.isEmpty { return fallbackSeed }
        var r: Int64 = 0, g: Int64 = 0, b: Int64 = 0
        for p in pixels {
            r += Int64(ColorUtils.red(p))
            g += Int64(ColorUtils.green(p))
            b += Int64(ColorUtils.blue(p))
        }
        let n = Int64(pixels.count)
        return 0xFF00_0000 | ARGB(r / n) << 16 | ARGB(g / n) << 8 | ARGB(b / n)
    }

    private static func isMostlyNeutralArtwork(_ population: ColorPopulation) -> Bool {
        if population.isEmpty { return false }
        var total = 0.0, neutral = 0.0, highChroma = 0.0, weightedChroma = 0.0
        for (argb, countInt) in zip(population.colors, population.counts) {
            if countInt <= 0 { continue }
            let count = Double(countInt)
            let chroma = Hct.fromInt(argb).chroma
            total += count
            weightedChroma += chroma * count
            if chroma <= neutralPixelChromaThreshold { neutral += count }
            if chroma >= highChromaThreshold { highChroma += count }
        }
        if total <= 0.0 { return false }
        return neutral / total >= requiredNeutralPopulation && highChroma / total <= maxHighChromaPopulation
            && weightedChroma / total <= maxWeightedChromaForNeutral
    }

    static func isArgbNearGrayscale(_ argb: ARGB) -> Bool {
        let r = ColorUtils.red(argb), g = ColorUtils.green(argb), b = ColorUtils.blue(argb)
        return max(abs(r - g), abs(g - b), abs(r - b)) <= maxGrayscaleChannelDelta
    }
}

/// Android `generateColorSchemeFromSeed` / `generateMonochromeColorSchemeFromSeed`.
enum SchemeBuilder {
    /// Android's own fallback pair (`ColorSchemePair(LightColorScheme, DarkColorScheme)`) is only reached when the
    /// colour utilities throw, which the Swift port never does; kept for parity of intent.
    static func pair(seed: ARGB, style: ArtworkPaletteStyle) -> ColorRolesPair {
        let source = Hct.fromInt(seed)
        let forceNeutral = source.chroma <= SeedColorSelector.grayscaleChromaThreshold
            && SeedColorSelector.isArgbNearGrayscale(seed)
        let light = scheme(source, style: style, isDark: false).colorRoles()
        let dark = scheme(source, style: style, isDark: true).colorRoles()
        if forceNeutral {
            return ColorRolesPair(light: light.map(grayscale), dark: dark.map(grayscale))
        }
        return ColorRolesPair(light: light, dark: dark)
    }

    /// The app-wide accent scheme (iOS-only, owner request 2026-10-07; no Android counterpart): TonalSpot's
    /// secondary, tertiary and neutral palettes and its role tones, but the primary palette keeps the seed's own
    /// chroma (never below TonalSpot's 36). A picked red stays a real red in light mode instead of TonalSpot's brick;
    /// a muted pick stays muted. Contrast still comes from the fixed role tones (primary 40 / 80 against the
    /// background), so every seed is as legible as the brand scheme. Dark tones (80) are gamut-limited and come out
    /// pastel, much like TonalSpot's.
    ///
    /// Near-grey seeds (the same test as `pair`, e.g. the Graphite preset) give pure greys: every palette at chroma 0,
    /// so each role is the exact grey of its tone (error stays red). `pair` instead maps the tinted roles through
    /// Android's HSL grayscale, which can land a hair under 4.5:1 for `primary` on the background; the accent has no
    /// Android counterpart to match, so it keeps the scheme's contrast exactly.
    static func accentPair(seed: ARGB) -> ColorRolesPair {
        let source = Hct.fromInt(seed)
        let forceNeutral = source.chroma <= SeedColorSelector.grayscaleChromaThreshold
            && SeedColorSelector.isArgbNearGrayscale(seed)
        func roles(isDark: Bool) -> ColorRoles {
            if forceNeutral {
                let grey = TonalPalette.fromHueAndChroma(source.hue, 0.0)
                return DynamicScheme(source: source, variant: .tonalSpot, isDark: isDark, contrastLevel: 0,
                                     primary: grey, secondary: grey, tertiary: grey, neutral: grey,
                                     neutralVariant: grey).colorRoles()
            }
            let base = DynamicScheme.tonalSpot(source, isDark: isDark)
            return DynamicScheme(source: source, variant: .tonalSpot, isDark: isDark, contrastLevel: 0,
                                 primary: .fromHueAndChroma(source.hue, max(36.0, source.chroma)),
                                 secondary: base.secondaryPalette, tertiary: base.tertiaryPalette,
                                 neutral: base.neutralPalette, neutralVariant: base.neutralVariantPalette).colorRoles()
        }
        return ColorRolesPair(light: roles(isDark: false), dark: roles(isDark: true))
    }

    static func monochromePair(seed: ARGB) -> ColorRolesPair {
        let source = Hct.fromInt(seed)
        return ColorRolesPair(light: DynamicScheme.monochrome(source, isDark: false).colorRoles(),
                              dark: DynamicScheme.monochrome(source, isDark: true).colorRoles())
    }

    static func scheme(_ source: Hct, style: ArtworkPaletteStyle, isDark: Bool) -> DynamicScheme {
        switch style {
        case .tonalSpot: DynamicScheme.tonalSpot(source, isDark: isDark)
        case .vibrant: DynamicScheme.vibrant(source, isDark: isDark)
        case .expressive: DynamicScheme.expressive(source, isDark: isDark)
        case .fruitSalad: DynamicScheme.fruitSalad(source, isDark: isDark)
        }
    }

    /// Android `toGrayscaleColorScheme`'s `convert`: AndroidX `ColorUtils.colorToHSL`, hue and saturation zeroed,
    /// `HSLToColor` (Float maths; `Color.rgb`, so the result is opaque).
    static func grayscale(_ argb: ARGB) -> ARGB {
        let r = Float(ColorUtils.red(argb)) / 255, g = Float(ColorUtils.green(argb)) / 255
        let b = Float(ColorUtils.blue(argb)) / 255
        let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
        let l = (maxC + minC) / 2
        // HSLToColor with s = 0: c = (1 - |2l - 1|) * 0 = 0, m = l - c/2 = l → every channel = round(l * 255).
        let c = (1 - abs(2 * l - 1)) * 0
        let m = l - 0.5 * c
        let v = ARGB(Int(KotlinMath.roundToInt(m * 255)).coerced(in: 0, 255))
        return 0xFF00_0000 | v << 16 | v << 8 | v
    }
}
