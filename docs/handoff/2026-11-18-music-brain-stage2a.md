# Music brain, stage 2a (iOS): running handoff

Branch `music-brain`. The contract is `docs/brain-spec.md` (v1.1), section 14 "Stage 2", half 2a: everything moved from
stage 1, the brain scorer behind `BrainSwitch.engine`, and Daily Mix / Your Mix with new music. The reference is the
Android repo's branch `music-brain` and its `handoff/2026-11-18-music-brain-stage2a.md` (its commits `9125ee8` to
`698abba`). Stage 1's iOS handoff (`docs/handoff/2026-11-17-music-brain-stage1.md`) is the map of what exists; its
deviations are numbered 1 to 66. This file continues at **67**. Android's 80 to 100 hold here unless a line below says
otherwise.

**Nothing below has been run on a phone.** Only `Packages/PixlCore` compiles on the Windows machine; `App/` is compiled by
GitHub CI alone. "Works" means: unit tests pass and the code paths were read end to end. Every section ends with what is
still unverified.

This is milestone 1 of 2a ("the mixes get new music"), the port of Android's milestone 1. The second milestone of 2a
(Private session, "Don't learn from this", New releases) is not started.

---

## What the listener gets (once checked on a phone)

- Daily Mix (30) and Your Mix (60) hold music from outside the library: about a quarter of the Daily Mix, a fifth of Your
  Mix, scaled by the Familiar / Blend / Discover switch (0.4 / 1 / 2, at most 0.6). A track from outside plays as `yt:<videoId>`
  like an Autoplay pick. A row of new music has a line under it ("Fans of X also play this", "More from X") and a Save button;
  Save makes it a library track (the same path as Like).
- A mix is the same all day, comes back after a restart without the brain being read, and no track is in both mixes of one
  day. Your Mix's regenerate button draws another list. A track served often in the last 30 days costs value in the next list.
- Settings > Developer mode > Maintenance has two switches: "Music engine" (off gives the old mixes back; regenerate the
  daily mix to see it) and "Background music search".
- Once a day, on Wi-Fi and not in Low Power Mode, the app asks YouTube Music for the radios of the day's seeds (the listener's
  own tracks) and the artist pages of their top artists, so the mixes have new music to pick from.
- Spotify Connect: Autoplay and stations run, limited to what Spotify has. AirPlay is unchanged.

## Where things are

**`Packages/PixlCore/Sources/PixlLibrary/Brain/`** (pure; scanned by `BrainPurityTests`; same file names as `:brain`)

| File | What | Android twin |
|---|---|---|
| `MixPlanner.swift` | `kindDaily` / `kindYour`, `nuOf`, `tieSeedOf`, `plan` (runs `StationPlanner` in `modeMix`), `jitter` 1.0 | `MixPlanner.kt` |
| `Repetition.swift` | `servedPenalty` (max 1.2), `mixDay` (04:00), `timesServed`, `takenOnDay`, `keepAfter`, `distinctRatio`, `maxArtistShare` | `Repetition.kt` |
| `Seeds.swift` | the four groups, 24 a day, two per artist, `pseudoRandomOrder` | `Seeds.kt` |
| `Snapshot.swift` | `brain-snapshot-v1` `encode` / `decode` | `Snapshot.kt` |
| `Eval.swift` | test 1 (`skipPrediction`, `auc`, bootstrap) and test 5 (`listHealth`) | `Eval.kt` |
| `AutoplayRemote.swift` | `RemoteOutput`, `RemoteRule`, `remoteRule`, `isSpotifyTrackId`, `keepPlayable` | `AutoplayPolicy.kt` (remote part) |
| `ListBuilder.swift`, `StationPlanner.swift`, `WhyLine.swift`, `Graph.swift`, `BrainHash.swift`, `Brain.swift` | `servedPen` and `noise` in the value, `modeMix` (seeds are candidates, no closeness to a seed), "on repeat lately" needs rate and mass, `addEdge`, `unit`, `specVersion` 2 | same files |

**`Packages/PixlCore/Sources/PixlLibrary/BrainStore/`** (file I/O and `Song`; outside the purity scan)

| File | What | Android twin |
|---|---|---|
| `GraphEdgeStore.swift` | `graph_edge.pbl`: edges of the radio lists, weights times 65,536, replaced per seed, pruned after 30 days, the one-time conversion flag | `GraphEdgeStore.kt` |
| `ServedListStore.swift`, `MixModel.swift` | `served_list.pbl`: the served log (60 days) and the saved mixes (`StoredMix`, `StoredMixItem`); `MixView` | `ServedListStore.kt`, `MixModel.kt` |
| `FeedbackStore.swift` | `feedback.pbl`: created, tested, written by nobody yet | `feedback` table |
| `BrainMixes.swift`, `MixPool.swift` | `BrainMixes` (actor: `publish`, `saved`, `today`, `regenerateYourMix`, `removeItem`, `seedsForRefresh`, `topArtistSeeds`), `MixConstraints`, `MixSources`, `MixPoolBuilder`, `SeedQueries`, `SeedGroups` | `BrainMixes.kt`, `MixPool.kt`, `TasteConstraintAdapter.kt` |
| `BrainRefresh.swift` | `BrainRefreshRunner` (the rules), `BrainRefreshWork` (the app's work), `BrainRefresh` (one run and its note), `RefreshSchedule` (when) | `BrainRefresh.kt`, `BrainRefreshScheduler.kt` |
| `BrainEngineChoice.swift` | `legacy` / `brain`, `useBrain`, `hasState`; `BrainRemoteConfig.refreshAllowed` | `BrainEngineChoice.kt`, `BrainRemoteConfig` |
| `BrainTables.swift`, `BrainRepository.swift`, `BrainEngine.swift`, `BrainEventLog.swift`, `AutoplayPlanning.swift` | `edges` beside the other tables; `cachedRadio`, `cachedArtistRadio`, `backfillEdgesOnce`, `edgesFor`, `pruneEdges`, an edge written with every stored radio (not an artist station's); `heardTrackCount`, `hasState`, `readAffinity`, `planMix`, `recentEvents`, `salt`, `setStoredValue`; `events(startedSince:)`; `pickedEntries`, `narrowed` | `BrainRepository.kt`, `BrainEngine.kt` |

**`App/`** (not compiled locally)

| File | Change |
|---|---|
| `Playback/AutoplayController.swift` | `Sources.remoteOutput` (instead of `isRemoteSession`) and `playableOnRemote`; `remoteRule()` read at every place that asked "is it remote"; `keepWhatTheOutputPlays`; the settle wait as a plain delay on Connect |
| `Services/Spotify/SpotifyConnectController.swift` | `canPlay(_:)`: the lookup a queue entry gets, same cache, at most 24 searches a call |
| `AppEnvironment.swift` | builds `MixSources` (library, legacy picks, constraints, switch, novelty), registers the background task, hands the mixes to Home |
| `Services/Brain/BrainService.swift` | owns `BrainMixes` and `BrainRefresh`; `waitForStartup`, `mixWasBuilt`, `runRefresh` (unmetered, not Low Power Mode, never while playing), `sceneBecameActive` (the foreground fallback) |
| `Services/Brain/BrainBackground.swift` (new) | the `BGProcessingTask` `io.github.redsn0w1877.pixlaudio.brain-refresh`: registered at launch, requested after the first mix build, `earliestBeginDate` a day after the last run plus up to an hour |
| `Services/Brain/BrainRemoteFlags.swift` (new) | reads `brain.refresh.enabled` from the copy of `remote/config.json` the app already saves |
| `Features/Home/HomeStore.swift`, `Features/Mixes/MixScreens.swift`, `Features/Brain/MixRowNote.swift` (new) | the brain's mixes replace the legacy ones in `content` once published; rows get the reason line and Save; a play carries every row's tag |
| `Stores/SettingsStore.swift`, `Features/Settings/Categories/DeveloperSettingsSection.swift`, `Features/Brain/BrainStrings.swift` | `brain_engine` (default 1), `brain_refresh_enabled` (default on), the two rows, "On repeat lately", the reworded "less repetition" promise, "Save" / "Saved" |
| `Services/YouTube/YouTubeServices.swift`, `PixlAudioApp.swift`, `project.yml`, `remote/config.json` | `radioBudget` shared with the refresh; the scene phase calls; the task identifier in `BGTaskSchedulerPermittedIdentifiers`; the `brain.refresh.enabled` key (true) |

Docs: rows in `docs/parity.md` and `docs/test-parity.md`.

## The golden files

`Fixtures/brain/` holds Android's committed `brain/src/test/resources/brain-golden` as of its commit `698abba` (**the files
changed twice on Android in this pass**; `Brain.specVersion` is 2). Compared by git blob id with `git ls-tree music-brain`:
every file is identical. `BrainMixGoldenTests` replays the five new ones (`mixes`, `snapshot`, `repetition`, `eval`, `why`) and
`BrainGoldenTests` the earlier ten; the manifest test now expects 16 entries. Every line passed on its first run: the new
pure core is bit-identical to Android's. The version bump makes every install rebuild its affinity state once, in the
background, on first use after the update (`isRebuildNeeded` reads `affinity_spec_version`).

## Task 1: Spotify Connect and AirPlay with a track that has no Spotify URI (spec 14.6, owner question 7)

**The trace (read from the code, not run).**

*AirPlay.* It is a route. The phone's own `DualDeckEngine` decodes and streams the audio and the system sends the sound to
the speaker. `PlaybackStore.isRemoteActive` is false (`RemotePlaybackOutput` has one implementation, Connect), the queue, the
prefetcher, the crossfade and every queue edit behave as on the phone's speaker, and `yt:<videoId>` tracks play exactly as
they do there (`MusicHapticsController` already treats AirPlay as a route and not as a remote). **Decision: nothing changes.**
`RemoteOutput.none` covers it.

*Cast.* iOS has none (nothing under `App/` or `Packages/` mentions it). Android's "Cast stays off" has no twin.

*Spotify Connect.* The device plays the phone's queue as a window of up to 100 `spotify:track:` URIs
(`SpotifyConnectWindow.make` over `slots`, built by `rebuildSlots`). A queue entry with a real Spotify id plays directly
(`SpotifyConnect.directURI`). Any other entry (an engine pick is `yt:<videoId>` and has none) is resolved by
`SpotifyConnectResolver.resolve`: an ISRC search when the file has one (a pick has no file, so none), then "title artist", and
accepted only on a strict match (same cleaned title, same primary artist, length within 3 s, no live / remix / cover
mismatch); otherwise `.skipped`, cached for a week. `remoteQueueChanged()` coalesces edits for 350 ms and `resync()` sends
nothing when the device's remaining list is unchanged or only extended at the end, so **appending a pick is not audible**;
replacing the tail would be. **Decision: Autoplay and stations run on Connect, limited to what Spotify has**, as on Android:
the planner's picks are looked up before they are queued (`SpotifyConnectController.canPlay`, the resolver and cache the
window send uses, at most 24 searches a call), and a pick Spotify does not have never reaches the queue: it leaves the pool and
is remembered as failed for 30 minutes (`AutoplayController.keepWhatTheOutputPlays`). A library pick on the library-only path
goes in only when it carries an id Spotify gave out. The tail is not re-scored, the artist of a hard skip is not dropped from
the tail, and a change of direction does not rebuild the pool while the session is on Connect. The settle wait is a plain
1.5 s delay (the phone's player sits paused at 0). One constant turns it off: `AutoplayPolicy.autoplayOnConnect`.

**Tested (PixlCore, `BrainRemoteOutputTests`, 6):** the rule for each output, the switch, `decide` with `!rule.picks`,
`keepPlayable` (order, a short answer, a repeated id), `AutoplayPlanning.narrowed` (the picks Spotify has, kept in order, and
the like's scheduled slot counted as used only while something is left), and the id rule against a table that PixlNet's
`SpotifyConnectIdTests` checks `SpotifyConnect.isTrackId` against.

**Not verified on a device:** that a Connect device plays an engine pick; that 24 searches cover a station's first batch of 20
on a cold cache (a miss leaves the batch short and the pool refills); that the line and the Familiar / Blend / Discover control
behave while a session starts or ends; whether Spotify's search finds enough of a YouTube Music radio at all.

**Deviation 67.** Cast has no iOS twin and AirPlay needs no rule, so Android's `CAST` output and its queue line "Off while
casting" are not ported. **Deviation 68.** `AutoplayController.Sources.isRemoteSession` became `remoteOutput` and
`playableOnRemote`; the controller reads the rule where it read the flag.

## Task 2: the record files

All under `Application Support/Brain/`, each a `KeyedLogStore` file, read on first use, a stage 1 install simply has none:

| File | Key | Payload (JSON, sorted keys, `v` = 1) |
|---|---|---|
| `graph_edge.pbl` | `src|dst|type` (1 radio, 2 related); `~backfilled` | `{r:rank, t:fetchedAt, v, w:wQ16}`; `{t, v}` |
| `served_list.pbl` | `recId` | `{builtAt, mix:StoredMix, modelVersion, nuQ, recId, rids, seed, surface, surfaceId, v}` |
| `feedback.pbl` | `id` | `{createdAtMs, id, kind, targetId, targetKind, undoneAtMs?, v}` |

A reader skips a record it cannot decode or whose `v` it does not know, and never deletes it; a field a later stage adds is
read with a default (`StoredMix`, `StoredMixItem` decode every key with `decodeIfPresent`). The old radio lists become edges
**once**, the first time the refresh runs or a mix is built (`BrainRepository.backfillEdgesOnce`; the flag is a record of the
graph file itself, so no other file needs to know); the edges keep the age of the list they came from (`min(fetchedAt, now)`)
and expire with it, an artist station's list is not converted (it is a top-songs list), and the weight is
`factor / log2(2 + rank)` times 65,536, equal to `Graph.Builder.addList` to 16 bits (tested). The served log is kept 60 days and
pruned on every write. `feedback` is truth and is never pruned; nothing writes it in this milestone.

Tests (`BrainStage2aStoreTests`, 12): the weights; replace on re-fetch (a Related tab is its own set); restart and prune; a
folder with no graph file and a file with a future version and a torn line; the one-time conversion of lists written the way
stage 1 wrote them, including its flag and the edge age; the saved mix and the 04:00 rollover at UTC+1 (14:00, 03:00 next day
still the same day, 05:00 not); the newest build of the day wins and every build counts for "Regenerate"; the 60-day retention
and what the budget reads back; a mix record with fields missing, and one of a version this code does not know; feedback.

**Deviation 69.** The saved mixes and the served log are one file (`served_list.pbl`), as on Android, not a separate "saved
mixes" file. **Deviation 70.** Records are JSON lines, not gzip (the format of every stage 1 record file); a 60-track mix with
18 outside rows is about 15 KB, so a month of two mixes a day is about 1 MB. **Deviation 71.** No migration step exists
because no record file has a schema; "a stage 1 file migrates" becomes "a stage 1 folder reads as empty for the new tables".
**Deviation 72.** The in-memory index of `served_list.pbl` holds the header of each list (surface, time, recordings), never
the items; today's mix is read from the file when asked for.

## Task 3: the refresh

iOS has no WorkManager. The app already uses `BGProcessingTask` for Cloud Studio (`CloudBackground`, identifiers in
`project.yml`), so the refresh follows it:

- `BrainBackground.register` runs in `AppEnvironment.init` (a handler must be registered before launch ends; nothing else runs).
- The request is made **after the first mix build** (`MixSources.mixBuilt` -> `BrainService.mixWasBuilt`), never at launch, and
  again at the start and end of every run: `earliestBeginDate` = a day after the last run that did a day's work, never before
  now, plus up to an hour of random delay (`RefreshSchedule.earliestBegin`, tested). It needs a network but not the charger.
- iOS decides when (and whether) the task ever runs, so the same work also runs **in the foreground**: the app has been in front
  for 90 seconds (`BrainService.sceneBecameActive`, started by the scene phase), a day has passed since the last run, the last
  try is 30 minutes old at least, and the brain was used (`RefreshSchedule.foregroundRunDue`, tested). It runs at `.utility`
  priority.
- Both go through `BrainService.runRefresh`, which first checks what Android hands to WorkManager as constraints: Wi-Fi or
  wired and not a hotspot or Low Data Mode, and no Low Power Mode (iOS cannot say "unmetered" to the scheduler, so it is
  checked when the run starts; `NetworkConditionsMonitor` is started then, never at launch).
- The rules are `BrainRefreshRunner` (pure over a `RefreshWork` protocol, tested without the system): the off switches are
  asked before the first request and before every one after it, it stops when music plays, it never runs two requests at a
  time, it stops when the budget says so, it is idempotent (a fresh cached list is answered without a request), and
  cancellation ends it between requests. Lane 1 is the day's radio seeds (8 recent chosen and finished, 8 top by decayed
  engagement, 4 liked or saved, 4 pseudo-random library tracks with non-negative affinity, two per artist, only tracks the
  listener chose, a seed without a known YouTube audio id skipped); lane 2 is the artist page and the artist radio for the
  top 20 artists by affinity.
- **Budget (inside `HostBudget`).** `HostBudget` on iOS is 60 a day with a burst of 24, then one per 40 minutes (stage 1's
  deviation 58). The refresh may use 40 of the day (the radios stored in the last 24 hours count, including the foreground's)
  and never the last 4 tokens of the burst (`BrainRefreshWork.requestsLeft`, which reads `YouTubeServices.radioBudget`, the
  same bucket `YouTubeRadioSource` spends). A note of each run is kept in `brain_state` (`refresh_last`, `refresh_attempt`).
- **The off switch.** The local one is Settings > Developer mode > "Background music search" (`brain_refresh_enabled`, default
  on); the remote one is `brain.refresh.enabled` in `remote/config.json`, read from the copy `RemoteClientConfigStore` already
  saves (`BrainRemoteFlags`, no network of its own). The key is in the file now with `true`; a missing file or key means on.

Tests (`BrainRefreshTests`, 11): lane order, one ask per seed, a second run asks for nothing, the switches (never starts; stops
within one fetch), playback, the budget, a missed seed, cancellation, the remote switch (including a config with fractions in
it), the schedule (a day, an hour, a clock set ahead), the foreground rule, and the note. `BrainMixesTests` covers what seeds
the work (`seedsForRefresh`, `topArtistSeeds`, the target's YouTube id from a `yt:` song or a Spotify match).

**Deviation 73.** The background job is a `BGProcessingTask` plus a foreground fallback; "idle" in the foreground is "the scene
has been active for 90 s", not "no touch for 90 s" (nothing in the app reports touches). While music plays the run stops with
`playing` and is not counted as the day's run. **Deviation 74.** "Unmetered", "battery not low" are `NetworkConditionsMonitor`
and `isLowPowerModeEnabled` checked at the start of a run, not scheduler constraints. **Deviation 75.** The budget is 40 of 60
(the radios stored in the day, which the daily limit already counts), as Android's, and the reserve is 4 of iOS's burst of 24.

**Not verified on a device:** that the processing task is ever granted (iOS may never run it; the foreground path is the one
that surely runs); `BGTaskScheduler` accepting the identifier (it is in `BGTaskSchedulerPermittedIdentifiers`); that the
unmetered check does not skip every run on a phone that sits on Wi-Fi with Low Data Mode on; the first-run cost (24 radios at
37 KB).

## Task 4: the pure core and the reason fix

`Snapshot`, `MixPlanner`, `Repetition`, `Seeds` and `Eval` are transliterations; `ListBuilder` and `StationPlanner` gained the
served-log penalty and the per-list jitter (zero for every stage 1 mode, so the stage 1 golden files did not move except for the
version number and the new files); `WhyLine.pick` takes the 21-day positive mass and `mix`. "On repeat" needs a rate above 1.0
**and** a mass of at least 2.5, and the sentence is "On repeat lately" (`BrainStrings`, `BrainCopyTests`). All proven by the
golden files. `BrainPurityTests` covers the new files (no `Foundation`, no libm).

## Task 5: the engine switch

`BrainEngineChoice.legacy | brain`, default `brain`, `UserDefaults` `brain_engine`. The brain builds the mixes only when it is
on and has played **10 different tracks** (Android's 90; `BrainEngine.heardTrackCount`, which includes imported history because
the affinity state does); otherwise `BrainMixes.publish` answers nil and Home's legacy mixes build exactly as before: the
legacy code in `HomeStore.computeIfActive` was not touched. Turning the switch off returns the old mixes at the next
regenerate. Settings > Developer mode > Maintenance has the row.

## Task 6: Daily Mix and Your Mix with new music

`BrainMixes` as Android's `BrainMixes`: a shortlist of about 500 library tracks (the legacy ranking's 300 through
`MixSources.legacyPicks`, favourites, 100 day-seeded deep cuts) with recording ids; the cached radios of the day's seeds
(`cachedRadio`, never the network); the artist lists; the persisted edges; the served log. `MixPoolBuilder` filters like
Autoplay (official audio, 60 to 900 s, no karaoke / cover / sped-up, live / remix only when the seed is), drops what the
library already has and what was ignored three times, and applies blocked artists and taste changes. `MixPlanner` plans;
`ServedListStore` saves; a saved mix is read back without the brain's state; a song that left the library or that a taste
change excludes now is dropped on read-back, and a mix with fewer than 10 songs left is built again. A mix built when no radio
was cached is built again once, after 10 minutes, if radios exist by then.

The app: `HomeStore.scheduleBrainMixes` runs after Home's own computation (and `brainQuiet` waits out the first 4 seconds of
the process, so the brain's files stay closed during startup), shows the result at once, keeps it in place while Home is
recomputed, and writes the library songs of both mixes to the legacy keys so a restart shows them before the brain is read.
`MixScreens` rows are `SongCard` plus `MixRowNote` (the reason line and Save); a play of either mix passes
`tags:` (surface, list, arm, reason, `chosen`) so every row reaches the queue and the event log as a listener's own pick.

Tests (`BrainMixesTests`, 14): shape (30 and 60, each track once, novel share, a closer that is familiar, the tag, true
reasons only, outside tracks registered in `playable`); disjoint mixes; the same all day and across a restart without loading
the brain and a new list the next day; "Regenerate" and the log; the three switch positions; the served penalty over five
days; a blocked artist, a song that left the library, removal across a restart; the 10-track threshold and the legacy
fallback; the stale rule; `publish`.

**Deviation 76.** The served penalty (1.2), the jitter, "seeds are candidates in a mix", "Daily Mix is one list" and "mixes are
built from a shortlist of about 500" are Android's 82 to 85 and 93 and hold here, as pure code proven by the golden files.
**Deviation 77.** The mix is published by `HomeStore` after its own computation, not by a state holder in front of it, so the
first frame after a launch shows the legacy-saved library songs and the brain's mixes replace them a few seconds later (as on
Android, deviation 100). **Deviation 78.** The Familiar / Blend / Discover switch is the one global control of stage 1c
(hidden while picks come from the library alone); the mixes read its level at build time and a change shows at the next
build or regenerate. **Deviation 79.** `BrainMixes.removeItem` exists and is tested but no screen calls it: iOS's mix screens
have no "remove from mix" action (Android's `removeFromDailyMix` has none here to port).

**Not verified on a device:** everything on screen (the row note under the glass cards, its wrap at Dynamic Type sizes, Save,
VoiceOver); that a mix built on a phone has the shape the fakes give; that a track from outside the library in a mix plays,
restores after a restart and saves; the 04:00 rollover and a time-zone change (tested with fixed zones only); mix build time
(`brain_mix_build` goes to the diagnostics log) and the first-open cost of loading the brain's state, which Home now causes
about 4 seconds after launch on the day's first open (the state load also starts the one-time rebuild after the spec version
changed).

## Task 7: the evaluation harness

`Eval` is pure; `BrainEvalTests` runs it on three synthetic listeners (`SyntheticListeners`, a transliteration of Android's).
**The expected numbers are Android's**, and they came out the same: held-out AUC of the prior scorer 0.787 / 0.697 / 0.657
(loyal / explorer / repeater), artist-rate baseline 0.792 / 0.727 / 0.549, track-completions baseline 0.631 / 0.559 / 0.655,
calibration error 0.19 / 0.14 / 0.19, distinct-track ratio over 30 days 0.668 / 0.837 / 0.713, no same-day overlap, largest artist
share at most 0.10, novelty gap at most 0.05, shortest list at least 25. They say nothing about any real listener.
**No real-data number exists; none is claimed.** On two of three synthetic listeners the prior is not above the plain artist
rate: that is what a real export has to answer (spec 14: a gap under 0.05 keeps the brain off for Home ranking).

The "Export play events" action was **not ported**: `play_event.pbl` is one record file, `eventId TAB json` per line, so the
test input is `cut -f2 play_event.pbl` from the app's container. There is no `BrainEvalTest` twin that reads such a file
(Android's skips without `PIXLAUDIO_EVAL_EXPORT`), so test 1 cannot be run on an iOS listener's history yet.

## What was cut or deferred

- The second half of "ignored three times" (a serve that never started playing) is not done, as on Android (86): it needs a
  "surface was opened" signal.
- Lane 2 is the artist top songs and radio, not the release diff of 6.3 (Android 87).
- Daily Mix is one list, K = 1 (Android 84); Your Mix is 60 and then Autoplay carries on (Android 94).
- No "Export play events" action and no iOS real-export eval test (above).
- `feedback.pbl` is unused (Android 95).
- A Developer mode "Regenerate" draws both mixes again; Your Mix's own button draws Your Mix alone (as on Android).

## Not verified (all of it on a phone)

1. Every screen of this milestone, dark and light, long titles, Dynamic Type, VoiceOver.
2. `App/` compiles (CI says; see the section below).
3. The processing task being granted; the foreground fallback; the unmetered check; the first refresh's cost.
4. A pick on a Connect device; the lookup bound.
5. A mix restoring after a restart with outside rows playing, and Save.
6. Mix build time and the state load at the first open of the day.
7. The refresh budget leaving Autoplay enough requests (24 burst, 40 of 60 a day for the worker).

## How to test on a phone

1. Use a build of branch `music-brain` (the `ipa` job). Sign in to Spotify, let the library sync, listen to about ten
   different songs through (60 seconds each is enough to be recorded; they must finish to count as chosen).
2. Play one song and let Autoplay run once (it caches a radio). Wait about 10 minutes, then open Settings > Developer mode >
   Maintenance > "Regenerate Daily Mix". Open Daily Mix: some rows are new music with a line ("Fans of ... also play this")
   and a Save button.
3. Kill the app and reopen it: the same Daily Mix, with the new music still there a few seconds after launch.
4. "Music engine" off, regenerate: the old mixes. On, regenerate: the new ones.
5. Your Mix's regenerate button: another list; Daily Mix unchanged.
6. Connect a Spotify Connect speaker and let the queue run out: picks that Spotify has follow; none that it lacks.
7. Leave the app open on Home for two minutes with Wi-Fi: the diagnostics log has a `brain` line, and "Background music
   search" off stops it.

## Commands and results

```
gh run list --branch music-brain --workflow ci --limit 3        # at the start: 44307349413 success
cmd //c "ci\\swiftw.cmd test --package-path Packages\\PixlCore --filter BrainMixGolden --filter BrainGoldenTests"
cmd //c "ci\\swiftw.cmd test --package-path Packages\\PixlCore --filter BrainEvalTests --filter BrainMixPlannerTests"
cmd //c "ci\\swiftw.cmd test --package-path Packages\\PixlCore --filter BrainMixesTests --filter BrainStage2aStoreTests --filter BrainRefreshTests --filter BrainRemoteOutputTests --filter SpotifyConnectIdTests"
cmd //c "ci\\swiftw.cmd test --package-path Packages\\PixlCore"
bash ci/check-forbidden.sh
powershell -NoProfile -ExecutionPolicy Bypass -File ci/parse-check.ps1
```

The full PixlCore suite: exit 0, **2,234 tests in 8 bundles, 0 failed** (79 more than the review-fix round's 2,155; the new
suites are `BrainMixGoldenTests` 7, `BrainMixPlannerTests` 18, `BrainEvalTests` 10, `BrainMixesTests` 14, `BrainStage2aTests`
29 in three suites, `SpotifyConnectIdTests` 1). `check-forbidden.sh`: OK. `parse-check.ps1`: 162 files OK (syntax only: nothing
under `App/` is type-checked on this machine). In a debug build the three list-health tests take about 80 to 90 s each, in parallel; a release build is far faster.

## CI

Run `44429445405` (workflow `ci`, branch `music-brain`, last code commit `eaa0f93`) finished **green on its third attempt**.

- Attempt 1 (commit `db8e57c`): `core` (Linux) passed; the app **did not build**: `BrainBackground.swift` used
  `currentTimeMillis()` without `import PixlModel` ("cannot find 'currentTimeMillis' in scope"). Fixed in `eaa0f93`.
- With `eaa0f93`: the app BUILT on its first try with no other compile error, so everything else under `App/` that this
  milestone touched type-checks (Swift 6 concurrency included). `core` (Linux): the eight PixlCore bundles passed, so the
  golden files hold on Linux too.
  - attempt 1: 657 unit tests, the only failure `SpotifyMatchCoordinatorTests.testConcurrentMatchesOfOneSongRunTheSearchOnce`
    (known flaky);
  - attempt 2: the only failure `SpatialPlaybackTests.testTheRenditionSwitchFadesForAQuarterSecondAndKeepsTheTwentySecondRule`
    (known flaky);
  - attempt 3: all 657 passed.
- `ipa` was skipped, as on every push. No screenshot (`[shots]`) run was made. CI green means `App/` compiles and its unit
  tests pass; no test drives the new `HomeStore` path, `BrainService.runRefresh`, `BrainBackground` or the mix rows, so it says
  nothing about whether they work.
