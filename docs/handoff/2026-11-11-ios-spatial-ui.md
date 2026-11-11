# iOS Spatial audio: UI (2026-11-11)

Role: **UI** (player entry, sheet, Settings rows, strings, UI-test plumbing). Branch `audio-ui`, cut from
`origin/audio-hq` at `6529ea4`. Contract and manual: `docs/handoff/2026-11-10-plans/cloud-audio-spec.md` ("spec") and
`docs/handoff/2026-11-10-plans/ios-integration-map.md` ("map"). Android reference: `RedSn0w1877/PixlAudio` branch
`audio-ui` (`presentation/spatial/*`, `res/values/strings_spatial_ui.xml`, its handoff
`handoff/2026-11-11-android-spatial-ui.md`), read only. **No contract file was changed** (PixlModel's `CloudAudio/*`,
`SpatialAudioModel`, `SpatialAudioContext`, `CloudAudioSettingsStore`, `AppEnvironment.swift` untouched).

CI: see the table at the bottom.

## What is there

### 1. The player entry (map 8.3, spec 6.5)

`App/Features/Spatial/SpatialAudioPlayerButton.swift`, placed in `NowPlayingView`'s `PlayerMetadataRow` as the **third
sibling after Lyrics and Ask Taizo**, inside their `GlassEffectContainer`: the place the Android player uses (map 8.3,
option 2). It is its own small view that reads `env.spatial.selection` and `env.spatial.snapshot.blockedBy` only, so a
pick redraws the button alone.

- **Off**: a 48 pt clear-glass circle (`playerGlass`, `onPrimary` at `GlassTint.playerChrome`, like its neighbours), the
  icon over "Off" in `labelSmall`, `primary` content.
- **On**: the glass fills with `primary` (`GlassTint.prominent`), content `onPrimary`, corners 24 → 16 pt, the
  profile's name instead of "Off"; the width hugs the name (at most 104 pt, then it truncates rather than squeeze the
  song title). One interruptible spring moves fill, corners and width.
- **Held back** (`blockedBy` is `.route` or `.sing`, the two blocks with a line of their own): the name stays, the fill
  goes. `.remote` and `.format` do not dim it (spec 6.5 has no line for them), as on Android.
- VoiceOver: label "Spatial audio", value "Off" / the name / "<name>. Not playing right now."; id
  `player.spatialAudio`. A tap presents `AppSheet.spatialAudio(fromPlayer: true)`.

### 2. The sheet (spec 6.5)

`App/Features/Spatial/SpatialAudioSheet.swift`, `AppSheet.spatialAudio(fromPlayer:)` (`Routes.swift`), mapped in
`SheetDestination`. Android's layout and order:

- header: the icon in a 44 pt `primaryContainer` glass circle, "Spatial audio" (`headlineSmall` bold), "For
  headphones.";
- the **status line** card (`secondaryContainer` glass, 20 pt corners, an icon per line): `env.spatial.statusLine`
  mapped by `SpatialAudioUI.statusText`, every row of the spec's table word for word; `.none` shows no card. A change
  crossfades, the card's height follows, VoiceOver announces the new line;
- **Off and the six profiles** (name + the spec's one-liner; Off's line is Android's "The normal stereo sound."), one
  glass shape per row in one `GlassEffectContainer`, 2 pt apart: 24 pt outer corners, 6 pt inner, the selected row rounds
  fully, takes `secondaryContainer` and a check that scales in. Rows are buttons with the selected trait
  (`spatialAudio.choice.<off|profile id>`);
- the quiet line "Spatial plays a little quieter so the peaks stay clean." (`SpatialCopy.levelNote`), always.

Picking a row calls `env.spatial.select(_:)` at once (a selection haptic) and the sheet stays open, so profiles can be
compared by ear. The sheet wraps its content like Android's `skipPartiallyExpanded` sheet (`fittedSheetDetent`, height
remembered per text size and with / without a line). From the player it takes the album colours (as Android's does);
from Settings the app's. Id `screen.spatialAudio`.

### 3. Settings (spec 6.5, map 8.1-8.2)

`App/Features/Spatial/SpatialAudioSettingsRows.swift`, called from `PlaybackSettingsSection`:

- **Settings › Playback › Sound**, after Audio quality (`SpatialAudioSettingsRows`):
  - "Spatial audio", subtitle "<name> · <one-liner>", chevron: opens the same sheet (app colours).
  - "Cloud renders": writes `spatial.cloud` only (`setCloud`).
  - "Cloud processing is off" / "Cloud renders need it. Tap to turn it on." — only while "Cloud renders" is on and Cloud
    Studio's master is off (`settings.cloud && !cloudRendersOn`); pushes `.cloudProcessing`. The master is never written
    from here (map 8.2).
  - "Prepare ahead" (`setPrepareAhead`); disabled with "Needs cloud renders." while "Cloud renders" is off (its value
    is kept).
  - "Songs ready: N · X GB on this phone" with "Remove downloaded renders" (disabled with nothing to remove or while
    removing), behind an alert "Remove downloaded renders?" (Remove / Cancel). `refreshUsage()` runs when the row
    appears.
- **Settings › Playback › Advanced** (Developer mode only, after the ReplayGain rows; `SpatialAudioDeveloperRows`):
  - "Spatial audio route": Headphones only / Always.
  - "Spatial cloud limit per month": $5, 10, 15, 20, **30**, 50, 75, 100, 150, 200, No limit (a stored amount not in the
    list is shown in its place); subtitle "Spatial renders only, apart from Sing. Spent this month: $X."
    (`usage.spentThisMonthMicroUSD` via `CloudCost.format`).
  - "Storage for Spatial renders": 14 stops, 256 MB … 64 GB (3 GB is a stop).
  - "Spatial songs a day ahead": 1 … 100, caption "Sent today: N.".
  - "Spatial audio: this song": rendition (+ profile), held back by, status, the local render of the selected profile,
    source codec, stem mode, loudness (integrated, source, headroom) and sample rate. The manifest comes from
    `renditionsOfCurrentSong()`, read when the song, the profile or the status changes, and only once the status is
    `ready` (Android's rule).
  - Sliders follow the finger and write once it lets go.
- Developer mode's file-info chip in the full player (`PlayerSeekBar`) ends with "• Spatial Studio on phone" / "•
  Spatial Studio cloud render" while a spatial rendition is audible (Android did the same).

### 4. Strings

`App/Features/Spatial/SpatialStrings.swift`: `nonisolated extension L10n`, English only, with **Android's keys**
(`spatial_ui_*`) and Swift's placeholders (`%1$@`, `%1$lld`), so a catalog regenerated from Android brings the same
words. `Localizable.xcstrings` untouched. `L10n.commonRemove` / `commonCancel` reused. No changelog entry.

### 5. Until ENGINE and CLOUD land

On the no-op services the snapshot is `.idle`: no status line, the button follows the stored pick only (never dimmed),
the diagnostics say "Nothing is playing.", the file-info chip adds nothing, "Songs ready: 0 · 0 GB on this phone" with
Remove disabled, $0.00 spent, 0 sent today. Unlike Android's no-op build, the "Cloud processing is off" row is already
right here: iOS's `cloudRendersOn` is the model's own `settings.cloud && isCloudStudioOn`.

### 6. Tests

- `AppTests/SpatialAudioUITests.swift` (XCTest, CI only): the words against the spec and PixlModel
  (`displayName`, `summary`, `SpatialStatusLine.text`, `SpatialCopy.levelNote`); no forbidden word in any string; the
  sheet's order and single selection; the button for every block; the Settings rows for the two switches and the usage;
  GB formatting; storage stops, cap choices and picks, the daily range; the diagnostics rows; and every demo screen
  through the real model (no-op services) showing the line its name says, all ten lines covered.
- `UITests/SpatialScreenshotTests.swift`: the sheet over the player for every line and Off (line checked word for word,
  selected row checked), the master-off variant, the player's button on and held back, button → sheet → pick Wide →
  close → the button says "Wide", the Sound rows, the master-off row, the Developer rows, and Remove's confirm (Cancel
  keeps, Remove empties the row).
- Demo screens (`DemoScreen`, `SpatialDemo`): `spatialAudio` (Studio, on the phone, cloud version coming),
  `spatialAudio.off`, `.waitingForWifi`, `.cloudLimit`, `.gettingCloudVersion`, `.cloudVersion`, `.onPhoneOnly`,
  `.cloudFailed`, `.headphonesOnly`, `.pausedForSing`; `nowPlaying.spatial`, `nowPlaying.spatialHeld`;
  `settingsCategory.playback.spatial` (12 songs, 1.4 GB, $1.24, 4 sent today).

## Divergences and choices (please confirm or overrule)

1. **Placement** (map 8.3 asked to settle it with the lead first): I followed the Android branch, which is the owner's
   port rule: the third circle of the song row. Up to four items with the loading chip; the title gives up about
   60 pt (Android accepted the same).
2. **The UI tests switch Cloud Studio's master on with a launch argument**, `-cloud_studio_enabled YES` (the
   `UserDefaults` argument domain is shared by every suite, so `CloudSettings` reads it). The contract's
   `setDemo(snapshot:libraryStatus:usage:)` cannot pin `isCloudStudioOn`, and `SpatialDemo.apply` has no way to reach
   Cloud Studio's settings, so without it no cloud line (on your phone for now, Wi-Fi, limit, getting, failed) can be
   shown in a UI test. Cleaner, if the lead wants: a `cloudStudioOn:` parameter on `setDemo`, or `CloudDemo` honouring
   a launch flag. Nothing in the app depends on the argument.
3. **Contract nit**: `SpatialAudioModel.removeDownloadedRenders()` is not guarded by `isDemo` like `refreshUsage()`: in a
   demo it asks the library for the status again and overwrites the pinned `libraryStatus` (the no-op answers `none`).
   Harmless for the screenshots (the line stays "On your phone for now…"); worth one `guard !isDemo` in the frozen model.
4. **Off first with its own line** ("The normal stereo sound.") and the header's "For headphones." are Android's choices
   (spec 6.5 gives no order and no line for Off); mirrored.
5. **The sheet from the player takes the album colours** (Android: `LocalMaterialTheme`); iOS's other player sheets use
   the app's. `AppSheet.spatialAudio(fromPlayer:)` carries the choice.
6. **The feature's symbol** is `person.wave.2` (a person with sound on both sides) for Material's `spatial_audio`. A
   symbol name is not checked by the compiler: look at the screenshots; swap `SpatialAudioUI.symbol` if it draws
   nothing.
7. **The monthly cap is a `Double` on iOS** (map 13): a stored fraction shows as "$12.50" and is offered in the list;
   Android only has whole dollars.
8. "Prepare ahead" is disabled while "Cloud renders" is off; the button dims only for the route rule and Sing; "X GB"
   uses binary units with halves rounded up and never reads "0.0" for something; the developer diagnostics' values are
   untranslated technical words — all as on Android.
9. The status line is announced to VoiceOver when it changes (Android: a polite live region).

## What other roles or the lead must do

- **ENGINE**: nothing for the UI to work. Publish truthful snapshots: `blockedBy` (derived from them) dims the button,
  `audible` drives the line, the file-info chip and the diagnostics.
- **CLOUD**: `usage()` answers from memory (the Settings page asks on appear); send `.usageChanged` when it moves so
  "Songs ready" stays live; `localRenditions(videoId:)` feeds the diagnostics; report `.waitingForNetwork` /
  `.capReached` / `.downloading` as their own statuses (they each have a line).
- **Lead**: confirm the divergences above (placement, the demo argument or a `setDemo` parameter, the `isDemo` nit);
  compare the sheet's order and the Off line with Android (identical today); ask for the changelog entry when the beta
  is cut.

## Not done / uncertain

- Nothing was run on a device; the app target compiles only in CI. Layout widths were reasoned from the code; the UI
  tests assert the behaviour (lines, selection, values, the pick, the confirm), not the looks: **the screenshots in
  artifact `shots-3a60dc66988f5a3f8bc6fa7c121b8d432d71d456` (run 43087884841) still want a look**, in particular the
  `person.wave.2` symbol and the button's width next to a long title.
- No local PixlCore run: this branch changes nothing in `Packages/PixlCore`; CI's `core` job ran it (green).

## CI (`ci.yml`, branch `audio-ui`)

| Run | Commit | Result |
|---|---|---|
| 43078803181 | ed2db49 | build for testing green; cancelled by the next push before the unit tests |
| 43079645843 | d2c4d31 `[shots:SpatialScreenshotTests]` | build green, **603 unit tests green**; screenshots 15 of 19: the first three tests' `app.launch()` failed in every attempt ("Failed to get background assertion" / "does not have a process ID": the freshly booted simulator still settling, the same tests passed in the next run), and the Developer rows test asked the page's last row to sit higher than the page can scroll (test bug, fixed) |
| 43087884841 | 3a60dc6 `[shots:SpatialScreenshotTests]` | **green**: build, 603 unit tests (11 of them `SpatialAudioUITests`), 19 of 19 screenshot tests, `core` |

Later commits on the branch touch only this note (no CI run).
