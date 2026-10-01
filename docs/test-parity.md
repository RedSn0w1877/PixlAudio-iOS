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
| `presentation/lyrics/LyricsScriptShapingTest` | 3 | `TextScriptsTests` (+ RTL edge cases, CJK variants, Kotlin whitespace/punctuation) | PixlFoundation | ported | `LyricsRenderStyle.needsShapedPieces` / `isRtlText` → `TextScripts`. |
| _Compose `animation-core` (not an app test)_ | 3,483 vectors | `ComposeReferenceTests` | PixlFoundation | new | Vectors from the real `FloatSpringSpec` (value, velocity, `getDurationNanos`), `CubicBezierEasing` and `FloatExponentialDecaySpec` (androidx 1.12.1) run on the JVM by `tools/android-reference/RefGen.java`; fixture `compose-reference.txt`. All spring and Bézier samples are bit-identical on Windows. |
| _Android `LyricsDocCodec` (not an app test)_ | 66 inputs | `LyricsDocGoldenTests` | PixlModel | new | Each input run through the Android app's compiled `LyricsDocCodec.decode`/`encode` (kotlinx.serialization 1.11) by `tools/android-reference/DocGen.java`; Swift must reject what Android rejects and re-encode byte for byte. Fixture `lyricsdoc-android-golden.txt`. |
| `utils/LyricsUtilsTest` | 23 | `ParsingLyricsUtilsTests` (+8 Swift-only: empty input, plain text, metadata/offset, Kugou, JSON/richsync/YRC dispatch, Korean romanisation, injected Japanese provider, `toLrcString`) | PixlLyrics | ported | |
| `utils/LyricsImportSecurityTest` | 12 | `ParsingImportSecurityTests` (+4 Swift-only: MIME/extension tables, empty/malformed payloads, local file sanitising, messages) | PixlLyrics | ported | `validateLocalLyricsFile_rejectsBinaryPayload` uses a temp file via `validateLocalLyricsFile(at:)`. |
| `data/network/lyrics/WordSyncTranspilersTest` | 12 | `ParsingWordSyncTests` (+2 Swift-only: YRC metadata/limits, richsync rounding and numeric strings) | PixlLyrics | ported | Completes the 2a partial row (2a ported the two pure `LyricsDoc` cases model-side; they are repeated here next to the transpilers). |
| `data/network/lyrics/LyricsfileParserTest` | 7 | `ParsingLyricsfileTests` (+4 Swift-only: YAML scalars stay strings, block scalars/folding, collections/anchors/limits, Lyricsfile edge rules) | PixlLyrics | ported | Includes the AMLL `matchesMetadata` case. |
| `data/network/lyrics/NeteaseLyricsSourceTest` | 3 | `ParsingCatalogTests` (+3 Swift-only: NetEase requests/response checks, AMLL lookups/parse, bounded bodies) | PixlLyrics | ported | The OkHttp fixture replies are fed as the same JSON through the pure functions PixlNet will call (`LyricsHTTP.decodeBody`, `NeteaseLyricsMatching.candidateTracks/trackId/lyrics`). The HTTP 403 sub-case has no parsing half (PixlNet never decodes a failed response). |
| `data/repository/LyricsRepositoryImplTest` | 9 | `ParsingRepositoryTests` | PixlLyrics | partial | Ported: `parseBestEmbeddedLyricsField_prefersSyncedLyricsWhenLyricsFieldIsPlain`, `fetchFromRemote_rejectsDurationOnlySearchMatch`, `fetchFromRemote_rejectsOriginalLyricsForRemix`, `fetchFromRemote_acceptsMatchingRemixVariant`, `fetchFromRemote_doesNotTreatArtistNameInFilePathAsVariant` (candidate-mode search then automatic exact match, as `fetchFromRemote` does). The four storage-order cases (`getLyrics_storageProbeFailure…`, `getLyrics_returnsSongLyricsBeforeNeedingStorageRead`, `getLyrics_apiFirst_usesStoredLyricsBeforeCallingLrcLib`, `fetchFromRemote_returnsStoredLyricsWithoutCallingApi`) test caching/DAO order and belong to the iOS `LyricsService` (stage 9); their parsing halves are `storedSongLyricsParseAsLocalLyrics`. |
| `data/repository/StreamingLyricsPersistenceTest` | 2 | — | PixlLyrics | n/a | JSON-cache file persistence is stage 9. The pure part (a torn `{"wordByWordLyrics":` cache is a miss) is in `rawContentCacheRecordAndUserSync`. |
| _Android lyrics parsers (not an app test)_ | 553 vectors | `ParsingGoldenTests` | PixlLyrics | new | Every case of `tools/android-reference/lyrics-cases.txt` run through the compiled Android `LyricsUtils.parseLyrics`/`toLrcString`, `TtmlLyricsParser`, `WordSyncTranspilers.yrc/richSync`, `LyricsfileParser` (SnakeYAML 2.4), `LyricsImportSecurity`, `MultiLangRomanizer` (pinyin4j 2.5.1 readings injected), the `LyricsRepositoryImpl` matching/ranking/raw-content helpers and the AMLL/NetEase matchers by `tools/android-reference/LyricsGen.java`; fixture `lyrics-android-golden.txt`. All 553 are identical on Windows. |
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
| `data/lyrics/sync/LyricsTapSyncTest` | 36 of 36 | `LyricsTapSyncTests` | PixlLyrics | ported | Same inputs and expected values case for case (tokenize ×7, buildDraft ×5, tap ×4, release, undo ×3, rewind, jumpToLine ×2, fixLine, skipLine, fillRest, nudge/offset learning, deriveEnds ×4, toLyricsDoc ×5). Seeded cases use a port of Kotlin's `Random(seed)` (`KotlinRandom`, XorWow), so `Random(3)`, `Random(7)` and the 500 property-test seeds produce the same inputs as on Android. `toLyricsDoc_isAlwaysValidForRandomSessions` (~500 random tap sequences: tap/release/undo/rewind/jump/fix/skip/fill/nudge/clear, every step checked for consistency, validity, line preservation and codec round trip) → `toLyricsDocIsAlwaysValidForRandomSessions` (session generator shared in `RandomSessions.swift`; it also checks the initial draft). `assertSame` (identity) → value equality. |
| `data/lyrics/sync/LyricsExportTest` | 8 of 8 | `LyricsExportTests` | PixlLyrics | ported | LRC headers/word tags/closing tag, `lrcTime` rounding, empty headers + newline flattening, TTML well-formedness/escaping/agents/nested background, flush syllables + clock format, dropped control characters + no `dur` — all ported; the TTML is parsed with Foundation `XMLParser` (namespace-aware, FoundationXML off Apple platforms) into a tiny DOM instead of `DocumentBuilder`. The three round trips (`lrc_roundTripsThroughTheAppParser`, `lrc_roundTripsTappedDrafts`, `ttml_readsBackThroughTheAppParser`) read the exports back through the Swift `LyricsUtils.parseLyrics` (enabled at integration A). |
| `data/lyrics/sync/LyricsSyncDraftStoreTest` | 5 of 5 | `LyricsSyncDraftStoreTests` | PixlLyrics | ported | JUnit `@TempDir` → a fresh folder under the temp directory per test; `runBlocking` → `async` tests against the `LyricsSyncDraftStore` actor; `setLastModified` → `FileManager.setAttributes([.modificationDate:])`. Passes on Windows. |
| _Android tap-sync/export/draft codec (not an app test)_ | 9 + 461 + 500 + 61 + 8 + 10 vectors | `TapSyncGoldenTests` | PixlLyrics | new | `tools/android-reference/TapSyncGen.java` runs the app's compiled `LyricsTapSync`, `LyricsExport` and `LyricsSyncDraftStore` codec on the JVM (fixture `tapsync-android-golden.txt`): Kotlin `Random` outputs; `tokenize` over 461 inputs (the test's samples and 400-line fuzz plus edge cases: ZWJ before a non-emoji, marks after controls, small kana, half-width kana, Ext-B ideographs, RTL/Indic/Thai, NBSP/U+3000/U+0085); **all 500 property-test sessions hashed step by step** (stored draft JSON, `SyncStep` seek/cleared/flags, `isConsistent`, the built document JSON + rough lines, and the final LRC/TTML) — byte-identical; the stored draft JSON byte for byte; 60 decode cases (quoted numbers and booleans, `TRUE`, float spellings, non-finite and zero speeds, missing/null fields, duplicate keys, trailing garbage…); SHA-1 file names; LRC/TTML of 5 documents byte for byte. |
| `data/worker/ArtistParsingUtilsTest` | 4 | `ArtistParsingTests` (4 ports + KDoc examples, legacy-delimiter migration, metadata repair) | PixlLibrary | ported | |
| `data/worker/AlbumGroupingUtilsTest` | 8 | `AlbumGroupingTests` (8 ports + 2 edge cases) | PixlLibrary | ported | `SongEntity` → `ScannedSong`, `AlbumEntity` → `LibraryAlbum`. |
| `data/repository/FolderTreeBuilderTest` | 4 | `FolderTreeTests` | PixlLibrary | ported | Internal methods are public statics on `FolderTreeBuilder`. |
| `utils/DirectoryRuleResolverTest` | 4 | `FolderTreeTests` | PixlLibrary | ported | |
| `utils/QueueUtilsTest` | 3 | `QueueUtilsTests` (3 ports + clamping cases) | PixlLibrary | ported | The suspending shuffle is `async` and yields with `Task.yield()` every 512 steps. The "yields for large queues" case checks a sibling task progresses; Swift's cooperative pool is multi-threaded, so that check is weaker than the single-threaded `runBlocking` original (the yields themselves are kept). |
| `data/recommendation/MusicRecommendationEngineTest` | 12 | `MusicRecommendationEngineTests` (12 ports + alias resolution, normalisation) | PixlLibrary | ported | The two identity cases ("shared feedback object", "separate histories with equal counters") pass the stored record's key through `signalSources`/`historySources` (Swift values have no identity; see deviations). |
| `data/recommendation/HomeRecommendationPlannerTest` | 10 | `HomeRecommendationPlannerTests` (10 ports + demoted-reason check) | PixlLibrary | ported | `java.time.LocalDate` → `LocalDate` (PixlLibrary). |
| `data/premium/PremiumSmartToolsTest` | 3 | `PremiumSmartToolsTests` (3 ports + hour label) | PixlLibrary | ported | |
| `data/playlist/PlaylistOrderTest` | 2 | `LibrarySortingTests` | PixlLibrary | ported | `mergePlaylistOrder` → `LibrarySorting.mergePlaylistOrder`. |
| `data/stats/PlaybackStatsRepositoryTest` | 6 | `PlaybackStatsTests` (6 ports + MONTH buckets, day buckets/distribution, sanitize, record/prune, import/merge, codec, `LocalDate`, DST gap) | PixlLibrary | ported | Fixed zone (Europe/Berlin) instead of `ZoneId.systemDefault()`. |
| `presentation/viewmodel/QueueStateHolderTest` | 1 of 10 | `LibrarySortingTests.playAlbumOrdersSongsByDiscThenTrackThenTitle` | PixlLibrary | partial | Only the album order (`LibrarySorting.albumPlaybackOrder`). The other 9 cases test coroutine dispatch to playback callbacks with mocked repositories: app layer (stage 5/7). |
| `data/recommendation/MusicDiscoveryRepositoryTest` | 0 of 5 | — | — | n/a | Network discovery (InnerTube search + Spotify import) — PixlNet/app. Its recording-key de-duplication is covered by the engine tests. |
| `presentation/viewmodel/DailyMixPersistenceTest` | 0 of 3 | — | — | n/a | State-holder persistence/coroutine races — app stage 7b. `DailyMixTests` covers the pure selection and seeds. |
| `presentation/viewmodel/ListeningStatsTrackerTest` | 0 of 2 | — | — | n/a | Live session tracking in the player — playback stage 5 (it feeds `PlaybackStats.recordingPlayback`). |
| `data/backup/module/EngagementStatsModuleHandlerTest` | 0 of 3 | — | — | n/a | Backup module — PixlBackup (stage 3e). |
| `presentation/viewmodel/FileExplorerDirectoryMergeTest` | 0 of 1 | — | — | n/a | MediaStore/file-system directory merge — Android-specific (iOS lists folder bookmarks). |

### Swift-only tests added in stage 2a
`SpringTests` (textbook closed forms for under/critically/over-damped and undamped springs, ms truncation,
convergence with the lyrics engine's rest thresholds, retarget continuity), `EasingTests` (bisection reference,
overshoot bounds, Compose's no-extrapolation rule, `fastCbrt`, Java `Math.min/max` semantics),
`ExponentialDecayTests` (fling friction 0.733 → λ 3.08/s, threshold/target consistency), `KotlinMathTests`
(half-even `round`, half-up `roundToInt`, saturating conversions), `JSONTests` (strict and kotlinx modes, escapes,
kotlinx numeric literals), `LibraryModelTests` (Song/Artist helpers, smart rules, Playlist/Transition/EQ/queue
Codable defaults).

## Stage 2b — PixlLyrics parsers

Tests in `Packages/PixlCore/Tests/PixlLyricsTests/Parsing*.swift`; fixtures in `Tests/PixlLyricsTests/Fixtures/parsing/`
(the four Android `app/src/test/resources/lyrics/*` files copied verbatim, plus the golden file).

### Swift-only tests added in stage 2b
`ParsingInfrastructureTests`: Java `Double.parseDouble` grammar (suffixes, hex floats, NaN/Infinity, rejects), Kotlin
`toLongOrNull` (Unicode digits, overflow), Java `Math.round`, `%02d`, Kotlin `lines()`, code-unit (not grapheme)
prefix/contains, Gson accessor conversions (`BigDecimal.longValue`), the XML reader (DOCTYPE/entity/namespace/
well-formedness rejections, DOM shape, end-of-line and attribute normalisation, deep documents without recursion),
TTML time expressions and text normalisation, and the romanisers. `ParsingRepositoryTests` also covers ranking
order/tolerances, title/artist scores, normalisation helpers (Java final-sigma lower-casing), all LRCLIB search
strategies, response decoding, catalog choice, raw content, the Gson cache record and the rate limiter.

### Behaviour notes found by the golden vectors
- `normalizeForMatch` NFD-decomposes Hangul syllables into conjoining jamo, which `isScriptThatNeedsRomanization`
  does not recognise, so Korean *base titles* never take the romanised path (search strategies still romanise the raw
  title). Kept.
- `romanizeHindi` has no inherent vowel (`नमस्ते` → `nmste`). Kept.
- SnakeYAML rejects a tab wherever a token starts (after `key:`, after `-`, after a quoted scalar, a tab-only line, in
  flow collections) but accepts tabs inside and after plain scalars. Mirrored.

## Stage 2c — PixlLyrics engine

Tests in `Packages/PixlCore/Tests/PixlLyricsTests/Engine/` (sources `Sources/PixlLyrics/{Model,Engine}`).

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

## Stage 2d — tap-sync, export, draft store

Tests in `Packages/PixlCore/Tests/PixlLyricsTests/Sync/` (sources `Sources/PixlLyrics/Sync`).

### Swift-only tests added in stage 2d
`kotlinLinesSplitsLikeKotlin`, `tokenizeSplitsOnScalarSpacesEvenBeforeCombiningMarks` (a space before a combining
mark is one Swift `Character` but two Kotlin chars), `isConsistentRejectsBrokenDrafts`,
`buildDraftFromSongUsesItsMetadata` (the `Song` overload, `displayArtist`), `lrcAndTtmlHandleBackgroundOnlyAndLineOnlyParagraphs`,
`saveCreatesTheDirectoryAndPrunesStrayTempFiles`, `oversizedFilesAreDiscarded` (8 MiB cap), `nonFiniteSpeedsAreNotSaved`,
`javaFloatStrings` (Java `Float.toString` layout incl. the two-digit minimum, `parseFloat` subset).

### Notes
- The full PixlLyrics run takes ~80 s in a Windows debug build, almost all in the two 500-seed tests (they run in
  parallel). They are the Android property test plus its golden replay; keep both.
- To regenerate the fixture: see the header of `tools/android-reference/TapSyncGen.java` (classpath = the stage-2a
  `DocGen` classpath + `kotlinx-collections-immutable-jvm` 0.5.0, timber's `classes.jar` and the SDK's `android.jar`
  for `Parcelable`). `java TapSyncGen debug <seed>` prints every step of one seed; on a hash mismatch
  `TapSyncGoldenTests` writes Swift's replay of the first three failing seeds to the temp directory for diffing.

## Stage 3a — PixlLibrary

Tests in `Packages/PixlCore/Tests/PixlLibraryTests/` (123 tests).

### Golden vectors from the compiled Android code (new)
`tools/android-reference/LibGen.java` runs the app's compiled classes (`compileDebugKotlin/classes`, kotlin-stdlib
2.4.0, Gson 2.14.0, kotlinx-collections-immutable 0.5.0, kotlinx-coroutines 1.11.0, Timber 5.0.1, android.jar 37 for
class loading) and xerial sqlite-jdbc 3.41.2.2 on JDK 26, and writes `Tests/PixlLibraryTests/Fixtures/*-golden.jsonl`
plus `Sources/PixlLibrary/Unicode61Tables.swift`. Classpath and command are in the file's header comment (see also
`tools/android-reference/README.md`).

| Fixture | Vectors | Swift test | What must match |
|---|---|---|---|
| `artist-parsing-golden.jsonl` | 10,870 | `ArtistParsingTests.matchesAndroidGoldenVectors` | `splitArtistsByDelimiters` (java.util.regex with Kotlin's implicit UNICODE_CASE, escapes, empty and pathological delimiters, `$` before final line terminators), `extractArtistsFromTitle`, `collectArtistNames`, `choosePreferredArtistName`, `normalizeMetadataText` (Windows-1252 repair, NFC) — exact strings. |
| `queue-golden.jsonl` | 672 | `GoldenVectorTests.randomAndQueueMatchAndroid` | Kotlin `Random(Int/Long)` (XorWow), `java.util.Random`, `String.hashCode`, `fisherYatesCopy`, anchored shuffles incl. the suspending/start-at-zero variant — exact. |
| `folder-golden.jsonl` | 440 | `GoldenVectorTests.folderTreeAndRulesMatchAndroid` | Folder trees (names, paths, song order, counts — incl. Java `HashSet` iteration order for name ties), inferred storage roots, directory rules. |
| `recommendation-golden.jsonl` | 90 scenarios + 300 `record` + 21 dates | `GoldenVectorTests.recommendationMatchesAndroid` | Rank scores **bit for bit**, reasons, select (6 limits × 6 fractions), Muselle 2, Home plan (Basic + Plus: ids, titles, songs, reasons), 6 smart presets, insights, artist/recording keys. |
| `stats-golden.jsonl` | 160 × 4 ranges | `GoldenVectorTests.statsMatchAndroid` | Full `PlaybackStatsSummary` in UTC, New York, Kolkata, Lord Howe (30-min DST), São Paulo (midnight DST) and Chatham. MONTH needs an Android `Context` for its labels and is tested by hand. |
| `history-codec-golden.jsonl` | 99 | `GoldenVectorTests.historyCodecMatchesAndroid` | Gson read (coercions, all-or-nothing failure) and write (field order, HTML-safe escaping) of `playback_history.json`. |
| `search-golden.jsonl` | 100 queries | `GoldenVectorTests.searchMatchesAndroidSQLite` | The DAO's MATCH string, FTS4/unicode61 hits and order, LIKE hits and order, merged list, album/artist LIKE, playlist `contains(ignoreCase)`. |

### Swift-only tests added in stage 3a
`LibraryAssemblerTests` (SyncWorker multi-artist assembly), `LibrarySortingTests` (every SortOption: SQL NOCASE song/liked
order, albums/artists/folders/playlists/playlist songs, storage filter), `SmartPlaylistRuleTests` (the four creation
rules + fallback), `M3UTests` (path/file-name/URI matching, `readLine` splitting, BOM, export), `SearchIndexTests`,
`PaletteExtractorTests` (solid/two-colour/grey art, transparency, premultiplied alpha, downsampling with row padding,
determinism, luminance), `DailyMixTests` (seeds, alias favourites, engagement history).

### Deviations (documented in the sources)
- **Feedback identity.** Kotlin's `rank` de-duplicates stored feedback by object identity. Swift takes the stored key
  per song id (`signalSources`/`historySources`); `RecommendationInputs.resolve` builds them exactly as
  `DailyMixManager.personalizedPicks` / `HomeDiscoveryStateHolder` alias `spotify_<id>`.
- **`playback_history.json`** is read as standard JSON; Gson's lenient-only syntax (comments, single quotes, unquoted
  names) is rejected. Android never writes it.
- **Stats day slicing** stops instead of looping forever if a zone ever puts the next midnight behind the cursor
  (Android would hang).
- **Folder stub songs** keep the artwork URI as is (Android rewrites MediaStore artwork URIs).
- **Song ids** are strings on iOS: SQL `id ASC` compares numerically when both ids are integers, else by UTF-8 bytes.
  "Online" songs are ids with `yt:`/`sp:` prefixes (Android `source_type != 0`).
- **Simple case mapping** (`Character.toUpperCase/LowerCase`) is derived from the Swift Unicode tables (single-scalar
  full mappings, title case for iota-subscript letters, `İ`→`i`); identical for every vector tested.
- `buildFolderTree`'s Android storage-volume discovery is replaced by explicit root paths (iOS folder bookmarks).

## Priority list (from architecture §4, must pass on Windows before UI work)
- ~~`LyricsEngineTest`, `LyricsClockTest`, `LyricsMotionMathTest`, `PreparedLyricsBuilderTest`,
  `LyricsBackgroundGradeTest` → PixlLyrics / PixlFoundation (stages 2b/2c).~~ Done (integration A).
- ~~`ArtistParsingUtilsTest`, album grouping, folder tree, queue utils → PixlLibrary (stage 3a).~~ Done (integration A).
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
