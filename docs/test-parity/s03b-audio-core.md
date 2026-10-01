# Stage 3b — PixlAudioCore (test parity)

Sources `Packages/PixlCore/Sources/PixlAudioCore/`, tests `Packages/PixlCore/Tests/PixlAudioCoreTests/` (105 tests in 11
suites; all pass on Windows, Swift 6.4).

## Rows for `docs/test-parity.md`

| Android test (class) | Cases | Swift test | Module | Status | Notes |
|---|---|---|---|---|---|
| `data/service/player/AudioFocusResumePolicyTest` | 4 of 4 | `AudioFocusResumePolicyTests` (+6 Swift-only: the `focusChangeListener` bookkeeping as `AudioFocusResumeState` — transient loss/gain, gain during a transition, paused stays paused, permanent loss, iOS `interruptionEnded(shouldResume:)`, delayed grant) | PixlAudioCore | ported | |
| `data/tais/dsp/FftWorkspaceTest` | 7 of 7 | `FftTests` (+3 Swift-only: impulse/DC, Bluestein round trips for odd sizes, empty input) | PixlAudioCore | ported | JUnit thread pools → `withThrowingTaskGroup`. `accidentally shared workspace serializes concurrent transforms` → `copiedWorkspaceUsedConcurrentlyStaysBitExact`: `Fft.Workspace` is a value type, so "sharing" one gives each task its own copy (no `@Synchronized` needed); the bit-exactness check is the same. `IllegalArgumentException` → `FftError`. |
| `data/tais/lyrics/CtcAlignmentCoreTest` | 8 of 8 | `CtcAlignmentCoreTests` (+4 Swift-only: empty input / too few frames, out-of-range tokens throw instead of trapping, flat-buffer entry point, short-clip window + constants) | PixlAudioCore | ported | `java.util.concurrent.CancellationException` → Swift `CancellationError` thrown from the `checkCancelled` closure. `IllegalArgumentException` → `CtcAlignmentError.tooLong`. |
| _Android audio classes (not an app test)_ | 5,280 + 1,536 + 1,824 + 393 + 94 + 32 + 38 + 58 + 402 + 300 + 18 vectors | `AudioGoldenTests` | PixlAudioCore | new | `tools/android-reference/AudioGen.java` runs the app's compiled `utils/Envelope.kt` `envelope` (4 curves × 1,320 progress values incl. ±0, NaN, ±∞, out-of-range), the `performOverlapTransition` gain expression with the real `envelope` (8 durations × 16 curve pairs × 12 elapsed times, start volumes and ReplayGain targets incl. >1), `ReplayGainManager.gainDbToVolume` / `getVolumeMultiplier` and the private `parseGainString` (94 tag strings: dB spellings, Unicode whitespace, `NaN`/`Infinity`, suffixes, hex floats, overflow/underflow, denormals, control characters, junk), `shouldResumeAfterTransientAudioFocusLoss` (all 32 inputs), `Fft.transform` and `Fft.Workspace` (19 sizes 1…6144 × forward/inverse, random input), `CtcAlignmentCore.windows` (58 sample counts), `align` (400 random cases: ties, −∞, non-zero blank ids, malformed extended sequences, 0…40 frames) + the 64 Mi cell limit at its boundary, `acceptsWordEvidence` (300 score lists), and `MidSideVocalProcessor` through Media3's `AudioProcessor` (Float and 16-bit, 9 attenuations incl. NaN/negative/>1). Fixture `audio-android-golden.txt`. **FFT, CTC, mid/side, parsing and the non-S-curve gains are bit-identical on Windows**; the S-curve (`cos`) and `pow` lines allow 2 ulps (none needed so far on Windows). |

Android has no unit tests for `Envelope.kt`, `TransitionController`, `TransitionRepositoryImpl`, `ReplayGainManager`,
`ReplayGainProcessor`, `EqualizerManager`, `SleepTimerStateHolder` or `MidSideVocalProcessor`; their Swift tests are
listed below (the pure maths of the first four and of the mid/side processor is also covered by the golden vectors).

### Swift-only tests added in stage 3b
- `TransitionTests` (13): envelope endpoints/monotonicity/shapes; rule priority (pair → playlist default → global,
  no playlist id → global, half-specified rules match neither query); skip reasons (global toggle only affects the global
  default); plan clamping (650 ms boundary, guard window, 500 ms floor); fire decision; adaptive countdown sleep incl. the
  0.1 speed floor; next target per repeat mode (no wrap with repeat-all, as on Android); suspensions; Android constants;
  `CrossfadeRun` gains/finish/final volume; `CrossfadeRamp` per-deck media-time gains agree with the Android loop;
  per-buffer interpolation; `GainRamp` no-ops.
- `ReplayGainTests` (13): tag strings, tag maps (case-insensitive keys, key priority, empty list falls through, unparsable
  first value decides), R128 Q7.8 conversion (deviation, below), gain → volume, fallbacks, the `ReplayGainProcessor`
  bookkeeping (user volume vs echo, stale tokens, streams, crossfade pending volume + incoming target, transition
  finished, metadata changes), the tap stage (parity cap at 1, boost + limiter, ramps) and `SoftLimiter` (transparent
  below the knee, monotonic, odd, bounded).
- `BiquadTests` (9): RBJ identities (0 dB = identity), peaking gain at the centre for 4 gains × 3 bands, shelf
  asymptotes and corner (half gain), Butterworth LP/HP −3.01 dB, sanitised frequency/Q, the cascade against a Double
  direct-form-I reference, steady-state sine amplitude = |H| with an independent silent channel, identity bypass and
  reset, vDSP order and stability.
- `EqualizerTests` (9): `setBandLevel` clamping/"custom"/out-of-range, effect toggles/strength clamps/unsupported
  effects, `restoreState` (custom, built-in, unknown → flat, loudness clamp), Android's 10 → N device-band averaging
  (Kotlin truncating division), millibel mapping incl. a ±1200 mB device, chain design (bass boost `15·s/1000` integer dB,
  loudness make-up gain, width), the UI response curve and log frequencies, `StereoWidth`, the processor bypass and
  bounded output.
- `SleepTimerTests` (12): duration timer schedule/fire/clear, 0 = cancel, cancel toasts, end of track (no song, replaces a
  duration timer, pauses at the end of the target song on an automatic transition, cancelled on a manual change, cleared
  at the end of the queue), counted play (repeat-one, loops, pause past the target, cancelled by another song or a
  repeat-mode change, restart, slider value), counted play independent of the timers.
- `MidSideVocalTests` (4): attenuation 0 untouched, full attenuation removes the centre, half attenuation, clamping and
  Int16 saturation.

### Deviations from Android (intentional)
- **R128 gains**: Android parses `R128_TRACK_GAIN`/`R128_ALBUM_GAIN` (Opus Q7.8 integers, −23 LUFS reference) as
  decibels, which turns a typical "-1536" into silence. `ReplayGain.extractGainValue` converts them (`v / 256 + 5`).
  `REPLAYGAIN_*` tags still win, as their keys come first.
- **Sleep timer after it fires**: Android pauses but leaves the timer row showing (the job that cleared it was removed);
  `SleepTimer.tick` clears the timer once it has paused.
- **End-of-track replaces a duration timer**: Android clears the timer state but leaves its exact alarm armed, so the
  old alarm could still pause later; `setEndOfTrack` emits `.cancelWakeUp`.
- **`onPlaybackEnded`** clears an end-of-track timer (Android's service clears its own copy; the UI holder kept waiting).
- `Fft.Workspace` is a value type (no `@Synchronized`); errors are thrown (`FftError`, `CtcAlignmentError`) instead of
  `IllegalArgumentException`, and an out-of-range CTC token throws instead of crashing.
- The equalizer runs as biquads in the tap instead of `android.media.audiofx`: bands = peaking filters at the Android
  band frequencies with Android's level → millibel mapping (1 level = 1 dB); bass boost = a 90 Hz low shelf at AOSP's
  `(15 × strength) / 1000` dB; virtualizer = mid/side stereo width (1 → 1.8); loudness enhancer = make-up gain + soft
  limiter. `ReplayGainStage` keeps Android's volume cap of 1 unless `allowBoost` is set.
- Every mode other than NONE runs the same overlap crossfade — that **is** Android's behaviour (FADE_IN_OUT and SMOOTH
  differ only by their curves); kept and documented.

### Notes for the integrator
- `tools/android-reference/README.md` table needs a row (left out here to avoid merge conflicts):
  `| AudioGen.java | The app's compiled Envelope.kt envelope, ReplayGainManager (incl. the private parseGainString), shouldResumeAfterTransientAudioFocusLoss, Fft/Fft.Workspace, CtcAlignmentCore and MidSideVocalProcessor (via Media3 AudioProcessor) | Tests/PixlAudioCoreTests/Fixtures/audio-android-golden.txt | AudioGoldenTests |`
  The classpath is in the generator's header (adds media3-common 1.10.1 and taglib 1.0.6 `classes.jar` extracted from
  their `.aar`s, guava 33.3.1-android, annotation-jvm 1.10.0).
- Fixture format: one vector per line, floats as IEEE-754 bit patterns; see the header lines of the fixture.
