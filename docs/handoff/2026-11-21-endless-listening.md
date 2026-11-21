# Endless Listening, milestone E1 (iOS): the station, the Home card, "Ask the host", the intro

Branch `endless-listening`, cut from `music-brain` (stages 1 to 4 landed). The iOS port of Android's E1 as it stands on its branch
`endless-listening` (commits `5fd1a9e`, `2acf412`, `4f5f88b`, `6d3690c`, `c50009c`, `f97306e`; handoff `handoff/2026-11-21-endless-listening.md`).
Read `docs/handoff/2026-11-21-music-brain-stage4.md` first.

**Nothing here has run on a phone.** Only `Packages/PixlCore` compiles on the Windows machine; `App/` is compiled by GitHub CI alone. "Works"
means: the golden file matches Android's bit for bit, the core tests pass, the App code was read against its neighbours.

## What was built

### The pure core (PixlLibrary), tested

- `Brain/EndlessSeeds.swift`: one seed per taste island (biggest first, at most five, a distinct artist each), the top artists, one track each,
  with fewer than two usable islands. `Brain/HostNotes.swift`: five note kinds over real facts only (new from an artist you play, a step
  sideways, an island's name, the atlas' sentence of a genre, a release year), at most one per five tracks counting the set notes
  (`Taken`), every sentence at most 12 words, two sentences at most, `WeeklyNote.forbidden` words dropped. Both reproduce Android's
  `endless.jsonl` (147 lines: 60 seeds, 70 notes, 9 facts, 8 speakable) bit for bit. The golden file, `README.md` and `MANIFEST.sha256` were copied
  from Android's `endless-listening` branch unchanged (no older golden file changed). The brief names a folder `Fixtures/songtap`: that was a
  copy-paste from another milestone; the files live where all the brain's golden files live, `Fixtures/brain`.
- `BrainStore/Station.swift`: `sourceEndless = 6`, `isEndless`, `Station.endless(...)`; `decode` takes sources 0 to 6 (old strings decode, 7 is
  refused). `MixModel.swift`: `MixKinds.endless = 7`.
- `BrainStore/EndlessSeedSource.swift`: `BrainMixes.endlessSeeds(now:)` draws the seeds from the Your Mix shortlist (the pool Your Mix is planned
  from, cached for the day) and the in-memory affinity tables, and `endlessIslandNames` names the islands as the Daily Mixes do (an unnamed
  island is left out). `MadeForYou.swift`: `islandGenreName` is the genre half of `islandSubtitle`, split out (same output).
- `BrainStore/HomePlanBuilder.swift`: `endlessCard`: first card of "Made for you", present with at least two seeds, `mixId` "endless", on the
  shelf only (it is in no `served_list` row and in `HomePlan.mixes` it is not, so the hero, the "Mixes" chip and the first-daily logic never see it).
- `BrainStore/HostNoteFacts.swift` and `Assistant/SetNoteLines.swift` (`HostFacts`, `forQueue(..., host:)`, `taken`): the island name of a library song
  (alias table, island fit), the engine's reason key of a pick (`new_release`, `adjacent_genre`) and the atlas sentence of a genre, read off the main
  actor for the next 40 songs only while Endless Listening is the queue and Host notes is on. A set note's `Taken` span is `count + 1` when it ends on a
  new artist (as Android).
- `Assistant/HostChips.swift`: `HostChip` (six, in order) and what each asks of the phone. `PixlNet/Claude/TaizoAssistant.swift`: `hostAddendum` (Android's
  `HOST_ADDENDUM`, word for word) and `withHostAddendum`, a block after the cached ones.
- `Brain/EndlessIntro.swift`: the five bars' heights from one time value.

### The app (App/), compiled on CI only

- Station: `BrainActions.startEndless()` picks the station up when it is the queue's (plays it if paused), else reads the seeds and starts the first
  (the rest follow through the autoplay batches, the code stage 2 to 4 already have for stations with several seeds). Saved and restored by
  `StationStore` with the other stations. `AutoplayLine` names it "Endless Listening" (no "Station ·") with "Keeps going from what you play, until you stop it".
- Home: the card (`MixCardUi`, kind 7): title "Endless Listening", subtitle "Starts from {islands} and keeps going." or "Starts from what you play
  and keeps going.", tag "Keeps going" in place of a song count. First tap opens the introduction, later taps start or pick up the station. "How it
  works" is in the card's context menu (long press).
- Host notes: the stage 4 surfaces, the row label in the queue and the line under the player title, now take `host:` facts (`SetNoteMemo`,
  `QueueSheet`, `PlayerSetNoteLine`), only while Endless Listening is the queue and Host notes is on.
- "Ask the host": a small glass capsule under the queue's count and under the player's note, only while the station is the queue; it opens
  `TaisChatSheet(hostMode: true)` (over the queue as its own sheet; from the player `AppSheet.askHost`). Six chips above the composer: Something new
  (Discover), Back to familiar (Familiar), Why this song (the existing sheet, over the chat), More upbeat and Slower (`steer_session`, scope session),
  Surprise me (`more_new`): all on the phone, no model call, so no part of the monthly allowance. Typed text goes through the existing agent and route
  unchanged with the addendum after the cached blocks of the system prompt (not saved with the conversation). Grounding is untouched.
- The introduction: `EndlessIntroView` (`AppCover.endlessIntro`): the three pages with the exact copy, a paged `TabView`, dots, one
  `GlassEffectContainer` around the "Start listening" capsule (the only one), "Not now" as text, five bars in one `Canvas` read from one time value in a
  30 fps `TimelineView` that pauses off screen and with Reduce Motion, their colour the album colours of the first seed (`AlbumSchemeReader`, cached),
  a static glow backdrop. Seen flag `endless_intro_seen` in UserDefaults (`EndlessState`). Start marks it seen and starts the station; Not now marks it seen.
- Settings › Endless Listening (`SettingsCategory.endless`, after AI features, shown without developer mode): Host notes (on by default) and "How it works".
- Strings: `Features/Brain/EndlessStrings.swift` (Android's `strings_endless.xml`; never the word "Apple", none of the forbidden words, no "learn").

## Deviations from Android

E1-1. The card's menu is a context menu (a button inside a glass button would swallow taps); the Settings row is the visible way to replay the introduction.
E1-2. The introduction's backdrop is a static glow, not the setup's drifting mesh (no continuous work beyond the five bars).
E1-3. The bars' colour is read once from the first seed's art through the existing `AlbumSchemeReader`, not through a throttled `ColorSchemeProcessor` read.
E1-4. The genre facts of the host are read for the window's genres before the notes are made (the atlas lookup is async on iOS), not through a synchronous closure.
E1-5. "Why this song" opens the existing sheet over the chat (a nested sheet), as the queue already does for its own reason lines.
E1-6. `AutoplayControllerHarnessTest`'s endless case has no direct counterpart (the controller is `App/`); `StationReseed.seedIds` is tested for five seeds.
E1-7. The Home plan is rebuilt once a day (or on a taste change): a plan saved before this build has no card until the next rebuild.

## Cut or deferred

Spoken host notes (milestone E2): no TTS, no ducking, no "Spoken host notes" switch yet. The brief's other ci-script changes (CoreBluetooth etc.) belong
to another milestone; `ci/check-forbidden.sh` is untouched.

## Not verified on a phone

The introduction's look, the bars' smoothness, the page swipe; the card's look and placement and its context menu; the chip's placement in the queue
header and under the player note; the host sheet over the queue sheet; whether the steer chips find five songs and what they say when energy is unknown;
island names on the card (they need the atlas); the cadence of host notes in a real queue; first open versus resume; the Settings category.

## How to test on a phone

1. Home with a few weeks of plays: "Made for you" starts with Endless Listening. First tap: the three pages; "Start listening" starts it.
2. The queue says "Endless Listening" and "Keeps going from what you play, until you stop it"; an "Ask the host" capsule sits under the count.
3. Within the next few songs a row shows a short note ("From your ... side.", "Released in ...", ...), one per five songs at most, none on a song a set note already describes.
4. "Ask the host": each chip answers in one line; "Slower" puts five songs next; "Something new" moves the switch to Discover.
5. Settings › Endless Listening › Host notes off: the notes go. How it works replays the three pages.

## CI

- Round 1, run 44855584431 (on `4a1de24`): `App/` compiled on the first try. Two real failures in the core job, both mine and fixed in `d615ed9`:
  `BrainPurityTests` (the pure `Brain/` folder is standard-library Swift only: `EndlessIntro.swift` imported Foundation and called `sin`, so it moved to
  `BrainStore/`) and `BrainGoldenTests.theManifestListsEveryFileWithItsHash` (the manifest has 46 files now). The app job's only failure was the known
  flaky `DualDeckEngineTests.testCrossfadeOverlapsBothDecksWithTheirGainCurves`.
- Round 2, run 44856992899 (on `d615ed9`): core green; the app job failed twice on the known flaky `StoreTests.testPlaybackStoreWithDemoEngine`
  (one failure of 664, a 50 ms timing test over the demo engine) and passed on the second `gh run rerun --failed`: green. The screenshot UI tests are not part of the push run.
- Locally: the whole `Packages/PixlCore` suite ran before round 2's fix with those two failures only; the three affected tests pass after it.
