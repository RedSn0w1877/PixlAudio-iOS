import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel
import SwiftUI

// Genre colours, illustrations and the library's genre list for Search's browse grid. Ports of the Android app's
// `ui/theme/GenreColors.kt` (`GenreThemeUtils`), `presentation/utils/GenreIconProvider.kt` and
// `MusicRepositoryImpl.getGenres` / `buildGenre`. Other stages that show genres (genre detail, quick fill) should
// reuse these rather than port them again.

/// A genre card's colours as ARGB (Android `GenreThemeColor`).
nonisolated struct GenreThemeColor: Hashable, Sendable {
    let container: UInt32
    let onContainer: UInt32
}

/// Android `GenreThemeUtils.getGenreThemeColor`: a fixed palette picked by the genre id's Java `hashCode`.
nonisolated enum GenreCardPalette {
    static let unknownLight = GenreThemeColor(container: 0xFFE5E5EA, onContainer: 0xFF1B1B20)
    static let unknownDark = GenreThemeColor(container: 0xFF3A3B42, onContainer: 0xFFF2F1F6)

    static let dark: [GenreThemeColor] = [
        .init(container: 0xFF004A77, onContainer: 0xFFC2E7FF), // Blue
        .init(container: 0xFF7D5260, onContainer: 0xFFFFD8E4), // Rose
        .init(container: 0xFF633B48, onContainer: 0xFFFFD8EC), // Pink
        .init(container: 0xFF004F58, onContainer: 0xFF88FAFF), // Cyan
        .init(container: 0xFF324F34, onContainer: 0xFFCBEFD0), // Green
        .init(container: 0xFF6E4E13, onContainer: 0xFFFFDEAC), // Gold/Orange
        .init(container: 0xFF3F474D, onContainer: 0xFFDEE3EB), // Slate
        .init(container: 0xFF4A4458, onContainer: 0xFFE8DEF8), // Purple
        .init(container: 0xFF7D2B2B, onContainer: 0xFFFFB4AB), // Red
        .init(container: 0xFF5B6300, onContainer: 0xFFDDF669), // Lime
        .init(container: 0xFF005047, onContainer: 0xFF8CF4E6), // Teal
        .init(container: 0xFF4F378B, onContainer: 0xFFEADDFF), // Indigo
        .init(container: 0xFF8B4A62, onContainer: 0xFFFFD9E2), // Maroon
        .init(container: 0xFF725C00, onContainer: 0xFFFFE084), // Yellow
        .init(container: 0xFF00213B, onContainer: 0xFF99CBFF), // Navy
        .init(container: 0xFF23507D, onContainer: 0xFFD1E4FF), // Steel Blue
        .init(container: 0xFF93000A, onContainer: 0xFFFFDAD6), // Brick Red
        .init(container: 0xFF45464F, onContainer: 0xFFC4C6D0), // Grey
        .init(container: 0xFF5D3F75, onContainer: 0xFFE8B6FF), // Violet
        .init(container: 0xFF7A5900, onContainer: 0xFFFFDEA5), // Amber
    ]

    static let light: [GenreThemeColor] = [
        .init(container: 0xFFD7E3FF, onContainer: 0xFF005AC1), // Blue
        .init(container: 0xFFFFD8E4, onContainer: 0xFF631835), // Rose
        .init(container: 0xFFFFD8EC, onContainer: 0xFF631B4B), // Pink
        .init(container: 0xFFCCE8EA, onContainer: 0xFF004F58), // Cyan
        .init(container: 0xFFCBEFD0, onContainer: 0xFF042106), // Green
        .init(container: 0xFFFFDEAC, onContainer: 0xFF281900), // Gold/Orange
        .init(container: 0xFFEFF1F7, onContainer: 0xFF44474F), // Slate
        .init(container: 0xFFE8DEF8, onContainer: 0xFF1D192B), // Purple
        .init(container: 0xFFFFB4AB, onContainer: 0xFF690005), // Red
        .init(container: 0xFFDDF669, onContainer: 0xFF2F3300), // Lime
        .init(container: 0xFF8CF4E6, onContainer: 0xFF00201C), // Teal
        .init(container: 0xFFEADDFF, onContainer: 0xFF21005D), // Indigo
        .init(container: 0xFFFFD9E2, onContainer: 0xFF3B071D), // Maroon
        .init(container: 0xFFFFE084, onContainer: 0xFF231B00), // Yellow
        .init(container: 0xFF99CBFF, onContainer: 0xFF003258), // Navy
        .init(container: 0xFFD1E4FF, onContainer: 0xFF051C36), // Steel Blue
        .init(container: 0xFFFFDAD6, onContainer: 0xFF410002), // Brick Red
        .init(container: 0xFFE2E2E9, onContainer: 0xFF191C20), // Grey
        .init(container: 0xFFF2DAFF, onContainer: 0xFF2C004F), // Violet
        .init(container: 0xFFFFDEA5, onContainer: 0xFF261900), // Amber
    ]

    /// Android `isUnknownGenreId`.
    static func isUnknownGenreId(_ genreId: String) -> Bool {
        let normalized = KotlinText.lowercase(genreId.kotlinTrimmed())
        return normalized == "unknown" || normalized == "unknown genre" || normalized == "unknown_genre"
    }

    /// `getGenreThemeColor(genreId, isDark)`. (Kotlin's `abs(Int.MIN_VALUE)` stays negative and would crash; the
    /// magnitude is used instead.)
    static func color(genreId: String, isDark: Bool) -> GenreThemeColor {
        if isUnknownGenreId(genreId) { return isDark ? unknownDark : unknownLight }
        let index = Int(KotlinText.hashCode(genreId).magnitude % UInt32(dark.count))
        return isDark ? dark[index] : light[index]
    }

    /// `getGenreThemeColor(genre, isDark)`: explicit colours on the genre win, else the palette by id.
    static func color(for genre: Genre, isDark: Bool) -> GenreThemeColor {
        let id = genre.id.isKotlinBlank ? "unknown" : genre.id
        if isUnknownGenreId(id) { return isDark ? unknownDark : unknownLight }
        let seed = parseHex(isDark ? genre.darkColorHex : genre.lightColorHex)
            ?? color(genreId: id, isDark: isDark).container
        let on = parseHex(isDark ? genre.onDarkColorHex : genre.onLightColorHex) ?? contrastContent(seed)
        return GenreThemeColor(container: seed, onContainer: on)
    }

    /// `contrastContentColor`: 90 % towards white on dark colours, towards black on light ones.
    static func contrastContent(_ argb: UInt32) -> UInt32 {
        let r = Double((argb >> 16) & 0xFF) / 255, g = Double((argb >> 8) & 0xFF) / 255, b = Double(argb & 0xFF) / 255
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return OklabMix.lerp(argb, luminance <= 0.5 ? 0xFFFFFFFF : 0xFF000000, 0.9)
    }

    /// `#RRGGBB` / `#AARRGGBB` (Android `Color.parseColor`).
    static func parseHex(_ hex: String?) -> UInt32? {
        guard var s = hex, !s.isKotlinBlank else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt32(s, radix: 16) else { return nil }
        switch s.count {
        case 6: return 0xFF00_0000 | value
        case 8: return value
        default: return nil
        }
    }

    /// `#AARRGGBB` as Android's `toHexString()` writes it for `buildGenre`.
    static func hexString(_ argb: UInt32) -> String {
        let digits = String(argb, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }
}

/// Compose's `lerp(Color, Color, Float)`: interpolation in Oklab.
nonisolated enum OklabMix {
    static func lerp(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let la = toOklab(a), lb = toOklab(b)
        let mixed = (la.0 + (lb.0 - la.0) * t, la.1 + (lb.1 - la.1) * t, la.2 + (lb.2 - la.2) * t)
        let alphaA = Double((a >> 24) & 0xFF), alphaB = Double((b >> 24) & 0xFF)
        return fromOklab(mixed, alpha: alphaA + (alphaB - alphaA) * t)
    }

    private static func toLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func toGamma(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    private static func toOklab(_ argb: UInt32) -> (Double, Double, Double) {
        let r = toLinear(Double((argb >> 16) & 0xFF) / 255)
        let g = toLinear(Double((argb >> 8) & 0xFF) / 255)
        let b = toLinear(Double(argb & 0xFF) / 255)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func fromOklab(_ lab: (Double, Double, Double), alpha: Double) -> UInt32 {
        let l = pow(lab.0 + 0.3963377774 * lab.1 + 0.2158037573 * lab.2, 3)
        let m = pow(lab.0 - 0.1055613458 * lab.1 - 0.0638541728 * lab.2, 3)
        let s = pow(lab.0 - 0.0894841775 * lab.1 - 1.2914855480 * lab.2, 3)
        func channel(_ v: Double) -> UInt32 { UInt32((min(max(toGamma(v), 0), 1) * 255).rounded()) }
        let r = channel(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s)
        let g = channel(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s)
        let b = channel(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        let a = UInt32(min(max(alpha, 0), 255).rounded())
        return (a << 24) | (r << 16) | (g << 8) | b
    }
}

/// A genre illustration (Android drawables): PixlAudio's own glyphs (`GenreArt.xcassets`, converted from the
/// app's vector drawables) or, for the Material Symbols it borrows, the matching SF Symbol.
nonisolated enum GenreIcon: Hashable, Sendable {
    case art(String)
    case symbol(String)

    /// `GenreIconProvider.getGenreImageResource(name)`: exact match on the lower-cased, trimmed name.
    static func forGenre(_ name: String) -> GenreIcon {
        GenreIconTable.byAlias[KotlinText.lowercase(name).kotlinTrimmed()] ?? GenreIconTable.fallback
    }
}

/// Draws a `GenreIcon` tinted with `color`.
struct GenreIconImage: View {
    let icon: GenreIcon
    let color: Color

    var body: some View {
        switch icon {
        case .art(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .foregroundStyle(color)
        case .symbol(let name):
            Image(systemName: name)
                .resizable()
                .foregroundStyle(color)
        }
    }
}

/// The library's genres (Android `MusicRepositoryImpl.getGenres`): every song's genre tag split on commas, trimmed,
/// one per id, sorted by lower-cased name, plus "Unknown" when some song has no genre.
nonisolated enum LibraryGenres {
    static let unknownName = "Unknown"
    static let unknownId = "unknown"

    static func genres(from songs: [Song]) -> [Genre] {
        var names: [String] = []
        var hasUnknown = false
        for song in songs {
            guard let raw = song.genre, !raw.isEmpty else { hasUnknown = true; continue }
            for part in raw.split(separator: ",", omittingEmptySubsequences: false) {
                let name = String(part).kotlinTrimmed()
                if !name.isKotlinBlank { names.append(name) }
            }
        }
        // The first name of each id, before the (palette-hashing) `buildGenre`: thousands of songs share a few genres.
        var seenIds = Set<String>()
        let unique = names.filter { seenIds.insert(genreId($0)).inserted }
        let known = unique.map(buildGenre)
            .kotlinSorted { KotlinText.compare(KotlinText.lowercase($0.name), KotlinText.lowercase($1.name)) }
        if hasUnknown, !known.contains(where: { $0.id == unknownId }) { return known + [buildGenre(unknownName)] }
        return known
    }

    /// `buildGenre`: id = lower-cased name with spaces and slashes as `_`; colours from the palette.
    static func genreId(_ name: String) -> String {
        KotlinText.equalsIgnoreCase(name, unknownName)
            ? unknownId
            : KotlinText.replace(KotlinText.replace(KotlinText.lowercase(name), " ", "_"), "/", "_")
    }

    static func buildGenre(_ name: String) -> Genre {
        let id = genreId(name)
        let light = GenreCardPalette.color(genreId: id, isDark: false)
        let dark = GenreCardPalette.color(genreId: id, isDark: true)
        return Genre(id: id, name: name,
                     lightColorHex: GenreCardPalette.hexString(light.container),
                     onLightColorHex: GenreCardPalette.hexString(light.onContainer),
                     darkColorHex: GenreCardPalette.hexString(dark.container),
                     onDarkColorHex: GenreCardPalette.hexString(dark.onContainer))
    }
}

/// A browse category (Android `SearchCategory`): opens the catalogue browser with `query`.
nonisolated struct SearchCategory: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let query: String

    init(_ id: String, _ name: String, query: String? = nil) {
        self.id = id
        self.name = name
        self.query = query ?? name
    }

    /// `DefaultSearchCategories`, same order.
    static let defaults: [SearchCategory] = [
        SearchCategory("lofi", "Lo-fi", query: "lofi beats"),
        SearchCategory("pop", "Pop"),
        SearchCategory("hiphop", "Hip-Hop"),
        SearchCategory("rock", "Rock"),
        SearchCategory("rnb", "R&B"),
        SearchCategory("electronic", "Electronic"),
        SearchCategory("indie", "Indie"),
        SearchCategory("jazz", "Jazz"),
        SearchCategory("metal", "Metal"),
        SearchCategory("classical", "Classical"),
        SearchCategory("kpop", "K-Pop"),
        SearchCategory("latin", "Latin"),
        SearchCategory("soul", "Soul"),
        SearchCategory("country", "Country"),
        SearchCategory("punk", "Punk"),
        SearchCategory("ambient", "Ambient"),
    ]
}
