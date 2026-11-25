# Song Tap: the iPhone sender never reached the Pixel, iOS port (2026-11-25)

Branch `everything`. Port of Android `e68f587` + `4b97ec3` (Android: `handoff/2026-11-25-songtap-connection.md` and "Follow-up 2" in
`handoff/2026-11-21-song-drop.md`). Wire protocol, `SongTapSpec.version`, goldens, detector numbers and gates unchanged.

First commit on the branch: `RingCodeDiagnosticsView.swift` now imports `PixlModel` (for `currentTimeMillis`), same as `f9c3a8e` on
`lyrics-duet`; without it the app target did not build.

## What changed

- `SongTapBleRoute` (PixlCore):
  - "tap ignored: no yes yet" / "tap ignored: not the phone you said yes to" in the log, at most every 2 s (`SongTapBleTuning.tapIgnoredLogMs`);
    a yes (`publishOffer` for a phone) clears it.
  - `followSamePhone`: when the pinned receiver has been silent more than 1.5 s (`SongTapNearbyBook.samePhoneGapMs`) and a receiver with
    the same short name is heard under another address, the new address takes over the old number (focus, pin, `lastFireMs`,
    `lastNearMs` carry over; the old peer and any list row are dropped); connected phones get "offer ready" again. Log:
    "#N changed its address (same name, X), following the new one".
  - `anotherReceiverNear` skips receivers with the target's name.
  - `stickyPrompt`: the prompt stays up 3 s (`promptGraceMs`) while a same-named listed phone exists. `ignorePrompt` silences the
    name for 60 s (`ignoredNames`), so a new address of the same phone is not asked about.
  - `start(role:)` is a no-op when already running ACTIVE with the same role and name ("radio already running (role), not
    restarted"); every start / stop is logged ("advertising start (send), start number N", "advertising stop (receive)").
  - Connect timeout (3 s, already in `tick`) now marks the peer `staleConnect`; a late `onConnected` from that attempt is closed,
    not taken. Log text changed to Android's "connecting to #N took too long, giving up for now".
  - Snapshot: `tapNote`, `needsYes` (an ignored tap with no yes in the last 15 s), `radioStarts`; "Copy log" prints them.
- `SongTapEngine.arm`: returns at once when already armed as that role (`armedPhases`).
- App:
  - New `App/Features/SongTap/SongDropViews.swift`: `SongDropNearbyList`, `SongDropArmedCard` and the `SongDropAsk` modifier
    (`.songDropAsk(...)`), moved out of `SongTapView` and shared with the diagnostics screen.
  - `SongTapDiagnosticsView` (Send): "Say yes first" block (red line when `needsYes`), the nearby list or "Play a song that can be
    shared first...", "Open Song Tap" (opens the cover without disarming), the armed card after a yes, and the same alert. Gate block
    shows "radio starts" and "last ignored tap". The screen now feeds `nowPlayingChanged` so it knows the song.
  - Strings in `SongTapStrings` (`diagYesTitle`, `diagSayYes`, `diagSayYesNow`, `diagNothingToSend`, `diagOpenSongTap`), same as Android.
- Tests: `SongTapBleRouteTests` "Follow-up 2" section (9), `SongTapTwoPhonesTests.armingAgainAsTheSameRole...` (1).
- Docs: `docs/parity.md` row "Connection fix", `docs/test-parity.md` rows.

## Differences from Android

- The connect timeout stays in `tick` (iOS had it before); Android checks it in `maybeConnect`. Same 3 s, same late-answer rule.
- `followSamePhone` also calls `radio.forget` on the old address (iOS drops a peripheral it purges); Android has no forget.

## Not verified

Nothing on a phone. The App/ part compiles only in CI.
