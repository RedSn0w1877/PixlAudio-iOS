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

---

# Milestone E2 (iOS): spoken host notes, host cards

Port of Android's E2 (`endless-listening` commits `6a17b25`, `b3d615e`, `33c5b3d`, `857b95e`; its handoff has a "For the iOS port" part). **Nothing here has
run on a phone.** Only `Packages/PixlCore` compiles on the Windows machine; `App/` is compiled by CI alone. Sound behaviour is a trace of the code.

## What was built

### The pure core (PixlLibrary), tested

- `Brain/HostVoice.swift`: `decide` (speak / wait / skip with a stable reason word, the first reason that holds ends it), `cancelReason` (a line stops at
  once on off, notes off, a skip, a pause, a transition, a lost focus, a call, a route change, a foreign volume write, or after 8 s), `ramp` (the duck,
  in thousandths), `line` (the note cleaned for a voice: "&" is said "and", marks a voice reads badly become spaces, at most 160 characters, two sentences,
  12 words each, none of the words the app never says; a note that is too long is not said, never cut), `estimateMs`. It reproduces Android's
  `hostvoice.jsonl` bit for bit (638 lines: 430 decide, 120 cancel, 70 ramp, 17 line, 1 estimate). The golden file, `README.md` and `MANIFEST.sha256` were
  copied from Android's branch unchanged (the manifest has 47 files; no older golden file changed). Standard-library Swift only (`BrainPurityTests`).
- `BrainStore/HostVoiceLog.swift` (the last 20 decisions, newest first, and the line each reads as) and `BrainStore/HostVoiceChoice.swift` (which installed
  voice: the listener's own English first, else US English, else any English; better quality first; never a novelty or personal voice).

### The app (App/), compiled on CI only

- The duck: `AudioEffectsParameters.duckGain`, one atomic every tap multiplies in last (`ProcessingTap`, after the crossfade and the deck's fixed gain; a new
  item starts at the level the duck has, so there is no jump). `Playback/HostDuck.swift` is its only writer: a step every 24 ms from `HostVoice.ramp`
  (250 ms down to 0.35, 400 ms up, 120 ms when a line was cut short); `abort` gives the level back at once. `DualDeckEngine.fade` aborts it when two decks
  start to overlap (a crossfade, a rendition switch), `rebuildAfterMediaServicesReset` aborts it, and the controller aborts it on an interruption.
  `DualDeckEngine+Host.swift` lets the controller read the decks (playing, song ids, position and what is left, `hostCanDuck`).
- The voice: `Playback/HostSpeaker.swift`, `AVSpeechSynthesizer`, created on the first line (or Test the voice) and handed back when the host is disarmed.
  The session is not touched: no category change, no `.duckOthers`, no activation, `usesApplicationAudioSession` stays on.
- `Services/Brain/HostVoiceController.swift` (the port of `HostVoiceStateHolder`): armed only while Spoken host notes, Host notes and the Endless station
  are all on. With the switch off nothing is registered (the app's start only reads one `UserDefaults` flag). Armed, it watches the song, the play state
  and the three switches through `withObservationTracking`, and the route and interruption notifications. On each new song it makes the very note the
  player shows (`SetNoteLines.forQueue` over the same window, history and host facts as `PlayerSetNoteLine`), `HostVoice.line`, and asks `decide` (300 ms
  at most between asks) until the answer is speak or skip. To speak: `hostDuck.begin()`, 250 ms, check `cancelReason`, speak, poll `cancelReason` every
  100 ms, `hostDuck.end()`. Every end writes one entry to the log (20, in memory). Calls come from `CXCallObserver` (an interruption also pauses the music).
- Host cards: `HostNoteCard` (Liquid Glass shape in the player, a flat tint in the queue's rows; no close button, skipping dismisses it). The player's card has
  "Ask the host" beside the note (the lone capsule when the song has no note); the queue's rows show the card while Endless Listening is the queue.
- Settings › Endless Listening: Host notes, **Spoken host notes (off by default, greyed while Host notes is off)**, Test the voice (says a sample, ducks
  like a note when it can, refuses during a call or while a note is being said, says why in a toast), How it works; developer mode adds Advanced › Host voice
  log (a sheet with the last 20: spoke / stopped: reason / skipped: reason). The same words as Android (`EndlessStrings`).

## Deviations from Android

E2-1. The duck is a gain inside the tap, not the player's volume: nothing else writes it, so Android's "a foreign write ends the duck" case does not exist
here (`volumeTaken` is never true), and Sing and Spatial audio need no special refusal. It is still refused while a transition runs, a hand-over is
scheduled, the session is not active or the music is not really playing (`hostCanDuck`).
E2-2. The voice is chosen by `HostVoiceChoice` (Android picks inside `HostSpeaker`); a phone with no installed English voice stays silent and the log says `no_voice`.
E2-3. The voice is ready as soon as the synthesizer is created, so `voice_pending` never happens on iOS.
E2-4. The player's card is glass, the queue's flat (rows scroll and are dragged).
E2-5. No `AudioDeviceCallback` grace period: iOS posts the route notification only for a real change.
E2-6. The host does not speak while the app's own player side is gone (as Android): the queue comes from the player store.

## Cut

Nothing from the brief. `ci/check-forbidden.sh` needed no change (`CallKit` and `AVFoundation` were already allowed).

## Not verified on a phone

The sound and quality of the installed voices and whether an English voice exists by default; that the synthesizer speaking through the app's `.playback`
session (long-form audio policy) never pauses or reroutes the music; the duck against a crossfade, ReplayGain on and off, Sing and Spatial audio; speech
cancelled at once on skip, pause, a call and a route change; `CXCallObserver` during a real call; the 1.5 s, 4 s, 15 s and 8 s numbers; the cards' look in the
player and the queue; Test the voice with music playing; the battery of an armed host (it asks every 300 ms for up to 15 s on a song with a note, and every
100 ms while a line is said).

## How to test on a phone

Settings › Endless Listening: switch Spoken host notes on, tap Test the voice with a song playing (the song dips, the sample is heard, the song returns at the
same loudness). Start Endless Listening from the Home card; a card appears when a song has a note and the voice says the same words 1.5 s into that song.
Skip while it talks (stops at once, music back in about a tenth of a second); pause; unplug headphones; take a call; play with crossfade on. Developer mode ›
Endless Listening › Host voice log shows each decision and why (`too_soon`, `transition`, `short_left`, `route_changed`, ...): use it to calibrate the numbers
in `HostVoice`.

## CI (E2)

- Round 1, run 44863345792 (on `683b05d`): core and app both green on the first try (`App/` compiled, `HostDuckTests` and the new tap test passed on CI).
- Locally: the whole `Packages/PixlCore` suite passed except one stage 3 test, `BrainLearnerEngineTests.theLearnedWeightsRankOnlyWhileTheGateHasThemOnAndNeverInAControlSession`,
  which timed out under the full run's load (13 s) and passes alone and in a second run of the whole `PixlLibraryTests` target (1021 tests). Not touched by this milestone.
