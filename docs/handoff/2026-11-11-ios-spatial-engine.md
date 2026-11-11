# iOS Spatial audio: ENGINE report (2026-11-11)

Branch `audio-engine` (worktree `PixlAudio-iOS-audio-engine`), cut from `origin/audio-hq` at `6529ea4`. Spec:
`docs/handoff/2026-11-10-plans/cloud-audio-spec.md` (section 7 = tables v1.1). Map:
`docs/handoff/2026-11-10-plans/ios-integration-map.md`. Only ENGINE's files (map 11) were touched, plus my own section
at the end of `docs/api-notes.md` and this note.

## What is done

### 1. The on-device stage (PixlCore, tested on Windows and Linux)

- `Packages/PixlCore/Sources/PixlAudioCore/Spatial/SpatialStage.swift`
  - `SpatialBiquad`: the reference's RBJ low-pass and high-pass (Q = 1/√2, a0 = 1); a cutoff of 0 is no filter.
  - `SpatialStageCoefficients`: all twelve tables in flat buffers, built once off the main thread, shared read-only by
    every stage (a profile change is an index change). FIRs stored reversed for the correlation form.
  - `SpatialStage`: one per tap. Spec 7 exactly: two cascaded low-pass biquads (Double, direct form I) per channel,
    `hi = x − lo`, the room input `rm = HP2(hi, roomHpHz)`, the two 192-tap FIRs (same side and cross), the two sparse
    rooms (`sparseL` into the left output, `sparseR` into the right, each tap reading both channels' `rm`), the low band
    delayed by `lowDelay`, times `gain`, then `SoftLimiter` (−1 dBFS, PixlAudioCore's) on every output sample while the
    stage is active. 44.1 and 48 kHz only (`init?` returns nil otherwise). Every buffer is allocated in `init`; the
    render path never allocates, locks or logs. vDSP (`vDSP_conv`, `vDSP_vsma`, `vDSP_vadd`, `vDSP_vsmul`) under
    `#if canImport(Accelerate)`, plain loops elsewhere. Buffers of any size (processed in parts of ≤ 512 frames).
  - Ramps: `out = (1 − m)·dry + m·level·wet`, `m = engaged × swap`. Bypass on/off ramps `engaged` over 80 ms; a profile
    change takes `swap` to 0 in 40 ms, swaps the coefficients at the next part, and back up in 40 ms. Dry is the input
    delayed by `lowDelay`. See "Divergences" 1-2 for the one case where it cannot be.
  - `reset()` forgets the sound (the tap calls it on a media-time jump, a seek).
- `SpatialPreviewTables.swift` (added to, nothing changed): `SpatialPreviewTable.roomHpHz` (0 for a v1 table of the
  older shape, validated `0 ≤ roomHpHz < rate/2`), a new init with it, the decoder reads it.
- `SpatialRenditionRules.swift`: `SpatialItemAudio` (own audio of a video / render / Sing's audio); which audio a song
  starts on; the in-song decision (`switchToRender`, `switchToOwnAudio`, `wait`, `none`) with the 20 s rule; media-time
  alignment arithmetic across rates; the video id of a download or a cached stream file.
- Tests (`Tests/PixlAudioCoreTests/`): `SpatialStageTests.swift` (the golden file for every profile and both rates
  within 1e-4 from a zero state without the limiter; the same with buffers of 1…777 frames; planar = interleaved; a
  Double port of `preview.py` `process` over 20 000 frames of noise, past Concert Hall's tail and through the ring's
  wrap; a table of the older shape; the limiter sample by sample; bypass bit-exact; first buffer fully on; ramps
  ~80 ms; engage, profile change and bypass never step beyond the steady sound's own steps; the delayed bypass is the
  input delayed by `lowDelay` exactly; the wet level and its ramp; reset), `SpatialRenditionRulesTests.swift`, and
  three `roomHpHz` tests in `SpatialPreviewTablesTests.swift`. All 38 Spatial tests pass locally (Windows, Swift 6.4).

### 2. The tap (`App/Playback/ProcessingTap.swift`, `TapParameters.swift`, `App/Playback/Spatial/SpatialTapShared.swift`)

- Global: `AudioEffectsParameters.spatial` (`SpatialTapShared`): the profile index every tap plays (or bypass), one
  atomic read per buffer; the coefficients, installed once and read in `prepare`.
- Per item (`TapItemParameters`, set before the tap exists): `spatialRole` (`stage` = the song's own audio, `render`,
  `none` = Sing's audio), `spatialHeadroomDb` (a render's manifest), `spatialFormat` (written by `prepare`: the stage
  runs only on stereo float at 44.1/48 kHz), `spatialEngagement` (meter).
- Chain: … EQ → width → limiter → mid/side → **stage + limiter** → crossfade ramp → deck gain (map 2.3: after 3, before
  4). The old width ("virtualizer") fades out along the stage's engagement ramp and is skipped entirely for render
  items. A render item never gets a stage (never spatialized twice); the stage's state is per tap.

### 3. Renditions (`Deck.swift`, `DualDeckEngine+Instrumental.swift`, `DualDeckEngine.swift`)

- `DeckItem.audio` says what an item plays. `DeckItemFactory.makeItem(for:overrideURL:timing:rendition:)`:
  - `.automatic` (every song start, the next song prepared ahead, Sing's "its own audio"): after the resolver (never
    inside it, map 2.2's trap), the video id comes from the resolved URL (`pixlstream://`, `Downloads/<id>.*`,
    `streams/<id>.*`) and `DeckSpatialSource.startRendition` answers the verified local render when a profile is on and
    the route passes; an unreadable render falls back to the stream. Own-audio items wait (once per launch, normally not
    at all) for the tables.
  - `.render(LocalRendition)` / `.ownAudio`: what the switch asks for.
  - Any file of the render store is a render whoever passes it (defensive "never twice").
- `switchCurrentRendition(to:placement:minimumSecondsLeft:requireAligned:)`: Sing's swap generalised by a
  `SwitchStyle` (Sing: 300-700 ms, no time rule, exactly as before; renditions: 250 ms linear, optional time-left rule
  checked before building and again at the final start). Preroll muted, lined up by media time (seconds, so a render
  at another rate lines up), `requireAligned` (50 ms) kept on for renders.
- `isRenditionSwitchBlocked`: loading, a seek not landed, two decks overlapping, a scheduled hand-over.
- `onSpatialItemChanged`: a new hook (the item changed, or the active deck's play state did), next to the taken ones.

### 4. Level

- Render items: `effectiveReplayGain()` returns `min(1, gain × 10^(headroomDb/20))` with the manifest's `headroomDb`.
- The stage: its wet sound is multiplied by `min(1, gain × 10^(4/20)) / gain`, so the spatial sound plays at
  `SpatialLevel.playbackGain(gain, headroomDb:)` and moves with the 80 ms ramps (see Divergences 3).
- With gain 1 (every stream today) both are 1: Spatial plays 4 dB under stereo, as the spec expects.

### 5. Route (`AudioSessionController.swift`, `App/Playback/Spatial/SpatialOutputRoute.swift`)

- `AudioSessionController.onRouteChange` (called after every route change, after the command it caused) and
  `currentOutputPort`. Mapping as map 6: headphones, USB, Bluetooth A2DP/LE pass; speaker, receiver, AirPlay, car,
  HFP, line out, HDMI do not; Spotify Connect is `.remote`. `spatial.route = always` passes anything but `.remote`.

### 6. `SpatialPlaybackController` (`App/Playback/Spatial/`), built by `SpatialPlaybackFactory` on real launches

- Publishes the stage target (`isActive ? profile : bypass`) at once on every change.
- Follows the route live, Sing (`isActive`, `isSwitching`) and Connect (`remoteOutputName`) through observation.
- Snapshots: `songId`, `videoId` (kept across Sing's audio for the same entry), `selection`, `route`, `output`,
  `routePasses`, `singInstrumentalOn`, `audible` (`render` for a render item, `onDevice` for the song's own audio while
  active unless its format is not taken, then `stereo`). The model asks the library from `wantedRender`.
- Switching (one at a time, coalesced, re-checked after anything that arrived meanwhile): a render that lands for the
  playing song, a local render of a newly picked profile, Spatial off or the route failing (back to the song's own
  audio), Sing done. Waits (a seek, a transition, Sing switching) are retried once a second, at most 30 times per item.
  `failed` / `misaligned` are given up for that item: the next play uses the render.
- The item prepared for the next song is rebuilt when its rendition is stale (selection or route changed, a render
  landed for it, its render was removed).
- `markPlayed` when a render item becomes current. Tables decode off the main thread at launch.
- UI tests: still the no-op (no audio).

### 7. App tests (`AppTests/SpatialPlaybackTests.swift`)

Route mapping; the vDSP path against the portable one (every profile and rate, 9000 frames); the tap offline (stage
on, bypass bit-exact, render never spatialized, the render's and the stage's level rule); the controller and the
switch on the real engine (a song starts on its render with the stage bypassed and `markPlayed`; picking a profile
turns the stage on and switches to a local render; 250 ms linear fade, the 20 s rule, the way back; a render of
another length is `misaligned`; a render landing mid-song switches in and Spatial off swaps back).

## Divergences from the spec or the map (and why)

1. **Bypass when the item was never delayed.** Spec 7: "dry = the untouched input delayed by `lowDelay`". When Spatial
   audio is switched on mid-song, the sound so far was not delayed, and putting the 1.1 ms delay under the sound is the
   click the spec forbids. So that first engage fades from the undelayed input to the wet sound (a short comb colour
   during the 80 ms, no click). From the moment the stage was fully on, everything follows the spec: the dry sound is
   the delayed input, and after a bypass the item stays delayed (the stage keeps a cheap delay line running) until it
   ends. An item that starts with Spatial active is delayed from its first frame. Android may want the same note.
2. **Profile change** = wet A → dry → wet B in 40 + 40 ms (≈ 80 ms in all; the swap waits for the next ≤ 512-frame part,
   at most ~11 ms more), rather than 80 ms down and 80 ms up. Today all profiles share `lowDelay`, `xoverHz` and
   `roomHpHz` per rate, so the dip is through an aligned dry sound and the histories carry over unchanged.
3. **Where the stage's level factor lives.** Map 5 suggests a headroom factor in `effectiveReplayGain()`. For renders it
   is exactly there. For the stage it is applied to the stage's wet sound (`wetLevel`), so the dry sound of a ramp is
   not raised by 4 dB; fully on, the result is the same `min(1, gain × 1.585)`.
4. **The old width effect is also skipped on render items** (spec 6.3 says "while the on-device stage is active"): a
   widened binaural render loses its cues.
5. **Time rules.** The 20 s rule applies to a render switching in over the song's own audio. A render of a newly picked
   profile replacing the old one, and the way back to the stream, have no time rule (only the swap's own 1 s clearance
   before the song's planned transition); when the way back cannot be made that late, the song finishes on the render
   and the next song is normal (spec 6.3's allowed fallback). iOS does swap back to the stream in every other case
   (unplugging pauses playback, so that swap is the silent paused one).
6. **Who calls `library.request`.** The task text says ENGINE calls it when a song starts with Spatial active and no
   local render; map 1.3 (binding) says the model is the only caller and ENGINE never calls it. ENGINE follows the map:
   its snapshot carries the video id and `audible`, so `wantedRender` makes the model ask, once.
7. **A seek resets the stage** (not in the spec): otherwise up to ~0.18 s of the old position's room rings on.
8. **Mono songs** are treated like an unsupported rate (`.format`, no stage, render still wanted).
9. **Ring size** is the next power of two ≥ longest delay + one 512-frame part + 1 (16 384 with today's tables, equal
   to `SpatialPreviewTables.ringCapacity`), because a part's own room input is written before it is read.

## Not done, uncertain

- The app target cannot be compiled here: CI is the judge (runs listed below).
- Not heard on a phone. Worth a listen: engage/bypass/profile changes while playing, a render landing mid-song, a
  Bluetooth disconnect while a render plays, Sing on/off with Spatial on.
- The render switch's placement uses Sing's gap planner (word-timed lyrics only); without word timing it switches as
  soon as the render is prerolled.
- Open item 5 of map 12 (another phone's render lining up within a 250 ms fade) is unmeasured; `requireAligned` stays
  on, and `misaligned` means "from the next play".

## What others need

- **CLOUD:** `localRendition` is awaited on the path to first audio of every song while a profile is on (answer from
  memory). Send `.renditionReady` when a render lands (ENGINE switches on it) and `.renditionRemoved` per key.
  `markPlayed` arrives when a render item becomes current (also when paused). `LocalRendition.fileURL` must be the store's
  `CloudAudio/<videoId>/sp-<profile>.flac` (ENGINE also recognises renders by that path).
- **OPUS:** ENGINE reads a playing item's video id from `pixlstream://<id>` (`YouTubeSongIdentity.videoId(from:)`) and
  from files named `<id>.<ext>` directly inside a `Downloads` or `streams` folder. Keep those, or tell ENGINE. A 48 kHz
  stream uses the 48 kHz tables automatically.
- **UI:** nothing new; every line comes from the snapshot (`blockedBy`, `audible`).
- **Lead:** spec 7 could say what "dry" is for an item that was never delayed (Divergence 1). Changelog line:
  "Spatial audio for headphones: six profiles, an instant on-device version, and the cloud version fades in mid-song
  when it is ready."
