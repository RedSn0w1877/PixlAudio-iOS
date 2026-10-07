import Observation
import PixlLibrary
import SwiftUI
import UIKit
import XCTest
@testable import PixlAudio

/// Settings › Appearance › Accent Color (iOS-only, owner request 2026-10-07): the stored value's format, the presets,
/// the scheme `ThemeStore` hands the app, persistence and the window tint. The scheme maths itself is tested in
/// PixlCore (`AccentPairTests`); the backup round trip in `BackupServiceTests`.
@MainActor
final class AccentColorTests: XCTestCase {
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "pixlaudio.accenttests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func themeStore(_ appearance: AppearanceSettings) -> ThemeStore {
        ThemeStore(extractor: ColorExtractor(pipeline: .shared, persistence: nil), appearance: appearance)
    }

    // MARK: Stored value

    func testHexParsesWithOrWithoutHashInAnyCase() {
        XCTAssertEqual(AccentPalette.seed(hex: "#FF453A"), 0xFFFF_453A)
        XCTAssertEqual(AccentPalette.seed(hex: "ff453a"), 0xFFFF_453A)
        XCTAssertEqual(AccentPalette.seed(hex: " #00c7Be\n"), 0xFF00_C7BE)
        XCTAssertEqual(AccentPalette.seed(hex: "#000000"), 0xFF00_0000)
    }

    func testEmptyOrUnreadableHexMeansTheDefault() {
        for bad in ["", "#", "#FFF", "#FF453A00", "#GG0000", "+12345", "-12345", "##FF453A", "red"] {
            XCTAssertNil(AccentPalette.seed(hex: bad), bad)
        }
        XCTAssertEqual(AccentPalette.pair(hex: ""), ArtworkTheme.brandPair)
        XCTAssertEqual(AccentPalette.pair(hex: "nope"), ArtworkTheme.brandPair)
        XCTAssertEqual(AccentPalette.pair(hex: "#FF453A"), ArtworkTheme.accentPair(seed: 0xFFFF_453A))
    }

    func testHexFormatsAsUpperCaseSixDigits() {
        XCTAssertEqual(AccentPalette.hex(argb: 0xFFFF_453A), "#FF453A")
        XCTAssertEqual(AccentPalette.hex(argb: 0xFF00_0A84), "#000A84")
        XCTAssertEqual(AccentPalette.hex(argb: 0x0000_0000), "#000000")
        for preset in AccentPalette.presets where !preset.hex.isEmpty {
            XCTAssertEqual(AccentPalette.hex(argb: AccentPalette.seed(hex: preset.hex)!), preset.hex)
        }
    }

    func testPickedColorsBecomeHex() {
        XCTAssertEqual(AccentPalette.hex(Color(argb: 0xFFFF_453A)), "#FF453A")
        XCTAssertEqual(AccentPalette.hex(Color(argb: 0xFF6C_4FF5)), "#6C4FF5")
        // Opacity is dropped; extended-range components are clamped.
        XCTAssertEqual(AccentPalette.hex(Color(argb: 0x8034_C759)), "#34C759")
        XCTAssertEqual(AccentPalette.hex(Color(.sRGB, red: 1.2, green: -0.1, blue: 0.6, opacity: 1)), "#FF0099")
    }

    // MARK: Presets

    func testPresetsAreTheOwnersListAfterTheDefault() {
        XCTAssertEqual(AccentPalette.presets.map(\.id), [
            "default", "blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "mint", "graphite",
        ])
        XCTAssertEqual(AccentPalette.presets.first?.hex, "")
        XCTAssertEqual(AccentPalette.presets.first?.seed, ArtworkTheme.brandSeed)
        XCTAssertEqual(Set(AccentPalette.presets.map(\.hex)).count, AccentPalette.presets.count)
        XCTAssertTrue(AccentPalette.presets.dropFirst().allSatisfy { AccentPalette.seed(hex: $0.hex) != nil })
    }

    func testPresetLookupComparesColorsNotText() {
        XCTAssertEqual(AccentPalette.preset(for: "")?.id, "default")
        XCTAssertEqual(AccentPalette.preset(for: "#ff453a")?.id, "red")
        XCTAssertEqual(AccentPalette.preset(for: "8E8E93")?.id, "graphite")
        XCTAssertNil(AccentPalette.preset(for: "#123456"), "a custom colour")
        XCTAssertEqual(AccentPalette.preset(for: "garbage")?.id, "default", "unreadable values show the violet")
    }

    // MARK: Theme

    func testDefaultAccentKeepsPixlAudiosViolet() {
        let settings = SettingsStore(defaults: freshDefaults())
        XCTAssertEqual(settings.appearance.accentColor, "")
        let store = themeStore(settings.appearance)
        XCTAssertEqual(store.accentPair, ArtworkTheme.brandPair)
        XCTAssertEqual(store.colors(for: .light).app, ThemeColors.brandLight)
        XCTAssertEqual(store.colors(for: .dark).app, ThemeColors.brandDark)
    }

    func testPickedAccentThemesTheAppLive() {
        let settings = SettingsStore(defaults: freshDefaults())
        let store = themeStore(settings.appearance)
        settings.appearance.accentColor = "#FF453A"
        let red = ArtworkTheme.accentPair(seed: 0xFFFF_453A)
        XCTAssertEqual(store.colors(for: .light).app.argb(\.primary), red.light.primary)
        XCTAssertEqual(store.colors(for: .dark).app.argb(\.primary), red.dark.primary)
        XCTAssertTrue(store.colors(for: .dark).app.isDark)
        // Nothing playing: the player takes the accent too.
        XCTAssertEqual(store.colors(for: .light).player, store.colors(for: .light).app)
        settings.appearance.accentColor = "#34C759"
        XCTAssertEqual(store.colors(for: .light).app.argb(\.primary),
                       ArtworkTheme.accentPair(seed: 0xFF34_C759).light.primary)
        settings.appearance.accentColor = ""
        XCTAssertEqual(store.colors(for: .light).app, ThemeColors.brandLight)
    }

    /// `colors(for:)` observes the setting even when the accent comes from the cache, so the shell re-renders live.
    func testAccentChangesAreObserved() {
        let settings = SettingsStore(defaults: freshDefaults())
        let store = themeStore(settings.appearance)
        _ = store.colors(for: .light) // fills the cache
        let flag = ChangeFlag()
        withObservationTracking {
            _ = store.colors(for: .light)
        } onChange: {
            flag.fired = true
        }
        XCTAssertFalse(flag.fired)
        settings.appearance.accentColor = "#0A84FF"
        XCTAssertTrue(flag.fired)
    }

    // MARK: Persistence

    func testAccentIsStoredUnderItsKeyAndReloaded() {
        let defaults = freshDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.appearance.accentColor = "#FF453A"
        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.accentColor), "#FF453A")
        XCTAssertEqual(PreferenceKeys.accentColor, "accent_color_v1")
        XCTAssertEqual(SettingsStore(defaults: defaults).appearance.accentColor, "#FF453A")

        // A restore writes the defaults, then the running store re-reads them (and the app re-tints).
        defaults.set("#00C7BE", forKey: PreferenceKeys.accentColor)
        settings.reload(from: defaults)
        XCTAssertEqual(settings.appearance.accentColor, "#00C7BE")
        defaults.removeObject(forKey: PreferenceKeys.accentColor)
        settings.reload(from: defaults)
        XCTAssertEqual(settings.appearance.accentColor, "")
    }

    // MARK: UIKit

    func testWindowTintFollowsLightAndDark() {
        let pair = ArtworkTheme.accentPair(seed: 0xFFFF_453A)
        let color = AccentPalette.dynamicPrimary(pair)
        func rgb(_ style: UIUserInterfaceStyle) -> UInt32 {
            let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
            func byte(_ c: CGFloat) -> UInt32 { UInt32((c * 255).rounded()) }
            return byte(r) << 16 | byte(g) << 8 | byte(b)
        }
        XCTAssertEqual(rgb(.light), pair.light.primary & 0xFF_FFFF)
        XCTAssertEqual(rgb(.dark), pair.dark.primary & 0xFF_FFFF)
    }
}

/// Set from `withObservationTracking`'s `@Sendable` `onChange`, which runs synchronously when the value changes.
private nonisolated final class ChangeFlag: @unchecked Sendable {
    var fired = false
}
