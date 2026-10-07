# Accent colour (2026-10-07, branch `wt/accent`)

Hoa asked for an app-wide accent colour. This branch builds it as decided in DECISIONS.md › Accent colour:
seed-chroma **vivid** scheme, presets plus Custom, the player keeps album colours, Player Theme's unused
"System Dynamic" option is renamed "Accent Color", and the default stays today's soft violet.

## What changed

- **PixlLibrary:** `ArtworkTheme.accentPair(seed:)` (`SchemeBuilder.accentPair`): TonalSpot surfaces, secondary,
  tertiary and role tones with the primary palette at the pick's own chroma (≥ 36). Near-grey picks (Graphite) give
  pure greys at the exact role tones. `brandPair` is untouched.
- **PixlBackup:** `AndroidPreferenceCatalog.iosOnly = ["accent_color_v1"]`, catalogued as portable, so it exports and
  restores by name. Android keeps unknown keys untouched on import.
- **App:**
  - `AppearanceSettings.accentColor` (`accent_color_v1`, `"#RRGGBB"`, `""` = violet), reloaded after a restore.
  - `AccentPalette` (presets, hex parse/format, picked colour → hex, `dynamicPrimary` for UIKit) and `WindowTint`
    (in `App/DesignSystem/AccentPalette.swift`).
  - `ThemeStore.accentPair`, memoised per value, replaces the brand pair in `colors(for:)`.
  - `RootView`: sheets and covers re-apply `.tint`, and the window tint follows the accent.
  - `alwaysDarkTheme` tints with the dark tone.
  - `AccentColorRow` in Settings › Appearance › Global Theme, after App Theme.
  - Strings in `AccentColorStrings.swift` (new keys, not hand-edited into the catalog).
  - `-accent RRGGBB` launch flag for UI tests.
- **Docs:** design.md § Colour, § Screenshot ids and § Accent colour; parity.md (new row + row 40);
  api-notes.md § Accent colour; test-parity.md § Accent colour.

## Verified here (Linux, no Mac)

- `swift build` + the **full** PixlCore test suite (Swift 6.4 on Linux): all 8 targets green, including the new
  `AccentPairTests` (7) and `ModuleTests` additions. The coloured presets' light primaries (and four dark ones) match
  the numbers Google's reference utilities gave in planning, digit for digit.
- `swiftc -parse` on every changed file; `ci/check-forbidden.sh` OK.
- The pure hex parse/format logic run on Linux.
- **Not compiled:** everything in `App/`, `AppTests/`, `UITests/` (no iOS SDK). CI is the compiler. The spots I'd
  watch: `Color.resolve(in: EnvironmentValues())` in a `@MainActor static func` inside a `nonisolated enum`;
  `UIColor(dynamicProvider:)` built in a nonisolated function; `nonisolated extension L10n`; the
  `private nonisolated final class ChangeFlag: @unchecked Sendable` in `AccentColorTests`.

## Differences from the plan (and why)

- **Graphite is pure grey at exact tones** (#5E5E5E light / #C6C6C6 dark), not Android's HSL greyscale
  (#6B6B6B / #D7D7D7). The HSL path put some grey custom picks at 4.49:1 for `primary` on the background, just
  under WCAG AA. With chroma 0 every grey pick keeps the designed contrast, and errors stay red.
- **Swatches show the named colour (the seed), not the scheme tone.** In dark mode the tones are pastel and nearly
  equal for Red/Pink (#FFB4AA / #FFB3B5) and Blue/Indigo. In light mode Yellow and Orange become olive and brown. So
  tones would make the grid hard to read. The app around the row shows the real tone live. As a bonus, the row
  builds no schemes at all (the plan's background `Task.detached` for 11 pairs isn't needed).
- The primary-on-background check is 4.5:1 (what the role rules guarantee), stricter than the plan's 3:1.

## Waiting on Hoa's phone

1. Alerts and confirmation dialogs: do their buttons follow the accent (window `tintColor`)? If not, the fallback
   is `UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor` (api-notes row).
2. Dark mode: are the pastel tones OK (vivid option, as explained in the decision)?
3. Custom: does the system picker feel right (the app re-themes 180 ms after the last drag step)?
4. A small change for everyone, even with no accent picked: default-tinted controls in sheets and covers (e.g. the
   Sleep Timer button) and alert buttons move from the asset's #7C5CFF/#9D8CFF to the in-app #5F5791/#C8BFFF.
   Expect diffs in `PlayerScreenshotTests`, `LyricsScreenshotTests`, `LyricsSyncScreenshotTests` and
   `BackupOnboardingScreenshotTests` sheet/cover shots.
5. A restore from an Android backup, or an older iOS one, resets the accent to the violet ("restore replaces
   settings").

## Next step

Push and run CI with
`[shots:SettingsScreenshotTests,ScreenshotTests,PlayerScreenshotTests,LyricsScreenshotTests,LyricsSyncScreenshotTests,BackupOnboardingScreenshotTests]`.
Fix any compile errors, then look at the `-accentRed` / `-accentGraphite` / `-accentCustom` / `-accentTapGreen`
Appearance shots and the `-accentGreen` / `-accentBlue` / `-accentPink` shell shots. Then hand Hoa a test build.

Follow-ups, not done: an Increase Contrast variant of the accent (`contrastLevel` 0.5 / 1.0); the launch screen still
uses the static `AccentColor` asset.
