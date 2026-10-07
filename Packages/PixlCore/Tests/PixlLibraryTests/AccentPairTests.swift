import Foundation
import Testing
@testable import PixlLibrary

/// The app-wide accent scheme (`ArtworkTheme.accentPair(seed:)`, iOS-only owner request 2026-10-07; Android has no
/// accent setting, so there is no test to port). Checks that every preset and any custom pick stays legible, that the
/// light primaries keep the pick's punch, that Graphite is grey, and that the surfaces stay TonalSpot's.
@Suite struct AccentPairTests {
    /// The Settings › Appearance › Accent Color presets (the app's `AccentPalette.presets`) and PixlAudio's violet.
    static let presets: [(name: String, seed: UInt32)] = [
        ("blue", 0xFF0A_84FF), ("indigo", 0xFF5E_5CE6), ("purple", 0xFFBF_5AF2), ("pink", 0xFFFF_2D55),
        ("red", 0xFFFF_453A), ("orange", 0xFFFF_9F0A), ("yellow", 0xFFFF_D60A), ("green", 0xFF34_C759),
        ("mint", 0xFF00_C7BE), ("graphite", 0xFF8E_8E93), ("brand", ArtworkTheme.brandSeed),
    ]

    private static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        Contrast.ratioOfTones(ColorUtils.lstarFromArgb(a), ColorUtils.lstarFromArgb(b))
    }

    private static func hex(_ argb: UInt32) -> String { String(format: "#%06X", argb & 0xFF_FFFF) }

    /// WCAG AA (4.5:1) for text on the accent, the accent on the background, and text on the accent container, in
    /// light and dark. These are the pairs the app draws: `onPrimary` on prominent glass, `primary` captions and
    /// switches on the page, `onPrimaryContainer` on selected rows.
    private static func legibilityFailures(_ name: String, _ pair: ColorRolesPair) -> [String] {
        var failures = [String]()
        for (mode, r) in [("light", pair.light), ("dark", pair.dark)] {
            let checks: [(String, Double)] = [
                ("primary/onPrimary", contrast(r.primary, r.onPrimary)),
                ("primary/background", contrast(r.primary, r.background)),
                ("primary/surface", contrast(r.primary, r.surface)),
                ("primaryContainer/onPrimaryContainer", contrast(r.primaryContainer, r.onPrimaryContainer)),
            ]
            for (label, ratio) in checks where ratio < 4.5 {
                failures.append("\(name) \(mode) \(label) \(String(format: "%.2f", ratio))")
            }
        }
        return failures
    }

    @Test func everyPresetIsLegibleInLightAndDark() {
        let failures = Self.presets.flatMap { Self.legibilityFailures($0.name, ArtworkTheme.accentPair(seed: $0.seed)) }
        #expect(failures.isEmpty, "\(failures)")
    }

    /// A custom pick can be anything the system colour picker offers: sweep hue, chroma and tone (including very
    /// light, very dark and greyish picks).
    @Test func anyCustomPickIsLegible() {
        var failures = [String]()
        for hue in stride(from: 0.0, to: 360.0, by: 15.0) {
            for chroma in [4.0, 20.0, 48.0, 90.0, 150.0] {
                for tone in [5.0, 30.0, 50.0, 70.0, 95.0] {
                    let seed = Hct.from(hue, chroma, tone).toInt()
                    failures += Self.legibilityFailures(Self.hex(seed), ArtworkTheme.accentPair(seed: seed))
                }
            }
        }
        for seed: UInt32 in [0xFF00_0000, 0xFFFF_FFFF, 0xFF80_8080, 0xFFFF_0000, 0xFF00_FF00, 0xFF00_00FF] {
            failures += Self.legibilityFailures(Self.hex(seed), ArtworkTheme.accentPair(seed: seed))
        }
        #expect(failures.isEmpty, "\(failures.count) failures, first: \(failures.prefix(5))")
    }

    /// The vivid option: the accent's primary is never more muted than TonalSpot's for the same seed, and the
    /// saturated presets are clearly more colourful in light mode.
    @Test func primaryKeepsTheSeedsChroma() {
        for (name, seed) in Self.presets where name != "graphite" {
            let accent = ArtworkTheme.accentPair(seed: seed)
            let tonal = ArtworkTheme.schemePair(seed: seed)
            for (mode, a, t) in [("light", accent.light, tonal.light), ("dark", accent.dark, tonal.dark)] {
                // ≥, not >: dark tones and Mint are gamut-limited to the same colour.
                #expect(Hct.fromInt(a.primary).chroma >= Hct.fromInt(t.primary).chroma - 1e-6, "\(name) \(mode)")
            }
        }
        for name in ["blue", "indigo", "purple", "pink", "red", "green"] {
            let seed = Self.presets.first { $0.name == name }!.seed
            let accent = Hct.fromInt(ArtworkTheme.accentPair(seed: seed).light.primary).chroma
            let tonal = Hct.fromInt(ArtworkTheme.schemePair(seed: seed).light.primary).chroma
            #expect(accent > tonal + 15, "\(name): \(accent) vs \(tonal)")
        }
    }

    /// Light primaries checked against Google's reference colour utilities (material-color-utilities, the same
    /// algorithm PixlLibrary ports, run with TonalSpot palettes and the primary at max(36, seed chroma)).
    @Test func primariesMatchTheReference() {
        let expected: [String: (light: UInt32, dark: UInt32?)] = [
            "red": (0xFFBD_0E12, 0xFFFF_B4AA), "blue": (0xFF00_5DB8, 0xFFAA_C7FF), "green": (0xFF00_6E28, 0xFF53_E16F),
            "yellow": (0xFF70_5D00, 0xFFE9_C400), "pink": (0xFFBE_0036, nil), "purple": (0xFF90_26C3, nil),
            "indigo": (0xFF4D_4AD5, nil), "orange": (0xFF88_5200, nil), "mint": (0xFF00_6A65, nil),
        ]
        for (name, seed) in Self.presets {
            guard let want = expected[name] else { continue }
            let pair = ArtworkTheme.accentPair(seed: seed)
            #expect(Self.hex(pair.light.primary) == Self.hex(want.light), "\(name) light")
            if let dark = want.dark { #expect(Self.hex(pair.dark.primary) == Self.hex(dark), "\(name) dark") }
        }
        // The vivid version of PixlAudio's own violet (the default accent stays `brandPair`).
        #expect(Self.hex(ArtworkTheme.accentPair(seed: ArtworkTheme.brandSeed).light.primary) == "#5D3CE5")
    }

    /// Graphite (and any near-grey pick) is pure grey at the scheme's exact tones (primary 40 light / 80 dark), so its
    /// contrast is exactly the designed one; errors stay red.
    @Test func graphiteIsGrey() {
        let pair = ArtworkTheme.accentPair(seed: 0xFF8E_8E93)
        func isGrey(_ value: UInt32) -> Bool {
            let r = (value >> 16) & 0xFF, g = (value >> 8) & 0xFF, b = value & 0xFF
            return r == g && g == b
        }
        for roles in [pair.light, pair.dark] {
            for value in [roles.primary, roles.onPrimary, roles.primaryContainer, roles.onPrimaryContainer,
                          roles.secondary, roles.tertiary, roles.background, roles.surfaceContainer, roles.outline] {
                #expect(isGrey(value), "\(Self.hex(value)) is not grey")
            }
            #expect(!isGrey(roles.error))
        }
        #expect(pair.light.primary == ColorUtils.argbFromLstar(40))
        #expect(pair.dark.primary == ColorUtils.argbFromLstar(80))
        #expect(Self.hex(pair.light.primary) == "#5E5E5E")
        #expect(Self.hex(pair.dark.primary) == "#C6C6C6")
    }

    /// Surfaces, secondary and tertiary stay TonalSpot's (a faint cast of the accent's hue, as with the brand
    /// violet); only the primary family changes. (Grey seeds are pure grey instead, see `graphiteIsGrey`.)
    @Test func surfacesStayTonalSpot() {
        let surfaceRoles: [KeyPath<ColorRoles, UInt32>] = [
            \.background, \.onBackground, \.surface, \.onSurface, \.surfaceVariant, \.onSurfaceVariant,
            \.surfaceContainer, \.surfaceContainerLow, \.surfaceContainerHigh, \.surfaceContainerHighest,
            \.outline, \.outlineVariant, \.secondary, \.secondaryContainer, \.tertiary, \.tertiaryContainer,
            \.error, \.errorContainer,
        ]
        for (name, seed) in Self.presets where name != "graphite" {
            let accent = ArtworkTheme.accentPair(seed: seed)
            let tonal = ArtworkTheme.schemePair(seed: seed)
            for path in surfaceRoles {
                #expect(accent.light[keyPath: path] == tonal.light[keyPath: path], "\(name) light \(path)")
                #expect(accent.dark[keyPath: path] == tonal.dark[keyPath: path], "\(name) dark \(path)")
            }
        }
    }

    @Test func isDeterministicAndDefaultIsUntouched() {
        #expect(ArtworkTheme.accentPair(seed: 0xFFFF_453A) == ArtworkTheme.accentPair(seed: 0xFFFF_453A))
        // The default accent is the brand pair itself (soft violet), not the vivid version of its seed.
        #expect(Self.hex(ArtworkTheme.brandPair.light.primary) == "#5F5791")
        #expect(Self.hex(ArtworkTheme.brandPair.dark.primary) == "#C8BFFF")
    }
}
