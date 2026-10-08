# Main health: favourite-heart tests, the full screenshot run, String Catalog (2026-10-07)

Branch `s21-main-health` (from `main` `27dcc76`). Goal: get `main`'s CI green again after the batch merge (PR #2) and
tidy what main's screenshots showed. No device testing was done; everything below was checked on CI.

## What changed

1. **The favourite heart was right; its two UI tests were wrong.** Found with CI diagnostics (a temporary test that
   tapped the full player's toggles in different ways, plus a temporary log line in the app, both removed again):
   - Every tap on the heart's **centre** flipped it at once, and the app logged each action. So the observation fix
     from the batch (`LibraryStore.observedSong(id:)`, `PlayerToggles`, `SongFavoriteTile`) works.
   - `testSongInfoFavoriteTogglesImmediately` found the **collapsed full player's hidden heart** (same label, off screen
     under the mini player) instead of the song sheet's, so it waited for a heart that can never be tapped. Both tests
     now find their heart by its own identifier (`player.favorite`, `songInfo.favorite`).
   - `testFavoriteTogglesImmediately`: XCUITest's `tap()` went to the heart's **top-left corner** (the synthesized-event
     records say (265, 775) on a heart at x 255–352, y 770–828). XCUITest picks that point from accessibility hit tests,
     and the **tab bar's UIKit tabs were still in the accessibility tree under the player's toggle row**. A toggle that
     is on is a full capsule, so that corner is outside it; toggles that are off (rounded rectangles) still caught it.
     Shuffle and repeat behaved the same way.
   - App fix (accessibility): while the player is expanded, the tab bar's UIKit segments now leave the accessibility tree
     (`LiquidTabBar.accessibilityHidden` → `accessibilityElementsHidden`, set from `RootView.HiddenWhilePlayerExpanded`
     through `\.tabBarAccessibilityHidden`). SwiftUI's `accessibilityHidden` around the bar didn't reach them. Before,
     VoiceOver touch exploration over the toggle row could land on a hidden tab.
   - Tests: the two favourite tests tap the heart's centre, like a finger. New `testTabBarLeavesAccessibilityUnderThePlayer`
     checks that the tabs are gone from accessibility under the player and that a plain element `tap()` now reaches the
     liked heart. New unit test `FavoriteObservationTests.testEveryToggleInvalidatesTheNextRead` (three taps in a row).
   - The lyrics More sheet's heart (`testLyricsOptionsFavoriteTogglesImmediately`) passed all along and was not touched
     (`s16-lyrics-page` owns that sheet).
2. **Main's full screenshot run had no room.** Run 37679882164 ran 276 UI tests (288 runs with retries) in 99.8 minutes:
   93 minutes of passes plus 12 retried failures. It hit the step's 100-minute limit just as the tests ended, so nothing
   was exported. Each test takes about 20 s, about 13 s of it launching the app (automation session + idle wait), which a
   test can't avoid. Slowest classes: ScreenshotTests 13.6 min, PlayerScreenshotTests 12.4, LibraryScreenshotTests 12.2,
   SettingsScreenshotTests 10.4. `ci.yml`: the step now allows **160 minutes** and the job **195** (still one job; branch
   `[shots:…]` runs are unchanged). The two fixed tests also stop costing four retries (about 2 minutes) per main run.
3. **Main's screenshots** (pulled out of the run's result bundle, which was uploaded even though the export failed):
   - Queue, song sheet, Daily Mix (aiPlaylist) and Taizo chat at 92 %: see-through glass in light and dark, with the
     screen behind showing through. `PresentationDetent.tallGlass` stays at 0.92.
   - Full-player top bar: no title; the phone is icon-only; "AirPods Pro" fills the pill. Fine.
   - Every `-accent` shot: fine (swatch rings, captions, switches; pastel in dark as designed).
   - AI settings: the "cloud" shots looked identical to the on-device ones because the cloud rows sit below the two
     cards. They now scroll to the Assistant section (on-device row, cloud switch, provider, Save on usage).
   - Fixed: Save as playlist's title truncated to "Save as pl…" and "Deselect all" wrapped inside its 40 pt pill. The
     pill keeps one line (`fixedSize`). A first try that stepped the title down a text style (`ViewThatFits`) still
     truncated on CI (no style fits beside the pill on a 402 pt iPhone), so the top bar is now Android's two-row
     `MediumTopAppBar`: close circle and Select all / Deselect all on a 64 pt row, "Save as playlist" (headlineMedium)
     on its own 48 pt row below, 20 pt in.
   - Fixed: genre Quick Fill's bar squeezed Select all · Clear to "S…" "C…". They keep their width. The songs step's
     status capsule (about 40 pt left, it showed a lone "0") is gone: Android has nothing between Select all · Clear
     and Next there. The genre step keeps its "Select a genre" / "Genre: …" capsule.
4. **String Catalog regenerated** (`tools/localization/android_strings_to_xcstrings.py`, Android beta2 `res`, English
   only): 922 → 1,143 keys. Added: the 77 `lyrics_sync_*` keys, 14 `settings_accent_*`, `common_ok`, `common_undo`,
   one `settings_player_*`, and 139 SwiftUI labels added since the last run. No existing text changed; 12 keys the app
   no longer uses were dropped. Re-run the script after merging any branch that adds strings, rather than resolving
   catalog conflicts by hand.
5. **`2026-10-07-batch-status.md`** now says CI compiled and passed the integrated branch (run 37678758736), that it is
   merged to `main` (PR #2), that R6 (HTTP/3 to googlevideo) landed, and that the open items are on `s16`–`s20`.
6. **A flaky unit test.** Run 37712713121 failed only on `SpotifyConnectStoreTests.testTransportGoesToTheRemoteWhileAttached`
   (all 145 UI tests passed). The test slept a fixed 20 ms after each command for the player's events, which the
   store hears on the main actor, shared with the test host app's own launch work. On a busy simulator the last two
   events ("moved to song 4", "playing") hadn't arrived yet. The app was fine; the test now waits up to 3 s for the
   state it checks (`waitUntil`, already used by the other playback tests). It passed before and after on CI.

7. **Review (2026-10-08).** A second agent reviewed `origin/main...HEAD` against AGENTS.md, DECISIONS and the
   player-controls plan, read the Android sources (`SaveQueueAsPlaylistSheet`'s `MediumTopAppBar` with no scroll
   behaviour and a 4 dp title inset; Quick Fill's songs step with only a weighted `Spacer`) and looked at the
   screenshots of runs 37712713121 and 37730110289. No blocker or major found. Two small fixes:
   - `testTabBarLeavesAccessibilityUnderThePlayer` looked the Library tab up with `app.buttons`. The UIKit segment's
     element type isn't pinned (the tab bar tests use `descendants(matching: .any)`, as the plan asks), so the
     "hidden" check could pass without matching anything. It now uses `descendants`, and it also collapses the
     player and checks that the tabs come back and can be tapped. Nothing tested that half before: a flag stuck on
     would have hidden the tab bar from VoiceOver for the rest of the session.
   - `SettingsScreenshotTests`: `capture`'s doc comment had ended up on the new `scrollToAssistant` helper.

Docs: `api-notes.md` (Main health section: `accessibilityElementsHidden`, coordinate taps, `fixedSize`; `ViewThatFits`
marked as tried and removed),
`design.md` (player changes › tab bar; floating bars › Quick Fill and Save as playlist), `test-parity.md` (player fixes).

## How it was verified (CI only, no Mac, no phone)

- Diagnostic runs 37707836493 and 37709339732 (temporary test + app log line, removed afterwards).
- Run 37711302173: build, all 261 unit tests, the favourite tests, the new accessibility test, collapse / drag, the tab
  bar tap and drag, and `GlassAccessibilityTests`: all green.
- Run 37712713121 (`cf965ba`): build, `PlayerScreenshotTests`, `LibraryScreenshotTests`, `SettingsScreenshotTests`,
  `AIScreenshotTests`, `HomeStatsScreenshotTests`, `GlassAccessibilityTests` and the three tab bar tests: all 145 UI
  tests green; one unit test flaked (item 6). Its screenshots showed the AI cloud rows, the toggled hearts and the
  tab bar right, and Save as playlist's title still truncated, which led to the two-row bar.
- Run 37730110289 (`80baeba`): build, all 261 unit tests, Save as playlist light + dark, Quick Fill (songs step light,
  genre step dark) and `GlassAccessibilityTests`: green. The four screenshots were looked at: the full title on its
  own row, one-line "Deselect all", Select all · Clear and Next with an empty gap, the genre step's status capsule.
- `ci/parse-check.ps1` on every changed Swift file; `ci/check-forbidden.sh`.

Not verified: the full `main` run with the new limit. It runs on the next push to `main` after this branch merges.
`LyricsSyncEntryTests` (`testLeaveReturnsToLyrics`, `testOpensFromSyncChip`) also failed on main's run;
`s16-lyrics-page` is changing those tests.

## Hoa's iPhone checklist

- [ ] Full player: tap the heart once on a liked song: it empties at once. Tap again: it fills. Same for shuffle and
      repeat, and on the song sheet (⋮ › heart).
- [ ] With VoiceOver on, drag a finger over the full player's shuffle · repeat · heart row: it reads those controls,
      never "Home", "Search" or "Library". Collapse the player: the tab bar reads normally again.
- [ ] Queue › ⋯ › Save as playlist: "Save as playlist" shows in full on its own line under the close button, and
      "Deselect all" is one line.
- [ ] A genre page › ⋮ › Quick Fill (Unknown genre): "Select all" and "Clear" are readable, with Next on the right;
      after Next the bar reads "Select a genre", then "Genre: …" once you pick one.

## Next step

The branch is green (run 37730110289). Merge `s21-main-health` into `main` (owner's call), then watch main's full run:
it should finish in about 95–100 minutes inside the new 160-minute limit. If the suite grows past about 130 minutes,
raise the limit again or split the run. After the other `s16`–`s20` branches merge, re-run
`tools/localization/android_strings_to_xcstrings.py` once so the String Catalog picks up their strings.
