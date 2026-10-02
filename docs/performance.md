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

## What was slow, and the rule now

| Transition | What cost frames | Rule |
|---|---|---|
| Tab switch | The cross-fade ran on the selection spring, whose tail kept both full-screen, glass-heavy stacks composited until ~0.6 s. | The fade has its own 0.21 s curve (`PixlMotion.tabFade`, `animation(_:body:)`); only the tab bar's pill springs. |
| Push / pop from a tab root, first play | The bars sat in one `safeAreaBar` around all three stacks: every push, pop or first play changed the inset of all three (hidden ones included). | Bars are an overlay; each page reserves their room itself (`ShellBarSpace`). Never put shell chrome in an inset that wraps every tab. |
| Keyboard | The mini player popped away un-animated and was rebuilt a frame late. | The card steps aside in the bars' own transaction and keeps its slot (`hiddenForKeyboard`). |
| Song change, play/pause | `PlaybackStore.current` was computed from the queue, and rows took closures: every live tab (hidden ones too) re-rendered its whole body. | `current` / `currentSongId` are stored; rows read playback in `PlaybackRowState`; screens don't read playback in `body`. |
| Album / artist push, album cards | Colour schemes came only from an actor: every page and card started in the brand theme and re-themed (0.25 s) mid-push. | `ColorExtractor.peek` reads a synchronous mirror in `body`; only real misses fade. |
| Pause, a second after any song change | The whole queue (often the library) was JSON-encoded on the main thread. | `QueueSnapshotStore` captures on the main actor and encodes in a `@concurrent` function. |
| Library pills, sort, rescans | Six eager pages re-ran on every LibraryView pass (fresh closures); sorts ran on the main actor below 1,500 songs; one monolithic `lists`. | Pages take plain values + `LibraryActions`; `LibraryModel` memoises each list by its inputs, computes off the main actor after the first frame, lands without animation; inputs compare the library by `LibraryStore.revision`. |
| Any library edit or rescan | Whole-snapshot comparisons in Home, Search, Library and detail pages; lookups rebuilt on the main actor; `SnapshotLoader` ran on its caller's actor. | Key on `library.revision`; snapshots arrive with lookups built off the main actor (`@concurrent`); edits patch lookups (`applyEdit`). |
| Detail pages | Album / artist / genre / folder pages filtered and sorted the whole library in their first frames, then re-rendered. | `library.detailIndex` (per revision, built off the main actor) + a `ViewMemo` in `body`: content in the first frame, no second pass. |
| Player sheet | The full player was rebuilt on every expand and drag; the morph wrote its progress into the environment every frame. | The full player is built once (pre-warmed) and kept hidden; fades are their own `Animatable` modifiers. Never write fast-changing values into the environment. |
| Player → album / artist | Collapse and push shared their frames. | Collapse first, push at 10 % (`collapse(thenAfterReaching:)`), as Android. |
| First visits, revisits | Artwork keyed by exact pixel size, FIFO, unbounded: placeholders and fade-ins mid-push. | Size buckets, byte-bounded LRU, purge on memory warning, stand-in from another size. |
| Sheets | Wrap-content sheets opened at `.medium` and re-targeted; the queue sheet copied the queue per pass and re-ran its body per drag event; pickers filtered the library on the main actor. | Remembered heights; per-row reorder model; index-addressed rows; precomputed / off-main filtering without debounce. |
| Settings, notices, stats | Whole category bodies built in one frame; ungrouped row glass; a 30 KB `Text`; Stats / Recently Played swapped a spinner for their content mid-push. | Sections are lazy-stack children; groups share a `GlassEffectContainer`; notices by paragraph; `ScreenDataCache` opens on the last result. |
| First use of a service | CIContext, route monitor, AI service + Keychain, lyrics shader, first WKWebView, audio session — all on the main thread inside a transition. | Create them on their actor, at idle, or off the main actor (`@concurrent`), never in a transition's first frame. |

## Things to remember

- Under approachable concurrency a plain `nonisolated async` function runs on its caller's actor. Off-main work is
  `@concurrent` or `Task.detached`.
- Glass shapes that sit together go in one `GlassEffectContainer` with spacing below their gap. Children of a
  container (and of any non-element view with its own identifier) keep only their accessibility labels: UI tests look
  such controls up by identifier **or** label.
- A view that should start with data has it on its first frame (a synchronous cache, a memo in `body`, or a value
  seeded in `init`), not in `onChange(initial:)` / `task`, which costs a second pass or a pop-in.
- Pending on-device checks (Instruments): grouped settings rows while pressed (2 pt gaps), the cost of the hidden
  pre-built full player, and whether zero-opacity glass costs anything (the card's glass is still removed above 25 %).
