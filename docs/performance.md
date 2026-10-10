# Transition performance

Hoa's first install (main `4e4ad32`, iPhone on iOS 27, 120 Hz) felt fast but showed "a few noticeable stutters
between menu or page transitions". Branch `perf-transitions` (2026-10-02) audited every transition — tab switches,
pushes and pops, Library pills and sorts, search, sheets and covers, the player sheet, the mini player appearing —
and fixed what was found. Target: no dropped frame at 120 Hz in any transition, with the look unchanged (it is a
port: layouts, sizes, colours and glass stay exactly as they are). This page records what was slow and the rule
that now prevents it. AGENTS.md › Performance rules still apply; these are the transition-specific ones.

## Measuring

`UITests/TransitionPerformanceTests` drives the transitions in a demo library of real size (`-demoScale 100`: the
24-song demo library repeated 100 times, about 2,400 songs and 1,300 albums; copy 0 keeps its ids, so screenshots
don't change) and records, per transition, five iterations of:

- `XCTHitchMetric(application:)` (iOS 26) — reports on a device; the CI simulator reports nothing for it;
- `XCTOSSignpostMetric.navigationTransitionMetric` for pushes and pops (the simulator reports it for some);
- `XCTClockMetric` and `XCTCPUMetric(application:)` — the app's CPU time is the useful simulator number: main-thread
  work shows there, the GPU cost of Liquid Glass does not.

Run it with `[shots:TransitionPerformanceTests]` in a commit message; CI copies every "measured [...]" line into
`perf-metrics.txt` in the `shots-<sha>` artifact and the job summary. Simulator numbers are indicative; for frame
drops use Instruments on the phone (Hitches + Core Animation + SwiftUI templates).

### What the CI simulator showed (2026-10-02)

Matched runs — same CI, same test code, only `TransitionPerformanceTests`: **baseline** = main's app without these
fixes plus the demo scaling the test needs (branch `perf-baseline`, run 37043124411); **after** = this branch at
`545aa45` (branch `perf-after`, run 37043122500). Two more runs of the same app code (the full rounds 37033768416
and 37043079129, where the measurements run after every screenshot class) show the spread. Average app CPU time per
iteration, seconds:

| Transition (one iteration) | Baseline | After | Same code, other runs |
|---|---|---|---|
| Tab switches Home → Search → Library → Home | 1.33 | 1.69 | 1.66 · 2.79 |
| Library › Albums → album → back | 3.24 | 3.40 | 3.67 · 2.71 |
| Library › Artists → artist → back | 2.98 | 3.45 | 3.91 · 2.79 |
| Library pills ×4 | 3.45 | 3.78 | 4.77 · 3.31 |
| Settings → Appearance → back | 1.03 | 1.33 | 1.47 · 2.09 |
| Song options sheet open → drag closed | 3.91 | 4.60 | 4.70 · 5.57 |
| Mini player → full player → collapse | 1.32 | 1.28 | 2.14 · 1.29 |

The same code varies by up to ~70 % from run to run (a fifth run without the full player's pre-warm, 37045873142,
measured 30–75 % more than "after" in every test, settings and tab switches included, which never build the full
player). The CPU time is dominated by XCUITest's own queries (each one snapshots the app's accessibility tree), the
navigation-transition durations stay at 0.54–0.72 s either way (the push animation itself), and the hitch metric
reports nothing on the simulator. So the simulator can't resolve these fixes in either direction: they stand on the
code-level findings below, and the on-device check is Instruments' Hitches template on Hoa's phone.

CI screenshot flakes that show up in any comparison with main and are not changes (main's own runs show them too):
swipe-scrolled shots land at slightly different offsets (`home7b-shelves`, `stats-scrolled`, `aiPlaylistLab-scrolled`,
`spotifyDashboard.tested`); About and the Equalizer are caught at different points of their appear fade; the
lyrics cascade frames and animated backgrounds move; the full player's cover is sometimes caught at its paused
scale (0.95) in shots taken right after launch (`playerExpanded`, `artistPicker`, `sleepTimer`, `devices`); the
playlist's More options menu (`MenuRecordingTests`, `menuPlaylistMore`) is caught at slightly different points of its
settle — main's two runs of `9e5ac90` differ from each other the same way, and a rerun of this branch's `73bc9d8`
(run 37074696142) matched main's latest run pixel for pixel in all three menu shots.

### A stuck full player, found by a probe (2026-10-03)

One full-suite run (37066421213) caught `playerExpanded-dark` as an empty screen in the album's `primaryContainer`:
the expanded card with no full player on it. A throwaway probe (`BlankPlayerProbeTests` on the experiment branches
`perf-x-blank*`, never merged) launched straight into the expanded player (`-screen nowPlaying`) and checked each
screen two seconds later: this branch showed it in 15 of 230 launches (2/40, 4/70, 8/70 without the lyrics shader
warm-up, 1/50) and never recovered; main showed it in 0 of 40. The probe's state dump named the cause: the full
layer's fade modifier (`FullLayerPlacement`, a modifier reading `playerSheet.expansion` itself) was evaluated once,
read 0, and was never evaluated again although the expansion was 1 and `FullPlayerLayer` around it re-ran. It had
been inserted by an update that `expand(animated: false)` forced: `isExpanded` and the build were set first, then
`withoutAnimation { expansion = 1 }` applied them as their own update before setting the expansion, and the new
modifier missed that change. Fixed in `da5d221`: the non-animated expand sets all three in one transaction, the
full layer's fade takes its progress from `FullPlayerLayer`'s body, and an expand that had to build the player
starts its spring on the next main-actor turn. With the fix: 0 of 50 launches, 0 of 25 taps and 0 of 25 drags
before the pre-warm (`-probeNoPrewarm`); the unfixed tree in the same run: 1 of 50, 0 of 25, 0 of 25. Only the
launch-into-expanded path (UI tests and launch states) showed it; the app's own tap and drag paths never did.

## What was slow, and the rule now

| Transition | What cost frames | Rule |
|---|---|---|
| Tab switch | The cross-fade ran on the selection spring, whose tail kept both full-screen, glass-heavy stacks composited until ~0.6 s. | The fade has its own 0.21 s curve (`PixlMotion.tabFade`, `animation(_:body:)`); only the tab bar's pill springs. |
| Push / pop from a tab root, first play | The bars sat in one `safeAreaBar` around all three stacks: every push, pop or first play re-ran the safe-area layout of all three (hidden ones included), for an inset the pages never received. | The bars are an overlay that takes no layout space. Pages lay out exactly as before: content scrolls under the bars, and a page that needs room above the mini player reserves it itself. Never put shell chrome in an inset that wraps every tab. |
| Keyboard | The mini player popped away un-animated and was rebuilt a frame late. | The card steps aside in the bars' own transaction and keeps its slot (`hiddenForKeyboard`). |
| Song change, play/pause | `PlaybackStore.current` was computed from the queue, and rows took closures: every live tab (hidden ones too) re-rendered its whole body. | `current` / `currentSongId` are stored; rows read playback in `PlaybackRowState`; screens don't read playback in `body`. |
| Album / artist push, album cards | Colour schemes came only from an actor: every page and card started in the brand theme and re-themed (0.25 s) mid-push. | `ColorExtractor.peek` reads a synchronous mirror in `body`; only real misses fade. |
| Pause, a second after any song change | The whole queue (often the library) was JSON-encoded on the main thread. | `QueueSnapshotStore` captures on the main actor and encodes in a `@concurrent` function. |
| Library pills, sort, rescans | Six eager pages re-ran on every LibraryView pass (fresh closures); sorts ran on the main actor below 1,500 songs; one monolithic `lists`; the Songs / Liked sort folded every title (NOCASE) and parsed both ids on every comparison (~60,000 for 5,000 songs). | Pages take plain values + `LibraryActions`; `LibraryModel` memoises each list by its inputs, computes off the main actor after the first frame, lands without animation; inputs compare the library by `LibraryStore.revision`. Sorts compute their keys once per element (`LibrarySorting.noCaseKey`, parsed ids; same order, checked against the old comparator in `LibrarySortingTests`). |
| Any library edit or rescan | Whole-snapshot comparisons in Home, Search, Library and detail pages; lookups rebuilt on the main actor; `SnapshotLoader` ran on its caller's actor. | Key on `library.revision`; snapshots arrive with lookups built off the main actor (`@concurrent`); edits patch lookups (`applyEdit`). |
| Detail pages | Album / artist / genre / folder pages filtered and sorted the whole library in their first frames, then re-rendered. | `library.detailIndex` (per revision, built off the main actor) + a `ViewMemo` in `body`: content in the first frame, no second pass. |
| Player sheet | The full player was rebuilt on every expand and drag; the morph wrote its progress into the environment every frame. | The full player is built once (pre-warmed) and kept hidden at a zero frame (a hidden screen-sized layer would widen the card's `ZStack`, and the mini player with it); fades are their own `Animatable` modifiers. Never write fast-changing values into the environment. |
| Player → album / artist | Collapse and push shared their frames. | Collapse first, push at 10 % (`collapse(thenAfterReaching:)`), as Android. |
| First visits, revisits | Artwork keyed by exact pixel size, FIFO, unbounded: placeholders and fade-ins mid-push; every new size re-read the source (embedded art is an AVAsset metadata read). | Size buckets, byte-bounded LRU, purge on memory warning, stand-in from another size. A display bucket missing on disk is downsampled from the smallest larger bucket already on disk before the source is touched (not written back, so every cached file is one generation from the original; colour extraction's 128 px always reads the source). Disk thumbnails are written atomically, so no reader sees a half-written file. |
| Sheets | Wrap-content sheets opened at `.medium` and re-targeted; the queue sheet copied the queue per pass and re-ran its body per drag event; pickers filtered the library on the main actor. | Remembered heights; per-row reorder model; index-addressed rows; precomputed / off-main filtering without debounce. |
| Settings, notices, stats | Whole category bodies built in one frame; ungrouped row glass; a 30 KB `Text`; Stats / Recently Played swapped a spinner for their content mid-push. | Sections are lazy-stack children; groups share a `GlassEffectContainer`; notices by paragraph; `ScreenDataCache` opens on the last result. |
| First use of a service | CIContext, route monitor, AI service + Keychain, lyrics shader, first WKWebView, audio session — all on the main thread inside a transition. | Create them on their actor, at idle, or off the main actor (`@concurrent`), never in a transition's first frame. |

## Things to remember

- Under approachable concurrency a plain `nonisolated async` function runs on its caller's actor, and a `Task {}`
  started from a view inherits the main actor. Off-main work is `@concurrent` or `Task.detached` (the lyrics shader
  warm-up builds and compiles its `Shader` in a detached task).
- The audio session is one per process: an activation that finishes off the main actor checks a process-wide record
  of decisions, so a late result never undoes a newer activate / deactivate — not even one made by another
  `AudioSessionController` (tests create one per engine).
- Glass shapes that sit together go in one `GlassEffectContainer` with spacing below their gap. Children of a
  container (and of any non-element view with its own identifier) keep only their accessibility labels: UI tests look
  such controls up by identifier **or** label.
- The bars' room is reserved per page (`BottomBarsClearance`: `safeAreaPadding` on each tab root and route, from an
  environment value set on each stack). A push or pop never changes a page's inset (a page is a root or a route for
  life); only the mini player's first appearance / last disappearance, compact mode, and the keyboard on the
  selected tab do. Equal values don't invalidate the pages.
- A `safeAreaBar` (or `safeAreaInset`) around a `NavigationStack` does not reach its pages here: the old shell bar
  never inset them. Screens that scroll to their end or pin content to the bottom (Home scrolled down, YouTube
  sign-in, the brick game, floating Save buttons) are the screenshots that show a changed inset.
- `LibraryStore`'s lookups (`song(id:)`, `album(id:)`, …) are `@ObservationIgnored` and patched in place by edits: a
  `body` that shows a field an edit changes in place (the favourite heart) reads `observedSong(id:)`, which also
  reads `revision`, in its **own small view** (`PlayerToggles`, `SongFavoriteTile`), so a library revision (an edit,
  an artist-image batch, a rescan) redraws that view only. Never from list rows, `NowPlayingView.body` or
  `LyricsView` (2026-10-07: the full player's heart stayed stale until shuffle or repeat redrew the player).
- A view that should start with data has it on its first frame (a synchronous cache, a memo in `body`, or a value
  seeded in `init`), not in `onChange(initial:)` / `task`, which costs a second pass or a pop-in.
- A cache that replaces a synchronous answer must be right whenever the old answer was: key it on **every** input
  the old computation read and fall back to the old computation on a mismatch, and drop it when something changes
  its inputs behind its back. `AIProviderStatus` is keyed on the provider **and** its base URL, drops its entry
  while a refresh's own check runs (a key saved a moment ago is never answered from the old entry), discards a check
  that finishes after a newer refresh or invalidation (a generation counter), and is invalidated and re-checked
  after a settings restore (which writes the Keychain); `PlayCountStore.reload` re-reads play counts once a play's
  engagement row is written (the history revision is bumped before that write lands) and after a restore.
- A view inserted by an update that `withAnimation` / `withTransaction` forces (they first apply the changes still
  pending, as an update of their own) can miss a change made inside the block: its first read of an `@Observable`
  value was never refreshed (the stuck full player above). Set the state that inserts a view and the values it
  reads in one transaction, make follow-up changes on a later main-actor turn, and feed an `Animatable` effect from
  a parent body that already follows the value rather than from a modifier inserted with it.
- Work moved off the main actor lands later, outside the transaction that triggered it: replay that transaction's
  animation when the result lands (the song picker's Liked chip and storage filter), or the change snaps where it
  used to animate. And guard the button that started it against a second tap (Edit song › Save).
- Moving a side effect earlier changes what happens when the rest fails. The audio session is now activated while
  the first item loads (`prepareActivation`); if nothing plays after all — every item failed, or a pause came first
  — `releasePreparedActivation()` gives it back (with `.notifyOthersOnDeactivation`), as before the session was only
  activated by a successful start.
- System menus on Apple's glass button style (`GlassCircleMenu`, the playlist's Sort Songs and More options) stay
  outside any `GlassEffectContainer` added for performance: their morph out of the button is the one Hoa approved
  on main, so `DetailTopBar` leaves its circles ungrouped (the collapsing album / artist header, which has no menus,
  keeps its container; Library's action row had its container before the menus came).
- Grouped glass keeps its accessibility: `UITests/GlassAccessibilityTests` checks that controls inside the new
  containers are still buttons, sliders and switches with their labels (settings groups, the player's top bar, the
  album header, the queue's toolbar and ⋯ menu).
- A glass morph needs a container that stays in the tree and an animation nobody overrides (the queue's ⋯ menu,
  2026-10-07). The toolbar and the open menu share one `GlassEffectContainer` whose content switches; an `if` around
  the container, or a modifier applied conditionally to it, changes its identity and drops the morph. An implicit
  `.animation(_:value:)` on an ancestor replaces the `withAnimation` spring for the whole subtree. Modal accessibility
  (`.isModal`, escape) goes on the part that exists only while open, never on a wrapper that also holds the closed
  state. The queue menu is PixlAudio's own glass, not a system `Menu`, so the rule above about keeping system menus
  outside containers doesn't apply to it.
- A see-through tall sheet (`PresentationDetent.tallGlass`: queue, song sheet, AI Daily Mix, Taizo) leaves the
  screen beneath on display, so that screen keeps rendering (the full player's ambient styles at their 30 Hz under
  the queue). A `.large` sheet covered it.

## Pending on-device checks (Hoa's phone, before merging)

1. **Instruments › Hitches** (plus Core Animation and SwiftUI) over the transitions in scope — the real frame check.
2. **Pressed settings rows**: rows in a group are 2 pt apart in one `GlassEffectContainer(spacing: 0)`; press and
   hold a row, a row hosting a Toggle and one hosting a Slider, and check the interactive highlight stays inside the
   row (no blending into its neighbour) and looks as on main.
3. **VoiceOver / Accessibility Inspector** over the player's top bar, an album / artist header and a settings group:
   every control announces its label and its button / switch / adjustable trait as on main (CI checks the element
   types; the spoken result is the device's).
4. **Tap-to-expand fade**: record main's and this branch's tap on the mini player (screen recording, slowed down) and
   compare the full player's fade-in. The full player is now pre-built and never inserted on expand, so it fades
   with `fullPlayerAlpha(p)` alone. On main it was inserted in the same tap: `isExpanded = true` is set outside the
   expand's `withAnimation`, and SwiftUI applies each transaction's changes as their own update, so the insertion was
   most likely unanimated and the curves match; if main's recording shows an extra fade (the default opacity
   insertion, roughly `spring(p) · fullPlayerAlpha(p)`), multiply `FullLayerPlacementEffect`'s opacity by the expand
   spring's progress during non-drag expands to reproduce it.
5. **Idle cost of the hidden pre-built full player**, and whether zero-opacity glass costs anything (the card's glass
   is still removed above 25 %).

## Streaming start (2026-10-07, branch `wt/stream`)

Streamed songs start through the network path in docs/design.md › Streaming speed. Nothing was measured on a device
before these changes (the estimates in `plans/streaming-speed.json` come from the code: a 1 MiB first chunk costs
~0.8 s at 10 Mbps and ~2.7 s at 3 Mbps; the remote-config fetch blocked the first stream of every launch for up to
10 s; skips rebuilt the next song from scratch). The app now measures every start: Settings › Developer › Test
playback › Stream start timings (and the deep probe's "Last start"). Read it as:
`• Song — 840 ms to play` / `steps (ms): url · tracks · item · start` / `resolve: … via VISIONOS (…) · n: no ·
config wait 0 ms` / `network: first chunk at … ms (128 KB), N fetches` / `loader: N requests (…), N cancelled`.

### Pending on-device checks (Hoa's phone)

1. Play five streamed songs cold (fresh launch, songs never played) and five skips; copy the Stream start timings.
   Expected: first chunk 128 KB, `config wait` ≈ 0 ms, skips to the next song "(skip into the prepared song)" when
   crossfade is on or in the last seconds, otherwise "network: none before playback" for the next 1–2 songs.
2. Same on cellular and with Low Data Mode on (Settings › Cellular › Data Mode): one song prepared on cellular, none
   in Low Data Mode.
3. Look at `n: yes/no` on VISIONOS resolutions and at the `cancelled` counts: `n: yes` makes R9 (cipher warm-up)
   worth doing; many cancellations or a slow first chunk after R2 make R10 (delegate streaming) worth doing; slow or
   failing VISIONOS resolutions mean turning on `innertube.hedge` in `remote/config.json` (R8).
4. A skip during a crossfade's prepared window plays at full volume at once (R7), and the gapless hand-over at the end
   of a song still has no gap.

## Launch, library and artwork (2026-10-08, branch `perf-ios-oct8`)

An audit of launch, library, artwork, the player and playback found work the app did for nothing. The look and the
behaviour stay as they are; the handoff (`docs/handoff/2026-10-08-ios-perf.md`) says what each change is worth and what
to check on the phone. The rules these changes leave behind:

| Where | What was slow | Rule now |
|---|---|---|
| Launch and foreground rescan | Every launch (300 ms in) and return to the app read the whole song table three times, rebuilt the artists and albums, rewrote the scan state and re-queried the music library, even with nothing changed. | An incremental scan compares what the last scan left (`ScanFingerprint`: all scan options, roots and where they live, hidden songs, tag overrides, the music library's last change, this build; the song table's row count; every file's stamp) and returns at once when all of it matches. It reads, builds and writes nothing and `LibraryStore.refresh` skips its reload (`LibraryImportSummary.isNoOp`). Add every new input of a scan to the fingerprint. |
| Mini player at launch | The restored queue waited for a full SwiftData read although the cached snapshot was already on screen. | `installCached()` → restore the queue → `reconcileWithStore()`; the cache and the queue decode from the first line of `start()`. Without a cache the order is as before. |
| Hidden tabs | All three tab roots were built at launch, two of them invisible. | A tab is built when first selected or by the idle build 2 s after launch (`prebuildHiddenTabs`, Library then Search); a built tab keeps its stack for life. |
| Full player | The glass tab bar and the tab's glass rows were composited under every frame of the opaque, settled player. | `PlayerSheetController.coversShell` is set when an expand's animation is gone and cleared first by anything that moves the card; `ShellCoveredByPlayer` fades the shell to 0 without animation. Never leave it set while the card can move. |
| Artwork | Embedded art was cached per audio file (N tracks, N decodes, N thumbnails, N colour extractions); decodes were never cancelled and all ran at once. | Embedded art is keyed by its picture (`EmbeddedArtworkIdentity`, `c:<digest>`); at most 3 decodes and 2 extractions run, newest first (`LIFOGate`), and a request whose last view is gone is cancelled. Learn a digest wherever the bytes are in hand. |
| Album colours | The scheme mirror started empty and held 1,024 pairs: every launch showed the brand tint, then fetched and animated a re-theme. | `ColorExtractor.warm` fills the mirror from the stored themes in one read; the restored song is themed before it appears (`ThemeStore.seed`); theme saves are coalesced (a batch delete flushes them first). |
| Skip in gapless mode | The next song was built in the last 4.5 s only, so almost every Next built it from scratch. | A next song from the library's files is prepared after the countdown's debounce (`preparesHandOverEarly`); streamed songs keep the late lead. |
| Spotify matcher | Every 48-track batch fetched and sorted every pending row, saved once per track, and the dashboard re-read every row per batch. | Keyset page in the store, one write per batch (`updateAutomaticMatches`), counters read only the id column, dashboard refresh at most every 2 s. |
| CI numbers | `TransitionPerformanceTests` ran on the Debug build. | `[perf]` in a commit message also builds `PixlAudioPerf` (Release) and runs them; the numbers are in the job summary and the `perf-<sha>` artifact. Compare Release with Release. |

## Many jobs at once (2026-10-09, branch `fix-many-jobs-ios`)

Report: "when multiple active jobs are working at once it lags up the app and the phone, then crashes". The causes
(file:line in `docs/handoff/2026-10-09-many-jobs-fix.md`) were the heavy local jobs overlapping in memory (the model
install's compile next to lyric alignment or stem separation), CPU-bound work at user-initiated priority, and the
Active jobs aggregator re-reading every source on every progress tick. Rules these changes leave behind:

| Where | Rule now |
|---|---|
| Heavy local jobs | Anything that holds hundreds of MB or every core takes a lease from `HeavyJobGovernor.shared` (one at a time, FIFO): the model install, lyric alignment, stem separation. Take it for the compute part only, after the model is in hand — never while waiting for something that needs the lease (the install), or two jobs deadlock. A job queued behind it shows "Waiting for other work to finish" in Active jobs (`JobState.waiting`, `ModelManager.waitingToInstall`). |
| Priority | Minutes-long CPU work (the TAIS lane, Cloud song preparation, the model install) runs at `.utility`, so the UI keeps the cores. Cloud preparation drops to one song at a time while the lane is busy. |
| Memory | Core ML models are released when the lane drains, when the other kind starts, and on a memory warning with no job running. `AudioPCMReader` splits channels buffer by buffer (no interleaved copy of the whole song). Whole files are never loaded into `Data` for a job; use mapped or streamed reads. |
| Active jobs | `ActiveJobs` re-reads its sources at most 4 times a second (`UpdateCoalescer`): the first change after a quiet moment is handled at once, a burst is served by one re-read. The sheet's rows are stored (`active` / `recent`), refreshed only while the sheet is up, written only when they differ, and `ActiveJobRow` is `Equatable` on its job. Home reads only `badgeCount` / `isWorking`. |
| System progress | `TaisBackgroundRun.update` sends the Live Activity at most twice a second. |
| Failures | A job that fails ends: a terminal state, a one-line reason (`JobFailureText`), its lease / lane slot / background run released (`defer`), no retry without a budget (`RetryBudget`; Cloud has its own ladder), and no transfer without a watchdog (`StallMonitor`: a background `URLSession` waits for connectivity for days, so a download that stops moving is failed after about two minutes). Anything shown in Active jobs has a cancel through its source, and a failed row can be dismissed (`ActiveJobs.cancelAll` / `clearFinished` / `dismiss` / `retry`). The badge counts running and waiting work only. One timer for all watchdogs, none while nothing is armed. |
