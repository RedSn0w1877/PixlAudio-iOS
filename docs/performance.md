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

For motion, `UITests/TransitionRecordingTests` (opt-in) runs the player sheet's expand and collapse (twice, then a
collapse interrupted 0.12 s in by an expand — the UI-test launch flag `-reexpandAfterCollapse`, since XCUITest waits
for the app to idle before every tap, so a tap from the test lands only after the fade) and held-down settings rows
slowly; with `[shots:TransitionRecordingTests] [record:TransitionRecordingTests]` CI films it
(`record-TransitionRecordingTests.mp4` in the shots artifact), so a branch's frames can be compared with main's
(`ffmpeg -fps_mode passthrough` keeps the recorder's own frames; it captures roughly 10–30 a second, too few for a
spring's curve but enough to see what is on screen).

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
code-level findings below. Read plainly, though, the matched pair leans the other way — the branch is higher in 6 of
7 transitions — and the branch adds some steady main-thread work of its own (the hidden pre-built full player
re-renders on song changes, play / pause and queue edits). So nothing here counts as a measured gain: Instruments'
Hitches template on Hoa's phone is a hard gate before merging (see "Merge gate" below). The two runs of the review
round (37106537754 and 37113795352, on a busier CI) measured above both columns everywhere — tab switches 3.60 /
3.04, the settings subpage 2.10 / 1.45, the song options sheet 6.51 / 4.55 — which is the noise again.

CI screenshot flakes that show up in any comparison with main and are not changes (main's own runs show them too):
swipe-scrolled shots land at slightly different offsets (`home7b-shelves`, `stats-scrolled`, `aiPlaylistLab-scrolled`,
`spotifyDashboard.tested`); the lyrics cascade frames and animated backgrounds move; the full player's cover is
sometimes caught at its paused scale (0.95) in shots taken right after launch (`playerExpanded`, `artistPicker`,
`sleepTimer`, `devices`, `nowPlaying` — a missed first play-state change, measured below; main's run 37108962548
caught it in `nowPlaying-dark` and `sleepTimer-light`); the playlist's More options menu
(`MenuRecordingTests`, `menuPlaylistMore`) is caught at slightly different points of its settle — main's two runs of
`9e5ac90` differ from each other the same way, and a rerun of this branch's `73bc9d8` (run 37074696142) matched
main's latest run pixel for pixel in all three menu shots. About and the Equalizer are not a timing flake of that
kind: see below.

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

A second probe (`StaleProbeTests`, `perf-x-stale*`) measured an older flake, the full player caught with the Play
icon and the paused cover scale (0.95) while music plays (`playerExpanded`, `devices`, `sleepTimer`, `artistPicker`
shots): a full player built at launch sometimes misses the first play-state change after it, and shows it until the
next one. It is main's as much as this branch's (launching into the expanded player: main 5 of 45, this branch 7 of
45; final run 37096729627 caught it again in `playerExpanded-dark` and `devices-light`), it doesn't heal by waiting,
and the next play / pause corrects it. It never happened when the player was pre-built and expanded later (0 of 30
on each), and the pre-built player, kept hidden while collapsed, missed none of 160 play / pause changes made from
the mini player (run 37103669582) — so keeping the player between expands doesn't make it stick.

### The collapse lost its fade; pressed rows didn't change (2026-10-03, CI recordings)

The review asked for the checks that need eyes on motion. CI can film a UI test (`[record:Class]`), so a throwaway
class (`PressFadeRecordingTests` on `perf-x-hdr` and `perf-x-hdr-main`, now `UITests/TransitionRecordingTests`) ran
the same slow steps on main and on this branch (runs 37106597201 and 37106594140), and the videos were compared frame
by frame:

- **Pressed settings rows** (two interactive rows of one group; a choice row between an item row and a switch row,
  held down for 2.5 s): where the recorder caught the highlight (the first and the third row) it is the same on
  both — the row's own shape brightens, the 2 pt gap and the neighbours' corners stay intact, nothing blends in the
  branch's `GlassEffectContainer(spacing: 0)`. Matching frames are identical or differ by a few thousand pixels of
  the press animation's phase.
- **Expand from a tap**: the same; the recorder catches only one or two frames of the 0.4 s spring, and those agree.
- **Collapse from the button**: different. On main the full player was removed by the collapse's update, so SwiftUI
  faded it out with the default opacity transition on the collapse's spring, frozen where the collapse began, while
  the card shrank around it. The branch kept the player built and hid it on the collapse's first frame: the card
  collapsed empty, a plain album-colour shape, until the mini player faded in. Fixed in `c9a81ee`: a collapse keeps
  the kept player's placement where it began (`collapseFadeFrom`) and fades it from 1 to 0 on the collapse's own
  animation (the Reduce Motion ease too), and hides it as before once that animation is done
  (`withAnimation(_:completionCriteria:_:completion:)`, `.removed`). While it fades it takes no touches and is hidden
  from VoiceOver, as a removed view was. The fixed build's recordings (runs 37111666646 and 37113795352) show the
  full player in the card where the unfixed one showed it empty, and the second caught a frame a quarter of the way
  down with the player part-faded in the shrinking card, as main's recording shows it. The recorder catches too few
  frames of the 0.4 s spring to compare the fade's curve, which stays on-device check 4.
- **But `c9a81ee` brought back a layout jump** (found by the review in run 37113795352's recording, on both
  collapses; it was missed when that recording was first checked). The fade used one flag for the full layer's
  visibility and for its zero frame (`767ba66`: a hidden screen-sized layer must take no room in the card's
  `ZStack`). So for the whole fade, about 0.5 s, the layer took room again, the mini player was laid out at the
  screen's width (402 pt instead of the card's 370: its controls 32 pt to the right, Next clipped by the card), and
  the controls jumped back when the fade ended. Main zeroes the frame on the collapse's first frame (its player is
  removed there), so its mini player never moves; pre-perf main (`perf-x-hdr-main` on `9e5ac90`) stayed clipped
  after a collapse and never jumped. Fixed in `53b7e56`: two gates. The zero frame follows `occupiesLayout`
  (expanded, dragging or expansion above 0), the opacity follows `isShown` (that, or fading out). The zero frame
  is anchored top-leading and doesn't clip, so the fading player still draws in the same place, and the mini player
  gets the card's width from the collapse's first frame, as on main. Re-filmed in run 37120024541: in both collapses
  the mini player's controls (previous / play / next, the strip's right 147 pt) match their resting frame within 1
  grey level (of 255) from the first frame the card has arrived, about 0.3 s after the tap, and stay there — where
  run 37113795352 showed them 32 levels off for 0.4–0.5 s and then jumped. The only later change, a sub-pixel move
  of the whole card about 0.4 s on (2.5–2.9 levels, two frames), is in main's recording too (run 37106597201).
- **An expand during the fade** (a tap on the mini player within about half a second of a collapse) cleared the
  fade in a separate non-animated update and only then set the expansion inside `withAnimation`; depending on how
  SwiftUI combined the two, the player could pop to full opacity in a still-small card or restart its fade. Since
  `53b7e56` the expand clears the fade inside its own `withAnimation`, with the expansion (one transaction, as the
  rule below says): the placement springs on from where the collapse froze it and the opacity from where the fade
  had got to. A drag still clears it without animation, as the drag itself sets the expansion. Known limit: a
  collapse while an expand's spring is still running freezes at the model value (1), not the fraction on screen
  (the controller can't see the presentation value), so a collapse tapped before an expand has settled fades the
  player from its resting placement. `TransitionRecordingTests` films the interrupted collapse.

### Settings pages opened scrolled (2026-10-03)

The review noticed that About and the Equalizer screenshots were not caught mid-fade, as this page said before:
they were scrolled a few points, the content fully opaque and the collapsing header part-collapsed — on main in 3
of 6 About samples (up to about 10 pt), on this branch in 8 of 8 (6–20 pt) and in 2 of 4 Equalizer-light samples
(about 20 pt). The cause is `SettingsHeaderSnap`, the scroll target behaviour that snaps a release in the middle of
the header's collapse. SwiftUI asks a scroll target behaviour for a target not only when a scroll gesture ends but
also "when a scrollable view's size changes" (developer.apple.com), and the size changes while a page is at rest:
the first layouts after a launch, the mini player's first appearance, main's per-page bars clearance. Asked then,
the snap read the resting list as part-collapsed and moved it. The numbers below fit a target whose top is
already 0 at rest, to which the snap adds the 62 pt top inset: a resting page moves to `distance − 62 pt` when its
collapse distance lies between 62 and 124 pt (about 2 pt on the 128 pt headers, 22 pt on the 148 pt headers of
two-line titles), and About (54 pt) only by varying amounts while its inset is still settling after a launch.

A probe (`HeaderSnapProbeTests` on `perf-x-hdr2` / `perf-x-hdr3`, never merged) ran the old snap
(`-probeOldSnap`) and the fix in the same build, reading the header title's position two seconds after a page
opened (title minY: About at rest 115.8, Equalizer 125.8, Music Management 145.8):

| Opened by | Old snap | Fix |
|---|---|---|
| Launch straight into About | 9 of 10 scrolled (97.3–114.3; the tenth at 115.4) | 0 of 10 (once 115.4, 0.4 pt) |
| Launch straight into the Equalizer | 10 of 10 scrolled (101.4–123.3) | 0 of 10 |
| Launch straight into Music Management | 4 of 4 at 117.7 (22 pt) | 0 of 4 |
| A tap in Settings, the Equalizer | 2 of 9 before the main merge, 6 of 6 after it (123.3) | 0 of 15 |
| A tap in Settings, Music Management | 6 of 6 at 117.7 | 0 of 6 |
| A tap in Settings, About | 0 of 9 | 0 of 9 |

So on today's main a tapped settings category opens part-scrolled every time; the branch's launch timing made the
launch-into screenshots worse before, and main's per-page clearance made the real path worse since. Fixed in
`07961f6`: the snap acts only while the user scrolls — `onScrollPhaseChange` opens a gate on `.tracking`,
`.interacting` or `.decelerating` and closes it on `.idle`, and the behaviour reads the gate when it is asked
(`SettingsSnapGate`, not observed: the behaviour value never changes during a gesture). The screenshots of settings
pages launched straight into a page now show the header fully expanded, as a tap shows it on Android.

This is older than the perf work, so it is a change Hoa will see, not only the undoing of a regression: pre-perf
main (`9e5ac90`, run 37062681023) already opened Music Management, the other two-line-title pages and the Settings
root a few points scrolled (about 22 pt on two-line titles), while About and the Equalizer opened at rest there and
do again now. Opening at rest is Android's resting state; it is listed under "Needs Hoa's OK" below. Whether the
snap still acts on a real finger lift depends on the order of the phase callbacks and `updateTarget` at lift-off,
which only the phone can show (check 6).

Not fixed here, and the same on main: the snap's arithmetic itself. A slow drag released mid-way on Music
Management ends 22 pt down (part-collapsed) instead of open, and a longer one may stay where it is — the probe's
drags of 12–46 pt landed at 22 pt, fully collapsed or in between, old and fixed alike. Dropping the inset from
`SettingsHeaderSnap` (`resting = target.rect.minY`, targets `0` and `distance`) should give Android's snap; it is a
behaviour change of main's, so it needs its own check on the phone.

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
| Player sheet | The full player was rebuilt on every expand and drag; the morph wrote its progress into the environment every frame. | The full player is built once (pre-warmed) and kept hidden at a zero frame (a screen-sized layer in the layout would widen the card's `ZStack`, and the mini player with it); fades are their own `Animatable` modifiers; a collapse fades it out frozen where it began, as its removal did, before hiding it — at the zero frame from the collapse's first frame (it still draws there), so only its opacity outlives the open state. Never write fast-changing values into the environment. |
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
  album header).
- Keeping a view instead of removing it also drops its removal transition. When a view that used to come and go is
  kept for speed, find out what its insertion and removal looked like (film both on CI with `[record:Class]` and
  compare frames) and reproduce what showed: the kept full player fades out on collapse as the removed one did.
  Keep its layout and its visibility on separate gates: a removed view left the layout at once even while its
  removal transition still drew it, so the kept one takes its zero frame on the first frame and only its opacity
  follows the fade. Changes that end such a fade go in the transaction that interrupts it (the expand's
  `withAnimation`), never in a separate update before it.
- A `ScrollTargetBehavior` is asked for a target when a gesture ends **and** when the scroll view's size changes.
  Logic meant for the user's release must check that the user is scrolling (`onScrollPhaseChange`), or a page at
  rest moves whenever its size or insets change.

## Merge gate: on-device checks (Hoa's phone)

The branch is not merged until these pass on the phone. The simulator can't settle them: its CPU numbers lean the
wrong way in the matched pair (above) and it reports no hitches. Each check compares main and this branch on the same
phone, the same library and the same steps; record the screen for both and put the recordings side by side.

1. **Hard gate — Instruments › Hitches** (plus Core Animation and SwiftUI) over the transitions in scope, main and
   this branch, with a library of real size. Merge only if this branch has no more hitches or hitch time than main
   in any transition, and fewer in the ones it targets (tab switches, album / artist pushes, Library pills, settings
   pages, sheets, the player sheet). If it is worse anywhere, find that commit before merging.
2. **Pressed settings rows**: rows in a group are 2 pt apart in one `GlassEffectContainer(spacing: 0)`; press and
   hold a row, a row next to a Toggle row and one next to a Slider row, and check the interactive highlight stays
   inside the row (no blending into its neighbour) and looks as on main. The simulator recordings showed no
   difference (above); the phone renders glass on its own GPU. If a group's pressed rows blend, drop that group's
   container (`SettingsGroup`) — the look comes first.
3. **VoiceOver / Accessibility Inspector** over the player's top bar, an album / artist header and a settings group:
   every control announces its label and its button / switch / adjustable trait as on main (CI checks the element
   types; the spoken result is the device's).
4. **Expand and collapse fades**: record main's and this branch's tap on the mini player and the collapse (slowed
   down) and compare the full player's fade in and out. Expand: the full player is pre-built and never inserted, so
   it fades with `fullPlayerAlpha(p)` alone; on main its insertion was unanimated (`isExpanded = true` outside the
   expand's `withAnimation`), and the CI recordings agree. Collapse: main's removal faded the player out on the
   collapse's spring, frozen where it began; the branch now does the same with `collapseFadeFrom` /
   `fullLayerFade` (above) — check that the curves match, and that the mini player's previous / play / next stay in
   place in every frame of the collapse (no shift to the right while the player fades, no jump when it ends). Also
   tap the mini player right after a collapse: the player must spring back from where it was, without popping to
   full opacity in a small card or restarting its fade. A collapse tapped before an expand has settled fades from
   the resting placement (the known limit above). `[record:TransitionRecordingTests]` films all of it on CI.
5. **Steady cost of the hidden pre-built full player**: with the player collapsed and a large queue (a few thousand
   songs), skip through ten songs, play / pause and edit the queue, under Instruments' SwiftUI and Time Profiler
   templates, main against this branch. The hidden `NowPlayingView` re-renders on each of these (its seek bar and
   ambient background timelines already pause while it is hidden). If it shows up (main-thread time or dropped
   frames that main doesn't have), gate its playback-driven sections while collapsed (cover, titles, play state,
   queue-driven parts) so they read playback only while expanded or being dragged. Also check
   whether zero-opacity glass costs anything (the card's glass is still removed above 25 %, P13).
6. **Settings pages open at rest**: push Settings › About, Settings › Equalizer and Settings › Music Management by
   tapping, several times (right after launch and later, before and after the mini player first appears), and check
   each opens with its header fully expanded and the list at the top (see "Settings pages opened scrolled" above;
   main opens the last two part-scrolled; pre-perf builds already opened two-line-title pages about 22 pt
   scrolled). Then scroll each list a little, a lot, and fling it, and check the header ends where it does on main.
   Binding: include a slow drag released mid-way through the header's collapse with the finger at rest (no fling)
   on Music Management and on About. The snap must still act on that release as it does on main: the gate is
   opened by `onScrollPhaseChange` and must still be open when SwiftUI asks the behaviour at lift-off. If a slow
   mid-way release stays put on the branch where main moves it, the phase callback closes the gate too early on the
   device; then close it a main-actor turn after `.idle` instead of at once (a size change at rest must still find
   it closed).

## Needs Hoa's OK

- **Settings pages open at rest**: every settings page built on `SettingsScaffold` now opens with its header fully
  expanded and the list at the top, as on Android. Pre-perf builds opened Music Management, the other two-line-title
  pages and the Settings root a few points scrolled (about 22 pt on two-line titles), and today's main opens tapped
  categories part-scrolled too ("Settings pages opened scrolled" above). The screenshots of those pages differ from
  main's for this reason only. It is a visible change on pages Hoa has already seen.
- **Open-source notices, long-press Copy** (P41): the notices sheet now lays its text out by paragraph, so only the
  visible paragraphs are laid out when it opens (the single 30 KB `Text` was laid out on the main thread before the
  sheet could present). A side effect: long-press › Copy copies one paragraph instead of the whole notices text. The
  look is unchanged. If whole-text copy matters, the choices are a "Copy all" button (a visible addition) or the
  single `Text` again (and its slow open).
