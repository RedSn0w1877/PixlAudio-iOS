# 2026-10-18 iOS everything (branch `ios-everything`, on top of `fix-queue-search-ios`)

Applies the other agent's research (`PixlAudio-RESULTS-from-other-agent.md`) after checking each proposal against the
real code. The research read code only and quoted a different revision in places, so several proposals were rewritten
or not applied. Nothing here was run on a phone; CI is the compiler. PixlCore `swift test` passed on Windows.

## What changed, per bug

### Bug 1: queue scroll over song rows
- Real cause (agreed with the research): `.simultaneousGesture(canReorder ? swipeGesture : nil)` was a
  `DragGesture(minimumDistance: 16)` that claims a drag in any direction and cancels the scroll view's pan.
  `interactive: false` on the glass (PR #12) was kept (harmless) but is not the fix.
- `App/Features/Queue/QueueSheet.swift`: the swipe is now `HorizontalRowSwipe` (a `UIGestureRecognizerRepresentable`
  around a `UIPanGestureRecognizer`, line ~700) whose delegate refuses to begin unless the pan is mostly horizontal
  (`|vx| > 1.2 |vy|`). Vertical drags fail at UIKit level and the list scrolls over the whole row. Behaviour kept: left
  swipe only, tension up to 60 pt, remove past 40 % of the width (`swipeChanged` / `swipeEnded`). The drag handle's
  own reorder gesture is untouched. API ledger entry added.
- The "12 pt padding outside `.contentShape`" point is true but harmless: that strip is outside the row on purpose.

### Bug 5: songs skipping ("source not found")
- `Packages/PixlCore/.../YouTube/TrackMatcher+Matching.swift` (new): `scoreForMatching` and `matchScore` (= the higher
  of the untouched Android-port `score`, which the golden vectors pin, and the lenient one). It strips `(feat. X)`,
  `(with X)`, `[2011 Remaster]`, `- Remastered 2011`, `- 2013 Remaster`, `- Radio Edit`, `ft. X` from both titles,
  accepts `Artist - Title` and `Title - Artist` video titles, counts any credited artist, and treats a 9 to 20 s
  duration gap as neutral (before, any gap over 8 s capped the score below the 0.55 accept line). Live/remix/cover
  etc. are never stripped, so variants still lose. `findMatch` and `findMatchFanOut` rank with `matchScore` and take
  `excludingVideoIds`.
- `InnerTubeParsing.swift:119/153`: `splitBulletSegments` joins the runs between `•` separators, so
  `Lady Gaga & Bruno Mars • MAYHEM • 4:12` keeps the whole artist credit and the real album.
- A video that cannot be streamed is no longer cached forever:
  `App/Playback/Deck.swift:~95` (`DeckItemFactory.makeItem`): when `loadTracks` fails, asks the resolver once for
  `recoverPlayableURL` (never for a rendered override, never when cancelled), detaches the failed asset (it used to
  leak its loader). `SpotifyYouTubeBridge.swift:112`: the Spotify resolver sets the failed video aside (30 min,
  memory only), searches again excluding it and persists the next-best candidate with the new
  `PersistenceActor.replaceAutomaticMatch` (never a manual pick). `SpotifyMatchCoordinator` (line 162) also
  coalesces concurrent play-time matches per song and remembers "searched, nothing found" for 10 minutes (a timeout
  or network failure is not remembered).
- `SpotifyService.start()`: one re-queue of songs the old matcher marked unmatched (`spotify.matcherVersion` = 2), run
  only when `HeavyWorkGate.allowsLaunchWork`, version recorded when the pass starts.
- `DeckItemError` now has a readable message (the skip toast used to print `PixlAudio.DeckItemError error 0`).
- Tests: `TrackMatcherMatchingTests` (the research's 12-title list incl. Starboy, Stay, Bohemian Rhapsody, Hotel
  California, Empire State Of Mind, One Dance; variant, short-title and duration guards; exclusion; bullet
  splitting), `SpotifyMatchCoordinatorTests`.

### Bug 4: lyrics background only after pause/unpause
- `App/Features/Lyrics/LyricsArtworkBackground.swift`: `revision` state (line 41) is read in `body` and in
  `frame(clock:)` and bumped when a bake finishes and when `paused` turns true (also finishes a cut-short fade).
  The clock stays a plain class (an observable one would invalidate at 30 fps). The art is requested via
  `cachedImageOrVariant` first, else a cached bucket size (`displayBuckets.first` = 180 px); 96 px is not a bucket,
  so it missed both caches and re-downloaded the cover.

### Bug 6b: tap to audio
- Applied: `StreamingPolicies.swift` `prepareDelayMs` 1500 -> 500 and `headStartPositionMs` 3000 -> 1000 (the
  research said 400/500; 1 s keeps the next song's head bytes from competing with the current song's first
  bytes). The early preparation (match, resolve, head bytes) now runs only when the app is in the foreground, not in
  Low Power Mode, no recent memory pressure and `allowsLaunchWork` (not safe mode / very hot):
  `StreamPrefetchPolicy.allowsEarlyPreparation`, used at `YouTubePlayback.swift:~126`. The gapless top-up 30 s before
  the end is unchanged. Depth stays 2 on Wi-Fi, 1 otherwise, 0 in Low Data Mode.
- Applied: `YouTubeServices.start()` fetches YouTube's visitor id 3 s after launch (utility priority, skipped in
  Low Power Mode/safe mode); the first play used to pay that request.
- Not applied: `preferredForwardBufferDuration = 1.0` and `playImmediately` on `.readyToPlay` (`Deck.play` already
  calls `playImmediately`, and a 1 s buffer invites stalls on a slow link); skipping `asset.load(.duration)` (the
  Spotify duration can differ from the stream's, which would shift crossfade/gapless timing); starting
  `service.resolve` in the bridge (the loader asks about 20 ms later anyway); warming `base.js` at launch (2.9 MB,
  and VISIONOS needs no JS); fanning out all matcher queries at once (more searches for every song to speed up
  the rare unmatched one); an in-memory videoId cache (the stall claim was not shown).

### Bug 3: Cloud Studio speed (app side only)
- `CloudAudioPreparer.wholePacketFrames` (`CloudAudioPreparer.swift:282`): CoreAudio reports `mFramesPerPacket` 0
  for FLAC, so pass 1 padded nothing, the read-back found the encoder's padding and the whole song was decoded and
  encoded again. Pass 1 now rounds up to 4,608 frames. The read-back after pass 1 is kept as verification (the
  research dropped it), so the typical cost goes from 4 passes to 2. The old second pass remains as the fallback.
- `CloudTiming.statusPollIntervalMs` 15 s -> 2.5 s, and the poll loop uses `activePollInterval` (2.5 s) only while a
  job is at RunPod, otherwise the old 15 s (`CloudStudio.swift:666/675`). `/status` is free; the `out/` listing is
  one cheap R2 operation per tick, foreground only.
- Existing `CloudStudioTests` advance the clock 16 s per pump, so they are unaffected.

## Worker side: nothing changed (owner decisions)
No file under `cloud/runpod-worker/` was touched and `deploy/endpoint.json` is unchanged. Reasons, with the cost trap
in mind (an idle worker is billed about $0.65 an hour; the 2026-10-08 incident sat 7+ minutes; the reaper only runs
every 30 minutes):
- Dropping `refresh_worker` on `last_in_batch` / selftest / bench: NOT applied. It is the protection against the idle
  trap and the app already marks only the last job of a burst, so back-to-back songs of one batch stay warm.
- `warmup` op fired on Send: NOT applied. The models load at process start (`handler.py` `load_models`), so the op
  would do nothing but wake a worker; with `idleTimeout` 10 s the worker would be gone again before a 15 to 30 s
  prepare+upload finishes, and a warmup that does not refresh would strand an idle worker (the trap), one that does
  refresh gives little. Each Send would add a billed cold start (roughly 25 s of GPU, about $0.005). Owner decision;
  if wanted, make it once per batch, at most every 5 minutes, `refresh_worker: True`.
- Parallel stages 6/7: NOT applied. The research diff does not match the real `pipeline.py` (stage 6 mutates
  `run.status/warnings/refresh_worker`, a lyrics failure with stems leaves a `partial` result, `del vocals` frees
  memory between the stages). The gain is about 1 s of 6.5 s.
- `ADA_24` pool: NOT applied. No evidence of better availability, and about 1.6x the per-second price. Owner decision:
  add `"ADA_24"` to `gpu.pools` in `deploy/endpoint.json` (about +$0.0007 a song if it is picked).
- Dropping `htdemucs_ft` / shrinking Qwen3-ASR (about 5 GB of image weights): NOT applied. `stems4` and ASR
  transcription are schema features other clients may use; the 200 s wait was not shown to be the image pull.
- Upload the streamed M4A unchanged (`forceDecode: false`): NOT applied. Streamed AAC is decoded to FLAC on purpose,
  for sample-exact import checks.
- Research item 5.4 `trackPageSize` 100 -> 50: NOT applied. Android beta2 still uses 100; iOS import works, and the
  offset advance uses the server's reported limit anyway. `SearchPacer`: not applied (no evidence).
- Research 5.5 (`lastError` wiped by `itemChanged`): not found in the code (`lastError` is only set).
- Bug 2/6a review: the research found the branch clean; its one suggestion (queue the remaining search results
  after an online tap) was left as a product decision.

## Plain phone checks
1. Queue: open it, put a finger on the middle of a song row and drag up and down: the list scrolls. Swipe a row
   left past about half the width: it is removed. Drag the three-line handle: reorder still works.
2. Songs: play a playlist with "(feat.)", "(with)" and "Remastered" titles (Starboy, Stay, Bohemian Rhapsody): they
   play instead of skipping. If a song's video is broken, it should switch to another version after a moment instead
   of skipping. On first launch after the update, the Spotify dashboard's "Ready to play" count should climb.
3. Lyrics: play a song, open lyrics (also with Low Power Mode on): the moving artwork background appears without
   pausing; leaving and re-entering shows it at once.
4. Speed: tap a song right after launch and in the middle of a playlist; use Settings > Diagnostics start timings.
5. Cloud: send a song; preparing should take a few seconds (was 15 to 35 s); the phone should notice the finished
   job within a few seconds.
