# Lyrics page: Translate · Sing, always-on screen, Liquid Glass (2026-10-07, branch `s16-lyrics-page`)

Owner items 1 and 11 of the 2026-10-07 batch, built from `2026-10-07-plans/lyrics-page.json` with
`DECISIONS.md` › Lyrics page. It builds on the sync-editor fix (`2026-10-07-sync-editor.md`) and the heart fix
(`2026-10-07-player-controls.md`), both already on `main`. Design notes: `docs/design.md` › Stage 9 notes › Lyrics page.

## What changed

- **Translate · Sing replace Synced · Static** in the lyrics toolbar (`Features/Lyrics/LyricsChrome.swift`).
  - **Translate:** a tap shows or hides the lyrics' translations. When they have none, it translates the synced lines
    on this iPhone into the phone's language (the system translator), with a spinner while it runs. Touch and hold:
    **Translate via AI** and **Show romanization** (when the lyrics have it). Plain-only lyrics: the segment looks
    dimmed and a tap explains why; Translate via AI still works from the long press.
  - **Sing:** vocals off / on through the song's studio instrumental. Without one, a tap starts the render
    ("Removing vocals 48 %", the progress filling the segment) and switches to the instrumental when it is ready.
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
  (`LiquidTabCapsule`), and shuffle / repeat / heart is the full player's `PlayerToggleRow`. The heart keeps the
  observed-lookup fix (`liked`, `@Environment(LibraryStore.self)`).
- **Unchanged on purpose:** lines still fade before the bars; the karaoke engine and its constants; the seek bar is
  not interactive glass (it could pull the thumb from the finger); the track pill is outside the container.
- **Docs:** `design.md`, `parity.md` (rows 25 and 27), `api-notes.md` (`isIdleTimerDisabled`, `glassEffectTransition`,
  `contextMenu`, first use of `Toggle(_:systemImage:isOn:)`, iOS 14, checked on developer.apple.com),
  `test-parity.md`.

## How it was verified

- `ci/parse-check.ps1` on every changed Swift file and `ci/check-forbidden.sh`: OK.
- PixlCore `PixlBackupTests` on Windows (Swift 6.4): 146 tests pass, including the new
  `retiredKeepScreenOnIsSkippedAndReported` and the updated `catalogueKinds`.
- CI (macOS, Xcode 27): see the run on this branch — the core job, the app build, the unit tests (including
  `BackupServiceTests.testOldBackupWithKeepScreenOnRestoresAndListsItSkipped`) and the screenshot classes
  `LyricsScreenshotTests`, `LyricsSyncScreenshotTests`, `LyricsSyncEntryTests`, `GlassAccessibilityTests`,
  `BackupOnboardingScreenshotTests`, `SettingsScreenshotTests`, plus `PlayerScreenshotTests/testLyricsOptionsFavoriteTogglesImmediately`
  and the three `TaisScreenshotTests/testInstrument*` shots.
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
- [ ] ⋯ opens as a half-height floating glass sheet; drag it up, still see-through. Is it readable over bright art?
- [ ] Show as plain text switches to plain lyrics and back; the next song goes back to synced.
- [ ] The alignment lens and the shuffle / repeat / heart row feel like the full player's; the heart flips at once.
- [ ] The controls look like the full player's glass (not dark plastic), also over very bright and very dark art.
- [ ] Seek by dragging the seek bar: the thumb stays under the finger.
- [ ] If the glass still looks solid: Settings › Display & Brightness › Liquid Glass "Tinted" or Reduce Transparency
      make all glass more frosted.
- [ ] An old backup (with "Keep screen on") restores and lists `keep_screen_on_lyrics` under skipped settings.

## Next step

Merge after review once the branch is green, then check the list above on the phone. Not done here (plan
"optional"): Android's AI lyric-sync row in the More sheet, and letting lines scroll under the glass bars (owner:
not for now).
