# Test parity — stage 2c (PixlLyrics engine: `Sources/PixlLyrics/{Model,Engine}`)

Rows to fold into `docs/test-parity.md`. Swift tests live in `Packages/PixlCore/Tests/PixlLyricsTests/Engine/`.

| Android test (class) | Cases | Swift test | Module | Status | Notes |
|---|---|---|---|---|---|
| `presentation/lyrics/model/PreparedLyricsBuilderTest` | 25 of 25 | `PreparedLyricsBuilderTests` (+ UTF-16 offsets with emoji/combining marks, voice-role parsing) | PixlLyrics | ported | Supersedes the 2a partial row (`graphemeAndWordCounts`). |
| `presentation/lyrics/LyricsEngineTest` | 16 of 16 | `LyricsEngineTests` (+ change flags, settled engine, σ output, equal-model skip + hit testing, empty lyrics) | PixlLyrics | ported | Android reads positions through `LongSource` providers; Swift passes the position to `step(frameNanos:positionMs:offsetMs:)` / `LyricsClock.tick`. |
| `presentation/lyrics/LyricsClockTest` | 3 of 3 | `LyricsClockTests` (+ speed-scaled prediction, markSeek/reset) | PixlLyrics | ported | `peekMs()` has no counterpart (the caller owns the position); its case checks that only `tick` publishes. |
| `presentation/lyrics/LyricsMotionMathTest` | 23 of 23 | `LyricsMotionMathTests` (+ σ quantisation, RTL sweep edge) | PixlLyrics | ported | Supersedes the 2a partial row (`graphemeBoundaries_keepCombiningMarksTogether`). |
| `presentation/lyrics/background/LyricsBackgroundGradeTest` | 6 of 6 | `LyricsBackgroundTests` (+ mean luma, shader steps, twist, sprite geometry, crossfade/motion clock) | PixlLyrics | ported | Random colours from a seeded SplitMix64 instead of Kotlin's `Random` (the cases are properties over many colours). |
| `presentation/lyrics/LyricsScriptShapingTest` | 3 of 3 | `LyricsScriptShapingTests` (through `LyricsRenderMetrics`) | PixlLyrics | ported | Also covered in PixlFoundation `TextScriptsTests` (2a). |
| `presentation/components/LyricsSheetLogicTest` | 10 of 12 | `LyricsSheetLogicTests` (+ timestamp-tag and voice-tag edge cases) | PixlLyrics | partial | The 2 `lyricsChromeColors` cases test Material 3 colour roles: n/a (no Material on iOS). |
| _Android `PreparedLyricsBuilder` (not an app test)_ | 32 inputs | `LyricsGoldenTests.preparedLyricsMatchAndroid` | PixlLyrics | new | Every line/syllable/row/summary field of the Android app's compiled builder on the JVM (`tools/android-reference/EngineGen.java`, inputs `lyrics-engine-cases.txt`), incl. CJK, emoji, RTL, voice tags, LRC timestamps in text, unmatched words, background/duet grouping, same-start lines, documents with whitespace-only and zero-duration syllables. Fixture `lyrics-prepared-golden.txt`. All match exactly. |
| _Android `LyricsEngine` + `LyricsClock` (not an app test)_ | 13 scenarios, 1,024 dumped frames (17,061 row dumps), ~213k checks | `LyricsGoldenTests.engineTracesMatchAndroid` | PixlLyrics | new | Scripted scenarios (cascade, first-show animate-in at 120 Hz, seeks and jitter, drag/fling/snap-back, seek ending user scroll at density 2.75, no-blur fallback, reduced motion, pause/rebase, variable heights, document groups + interlude, tap/resize/scrollBy, background vocals with an offset, rebuild + song change) run through the compiled Android engine; every frame dump compares all 9 published row outputs plus spring y, pending cascade time and σ target, the clock, scroll target/offset, user-scroll, at-rest, needs-frame and laid-out flags. Floats within 4 ulps (in practice bit-identical on Windows). Fixture `lyrics-engine-golden.txt`. |
| _Android lyrics maths (not an app test)_ | 5,220 vectors | `LyricsGoldenTests.lyricsMathsMatchAndroid` | PixlLyrics | new | `LyricsSprings` table + normal stiffness grid, `LyricsBlurMath`, `LyricsCascade`, `EmphasisMath` (amount/glow/durations/envelope/lift/hop/grapheme timing/sweep), `KaraokeAlpha`, `InterludeTimeline`, `LyricsBackgroundGrade` matrix + reference grade + luma, `SpriteBlur` radii + baked sprites (±1 per channel allowed), `ArtworkSpriteBaker` geometry, the line sanitisers, grapheme/word counts and script shaping. Fixture `lyrics-math-golden.txt`. |

### Swift-only tests added in stage 2c
`LyricsRenderMathTests` — the renderer maths extracted from `LyricsView.kt` / `LyricLineNode.kt` / `InterludeDots.kt`
(no Android unit test covered them): paddings/alignment/pivots (duet, RTL, centre, end), row layout and press-highlight
box, line alphas (lead, background, high contrast, bright art, translation clamp, when words animate), word pieces with
a fake layout (emphasis graphemes, syllable pieces, untimed text, multi-line time sharing by width, shaped RTL scripts
drawn clipped, per-frame fill/edge/lift/scale, gradient alpha), interlude-dot geometry, edge-fade mask and anchor rule,
appearance-preference mapping.

### Deviations from Android (intentional)
- `LyricsEngine.setLyrics` ignores a model **equal** to the installed one (Android compares identity; its view only calls
  `setLyrics` from `remember(engine, prepared)`, i.e. on equality changes, so behaviour in the app is the same).
- Outputs are flat arrays + change masks (`rowChanges`, `changedRows`, `changes`, cleared by `clearChanges()`) instead of
  Compose snapshot state. Values and write epsilons are Android's.
- Extra iOS output `rowBlurSigma` (σ in points × strength, quantised to `LyricsEngineConfig.blurSigmaQuantum`, default
  0.3 pt) next to Android's Skia radius `rowBlurRadiusPx` (kept for parity).
- `LyricsBackgroundMotion` clears the outgoing set in `step` once the fade is done (Android does it in `publish`, which
  runs right after); there is no separate 30 Hz publish step.
- The tier-A noise tile and ColorMatrix canvas path are not ported (iOS uses the Metal shader path; the CPU reference
  functions describe that shader).
