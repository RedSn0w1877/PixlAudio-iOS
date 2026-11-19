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
