# Sync editor: "loading, then it disappears" (root cause, verified by code reading)

Owner symptom on a real iPhone: tap sync → loading screen → the editor disappears → nothing.

## Root cause
The editor replaces the lyrics cover in ONE shared root `fullScreenCover(item:)` slot, and its
teardown navigates.

1. Every real entry point opens the editor from inside another full-screen cover.
   - The sync chip, the empty-state button and the More row call
     `LyricsSyncEditorView.open(... fromLyrics: true)` (LyricsView.swift ~351-355, used at ~260,
     ~297-298, ~370).
   - `open()` sets `router.cover = .lyricsSync` (LyricsSyncEditorView.swift ~38-42,
     Router.swift ~84) while `router.cover == .lyrics`.
   - Edit song does the same from `.editSong` (EditSongSheet.swift ~287-290).
2. The root has a single `fullScreenCover(item:)` (RootView.swift ~60-65). Changing the item
   identity dismisses the shown cover and presents a new one, so the lyrics screen is torn down
   as the editor is shown.
3. The editor's session lifetime is tied to appear/disappear:
   - `.onAppear(perform: start)` opens a session (~84, ~157-197);
   - `.onDisappear { session?.close() }` (~85-88) closes it.
4. `close()` always navigates (LyricsSyncSession.swift ~310-326): it calls `onClosed` whenever the
   session was open. `onClosed` (LyricsSyncEditorView.swift ~184-191) either runs
   `router.present(.lyrics)` (when the STATIC `returnToLyrics` is set) or `router.dismissCover()`.
   The static flags (~32-34, consumed ~160-163) are shared across instances. So any disappear
   during the swap or re-host navigates the router away, too.
5. The user sees:
   - `close()` sets `.closed` before `load()` finishes, and `.closed` renders as
     `SyncLoadingScreen` (~125), so the spinner shows;
   - `onClosed` then dismisses or swaps;
   - `guard session == nil` (~158) stops recovery on re-appear.
6. CI never caught it:
   - all editor tests launch with `.lyricsSync` as the first cover (UITestLaunchRouter.swift ~243,
     LyricsSyncScreenshotTests.swift ~60);
   - `-syncStep` skips `open()`/`load()`.

Alternatives (fix them too):
- The More sheet's `dismiss()` plus `onSync()` in the same tap (LyricsMoreSheet.swift ~88-90)
  causes a double dismissal that can nil the root binding.
- Edit song requests a root cover while the song-info root sheet is still up.
- Silent closes: song becomes nil → close after 600 ms (~337-346); no load timeout; no
  Connect-active error. `openWaitMs` (~78) is declared but unused.

## Fix (implement all)
**A. Teardown never navigates.**
- Add `enum SyncCloseReason { case user, saved, removed, songChanged, playerUnloaded, viewGone }`
  and `close(_ reason: = .user)`.
- When `reason == .viewGone`, do the teardown but do not call `onClosed`.
- Pass the right reason at each call site. `SyncErrorScreen`'s `action: session.close` becomes
  `{ session.close() }`.
- Editor `.onDisappear { session?.close(.viewGone); session = nil; ... }`, so a re-appear starts a
  fresh session.

**B. Remove the static flags.**
- Make it `LyricsSyncEditorView(songId:entry:onClose:)`.
- Make `SyncEntry` `Hashable` and add `LyricsSyncRequest: Identifiable, Hashable` (id = songId).
- The `.lyricsSync` CoverDestination wraps it with `onClose: { router.dismissCover() }`. That route
  stays for `-screen lyricsSync` UI tests only.

**C. Present the editor from inside the lyrics cover** (Android shows it as an overlay inside the
full player).
- `LyricsView` owns `@State syncRequest: LyricsSyncRequest?` plus
  `.fullScreenCover(item: $syncRequest)`.
- The chip and empty state set `syncRequest` directly.
- The More row sets `syncAfterMore`, and the More sheet's `onDismiss` moves it into `syncRequest`,
  so the editor opens only after the sheet has fully gone.
- Do the same in `EditSongSheet`: it owns its own nested cover and drops the `dismiss()` at ~288.
- If nested covers misbehave, the fallback is a ZStack overlay in `LyricsView` (pause its
  driver/background underneath).
- Keep-screen-on: the lyrics screen now always keeps the screen on (owner decision), so the
  editor's close must not turn the idle timer off while lyrics is still showing underneath.

**D. Errors instead of silent closes.**
- A load watchdog using `openWaitMs`, cancelled in `close()`:
  `phase = .error("Couldn't get the song ready. Close and try again.")`.
- In `open()`: if remote playback (Spotify Connect) is active →
  `.error("Syncing only works on this iPhone. Switch playback back to this iPhone first.")`.
- `currentSongChanged(nil)`: flush the draft, then `.error("Playback stopped.")` instead of a
  silent close.

**Tests.**
- New `UITests/LyricsSyncEntryTests.swift`:
  - launch `-uiTest -screen lyrics -lyricsDemo lines -appearance dark`;
  - tap the "Make the words light up · Sync it yourself" chip;
  - assert `sync.start` exists within 10 s and STILL exists after 3 s;
  - tap `sync.close` and assert `screen.lyrics` returns;
  - a second case goes through "Lyrics options" → "Sync the words yourself".
- Unit test: `close(.viewGone)` must not call `onClosed`.

**Docs.** Update `docs/design.md` (Stage 10 + Integrate B entry-point notes) and
`docs/api-notes.md` for any first-use API.
