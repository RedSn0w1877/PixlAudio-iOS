# Sync editor fix (2026-10-07), stage 1 of the lyrics batch

Branch `wt/lyrics`. Stage 2 (the lyrics page: Translate · Sing, always-on screen, glass chrome and More sheet) builds
on this in the same branch.

## What Hoa saw

On the phone: tap sync → "Getting the song ready…" → the editor disappears → nothing.

## Why

The editor took the lyrics screen's place in the app's one root full-screen cover. Swapping that cover tears down
what it shows, and the editor's own teardown navigated: closing the session on disappear always ran `onClosed`, which
swapped or dismissed the root cover. The editor showed its spinner (the closed phase draws it) and then went away.
Every editor test launched straight into the editor, so CI never went through the real entry points.

## What changed

- The editor is a cover nested **inside** the lyrics screen and inside Edit song (`LyricsSyncRequest`,
  `LyricsSyncEditorView(songId:entry:onClose:)`). The static `open(…)` and its flags are gone. `AppCover.lyricsSync`
  is only for `-screen lyricsSync` UI tests.
- The More sheet's "Sync the words yourself" only records the request; the editor opens from the sheet's
  `onDismiss`.
- `close(_ reason:)`: a disappearing editor (`.viewGone`) restores the player but never navigates; a later appearance
  starts a fresh session.
- Error screens with Close instead of silent closes: Spotify Connect playing (at open and mid-session; nothing is sent
  to the device, and it is never paused), a load over 8 s, the player unloading.
- `ScreenAwake`: one keep-screen-on claim per owner, so the editor closing never lets the screen lock under the
  lyrics screen. The lyrics screen stops its display link and Metal background while the editor covers it.
- The notice pill over the tap pad lets taps through unless it offers Undo.
- Details: `docs/design.md` › Stage 10 notes › Sync editor entry fix. Parity row 25, `docs/api-notes.md`,
  `docs/test-parity.md` updated.

## Verified here, and how

- No Mac: `swiftc -parse` (Swift 6.4, Linux) on every changed file, and `ci/check-forbidden.sh`. Nothing compiled
  against the iOS SDK yet.
- New tests, not run yet: `AppTests/LyricsSyncTests` (close reasons, the Connect guard at open and mid-session,
  `ScreenAwake`) and `UITests/LyricsSyncEntryTests` (chip ×2, More sheet on line- and word-synced lyrics, Leave via
  the alert, the Connect message).

## Waiting on CI and on Hoa's phone

1. CI: build, unit tests, and shots for `LyricsSyncEntryTests,LyricsSyncScreenshotTests,LyricsScreenshotTests` plus
   `PlayerScreenshotTests/testEditSongLight` (Edit song now owns a cover).
2. On the phone: open the editor from the chip, from ⋯ → "Sync the words yourself" (a BiniLyrics song too), and from
   Edit song → Fix timing; tap along, Save, and check the lyrics screen comes back with the toast. With a Connect
   speaker playing, the editor should explain and close.

## Not done (left for later)

- The words screen's container tap gesture (`SyncWordsEntryScreen`, plan item, unverified on device).
- After "Change the words" from Edit song, Edit song still shows the old words until it is reopened.
