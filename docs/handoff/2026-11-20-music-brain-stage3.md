# Music brain, stage 3 (iOS): running handoff

Branch `music-brain`. The contract is `docs/brain-spec.md` (v1.1), section 14 "Stage 3: It learns, and shows it". This file is the iOS
port of Android's stage 3 as it stands in Android's commits `38019c0`, `eb1ea87` and `670e957` and its handoff
`handoff/2026-11-20-music-brain-stage3.md` (read its "Deviations 175 and on" and "Deletion plan"; they hold here unless a line below says
otherwise). The earlier handoffs are the map of what exists: stage 1 (deviations 1 to 66), stage 2a (67 to 106), stage 2b (107 to 139).
This file continues the iOS numbering at **140**.

**Nothing below has been run on a phone.** Only `Packages/PixlCore` compiles on the Windows machine; `App/` is compiled by GitHub CI
alone. "Works" means: unit tests pass, the golden files match Android's bit for bit, and the code paths were read end to end.
**The learner has only ever run on synthetic listeners. There is no real-data number yet**: no accuracy, no log-loss and no test 6 result
on a real export exist anywhere (code, copy or this file), and none may be claimed until one is computed from a real export.

## What this pass was

An independent review of the iOS branch found no stage 3 code on it at all (branch `music-brain` was at `ed220b8`, the same as origin), so
its findings list was empty and every "done means" item was "not met". This pass built the iOS stage 3 that Android's milestone has, up to
the same cut line, so every item is now met or cut with a reason below. Android's own review findings (its table in "Review findings, one
by one") were fixed in Android before the port, so the port starts from the fixed code.

## What the listener gets (once checked on a phone)

- **Settings › Library & storage › Listening history › Your sound** (new row). A page with only the sections that have data: *Right now*
  (the islands of the last 28 days, with bars), *Genres* (tap one for its page), *Eras*, *Through the day*, *Over months*, *New and
  familiar*, and *How well I know you*. That last section says only what is true of the model at that moment:
  "Still getting to know you" with a count below 300 graded plays; "Your picks use the standard recipe for now." with the standard recipe's own
  accuracy from 300; and "Learning from N plays." with the accuracy now, a month ago when there is one, and the standard recipe's, only
  while the learned weights are really in use (the gate has had them win two weeks running). A *Controls* card holds **Reset what I've
  learned** (with a confirmation) and a link to Ask Taizo's taste changes.
- **A genre page** (from Your sound, and from the links on another genre page): the atlas's name, where and when it began, its own paragraph
  for the roughly 200 genres the atlas describes, a **Play station** button, and *Comes from*, *Branches*, *Close to* and *Shaped by* as links.
  Nothing is written at run time; a genre or a link whose name the app does not say is absent.
- Under the hood: every graded play updates the ranker's weights (one small step, off the main actor, saved with the play); mixes, autoplay,
  stations and Home rows are ranked with the learned weights **only while the gate has them on**, and one session in ten is always ranked
  with the standard recipe and flagged as a control.

## Where things are

**`Packages/PixlCore/Sources/PixlLibrary/Brain/`** (pure; scanned by `BrainPurityTests`; same names as `:brain`)
`RankerLearner.swift` (`RankerModel`, and the learner half of `Ranker`: `newModel`, `update`, `forget`, `applyEvent`, `predict`,
`predictPrior`, `weightsFor`, `precisionFor`, `sampleWeights`, `listSeed`, `isControlSession`, `WeightSource`), `Gate.swift`,
`LearnReplay.swift` (`run`, `applyLive`, `featuresOf`, `test6`), `LearnerCodec.swift`, `YourSound.swift` (`YourSound` and `ModelVoice`),
`GenrePage.swift`; `StationPlanner.Request.ranking` and `MixPlanner.Request.ranking` (nil is `M0`, so every earlier plan is byte for byte
what it was); `Brain.onEvent` has an optional `beforeApply` hook.

**`Packages/PixlCore/Sources/PixlLibrary/BrainStore/`** `BrainEngine.swift` (`Learner`, `Loaded.learner`, `Loaded.ranking`, the live update in
`apply`, `loadLearner`, `resetLearned`, `learnerFigures`, the rebuild's training and adoption, the control flag and `modelVersion` in `record`),
`BrainMigration.swift` (`ReplayMerger.rebuild(... learn:)`), `BrainEventLog.swift` (four new `brain_state` keys), `YourSoundReader.swift`
(Your sound's rows and the genre page's names; the pure parts are `pass` and `facts`).

**`App/`** `Features/Brain/YourSoundView.swift` (the screen and its model), `GenrePageView.swift`, `BrainStringsSound.swift` (every word),
`Services/Brain/BrainService.swift` (`yourSound`, built with the mixes, nothing computed until a screen asks), `Core/Routes.swift`
(`.yourSound`, `.genrePage(atlasId:)`), `Shell/RouteDestinations.swift`, a row in `LibrarySettingsSection`.

**Tests** `BrainStage3GoldenTests` (the four new golden files), `BrainLearnerTests` (30), `BrainLearnerEngineTests` (6),
`BrainYourSoundTests` (10), `BrainYourSoundReaderTests` (3), `BrainCopyTests` (one new test). Fixtures: `ekf.jsonl`, `listseed.jsonl`,
`replay.jsonl`, `learner.jsonl` added; `MANIFEST.sha256` and `README.md` replaced; no earlier fixture changed (compared by git blob id with
Android's `music-brain` at `670e957`). `Brain.specVersion` stays 2: no earlier output changed.

## What was done, against the review's "done means"

1. **Learner matches a batch refit, stays in its box, resets on a non-finite value**: done. `BrainLearnerTests` has the one-pass-against-batch
   comparison and the reset cases; the update, the forgetting and the replay are bit-identical to Android's (`ekf.jsonl`, `replay.jsonl`).
2. **Frozen-prior gate, Reset, Your sound statement**: done (`Gate`, `BrainEngine.resetLearned`, `ModelVoice`). The gate starts off, needs two
   weekly wins in a row, and turns off at once when the learned weights do not predict better.
3. **Your sound shows only sections with data, accuracy only from 300 graded plays**: done in the pure core (`ModelVoice.of`); the screen only
   draws it. Every percentage is from the listener's own graded plays.
4. **No second background job; per-play update and rebuild off the main thread**: done. The update runs under the engine actor (a copy of 51
   doubles, one feature vector); the replay and the gate's evaluation run inside the existing rebuild, in its detached task; nothing runs at
   app start (the engine loads the saved learner with the first play or plan, as it loads the affinity rows).
5. **Genre pages from atlas facts only**: done (`GenrePage`, `YourSoundReader.facts`).
6. **Legacy engine, Muselle and the recommendation golden files still present, with a written deletion plan**: nothing was deleted
   (`Recommendation.swift` and `recommendationMatchesAndroid` are untouched). The plan is Android's, with step 4 "the same on iOS after
   Android": remove `BrainEngineChoice.legacy` and its switch row, delete `Recommendation.swift` and its golden test once nothing reads
   them. It may run only if the gate passes on **real** data; nobody has run that.
7. **Android golden files matched bit for bit; stage 2 state loads without loss**: done. No file or record changed; the learner is four
   values in `brain_state.pbl` (`learner_v1`, `learn_version`, `learner_liked_v1`, `learn_after_event_id`), so a stage 2 install loads as it
   was and the next rebuild trains the learner.
8. **"learn" only in the true strings, other forbidden words still fail**: done. `BrainCopyTests` allows the word in exactly three
   literals (`Learning from \(count) plays.`, `Reset what I've learned`, `Reset what I've learned?`) and requires that no other literal of
   `App/Features/Brain` says it.

## Deviations 140 and on

140. **The learner is saved right after the play's rows, not in the same transaction** (Android 178: one transaction). iOS has separate record
     files. The order is event, affinity rows, learner; a crash between the last two loses one learner step and can never apply one twice
     (the watermark `lastEventId` in the saved model). The next replay realigns it.
141. **`isRebuildNeeded` is also true when `learn_version` differs from `LearnReplay.version`.** The first run after the update therefore does
     one rebuild that trains the learner: the same delayed first-use rebuild the app already does (15 s after first use, never at launch).
142. **`RankerModel` is a value type.** `Ranker.update(&model, ...)`, `LearnReplay.applyLive(&model, ...)`. Android's is a mutable class. Because a
     Swift struct cannot be captured while the engine holds the state `inout`, the hook of `Brain.onEvent` is handed the affinity and the session
     as they were, and the engine runs the learner on a copy of the model that it puts back (`BrainEngine.apply`).
143. **There is no separate weekly job; the gate's weekly evaluation is the rebuild.** On iOS a rebuild runs at first use when the last one is
     over 7 days old, and when forced (an import changed, an exclusion, the Spotify switch, a reset). The gate's 6-day guard (`Gate.weekMs`)
     stops a burst of forced rebuilds from counting as weeks, so the two-weeks rule is by time, as on Android. This is also why nothing was
     added to `BrainRefresh`: it stays the one background job.
144. **`resetLearned` is an actor method that returns at once** (Android: suspend). It stores `learn_after_event_id`, writes the prior model,
     bumps the epoch and asks for a forced rebuild; `YourSoundModel.reset` then reloads the figures.
145. **Your sound reads the log as bytes on the engine actor and decodes and counts it in a detached task** (`engine.eventPayloads()` then
     `YourSoundReader.pass`), the way the rebuild does. The read itself is on the actor for as long as it takes to hand over the file's bytes.
     Never measured on a log of 100,000 plays.
146. **The rebuild's `tzNowMin` is `TimeZone.current` at that moment**, as Android's `TimeZone.getDefault()`.
147. **No test sends the engine's model back to the prior through a play** (Android's last `LearnerEngineTest` case): a saved model cannot hold a
     non-finite value (the reader refuses it), so the test would have to reach into the actor. The pure path (`Ranker.update` resetting on a bad
     model, `BrainLearnerTests`) is covered; the engine's `requestRebuild(force: true)` on `updateReset` is read, not run.
148. **The genre page's "Play station" uses the existing `BrainActions.startGenreStation`**; when nothing of the listener's is under the genre the
     existing notice (`BrainStrings.stationGenreNothing`) says so; Android's own toast text (`brain_genre_nothing`) is not added.

Android 175 to 188 hold on iOS (the bias as an offset from `logit(p0)`, forgetting as a pure function of the days, `x` recomputed at
finalisation, the gate off at the start, accuracy against the base finish rate, one posterior sample per list for mixes only, `modelVersion = 1`,
Reset's `learn_after_event_id`, test 6 not run on real exports, Your sound computed when the screen opens and cached 5 minutes, the sections and
what was cut from them, genre pages atlas-only, the learned weights ranking mixes, stations, autoplay and Home rows only), except 178 (see 140).

## Cut or deferred (and why)

The same cut line as Android, nothing more:

- **The arm bandit, the learned novelty appetite, context lift and the daypart mix, impressions and the shelf bandit** (5.10, scope of stage 3):
  not built. Features 29 and 36 stay as in stage 2. The posterior sample per list is built.
- **The `brain` backup module**: not built (iOS's backup sections have validators and golden files that would all change).
- **The `M0` refit on pooled exports, test 6 on real exports, deleting the legacy engine**: need real exports. `LearnReplay.test6` exists and runs on
  synthetic listeners only. **Nothing was deleted.**
- **Your sound's "Lately" section, tap-through on islands (top artists and songs, Play station, More / Less), the genre tree, the energy and mood
  sections, the artwork-tinted hero, an entry from Home's avatar**: cut (Android cut them too); the page is reached from Settings only.
- **Genre page key artists, "From your library", "You and this genre", More / Less of this**: cut, as on Android.
- **A UI test or a screenshot demo of the two screens** (`UITestLaunchRouter`): not added; the screens read the brain, which is nil in UI tests, so
  they would show the empty state. The two accessibility ids are `screen.yourSound` and `screen.genrePage`.

## How to test on a phone (stage 3, for Hoa)

1. **Update over the previous build.** The app opens. Settings › Library & storage › Listening history has a new row, **Your sound**; it opens. With
   under 300 graded plays it says "Still getting to know you" and "N of 300 plays so far". Nothing says "learning" anywhere yet.
2. **First replay.** Use the app for a minute (play a song). About 15 seconds after first use, one rebuild runs in the background (the one that
   already ran in stage 2); nothing blocks the screen. Open Your sound again: with 300 or more graded plays it says "Your picks use the standard
   recipe for now." with a percentage.
3. **The gate.** The learned weights turn on only after two rebuilds at least six days apart in which they predicted better, so no earlier than
   a week to two weeks in. Until then every pick uses the standard recipe and the page says so. Nothing the app shows before that may say it is learning.
4. **Learning shown.** Once on, the page says "Learning from N plays." with the accuracy now, a month ago when there is one, and the standard
   recipe's. Check that no percentage appears before 300 graded plays.
5. **Control sessions.** One session in ten uses the standard recipe as a check. After 300 plays there, a line shows the two finish rates side by side.
6. **Reset what I've learned.** Controls › Reset › confirm: a notice says "Back to the standard recipe."; the page then says the standard recipe is in
   use; after the next rebuild it still does (only plays from now on are learned from). Your plays, blocked artists and taste changes are still there.
7. **Genres.** In Your sound, tap a genre: its page with the origin, a paragraph when the atlas has one, and the links; **Play station** starts a station
   from the listener's songs under it, or says there are none; tap a link to go to the next page.
8. **Nothing at start, one job.** A cold launch does no brain work (the learner is read with the first play or plan); Settings › Developer mode shows no
   new background task; the one `brain-refresh` request is the only one.

## What nobody has verified on a device

Everything above. In particular: how the two screens look (Liquid Glass cards, the bars, the genre links wrapping) and that the row, the routes and the
confirmation work; the replay time and memory on a real log of 20,000 to 100,000 plays (it computes a feature vector and two predictions per play; the
tests run a 2,000 play synthetic listener in well under a second, never a real log); the time `YourSoundReader` takes on a long log (deviation 145);
whether the learned weights ever beat the prior on a real listener (**no real-data number exists**); the gate's two-week rule in practice; Reset on a real
install; the saved learner after a process kill (the order of writes is in deviation 140); the control-session completion rates (the flag and
`modelVersion` are set when a play ends, not when the list was ranked, as on Android); that `App/` compiles (CI alone says so, see below).

## Commands and results

```
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainStage3GoldenTests"   # 5 tests, 0 failed (the four golden files, bit for bit)
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainLearnerTests"        # 30 tests, 0 failed
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainLearnerEngineTests"  # 6 tests, 0 failed
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainYourSoundTests"      # 10 tests, 0 failed
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainYourSoundReaderTests"# 3 tests, 0 failed
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainCopyTests"           # 4 tests, 0 failed
bash ci/check-forbidden.sh                                                                       # OK
powershell -NoProfile -ExecutionPolicy Bypass -File ci/parse-check.ps1                           # 251 files OK
```

```
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore"   # 8 bundles, 2,516 tests: one failure, then fixed
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainGoldenTests"   # 12 tests, 0 failed (after the fix)
```

The full run had exactly one failure, `BrainGoldenTests.theManifestListsEveryFileWithItsHash`, whose expected file count was still 29 (the manifest now lists
33); the count was changed and that suite re-run alone (12 tests, 0 failed). The whole package was not run a second time after that one-line change.

## CI

Run **44627072802** (`1e9fa56`, workflow `ci`, branch `music-brain`): `core` (PixlCore `swift test` on macOS) **passed**, `app` (build and unit tests,
Xcode 27, Swift 6 strict concurrency, which is the only compiler for `App/`) **passed**, `ipa` skipped as for any branch push. Conclusion: **success**, on the first
attempt, with no rerun and no known flake hit. Green CI says nothing about how the two new screens look or behave on a phone.

---

# Stage 3 completion (iOS, second pass)

This pass ports Android's second pass (its commits `aedd3cc`, `053340a`, `52c9439` and `c3a6f14`, and the section "Stage 3 completion" of its
`handoff/2026-11-20-music-brain-stage3.md`, deviations 189 to 201, which hold here unless a line below says otherwise). It built what the first pass
cut: control sessions measured on what was ranked, the arm bandit, the novelty appetite, context and the daypart mix, impressions and the shelf bandit,
Your sound's Lately, genre tree and island sheet, the genre page's own sections, the music picks backup module and the test 6 command.

**Still true: nothing below has run on a phone, every number is from synthetic listeners, there is no real-data number for the learner anywhere
(code, copy, docs), and the legacy engine is NOT deleted.** `Brain.specVersion` is still 2; no earlier golden file moved.

## What was built (files)

Pure core, `Packages/PixlCore/Sources/PixlLibrary/Brain/` (same names as `:brain`; Android's five NEW golden files `bandit`, `novelty`, `context`,
`shelfbandit`, `posteriors` are matched bit for bit; `MANIFEST.sha256` and `README.md` copied, 38 files now):
`ArmBandit.swift` (+ `ArmPicker`, `ClosureArmPicker`, `Sampler`), `NoveltyAppetite.swift`, `Posteriors.swift` (+ `PosteriorUpdate`, `PosteriorCodec`),
`ContextLift.swift`, `ShelfBandit.swift` (+ `ShelfBanditCodec`); changes to `ListBuilder` (`armPicker`, `Pick.explore`), `StationPlanner` (`armPicker`,
`Pick.explore`, `Plan.control` / `modelVersion`), `MixPlanner` (`armPicker`, `nuBase`, `nuOverride`, `nuOf(appetite:)`), `HomePlanner` (`daypartMix`,
`reorder`), `LearnReplay` (`Result.posteriors`, `applyLive(posteriors:)`), `Replay.applyFacts` (a TAG adjustment), `YourSound` (`lately`, `genreTree`,
`genreHistory`).

Engine and stores, `PixlLibrary/BrainStore/`: `BrainEngine` (`RankingChoice`, `Loaded.rankingChoice` / `armPicker` / `sessionNu`, `Learner.posteriors`,
the live update of both, `posteriors_v1`, reset, rebuild, `usesLearned`, `configureAtlas`, `backupState` / `restoreBackupState`), `ShelfStore.swift`
(`ShelfStore`, `Impression`, `ImpressionFile`), `ContextStore.swift`, `BrainMixes` / `MixModel` (the daypart kind, `explore`, `control`, `model`),
`BrainHomeRows`, `HomePlan` (`PlanItem.explore`, `PlanShelf.control` / `model`), `HomePlanBuilder` (the daypart shelf after "Because you listened to",
the bandit's order), `BrainRefresh` (`settleShelves`), `AutoplayPlanning` (the tag reads the plan's choice), `YourSoundReader` (Lately, the tree,
island names, `genreExtras`), `BrainFeedback.genreChange`, `BrainMigration` (`LibraryFactsBuilder`: a genre change is a TAG pseudo-count),
`DnaStore` (`artistsWithTags`), `FeedbackStore` (`all`, `replaceAll`). Model: `BrainItemTag` and the saved queue item gained `control`, `modelVersion`,
`explore` (`brainControl`, `brainModel`, `brainExplore`, the same names as Android). Backup: `PixlBackup/Modules/BrainModule.swift`
(`BrainBackupModule`), `BackupSection.brain` (key `brain`, `sinceVersion` 4, label "Music picks"), its validator and importer.

App (thin): `BrainService` (builds `ShelfStore` and `ContextStore`, hands them to the plan builder, the refresh and Your sound; `backupBrain`,
`restoreBrain`), `HomePlanState` (the page shown, seen and started signals), `HomeView` (a one-second dwell per shelf, a started shelf),
`BrainStringsHome` / `BrainStringsSound` (every new word, the same sentences as Android), `YourSoundView` (Lately, the tree, the island sheet),
`GenrePageView` (More / Less, key artists, From your library, You and this genre), `BrainActions.adjustGenre`, `TasteAdjustmentStore`
(`backupText`, `restoreFromBackup`), `BackupService` (the `.brain` export and restore), `AppEnvironment` (wiring), `BackupSettingsSection`.

Tests: `BrainStage3bGoldenTests` (6), `BrainStage3bTests` (33), `BrainStage3bEngineTests` (15), `BrainBackupTests` (6), `BrainRealExportTest6` (1,
skipped without a file); `BrainLearnerEngineTests`' control case now passes the choice in the tag; `AndroidPortTests` counts 13 sections;
`BrainGoldenTests` counts 38 fixture files.

## Deviations (iOS numbering continues at 149)

149. **The ranking record travels on the plan.** Android sets `inputs.choice` on the mutable autoplay inputs. Here the engine puts `control` and
     `modelVersion` on the `StationPlanner.Plan` it returns (autoplay, station, Home row, mix), and `AutoplayPlanning.items` and `tag` read them, so
     `AutoplayController` needed no change. A pick taken in pool order has no plan: the prior, no control (Android 189).
150. **Impressions are two record files owned by `ShelfStore`**, not rows in `BrainEventLog`: `impression.pbl` (`visitId|position` -> `[v, visitId,
     position, shelf, daypart, shownAtMs, seen, activatedAtMs, settled]`, `v` = 1; a record of another version is ignored; a stage 1 to 3 install has
     no file) and `shelf_bandit.pbl` (the posteriors, `ShelfBanditCodec`). At most 200 visits and 90 days, pruned when a visit is added. Android keeps
     the posteriors in `brain_state`; they were kept apart here because the event log's files belong to the engine actor. A missing or unreadable
     posterior state starts from the priors (Android 196: the rows hold no reward, so they cannot make it again).
151. **`ContextStore` reads the whole log** (the file's bytes on the engine, decoded and counted in a detached task), cached for 30 minutes, not paged
     as on Android. Same trade as Your sound (deviation 145): never measured on 100,000 plays.
152. **`ShelfStore` is an actor; every call from the page is a detached `.utility` task**; nothing runs on the main actor, and the settle also runs at the
     end of the refresh (`RefreshWork.settleShelves`) and at the next page show, as on Android.
153. **A shelf is "seen" after a one-second dwell** of a SwiftUI `task(id:)` that starts when the shelf appears and is cancelled when it goes. Whether a
     shelf in a `LazyVStack` counts the way a listener would is unverified.
154. **Genre changes reach the tag only when the engine has the atlas**: `BrainEngine.configureAtlas` is called with the atlas provider when the
     mixes are configured. Without it a genre change is the ranking-time boost alone, as before.
155. **Backup.** `BackupSection.brain` is listed for developer mode only (`isTechnical`), so the everyday list keeps its seven sections; it is in every
     backup by default. Salt and exclusions cross platforms unchanged. The taste changes travel as the exporting app's own text: this app writes its
     JSON, and text from the other platform is not read (the changes here are left alone, never failed). The event log is not in the module (the
     playback history and imported history modules cover plays, as on Android 200). **Platform backup**: nothing under `Application Support/Brain/` is
     marked excluded from the device backup, so the whole folder (the event log is the truth, the rest small caches) is carried by iCloud / iTunes backup;
     Android excludes only its saved plans. No code was added for this.
156. **Test 6 on a real export** (`BrainRealExportTest6`): iOS has no "Export play events" action (stage 2a, deviation noted there), so the test also
     reads a copy of `play_event.pbl` (records are the same lines). Command:
     `PIXLAUDIO_EVAL_EXPORT=<play-events.jsonl or play_event.pbl> cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainRealExportTest6"`;
     the report is printed and written to `PIXLAUDIO_EVAL_REPORT`, else `Packages/PixlCore/.build/reports/brain-test6.txt`. It was run once on a
     synthetic file made from a golden file, to see that it works; **it was not run on a real export** and its numbers are not recorded here.
157. **Saved shapes that gained fields** (`StoredHomeItem`, `StoredHomeRow`, `PlanItem`, `PlanShelf`) got explicit decoders: a synthesized `Codable` would
     have refused every file a stage 2 install wrote. Tested with the old JSON.
158. **The island's detail is a sheet**, not an alert (a list with buttons), and a genre family opens in place. "Play station" is the existing
     `startGenreStation`, so with nothing of the listener's under the genre the existing notice says so (as deviation 148).
159. **Daypart titles** say "Your weekday mornings" ... "Your weekend nights" (Android 195): the shelf's bucket is weekday or weekend, never one weekday.

Android 189 to 201 hold, in particular: the arm bandit runs only while the learned weights are in use and the session is not a control (190), a
taste adjustment on a genre does not move tracks with no genre (199), the shelf order is used only with the learned weights on and after 20 shelf
updates (196).

## Cut or deferred (as on Android, nothing more)

Feature 29 `ctx_lift` is not fed into scoring; Your sound's energy and mood sections, the artwork-tinted hero and an entry from Home's avatar (Settings
only); a station from an island with no nameable genre; the `M0` refit on pooled exports and test 6 on real data; deleting the legacy engine.

## How to test on a phone (additions)

1. **Control flag**: play autoplay in a few sessions; about one session in ten has `controlSession` on its engine picks in the event log, and `modelVersion`
   is 0 on them and on every pick while the gate is off.
2. **Nothing changes until the gate is on.** After two weekly rebuilds in which the learned weights won, novel slots carry the exploration flag and the
   novelty share follows what you finish; Your sound's novelty line moves with it.
3. **Daypart shelf**: needs islands and 50 plays in one bucket of the week; then "Your weekday nights" (or the bucket you are in) appears after "Because you
   listened to". Absent otherwise.
4. **Shelf order**: with the gate on and 20 shelf updates the order can differ between dayparts, never within one. `impression.pbl` stays small (at most 200
   visits).
5. **Your sound**: Lately after a few days of moved plays; tap a family to open its genres, tap an island for its artists and songs, Play station, More of this,
   Less of this. A genre page: More / Less, Key artists, From your library, You and this genre (absent for a genre never played).
6. **Backup**: Settings › Developer mode lists "Music picks"; export, change a taste change, restore: the change comes back, the salt and exclusions too.
7. **Test 6** on your own export: deviation 156.

## What nobody has verified on a device

Everything above, and in particular: that the control flag and the model version reach events from every surface (read in code, tested at the recorder);
the arm bandit's exploration slots and whether the audit ever fires; what the learned appetite does to a mix over weeks; the context table on a real log
(time over 100,000 events) and the daypart shelf's content; the one-second dwell and the started-shelf signal in a real page; the settling and the frozen
order; the size of `impression.pbl` over months; Lately (two passes over a large log: time not measured); the island sheet and the tree; the genre page on
real atlas coverage; a backup export and restore of the music picks and the platform backup behaviour; that `App/` compiles (CI alone says so, below).
**There is still no real-data number for the learner.**

## Commands and results

```
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainStage3b"   # 54 tests in 3 suites, 0 failed (golden 6, pure 33, engine 15)
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainBackupTests"   # 6 tests, 0 failed
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter AndroidPortTests"   # 66 tests, 0 failed
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainLearnerEngineTests"   # 6 tests, 0 failed
bash ci/check-forbidden.sh                                                                  # OK
powershell -NoProfile -ExecutionPolicy Bypass -File ci/parse-check.ps1 -All               # 1,075 files OK
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore"                              # 8 bundles, 2,577 tests, 0 failed
```
