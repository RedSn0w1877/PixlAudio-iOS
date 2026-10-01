# Test parity (Android unit tests → Swift)

Every Android unit test that is ported gets a row. Android tests live in the read-only Android repo under
`app/src/test/java/com/theveloper/pixelplay/` (fixtures in `app/src/test/resources/`); Swift tests live in
`Packages/PixlCore/Tests/<Module>Tests/` (Swift Testing) or `AppTests/` (XCTest). Copy fixtures into
`Tests/<Module>Tests/Fixtures/` — the folder is already bundled (`Bundle.module`, subdirectory `Fixtures`).

Status: **ported** (all cases) · **partial** (list what's missing) · **n/a** (reason) · **todo**.

| Android test (class) | Cases | Swift test | Module | Status | Notes |
|---|---|---|---|---|---|
| _stage 0 placeholders_ | | `<Module>ModuleTests` (module linked, fixtures bundled) | all | — | |
| `data/model/SortOptionTest` | 4 | `SortOptionTests` (+ `tablesMatchAndroid`, extra `fromStorageKey` cases) | PixlModel | ported | The commented-out `main/…/SortOptionTest.kt` (null entries in `allowed`) is n/a: Swift collections cannot hold nil there. |
| `presentation/library/LibraryTabIdTest` | 3 | `LibraryTabTests` (+ malformed-order and `LibraryTabId` cases) | PixlModel | ported | `decodeLibraryTabOrder` → `LibraryTab.decodeOrder`. |
| `data/network/lyrics/WordSyncTranspilersTest` | 4 of 12 | `LyricsDocModelTests` | PixlModel | partial | Ported the `LyricsDoc` model/codec cases: `documentRoundTripRetainsRolesOverlapAndExclusiveEnds`, `jsonRejectsUnsupportedVersionUnknownVoiceAndExcessiveDepth`, and the model halves of `yrcUsesAbsoluteTimes…` (gaps, `findActiveLine`, `toLyrics` word joins) and `zeroDurationSpeech…` (zero-duration syllables invalid) on hand-built documents. The YRC/RichSync transpiler, NetEase matching, import-security and fixture-file cases belong to stage 2b (PixlLyrics/PixlNet). |
| `presentation/lyrics/LyricsScriptShapingTest` | 3 | `TextScriptsTests` (+ RTL edge cases, CJK variants, Kotlin whitespace/punctuation) | PixlFoundation | ported | `LyricsRenderStyle.needsShapedPieces` / `isRtlText` → `TextScripts`. |
| `presentation/lyrics/model/PreparedLyricsBuilderTest` | 1 of 25 | `TextSegmentationTests.graphemeAndWordCounts` | PixlFoundation | partial | Only `graphemeAndWordCounts` (the helpers live in PixlFoundation); the builder cases are stage 2c. |
| `presentation/lyrics/LyricsMotionMathTest` | 1 of 23 | `TextSegmentationTests.graphemeBoundariesKeepCombiningMarksTogether` | PixlFoundation | partial | Only `graphemeBoundaries_keepCombiningMarksTogether`; springs table, cascade, emphasis, interlude and blur cases test `LyricsSprings`/`EmphasisMath`/… and are stage 2c. |
| _Compose `animation-core` (not an app test)_ | 3,483 vectors | `ComposeReferenceTests` | PixlFoundation | new | Vectors from the real `FloatSpringSpec` (value, velocity, `getDurationNanos`), `CubicBezierEasing` and `FloatExponentialDecaySpec` (androidx 1.12.1) run on the JVM by `tools/android-reference/RefGen.java`; fixture `compose-reference.txt`. All spring and Bézier samples are bit-identical on Windows. |
| _Android `LyricsDocCodec` (not an app test)_ | 66 inputs | `LyricsDocGoldenTests` | PixlModel | new | Each input run through the Android app's compiled `LyricsDocCodec.decode`/`encode` (kotlinx.serialization 1.11) by `tools/android-reference/DocGen.java`; Swift must reject what Android rejects and re-encode byte for byte. Fixture `lyricsdoc-android-golden.txt`. |

### Swift-only tests added in stage 2a
`SpringTests` (textbook closed forms for under/critically/over-damped and undamped springs, ms truncation,
convergence with the lyrics engine's rest thresholds, retarget continuity), `EasingTests` (bisection reference,
overshoot bounds, Compose's no-extrapolation rule, `fastCbrt`, Java `Math.min/max` semantics),
`ExponentialDecayTests` (fling friction 0.733 → λ 3.08/s, threshold/target consistency), `KotlinMathTests`
(half-even `round`, half-up `roundToInt`, saturating conversions), `JSONTests` (strict and kotlinx modes, escapes,
kotlinx numeric literals), `LibraryModelTests` (Song/Artist helpers, smart rules, Playlist/Transition/EQ/queue
Codable defaults).

## Priority list (from architecture §4, must pass on Windows before UI work)
- `LyricsEngineTest`, `LyricsClockTest`, `LyricsMotionMathTest`, `PreparedLyricsBuilderTest`,
  `LyricsBackgroundGradeTest` → PixlLyrics / PixlFoundation (stages 2b/2c).
- `ArtistParsingUtilsTest`, album grouping, folder tree, queue utils → PixlLibrary (stage 3a).
- Transition controller / curves, ReplayGain, sleep timer, audio-focus policy → PixlAudioCore (stage 3b).
- TrackMatcher, InnerTube parsing, Spotify token rotation → PixlNet (stage 3c).
- Backup validators/sanitizer → PixlBackup (stage 3e).

## App tests (XCTest, not ported from Android)
| Test | Covers |
|---|---|
| `AppTests/LaunchConfigurationTests` | launch-argument parsing, UI-test routing for every `DemoScreen`, demo search, demo playback store |
| `TestToneWriterTests` | WAV header/size, tone not silent and not clipping |
| `KeychainStoreTests` | set/read/delete round trip (skips if the simulator build lacks keychain entitlement) |
| `UITests/ScreenshotTests` | home, library, search, search results, mini player (inline), diagnostics × light/dark |
