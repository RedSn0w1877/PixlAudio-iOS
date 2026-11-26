# 2026-11-26 — Brain: two lanes (iOS port)

Port of Android `brain-tuning` commit `82237d9` (handoff `handoff/2026-11-25-brain-tuning.md`, "2026-11-26 (later): two lanes, shipped";
spec 5.7 "Two lanes" and 6.5 "lanes"). Branch `brain-twolane`.

## What changed

- `Ranker.choiceShiftTable` / `choiceShift(_:)` / `choiceWeights(_:)`: the choice scorer is the finish weights plus a fixed shift,
  literals as on Android ([1] -0.8, [3] +0.6, [4] -0.4, [12] +1.5, [13] +0.6, [14] +0.1, [15] -0.1, [16] -0.2, [24] +0.5), added in index order.
- `ListBuilder.Scored`: `zChoice` / `pChoice` (init defaults to `z` / `p`) and `laneZ` / `laneP`. Bridge, opener, closer and the
  within-slot value (familiar, liked) read the lane score; novel slots read `z` / `p`.
- `StationPlanner.plan`: `choiceWeights = Ranker.choiceWeights(weights)`; for an `inLibrary` candidate `zc = z(choiceWeights, x)`
  plus the same station pull and `boostLn` as `z`; `pChoice` from `zc` with the same precision; a novel candidate gets `zc = z`, `pChoice = p`.
- Unchanged: discovery lane, novelty share, skip prediction, served `pQ`, reward, learner, `LearnReplay.version` (no second model).
- Goldens copied from Android at `82237d9`: `lists`, `mixes`, `session`, `stage2a`, `eval` + `MANIFEST.sha256` (only those five hashes moved).
- `docs/brain-spec.md`: the two paragraphs of 5.7 and 6.5 copied word for word.

## Not ported

- Android's `tools/eval` `compose` command (Kotlin-only research tool; iOS has no eval tool).

## Left

- Nothing run on a phone. Home rows and First Listen are all novel, so they are unaffected by construction.
