# Music brain, stage 5 (iOS): on-device tempo and loudness, flow ordering

Branch `brain-stage5` (from `everything`). The iOS port of Android's `brain-stage5` (commits `116a6ce`, `d670b42`, `6b07937`, `b1fb204`,
`1496f3d`; handoff `handoff/2026-11-25-music-brain-stage5.md`, its deviations S5-1 to S5-4 hold here). Spec: `docs/brain-spec.md` 3.3, 3.5,
6.5, 14 "Stage 5". This file continues the iOS numbering of the earlier brain handoffs at **S5-i1**.

**Nothing here has run on a phone.** PixlCore is tested on Windows; `App/` compiles on CI only. The estimator is checked on synthetic PCM
(Android's fixtures, rebuilt bit for bit); the AVFoundation decode, the stall rule and the diagnostics row are read from code, not observed.

## What was built

### Pure core (PixlLibrary, bit for bit with Android)

- `Brain/AudioFeatures.swift`: the estimator (`Estimator(sampleRate:channels:)`, `feed` of 16-bit or float interleaved PCM in any block
  size, `full`, `finish()`), `tanSmall`, `windowStartMs`, `chooseTempo` (trusted measurement >= 550 > Deezer > weak >= 250 > unknown),
  `chooseGain` (Deezer's gain first, measured LUFS fills). Expression order copied from Kotlin; `BrainMath` only, no FMA.
- `Brain/Flow.swift`: `tempoDist`, `step` (tempo, gain capped at 0.15, energy step), `target` / `arc` (finite lists), `cost`, `roughness`,
  `Facts`, `Context` (median energy computed once).
- `TrackDna`: `tempoUnknown/Deezer/AcousticBrainz/OnDevice/OnDeviceWeak` (0...4), `feel(_:_:gainDbX10:tempoBpmX10:)` (the tempo nudge,
  +-15, valence untouched).
- `ListBuilder.Request.flow` (subtracted in `value` with the slot index), `StationPlanner.Request.flow`, `MixPlanner.Request.flowFacts`
  (arc for Daily Mix). Nil / empty builds byte-identical lists: every earlier golden file still matches.
- Golden files `audiofeatures.jsonl` (80) and `flow.jsonl` (628), Android's `README.md` and `MANIFEST.sha256` (49 entries) copied unchanged.
  `Tests/PixlLibraryTests/AudioFixtures.swift` is the port of the fixture synth; every `estimate` line checks `pcmHash` and `samples`
  first. `BrainStage5GoldenTests` also ports `AudioFeaturesTest` and `FlowTest`.

### Store (PixlLibrary/BrainStore)

- `AudioMeasureStore.swift`: `AudioMeasureRow` (Android's `AudioMeasureEntity`, same columns), `AudioMeasureRepository` (actor, file
  `audio_measure.pbl`), `AudioMeasurePolicy` (`wants`: once per version, a failure waits a day, three wait 30 days; `facts`),
  protocols `AudioMeasureLookup` and `FlowFactsSource`.
- `DnaAssembler.assemble(..., measured:)` and `DnaEnricher(measures:)`: tempo by `chooseTempo` (an AcousticBrainz tempo stays while
  nothing better is known), gain by `chooseGain`, energy with the tempo nudge.
- `CandidateDna.Known.flowFacts` (from `CandidateDna(flow:)`) feeds `BrainMixes` (Daily, daypart, Your Mix, First Listen) and
  `AssistantMixer` (Ask Taizo mixes).
- Autoplay and stations: `AutoplayPlanInputs.leadRid` (from `AutoplayPlanning.leadRid`, the queue item before the planned slots),
  `flowFacts`, `flowRids`, `flowContext`; `BrainEngine.plan` passes the context (re-score patches too). The app reads the facts before
  the plan (`BrainService.withFlowFacts`).

### App

- `Services/Brain/AudioMeasurer.swift` (`@MainActor @Observable`): told by `PlaybackServices` about each track change (the song and the
  next one the queue plays on its own) and about stalls (`DualDeckEngine.onPreparingChanged` while `playWhenReady`). Waits 10 s,
  resolves the rid with the same keys a play is recorded under (`BrainService.recordingId`), asks `wants`, takes the engine's own
  resolver chain: a file URL (download, prepared Opus, complete stream cache) decodes on any network; a `pixlstream://` URL only on
  Wi-Fi / Ethernet that is not expensive and not Low Data Mode, through the app's own resource loader. `AVAssetReader` +
  `AVAssetReaderTrackOutput` to 16-bit interleaved LPCM, `timeRange` = 42 s from 20% in, one reused sample array, on a detached
  background-priority task. A stall pauses between buffers; 8 s of stall gives the window up without a failure; 60 s deadline; a skip
  cancels.
- Developer mode › Maintenance: "Tempo and loudness" (`Features/Brain/BrainMeasureRow.swift`, after Brain data, Android's copy word for word).
- Spotify Connect: a pick Connect cannot play is logged (`autoplay: n of m picks left out, not playable on connect`).
- Cast: not built (no Cast on iOS; Android did not build it either).

## Deviations (iOS)

- S5-i1: no SQL migration. iOS brain tables are keyed record files; a stage 4 install simply has no `audio_measure.pbl` (an empty store).
  That is the iOS form of `MIGRATION_7_8`.
- S5-i2: the stall signal is the engine's "preparing" state while it should play (load or `waitingToPlayAtSpecifiedRate`), Android's
  `STATE_BUFFERING && playWhenReady`.
- S5-i3: the decode stops between sample buffers only (`copyNextSampleBuffer` blocks); a stall is noticed at the next buffer.
- S5-i4: the stream goes through the playback resource loader, not a separate purpose header: the bytes it reads land in the stream cache
  like playback's own. Stream-start timings are not affected (they are recorded by the deck, not the loader).
- S5-i5: resolving the playable URL of the next song may look up its YouTube match (the prefetcher usually has it already).

## To check on a phone

Developer mode › "Tempo and loudness" fills in 10-20 s into a song on Wi-Fi; a downloaded song measures on mobile data; airplane mode
mid-song pauses it; a Daily Mix built after some days of measuring steps smoothly; the AVAssetReader path through `pixlstream://` is
the least certain part (if it fails every streamed song shows "Could not decode", files still work).
