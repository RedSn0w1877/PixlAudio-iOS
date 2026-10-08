# Lyrics page: Translate · Sing, always-on screen, Liquid Glass (2026-10-07, branch `s16-lyrics-page`)

Owner items 1 and 11 of the 2026-10-07 batch, built from `2026-10-07-plans/lyrics-page.json` with
`DECISIONS.md` › Lyrics page. It builds on the sync-editor fix (`2026-10-07-sync-editor.md`) and the heart fix
(`2026-10-07-player-controls.md`), both already on `main`. Design notes: `docs/design.md` › Stage 9 notes › Lyrics page.

## What changed

- **Translate · Sing replace Synced · Static** in the lyrics toolbar (`Features/Lyrics/LyricsChrome.swift`).
  - **Translate:** a tap shows or hides the lyrics' translations. When they have none, it translates the synced lines
    on this iPhone into the phone's language (the system translator), with a spinner while it runs. Touch and hold:
    **Translate via AI** and **Show romanization** (when the lyrics have it). Plain-only lyrics: the segment looks
    dimmed and a tap explains why; Translate via AI still works from the long press. The segment is a SwiftUI `Menu`
    with a primary action: the first build used a `contextMenu`, and on CI holding it ran the tap instead of opening
    the menu.
  - **Sing:** vocals off / on through the song's studio instrumental. Without one, a tap starts the render
    ("Removing vocals 48 %" in place of the mic symbol, the progress filling the segment) and switches to the
    instrumental when it is ready.
    Disabled while the player switches and while Spotify Connect plays. The floating instrumental button is gone.
  - Synced vs plain is automatic. The More sheet has a **Show as plain text** switch for the current song.
- **Screen always on** while the lyrics are open, paused too. The Keep screen on switch is gone (UI and
  `LyricsViewPreferences`; the stored value is removed). `keep_screen_on_lyrics` is android-only in backups now: old
  backups restore cleanly and list it under skipped settings (`PreferencesModule`, `BackupRestoreReport` demo).
- **Glass on the lyrics screen:** the passive glass uses the full player's chrome tint (14 % `onPrimary`) instead of
  the ~34 % album colour that looked like dark plastic. Play/pause and the active segment stay as strong as the full
  player's. The controls share one `GlassEffectContainer`; the sync-offset row is five glass capsules that
  materialise. "Add lyrics and sync them" is a glass capsule; the find-lyrics card is a bit clearer (45 % tint,
  35 % dim).
- **Glass on the More sheet:** it opens at half height (`[.medium, .tallGlass]`) as floating Liquid Glass (at full
  height iOS made it opaque). Rows stay soft fills, grouped like Settings. The alignment picker is the liquid lens
  (`LiquidTabCapsule`, in the sheet's album palette), and shuffle / repeat / heart is the full player's
  `PlayerToggleRow`. The heart keeps the observed-lookup fix (`liked`, `@Environment(LibraryStore.self)`).
- **Unchanged on purpose:** lines still fade before the bars; the karaoke engine and its constants; the seek bar is
  not interactive glass (it could pull the thumb from the finger); the track pill is outside the container.
- **Tests fixed along the way** (they failed on the first CI run of this branch):
  - `LyricsSyncEntryTests` looked for the sync chip by identifier, which the lyrics screen's own identifier hides;
    it now also matches the chip's label. These tests had never run green on CI before (main's full run timed out).
  - `PlayerScreenshotTests.testLyricsOptionsFavoriteTogglesImmediately` found the full player's heart (built under
    the sheet, same labels, off screen) instead of the sheet's; it now looks inside the sheet. The same unscoped
    query is a likely cause of `testSongInfoFavoriteTogglesImmediately` failing on main ("the heart can't be tapped":
    it waits for the hidden full player's heart). That test belongs to `s21-main-health`; not changed here.
  - Once the chip was found, `testLeaveReturnsToLyrics` left a 3-tap draft in the UI-test drafts folder, which
    outlives the app between tests, and every later editor test opened on "You synced 3 of 128 words last time"
    instead of the intro. Under `-uiTest` the editor now clears that folder once per launch
    (`LyricsSyncEditorView.clearUITestDraftsOnce`; real drafts are untouched).
  - `testShowAsPlainText` and `testMoreSheetBottomInLightApp` (its shot never reached the bottom row) now swipe on the
    sheet until the target sits clear of the screen's edge.
  - `testShowAsPlainText` still failed in all three CI runs: the switch read "0" after a tap on it and after a drag
    across it (the sheet was settled, the switch on screen and hittable). The More sheet's switch rows now work as
    Android's do: the **whole row** is the tap target (Android puts `.clickable { onChange(!checked) }` on each row),
    with the rows' press feedback. The switch only shows the state (it takes no touches of its own, so a tap can't
    flip it twice); VoiceOver and UI tests still see a switch with the row's title (`accessibilityRepresentation`).
    This applies to Show romanization, Show translations, Show as plain text and Disable immersive (once). The test
    taps the row's title and reports what the switch reads if the lyrics don't switch.
- **Docs:** `design.md`, `parity.md` (rows 25 and 27), `api-notes.md` (`isIdleTimerDisabled`, `glassEffectTransition`,
  `contextMenu` with a caution for the player's output pill, `Menu(content:label:primaryAction:)`, first uses of
  `Toggle(_:systemImage:isOn:)`, iOS 14, and `accessibilityRepresentation(representation:)`, iOS 15, checked on
  developer.apple.com), `test-parity.md`.

## Adversarial review (2026-10-08)

A second agent reviewed `git diff origin/main...HEAD` against the plan, `DECISIONS.md` and `AGENTS.md`, and looked at
the shots of run 37730028431 (Translate · Sing, the half-height sheet, Show as plain text, Sing rendering, the
Translate menu, bright art, no lyrics). No blocker or major was found. Fixed (commit `cdac85a`):

- Translate and Sing taps didn't count as touching the screen, so with immersive lyrics on the controls could hide
  right after a tap (Synced / Static did call `resetImmersive`). They do now (`onSegmentTap`).
- Their haptic fired on any state change, including a song change that showed or dropped translations or reset
  Sing. It now answers taps only.
- Tapping Sing while the automatic studio was already rendering the song only waited for it; pressing play then
  cancelled that unattended job, so the tap was lost without a word. The tap now calls `studio.start`, which adopts
  the running job as the person's (`TaisStudio.adopt`).
- A render landing while a Spotify Connect speaker plays no longer switches this iPhone's player to the instrumental.
- A late on-device translation result for an earlier song could clear the spinner of a translation started since;
  `finishTranslation` now clears it only for its own run (a song change already clears it in `.task(id:)`).
- The sync editor re-claims "screen always on" when the app becomes active (plan item; matters when it is opened
  from Edit song, with no lyrics screen underneath).
- `testTranslateMenu` now also taps Translate twice (hide, show) before the long press, so the segment's main action
  has a test. `test-parity.md` described the old drag fallback of `testShowAsPlainText`; corrected.

Verified: parse-check and check-forbidden OK; **CI run 37736634144 on `cdac85a` is green** — core job, app build,
261 unit tests, and 50 UI tests with no failures and no retries (`LyricsScreenshotTests` 22, `LyricsSyncScreenshotTests`
15, `GlassAccessibilityTests` 5, `LyricsSyncEntryTests` 5, the three `TaisScreenshotTests/testInstrumental*`). The
shots `lyricsTranslateMenu` (menu open after the two taps, translations back on) and `lyricsSingActive` were checked
by eye. The More sheet, backup and settings code is unchanged since run 37730028431, which covered those classes.

Left as is (minor, noted for later):
- With "Show as plain text" on, the plain view shows the plain lines, which don't carry translations made from the
  synced lines, so Translate can light up with nothing visible changing. Plain mode rendered translations the same
  way before this branch (the old Static segment).
- The alignment lens (`LiquidTabCapsule`, 56 pt frame) leaves a gap above and below its capsule inside the
  Alignment card. It is the shared component's frame; changing it would move the other sheets' tab capsules.

## How it was verified

- `ci/parse-check.ps1` on every changed Swift file and `ci/check-forbidden.sh`: OK.
- PixlCore `PixlBackupTests` on Windows (Swift 6.4): 146 tests pass, including the new
  `retiredKeepScreenOnIsSkippedAndReported` and the updated `catalogueKinds`.
- CI (macOS, Xcode 27): **green on run 37730028431 (commit 1ed20d0)** — the core job, the app build, the unit tests
  (261 passed, including `BackupServiceTests.testOldBackupWithKeepScreenOnRestoresAndListsItSkipped`) and 109 UI
  test runs: the classes `LyricsScreenshotTests`, `LyricsSyncScreenshotTests`, `LyricsSyncEntryTests`,
  `GlassAccessibilityTests`, `BackupOnboardingScreenshotTests`, `SettingsScreenshotTests`, plus
  `PlayerScreenshotTests/testLyricsOptionsFavoriteTogglesImmediately` and the three `TaisScreenshotTests/testInstrument*`
  shots. One retry: `BackupOnboardingScreenshotTests/testBackupExportPickerLight` hit "Failed to terminate" the app
  (the simulator, not this branch) and passed on its second try. The core job's "YouTube live smoke (non-blocking)"
  step reports exit 1, as it is allowed to. Shots checked by eye: the More sheet at half height, its bottom, and
  Show as plain text turned on (Adjust sync gone, the switch on).
- New UI tests: `testSingActive`, `testSingRendering`, `testTranslateMenu`, `testShowAsPlainText`,
  `GlassAccessibilityTests/testLyricsToolbarKeepsButtonTraits`.

Nothing here ran on an iPhone. The simulator can't render a real instrumental, a real translation or a Connect
speaker, so those paths are only checked with demo states.

## For Hoa's iPhone

- [ ] The lyrics screen doesn't lock with the music paused, and does lock again after you leave it.
- [ ] Translate on a song in another language: the translations appear and the button lights up; tap again hides them.
- [ ] Hold Translate: Translate via AI works; Show romanization appears on a song that has it (e.g. Japanese, Korean).
- [ ] Sing on a downloaded song: the first time it renders ("Removing vocals …"), then the vocals go away; tap
      again brings them back without a skip. On a Spotify Connect speaker, Sing is greyed out.
- [ ] With immersive lyrics on (Settings), tapping Translate or Sing keeps the controls up for the full timeout.
- [ ] ⋯ opens as a half-height floating glass sheet; drag it up, still see-through. Is it readable over bright art?
- [ ] Show as plain text switches to plain lyrics and back on the first tap, on the switch and on the row's title
      alike (the whole row is the target, as on Android); the next song goes back to synced. Same for Show
      translations. The switch no longer slides under a drag: tap it.
- [ ] The alignment lens and the shuffle / repeat / heart row feel like the full player's; the heart flips at once.
- [ ] The controls look like the full player's glass (not dark plastic), also over very bright and very dark art.
- [ ] Seek by dragging the seek bar: the thumb stays under the finger.
- [ ] If the glass still looks solid: Settings › Display & Brightness › Liquid Glass "Tinted" or Reduce Transparency
      make all glass more frosted.
- [ ] An old backup (with "Keep screen on") restores and lists `keep_screen_on_lyrics` under skipped settings.

## Next step

The branch is green (run 37736634144 on `cdac85a`, after the review; run 37730028431 before it): review and merge
into `main` (not done by the agents), then check the list above on the phone. Not done here (plan
"optional"): Android's AI lyric-sync row in the More sheet, and letting lines scroll under the glass bars (owner:
not for now).
