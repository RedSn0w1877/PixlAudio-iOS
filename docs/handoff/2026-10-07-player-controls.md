# Player controls: favourite heart, skip timing, top bar (2026-10-07)

Branch `wt/player` (worktree of the iOS repo). Stage 1 of the player batch. Owner decisions:
`DECISIONS.md › Player` (fix A for the heart, Like wired, 220 ms skips, top bar option A).

## What changed

1. **Favourite heart updates at once** (Hoa: "the heart doesn't change until I touch shuffle or repeat").
   Root cause: `LibraryStore.songsById` is `@ObservationIgnored` and `applyEdit` patches it in place, so a body that
   read the favourite through `song(id:)` never redrew after an edit. The fix:
   - `LibraryStore.observedSong(id:)` reads `revision` and then the lookup (**shared file**, own commit).
   - Full player: shuffle / repeat / favourite moved into a private `PlayerToggles` view in `NowPlayingView.swift`
     (`PlayerToggleRow` unchanged). `NowPlayingView` no longer reads the library at all.
   - Song sheet: the heart is a private `SongFavoriteTile` (the sheet's body still uses `song(id:)`, so deleting a
     song doesn't flash "Song not found" while the sheet closes).
   - Lyrics More sheet: `liked` reads the library in the sheet's own body; the `isFavorite` parameter stays as the
     fallback, so `LyricsView` and `LyricsOptionsSheet` are untouched.
2. **Lock screen / Control Center Like** toggles the playing song's favourite (`AppEnvironment` wires
   `NowPlayingController.onLike` / `isFavorite`; **shared file**, six lines). `followFavorites(revision:)` keeps the
   command's state in step with edits made anywhere (`withObservationTracking` on `LibraryStore.revision`).
3. **Previous / next settle 220 ms after the tap**, like play/pause (`AnimatedPlaybackControls.releaseDelay`;
   Android holds a skip 600 ms). ≈ 0.45 s from tap to rest for all three.
4. **Top bar**: no "Now Playing" and no cloud. The output pill names any output but the phone's own speaker
   (Spotify Connect, AirPlay, Bluetooth, wired, car; the kind when the route has no name), hugs its content (50 pt
   icon only), and the right-hand cluster has `layoutPriority(1)`, so a name can use ≈ width − 146 pt before it
   truncates. Dot only for Connect / AirPlay; "Connecting…" + spinner while a Connect session starts. VoiceOver:
   "Playing on <device>" / "Playing on this phone". `AudioRouteMonitor.deviceName` / `kindLabel` (the devices
   sheet's subtitle now uses `kindLabel`).
5. **UI-test id** `nowPlaying.bluetooth` (**shared file** `Demo/UITestLaunchRouter.swift`, own commit):
   `AudioRouteMonitor` fixes the output to "AirPods Pro" for it.

Owner divergences from Android are in `docs/parity.md` (player sheet row, Now Playing row) and `docs/design.md`
(stage 8 notes › Player changes).

## Verified how

- No Mac here: `swiftc -parse` (Swift 6.4, Linux) on every changed file, and `ci/check-forbidden.sh` passes.
  Nothing else compiled locally. PixlCore is untouched.
- Every call site of a changed initialiser was checked: `PlayerTopBar` (one, in `NowPlayingView`),
  `LyricsMoreSheet` (unchanged initialiser), `DemoScreen` switches (the only exhaustive one, `route`, has the case).

## Tests to run on CI

- New: `PlayerScreenshotTests/testFavoriteTogglesImmediately`, `testSongInfoFavoriteTogglesImmediately`,
  `testLyricsOptionsFavoriteTogglesImmediately`, `testExpandedBluetoothLight`; `AppTests/FavoriteObservationTests`.
- Re-check: `PlayerScreenshotTests` (expanded shots: the icon-only pill is now 50 pt, not 58, and the title is gone),
  `SpotifyConnectScreenshotTests/testNowPlayingChipLight|Dark` (the "Playing on Kitchen Echo Show" label is kept),
  `GlassAccessibilityTests/testPlayerTopBarKeepsButtonTraits`, `LyricsScreenshotTests/testMoreSheet` /
  `testOptionsSheetRoute`. Look at the top bar at 375 pt and 440 pt widths.

## Waiting on Hoa's phone

- The heart in the full player, song sheet and lyrics More sheet flips on the tap.
- Skips feel as quick as play/pause. If a skip still hitches, it's the song change's own work in the same frame
  (carousel, artwork, re-theme), not the timer — see `player-controls.json › alternativeCauses`.
- The top bar with AirPods, a car, AirPlay and a Connect speaker; how a very long name truncates.
- **Like**: iOS decides where Like shows. With previous/next enabled the iPhone Lock Screen may not show it at all
  (it tends to appear on CarPlay, the watch, or a Lock Screen menu only when previous track is off). Check whether
  it appears anywhere on Hoa's devices before promising it.

## Merge notes

- `LyricsMoreSheet.swift` is also edited by the lyrics-page work (toggle row, keep-screen-on switch). This branch
  only adds `@Environment(LibraryStore.self)`, the `liked` property and swaps `isFavorite` → `liked` in the
  favourite toggle; keep those when the row becomes liquid.
- `DevicesSheet.swift` lost `outputSubtitle` (now `route.kindLabel`); the Connect-volume work touches the same file.
- The glass-expansion work must not touch the full-player top bar (owner rule); this branch owns it.

## Next step

Integrate, run CI with the tests above, look at the expanded-player and Connect chip screenshots, then hand Hoa a
test build with the checklist above.
