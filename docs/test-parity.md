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
| _BiniLyrics source (iOS-first; the Android port lands separately)_ | 18 + 8 + 1 | `ParsingBiniLyricsTests` (PixlLyrics), `BiniLyricsClientTests` (PixlNet), `LyricsFeatureTests.testBiniLyricsDocumentsAreStoredAndReadBackRichly` (app) | PixlLyrics, PixlNet | new | Matching (ISRC hit, remix/live decoys, ±3 s duration, ambiguity → nil, word → album → duration order, title/artist normalisation, request building, host allowlist and redirect targets, response decoding, the race's early decision, the fetch dialog entry) and `TtmlDocumentParser` (syllable merging, background vocals, duet agents, line-only and untimed documents, every time format, translations/transliterations, DOCTYPE refusal); the client over a scripted transport (307 → lrc.red, ISRC miss → search, no document without a confident match, off-allowlist and downgrade hops refused, redirect loops capped, oversized bodies, 429/5xx back-off with Retry-After, transport errors, cancellation, catalog-race priority). Fixtures are invented lyrics. |
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
| `data/backup/module/EngagementStatsModuleHandlerTest` | 3 of 3 | `EngagementStatsModuleHandlerTests` | PixlBackup | ported | Supersedes the stage-3a "n/a (stage 3e)" row. The DAO mock is replaced by the pure `EngagementStatsModule.restore/export`. |
| `presentation/viewmodel/FileExplorerDirectoryMergeTest` | 0 of 1 | — | — | n/a | MediaStore/file-system directory merge — Android-specific (iOS lists folder bookmarks). |
| `data/service/player/AudioFocusResumePolicyTest` | 4 of 4 | `AudioFocusResumePolicyTests` (+6 Swift-only: the `focusChangeListener` bookkeeping as `AudioFocusResumeState` — transient loss/gain, gain during a transition, paused stays paused, permanent loss, iOS `interruptionEnded(shouldResume:)`, delayed grant) | PixlAudioCore | ported | |
| `data/tais/dsp/FftWorkspaceTest` | 7 of 7 | `FftTests` (+3 Swift-only: impulse/DC, Bluestein round trips for odd sizes, empty input) | PixlAudioCore | ported | JUnit thread pools → `withThrowingTaskGroup`. `accidentally shared workspace serializes concurrent transforms` → `copiedWorkspaceUsedConcurrentlyStaysBitExact`: `Fft.Workspace` is a value type, so "sharing" one gives each task its own copy (no `@Synchronized` needed); the bit-exactness check is the same. `IllegalArgumentException` → `FftError`. |
| `data/tais/lyrics/CtcAlignmentCoreTest` | 8 of 8 | `CtcAlignmentCoreTests` (+4 Swift-only: empty input / too few frames, out-of-range tokens throw instead of trapping, flat-buffer entry point, short-clip window + constants) | PixlAudioCore | ported | `java.util.concurrent.CancellationException` → Swift `CancellationError` thrown from the `checkCancelled` closure. `IllegalArgumentException` → `CtcAlignmentError.tooLong`. |
| `data/tais/lyrics/TaisLyricsPersistenceTest` | 7 of 10 | `LyricAlignmentTests` (alignment state: partial / degenerate / spacer-line cases, explicit resync keeping repeated text, save check) (+14 Swift-only: vocabulary vs `wav2vec2_vocab.json`, CTC target building incl. decomposed accents, word timings and evidence from a path, the fixed 10 s Core ML windows, line assembly, the `LyricsDoc` result) | PixlAudioCore | ported (stage 14) | The 3 not ported exercise Room / the lyrics repository's enhanced-LRC write; iOS saves a `LyricsDoc` through `LyricsService` (app). |
| `data/tais/stems/StemAudioQualityTest` | 5 of 5 | `StemSeparationTests` (+8 Swift-only: WAV header, chunk overlap, numpy reflect padding, silent / full vocal model through the whole STFT loop, cancellation between chunks, file names) | PixlAudioCore | ported (stage 14) | |
| `data/tais/TaisInstrumentalRetentionTest` | 2 of 6 | `StemSeparationTests.completenessFollowsTheDeclaredWavSize`, `.fileNamesPreferTheCloudRenderAndRoundTrip` | PixlAudioCore | partial (stage 14) | The rest test Android's `RetainedAudioFiles` publish/copy on `java.io.File`; iOS writes through `.part` files + `moveItem` (`MdxStemSeparator.writeWav`) and `Data.write(options: .atomic)`. |
| _BsRoformerApiClient / DirectPostStemApiClient (no Android test)_ | — | `StemClientTests` (6: Gradio upload → submit → SSE with a reconnect → downloads, single output, error event, failed upload; direct POST multipart + audio check, non-audio answer) | PixlNet | new (stage 14) | Against a scripted `HTTPClient`. |
| _ustar archives (no Android counterpart)_ | — | `UstarTests` (5: a Python-written archive incl. a >100-char path through the ustar prefix, header parsing / checksum, path escapes, truncation, symlinks refused) | PixlFoundation | new (stage 14) | Fixture `tiny-mlpackage.tar` written by Python's `tarfile` (`USTAR_FORMAT`), like `ci/ml/common.py`. |
| _Android audio classes (not an app test)_ | 5,280 + 1,536 + 1,824 + 393 + 94 + 32 + 38 + 58 + 402 + 300 + 18 vectors | `AudioGoldenTests` | PixlAudioCore | new | `tools/android-reference/AudioGen.java` runs the app's compiled `utils/Envelope.kt` `envelope` (4 curves × 1,320 progress values incl. ±0, NaN, ±∞, out-of-range), the `performOverlapTransition` gain expression with the real `envelope` (8 durations × 16 curve pairs × 12 elapsed times, start volumes and ReplayGain targets incl. >1), `ReplayGainManager.gainDbToVolume` / `getVolumeMultiplier` and the private `parseGainString` (94 tag strings: dB spellings, Unicode whitespace, `NaN`/`Infinity`, suffixes, hex floats, overflow/underflow, denormals, control characters, junk), `shouldResumeAfterTransientAudioFocusLoss` (all 32 inputs), `Fft.transform` and `Fft.Workspace` (19 sizes 1…6144 × forward/inverse, random input), `CtcAlignmentCore.windows` (58 sample counts), `align` (400 random cases: ties, −∞, non-zero blank ids, malformed extended sequences, 0…40 frames) + the 64 Mi cell limit at its boundary, `acceptsWordEvidence` (300 score lists), and `MidSideVocalProcessor` through Media3's `AudioProcessor` (Float and 16-bit, 9 attenuations incl. NaN/negative/>1). Fixture `audio-android-golden.txt`. **FFT, CTC, mid/side, parsing and the non-S-curve gains are bit-identical on Windows and on macOS arm64 (CI)**; the S-curve (`cos`) and `pow` lines allow 2 ulps. |
| `data/youtube/TrackMatcherTest` | 7 of 7 | `TrackMatcherTests` (6 scoring cases) + `AudioFormatSelectionTests.qualityCapNeverPromotesMuxedVideoAboveRealAudio` | PixlNet | ported | `SpotifySongEntity` → `MatchableTrack`; the matcher's search dependency is the `YouTubeMusicSearching` protocol (mockk → a fake). |
| `data/ai/provider/AiProviderSupportTest` | 5 of 5 | `AiProviderTests` | PixlNet | ported | `createException` → `AiProviderSupport.makeError`, `AiProviderException` → `AiProviderError`. |
| `data/tais/dj/TaisIntentParserTest` | 5 of 5 | `TaisIntentParserTests` | PixlNet | ported | `TaisIntentParser` is a stateless enum. |
| `data/spotify/SpotifySnapshotRetentionTest` | 9 of 9 | `SpotifySnapshotRetentionTests` (all nine cases: pruning spares the browse playlist and Liked Songs, failed first / later playlist page, short page with a `next` cursor, failed Liked Songs, 403 on a playlist, partial Liked Songs, partial playlist after filtered + unfiltered failures, explicitly empty Liked Songs) + `SpotifyWebAPITests.snapshotPaginationGuard` | PixlNet | ported | The mocked `SpotifyDao` → `InMemorySpotifyLibraryStore` (same DAO semantics, a call log for the `coVerify(exactly = 0)` checks); Retrofit 503/403 → `FixtureHTTPClient`. The sync loop is PixlNet's `SpotifyLibrarySync`; the app's SwiftData store implements the same `SpotifyLibraryStore` (stage 12, `AppTests/SpotifyTests`). |
| `data/repository/LyricsRepositoryImplTest` (network halves) | — | `LyricsProviderTests` | PixlNet | new | The ranking/matching halves were ported in 2b (PixlLyrics); PixlNet adds the request builders, retries, rate limit, fast parallel strategies, AMLL/NetEase flows and the catalog race. |
| `data/network/lyrics/NeteaseLyricsSourceTest` | (3, parsing in 2b) | `LyricsProviderTests.neteaseMatchesTheRecordingAndReadsYRC` | PixlNet | new | The HTTP side of the same flow (search → matching track → `song/lyric/v1`), incl. the opaque `result` and non-200 `code` cases. |
| `presentation/viewmodel/MetadataEditLyricsPreservationTest` | 3 (file half) | `MetadataEditorTests.titleOnlySaveLeavesTheLyricsTagAlone`, `clearingTheLyricsFieldRemovesTheTag`, `editedLyricsAreWrittenTrimmed` | PixlTags | partial | The tag-file half of each case (nil lyrics keep the USLT frame, blank removes it, edited lyrics are trimmed and written). The Room/`lyrics/{id}.json` half (`resetLyrics`/`updateLyrics` calls) is the app's `MetadataEditStateHolder` (stage 7a). |
| _Android tag helpers (not an app test)_ | 1,103 vectors | `AndroidGoldenTests.everyVectorMatches` | PixlTags | new | `tools/android-reference/TagsGen.java` runs the app's compiled `ReplayGainManager.parseGainString`/`gainDbToVolume`/`getVolumeMultiplier`, `AudioMetadataReader.parseReplayGainDb`, `SongMetadataEditor.parseReplayGainUpdate`/`validateMetadataInput`/`detectContainerFormat`/`isProblematicFlacFile` (private methods via reflection, the editor allocated without its constructor), Kotlin `toFloatOrNull`/`toIntOrNull` and Java `URLConnection.guessContentTypeFromStream` (`guessImageMimeType`). Fixture `tags-android-golden.jsonl`. Floats compared bit for bit (`gainDbToVolume` included); all 1,103 identical on Windows. |
| _Real third-party files (not an app test)_ | 4 files | `RealWriterFixtureTests` | PixlTags | new | FFmpeg 8 (Lavf 62.12) output: ID3v2.4 MP3, ID3v2.3 MP3 + ID3v1, FLAC with PICTURE block and 8 KiB padding, M4A with `ilst`/`covr`. Read, mapped through `AudioMetadataMapper`, edited and re-read; the MP3 audio bytes are checked unchanged. |
| `data/backup/model/BackupSectionTest` | 9 of 9 | `BackupSectionTests` | PixlBackup | ported | |
| `data/backup/format/BackupFormatDetectorTest` | 7 of 7 | `BackupFormatDetectorTests` | PixlBackup | ported | |
| `data/backup/format/LegacyPayloadAdapterTest` | 5 of 5 | `LegacyPayloadAdapterTests` | PixlBackup | ported | The test's Gson is `setPrettyPrinting()` without `serializeNulls`; the Swift adapter always uses the backup Gson's output (pretty + nulls), which is what `BackupReader` passes on Android. |
| `data/backup/validation/ContentSanitizerTest` | 9 of 9 | `ContentSanitizerTests` | PixlBackup | ported | Lengths are UTF-16 units, as in Kotlin. |
| `data/backup/validation/ManifestValidatorTest` | 9 of 9 | `ManifestValidatorTests` | PixlBackup | ported | `System.currentTimeMillis()` → injected clock (`ManifestValidator(now:)`). |
| `data/backup/validation/ModuleSchemaValidatorTest` | 15 of 15 | `ModuleSchemaValidatorTests` (+ `tooManyEntriesIsFatal`) | PixlBackup | ported | |
| `data/backup/module/FavoritesModuleHandlerTest` | 2 of 2 | `FavoritesModuleHandlerTests` | PixlBackup | ported | `FavoritesModule.restore/export`. |
| `data/backup/restore/RestoreExecutorTest` | 3 of 3 | `RestoreExecutorTests` | PixlBackup | ported | MockK handlers → the `RecordingHandler` actor; the mocked `BackupReader`/`ValidationPipeline` are replaced by real archives built with `BackupWriter` (so validation runs for real). |
| `data/backup/BackupManagerTest` | 3 of 3 | `BackupManagerTests` | PixlBackup | ported | Real archives instead of mocks. The first case's warning is the validator's real message ("File extension is not .pxpl. The file may not be a valid backup."), the mock used a shortened one. |
| _Android backup code (not an app test)_ | 764 vectors | `BackupGoldenTests` (15 tests) | PixlBackup | new | See below. |
| _JDK `Deflater` (not an app test)_ | 44 streams | `InflateTests.inflatesJavaDeflaterOutput` | PixlBackup | new | Fixture `inflate-cases.jsonl`. |

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

## Stage 3b — PixlAudioCore

Sources `Packages/PixlCore/Sources/PixlAudioCore/`, tests `Packages/PixlCore/Tests/PixlAudioCoreTests/` (105 tests in 11
suites; all pass on Windows, Swift 6.4).

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

## Stage 3c — PixlNet

Tests in `Packages/PixlCore/Tests/PixlNetTests/` (145 tests in 18 suites, all on Windows; no live network — every
request goes to a scripted `FixtureHTTPClient`). Fixtures in `Tests/PixlNetTests/Fixtures/`: `innertube-player.json`,
`innertube-search.json`, `piped-streams.json`, `spotify-playlist-items.json` (hand-written in the shapes the services
return) and the golden file `net-android-golden.jsonl`.

### Golden vectors from the compiled Android code (new)
`tools/android-reference/NetGen.java` runs the app's compiled classes on JDK 26 (classpath and command in its header:
compileDebugKotlin/classes, kotlin-stdlib 2.4.0, kotlinx-serialization 1.11.0, gson 2.14.0, okhttp 4.12.0 + okio 3.18.1
for the AI clients' constructors, kotlinx-coroutines-core-jvm for `SignatureCipherSolver`'s fields, android.jar 37) and
writes `net-android-golden.jsonl` (612 lines). `NetGoldenTests` compares:

| Function | Vectors | What must match |
|---|---|---|
| `TrackMatcher.normalize` | 69 | Exact strings (NFKD, Java lower case with final sigma, bracket/trailing noise, `\p{L}\p{N}`), CJK/Cyrillic/Arabic/Hangul kept. |
| `TrackMatcher.similarity` | 69 | Float **bit patterns** (UTF-16 Levenshtein). |
| `TrackMatcher.score` | 144 (8 songs × 18 candidates) | Float **bit patterns**: title/artist/duration/album weights, video "Artist - Title" split, " topic"/"vevo" suffixes, variant penalties. |
| `pickBestAudio` | 48 | Chosen itag for 8 format sets × 6 caps (muxed last, cap ignored when it empties the list, Opus tie-break, first maximum kept). |
| `TaisIntentParser.parse` + `isMediaRequest` | 58 prompts | Action, genres, moods, query, media flag. |
| `AiSystemPromptEngine.buildPrompt` | 81 + default persona | **Byte for byte** for every type × 3 personas (incl. the multi-line default) × 3 contexts — Kotlin `trimIndent()` runs after template interpolation, so multi-line personas/contexts keep the template's indentation; reproduced by the generated `AiPromptTemplates.swift` (`tools/android-reference/gen-ai-prompts.js`). |
| `AiResponseCleaner` | 19 inputs × 4 functions | Fences, bracket matching with strings/escapes, first array/object. |
| `AiProviderSupport` | 12 chains, 10 recovery, 14 `createException`, 9 `wrapThrowable`, 3 model filters | Messages, parsed code/type, status inference (`\b[1-5]\d{2}\b`), the four classification flags. |
| Gemini / OpenAI request bodies | 18 + 18 + 1 | kotlinx `encodeToString` of the private `@Serializable` request classes (reached by reflection): defaults omitted, Float settings as `Double.toString`. |
| `SpotifyRepository.unifiedId` | 27 | FNV-1a ids in the song/album/artist bands. |
| `SignatureCipherSolver` | 6 players + 5 iframes | `buildSignatureFunction`/`buildNFunction` output (or null) over synthetic base.js (all name patterns, array indirection, function declarations, braces inside strings/template literals, missing bodies) and the player-id regex. |

### Swift-only tests added in stage 3c
- `InnerTubeTests`: client table (VISIONOS first, cookie flags), endpoints/headers/origins, org.json-exact player body
  (`\/` escaping), search request, authenticated headers, SAPISIDHASH against a known SHA-1 vector, player parsing
  (formats, muxed fallback, ciphers, SABR-only "OK but unusable"), playability statuses, org.json coercions in
  formats, search parsing order/limit/dedup/"not a results page", duration parsing, tree walking, visitorData from
  `responseContext` and from `ytcfg` HTML.
- `InnerTubeClientTests`: the cookie never reaches native clients; visitorData always sent (PoToken → anonymous →
  stored); WEB_REMIX PoToken body; failure reasons; search body/interleave; one failed shelf; `VisitorDataProvider`
  fetches once.
- `AudioFormatSelectionTests`: the iOS AAC-only pick (141 → 140 → 139, caps, itag 18 last, Opus/AC-3 rejected),
  PoToken eligibility.
- `CipherAndStreamTests`: call quoting, cipher parts, `n` rebuild (first value per name, Android re-encoding),
  `pot`, brace matching, `SignatureCipherSolver` (downloads once, deciphers, diagnose report), the strategy chain
  (order by sign-in, VISIONOS wins, fall-through details, probe failures, exclusions, ciphered/PoToken details),
  probe classification, timeout helper.
- `PipedTests`, `GoogleDeviceAuthTests` (form bodies, RFC 8628 poll steps, slow_down, expiry, refresh/invalid_grant),
  `SpotifyAuthTests` (RFC 7636 PKCE vector, authorize URL, callback validation, rotation persisted **before** the token
  is used, concurrent refresh sharing, failed persistence kept in memory, full sign-in), `SpotifyWebAPITests`
  (endpoints incl. the `/items` field filter, call policy, 401/429/403/transport retries, catalog paging + market
  fallback, pagination guard, row mapping, YouTube Music rows, ISO instants, lenient models, id bands),
  `LyricsProviderTests`, `AiProviderTests`/`AiOrchestratorTests`/`AiPlaylistTests` (codecs, clients, provider chain
  with cooldowns, cache, model recovery, on-device client, candidate pool JSON, full prompt indentation, digest, Java
  `%.2f`), `SupportTests` (Android/OkHttp encodings, org.json reader/writer, Java `Double.toString`, Kotlin text and
  `trimIndent`), `CloudStreamSecurityTests`.

### Notes
- Regex classes follow java.util.regex on the JVM (ASCII `\w`/`\s`/`\b`), like the earlier stages; Android's ICU regex
  differs only next to non-ASCII letters (e.g. `"ßhd"` in `TrackMatcher.normalize`), which the vectors include and
  JVM semantics decide.
- Regenerate: `javac -cp "$CP" NetGen.java && java -Duser.language=en -Duser.country=US -XX:+UnlockDiagnosticVMOptions
  -XX:-BytecodeVerificationRemote -cp "$CP;." NetGen <ios repo root>`; prompts: `node tools/android-reference/
  gen-ai-prompts.js <android repo> <ios repo>`. (Both are listed in `tools/android-reference/README.md`.)

## Stage 3d — PixlTags

Tests in `Packages/PixlCore/Tests/PixlTagsTests/` (73 tests, 9 suites; the interop dump test is skipped unless
`PIXLTAGS_DUMP_DIR` is set). All pass on Windows (Swift 6.4).

Android has **no unit tests** for its tag code (`data/media/*`: `SongMetadataEditor`, `ReplayGainManager`,
`AudioMetadataReader`, `AudioMetadataUtils`); the tag I/O itself is TagLib (native, `com.kyant:taglib` 1.0.6, a
TagLib 2.x build), JAudioTagger 3.0.1 and vorbis-java. So parity comes from three sources: golden vectors from the
compiled Android helpers, the file-tag half of the one related app test, and Swift tests that pin TagLib 2's
behaviour (read from TagLib's source and checked against the strings in the app's `libtaglib.so`).

### Golden generator
`tools/android-reference/TagsGen.java` (classpath and command in its header): the app's
`compileDebugKotlin/classes`, `android.jar` (platforms/android-37.0), kotlin-stdlib 2.4.0, Timber 5.0.1 and the
`com.kyant:taglib` 1.0.6 `classes.jar` (only for class loading; `libtaglib.so` is arm64-only and cannot run on the
JVM), JDK 26. Output: `Packages/PixlCore/Tests/PixlTagsTests/Fixtures/tags-android-golden.jsonl`, one
`{"fn","in","out"}` object per line.

The FFmpeg fixtures were generated with (bash, FFmpeg 8.0, a 2×2 red PNG as `_cover.png`):
```sh
COMMON=(-metadata "title=Ünïcode Title 日本" -metadata "artist=Artist A" -metadata "album_artist=Album Artist" \
  -metadata "album=The Album" -metadata "track=3/12" -metadata "disc=1/2" -metadata "date=2021" -metadata "genre=Rock" \
  -metadata "composer=Composer C" -metadata "REPLAYGAIN_TRACK_GAIN=-6.54 dB" -metadata "REPLAYGAIN_ALBUM_GAIN=-8,20 dB" \
  -metadata "lyrics=line one")
IN=(-f lavfi -t 0.15 -i anullsrc=r=22050:cl=mono -i _cover.png -map 0:a -map 1)
ffmpeg "${IN[@]}" -c:a libmp3lame -b:a 32k -id3v2_version 4 "${COMMON[@]}" -c:v copy -disposition:v attached_pic ffmpeg-id3v24.mp3
ffmpeg "${IN[@]}" -c:a libmp3lame -b:a 32k -id3v2_version 3 -write_id3v1 1 "${COMMON[@]}" -c:v copy -disposition:v attached_pic ffmpeg-id3v23.mp3
ffmpeg "${IN[@]}" -c:a flac "${COMMON[@]}" -c:v copy -disposition:v attached_pic ffmpeg.flac
ffmpeg "${IN[@]}" -c:a aac -b:a 24k "${COMMON[@]}" -c:v copy -disposition:v attached_pic ffmpeg.m4a
```

### Interop check (manual, local)
`PIXLTAGS_DUMP_DIR=<dir> swift test --filter InteropDumpTests` writes PixlTags-written ID3v2.3/2.4 MP3s (UTF-16 /
UTF-8 text, APIC, USLT, SYLT, COMM, TXXX ReplayGain, TDRC→TYER/TDAT) and a rewritten FLAC. Checked on 2026-09-30 with
ffprobe 8.0 and JAudioTagger 3.0.1: every field, the picture, the USLT/SYLT frames and the FLAC comment read back as
written.

### Swift-only tests added in stage 3d
- `ID3v2ReadTests` (22): v2.4 core frames → TagLib keys (`TIT2`…`TCOM`, ISO `T` → space in `DATE`), the four text
  encodings with terminators and BOM inheritance, empty-field dropping, TXXX keys (REPLAYGAIN, MusicBrainz/AcoustID
  translation), COMM/USLT/WXXX/W***/UFID keys, APIC (incl. truncated), SYLT, v2.3 TYER+TDAT+TIME folding and its
  rules, TORY/IPLS conversion and dropped v2.3 frames, v2.2 frame conversion incl. `PIC`, `TCON` genre references,
  v2.3 tag-level and v2.4 frame-level unsynchronisation + data-length indicator + grouping byte, extended headers
  (v2.3 with/without CRC, v2.4), the v2.4 footer, iTunes' plain frame sizes, frame flags and compressed (opaque)
  frames, padding/garbage termination, header validation, TagLib's `String::toInt`.
- `ID3v2WriteTests` (16): v2.4 layout and 1 KiB padding, TagLib's padding-reuse rule (1 %/1 KiB/1 MiB), in-place
  rewrite, v2.3 rendering (UTF-16, plain sizes, TDRC → TYER/TDAT/TIME, TDOR → TORY, TIPL/TMCL → IPLS, 2.4-only frames
  dropped), `checkTextEncoding`, discarded/unwritable frames, a round trip of every frame kind, `setProperties`
  semantics (kept frames, new frames for every key type, TIPL/TMCL, UFID, WXXX, multi-value LYRICS → TXXX),
  duplicate frames of a key, picture/SYLT setters, SYLT ↔ `SyncedLine`/LRC, whole-file MP3 writing (ID3v1 update,
  version keep, tag removal, tag creation, unsupported-version tag replacement).
- `FLACTests` (14): block parsing, STREAMINFO, Vorbis comment rules (key check, `METADATA_BLOCK_PICTURE`/`COVERART`,
  malformed counts), sorted rendering, `setProperties`, padding reuse/4 KiB/threshold, comment placement before the
  first picture, picture replace/remove, leading ID3v2 + trailing ID3v1 kept, empty comment → ID3 fallback, duplicate
  comments/invalid pictures dropped, structural errors, Android's hi-res analysis and `buildVorbisPictureBlock`.
- `MP4Tests` (5): every listed atom (`©nam ©ART aART ©alb trkn disk ©day ©gen covr ©lyr`, free-form
  `----:com.apple.iTunes:REPLAYGAIN_*`), item types (`gnre`, bool, int, uint, byte, long), duplicates, QuickTime-style
  `meta`, 64-bit sizes, missing/broken atoms, the key table.
- `MetadataEditorTests` (11, incl. the 3 ported cases): `AudioMetadataReader` field mapping and artwork rules,
  ReplayGain reading/volume, Java `%.2f`, editor property updates (album artist/composer/disc/ReplayGain/cover rules),
  failures (validation, ReplayGain, MP4/Opus unsupported, broken FLAC), FLAC routing, ID3v1-only MP3s.

### Deviations (documented in the sources)
- **TagLib, not JAudioTagger/vorbis-java.** Android writes WAV, Ogg, high-res FLAC (> 96 kHz or > 24 bit) and TagLib
  failures with JAudioTagger, and Opus with vorbis-java. PixlTags writes MP3 and every FLAC with TagLib's rules;
  MP4/M4A is left to the app (AVFoundation passthrough export), Ogg/Opus and WAV return `UNSUPPORTED_FORMAT`.
  `FLACStreamInfo.analyze` still ports `isProblematicFlacFile` exactly.
- **No ID3v1 is added.** TagLib 2's `MPEG::File::save()` duplicates the ID3v2 fields into a new ID3v1 tag; PixlTags only
  updates an existing ID3v1 tag (with TagLib's `setProperties`).
- **FLAC behind an ID3v2 tag** is routed as FLAC; Android's magic check (`AudioContainer.detect`, ported as is) calls it
  MP3 and TagLib's MPEG writer would then edit only the ID3v2 tag.
- **ID3v2.3 extended header** is skipped per spec (4 + size bytes); TagLib skips only `size` bytes.
- **Grouping byte** (v2.3/2.4 frame flag) is stripped before parsing; TagLib ignores the flag.
- **Compressed or encrypted frames** are kept opaque and written back only in the same version (TagLib inflates zlib
  frames; PixlCore has no zlib).
- **ID3v2.2 frames without a 2.4 equivalent** are dropped when read (TagLib keeps them as unknown frames that it can
  never write); v2.3 `TDAT`/`TIME` are folded into `TDRC` and not kept.
- **Version written**: 2.4 by default like TagLib; `TagChanges.id3v2Version = nil` keeps a 2.3 tag 2.3.
- **Artwork validity**: Android decodes the bounds with BitmapFactory; `ImageSniffing.isLikelyDecodableImage` checks
  the JPEG/PNG/GIF/WebP/BMP/HEIF signatures (the app can confirm with ImageIO). `guessContentType` omits Java's
  FlashPix branch.
- **Audio properties** (duration, bitrate, sample rate from TagLib) are not part of the port; iOS reads them with
  AVFoundation. FLAC `STREAMINFO` is exposed for convenience.
- **SYLT** is new on iOS (Android never reads it): `ID3v2SyncedLyrics.syncedLines()`/`lrcText()` treat entries starting
  with a line break as line starts.
- **Ports from memory of TagLib 2 tables** (frame/TXXX/MP4 key tables, ID3v1 genre spellings, TIPL roles) were checked
  against the strings in the app's `libtaglib.so`; TagLib behaviour cannot be executed on the JVM, so those parts
  have no golden vectors.

## Stage 3e — PixlBackup

Tests in `Packages/PixlCore/Tests/PixlBackupTests/` (143 tests in 23 suites, all passing on Windows). Android tests
live under `app/src/test/java/com/theveloper/pixelplay/data/backup/`.

### Golden vectors from the compiled Android code (new)

`tools/android-reference/BackupGen.java` (classpath and command in its header; it also needs `javax.inject-1.jar`)
runs the app's compiled `data/backup` classes with Gson 2.14.0 on JDK 26 and writes
`Tests/PixlBackupTests/Fixtures/`:

| Vectors (`fn`) | Count | Swift test | What must match |
|---|---|---|---|
| `detect` | 26 | `formatDetectionMatchesAndroid` | `BackupFormatDetector.detect` for every header shape. |
| `sanitizeString`, `sanitizeUrl`, `isValidModuleKey` | 87 + 28 + 21 | `sanitizerMatchesAndroid` | Kotlin `trim()` (NBSP, U+2003, U+3000, U+0085, ZWSP), UTF-16 truncation, control stripping, URL scheme rule, key regex. |
| `schema` | 147 | `moduleSchemaValidationMatchesAndroid` | Every error code, message, module and severity of `ModuleSchemaValidator` for all 12 modules — and the **Java exception class** where the Android validator throws (`"content": null` → `UnsupportedOperationException`, `"settings": []` → `ClassCastException`, `"durationMs": "abc"` → `NumberFormatException`, `[1, 2]` as a number → `IllegalStateException`). Includes Gson's `BigDecimal` truncation (`12.5` → 12), long wrap-around, `toLongOrNull` vs `asLong`. |
| `manifestValidate` | 252 | `manifestValidationMatchesAndroid` | Schema versions × timestamps × module sets. |
| `verifyChecksum` | 9 | `checksumVerificationMatchesAndroid` | `sha256:` prefix rules, case-sensitive hex. |
| `manifestDecode` | 26 | `manifestDecodingMatchesGson` | Gson binding of manifest.json (Kotlin defaults via the no-arg constructor, quoted numbers, `3.0` → 3, `3.5` fails, duplicate map keys fail, nulls kept) re-encoded byte for byte with the backup Gson. |
| `legacyAdapt` | 20 | `legacyAdapterMatchesAndroid` | v1/v2 adaptation: module selection, re-serialised payloads byte for byte (number literals kept, HTML escaping), checksums, entry counts, and the exception class on bad input. |
| `entities` | 92 | `gsonEntityBindingMatchesAndroid` | `gson.fromJson(payload, List<Entity>)` for every module record (alternate names with last-wins, JVM zero defaults, `nextLong`/`nextInt` coercions incl. `"5.0"` → 5 and `1.5` failing, `Boolean.parseBoolean`, unknown enum names → null, `LinkedHashSet` dedup, maps from arrays of pairs) re-encoded byte for byte. |
| `gsonPretty`, `aiUsageExport`, `engagementExport` | 11 + 1 + 1 | `gsonWriterMatchesAndroid` | Gson's pretty printer and compact writer, HTML-safe escaping, `Float.toString`/`Double.toString`. |
| `engagementRestore` | 15 | `engagementRestoreMatchesAndroid` | The private `parseEntries` merge (lenient names, truncating `toInt`, clamping, max-merge) and the empty-result failure. |
| `resolveSongId`, `resolverLibrary` | 22 + 1 | `playlistSongResolutionMatchesAndroid` | The cross-device song resolver (direct id + metadata check, title/artist, album, ±2 s duration; Kotlin `lowercase()` incl. `İ`, no case folding for `ß`). |
| `readV3`, `readLegacy` | 2 + 3 | `androidArchivesReadLikeAndroid` | The binary fixtures read like `BackupReader` (ZipInputStream / GZIPInputStream + the legacy adapter). |

Binary fixtures (same generator): `android-v3.pxpl` (every module, written like `BackupWriter`: ZipOutputStream,
DEFLATED, data descriptors), `android-v3-stored.pxpl`, `android-v2-legacy.pxpl` (written like
`AppDataBackupManager.encodePayload`), `android-v1-legacy.json.gz`, `android-v1-legacy.json`.

### Swift-only tests added in stage 3e
- `ChecksumTests` — CRC-32 check values, SHA-256 NIST vectors (incl. one million `a`), incremental hashing across block
  boundaries, injected hasher.
- `InflateTests` — JDK streams, stored-block round trips, hand-built fixed-Huffman blocks, every corrupt-stream error,
  the output limit (incl. a zip bomb stopped early), consumed-byte reporting, 8 MB of back-references in linear time.
- `GzipTests` — the Android legacy fixtures, concatenated members, trailing garbage ignored like `GZIPInputStream`,
  FEXTRA/FNAME/FCOMMENT/FHCRC headers, corrupt header/trailer/truncation.
- `ZipTests` — the Android archive with data descriptors, the local-header walk for an archive without a central
  directory, writer round trip (UTF-8 names, empty entries), first-entry-wins duplicates, CRC/encryption/method/size
  guards, ZIP64 refusal, CP437 names.
- `BackupImportTests` — end-to-end import of every Android fixture into PixlModel/PixlLibrary values (song ids resolved
  by metadata, skipped settings reported, unresolved songs counted), selected-module import, PixlAudio's own backups
  (pass Android's validators, round trip, resolve after a reinstall by metadata), `BackupManager.export` through
  handlers, restore progress, partial failure when a rollback fails, snapshot failure, checksum mismatch.
- `JavaNumberTextTests`, `GsonSemanticsTests`, `PreferenceTests` (coercions of `importPreferencesFromBackup`, the key
  catalogue, clear scopes, export filters, preset fallbacks), `PlaylistsModuleTests` (legacy array, pending
  resolution, export filters/metadata, Base64), `DataModuleTests` (Gson tree-reader numbers for lyrics rows, safe file
  names, numeric ids for PixlAudio songs, Kotlin non-null failures), `ContainerValidationTests` (file checks, path
  traversal, unexpected entries, oversized manifest, compression ratio bomb, reader messages, history list rules,
  progress).

### Deviations (documented in the sources)
- **Gson's lenient-only syntax** (comments, single-quoted strings, unquoted names, `;`/`=` separators) is rejected;
  unquoted values and case-insensitive `true/false/null` are accepted as Gson does. Android never writes the former.
- **Kotlin null-safety failures** become `BackupError`s with English messages: where Gson leaves a null in a non-null
  Kotlin field and Android later crashes (Room NOT NULL, `Intrinsics` checks, DataStore), the Swift restore fails the
  module with a message instead (same outcome: the module fails and is rolled back). A null `modules` map or an empty
  manifest document is an error at read/validation time instead of a later `NullPointerException`.
- **Nullable fields kept optional** in the Android record types (`AndroidBackup.*`), so re-encoding is byte-identical;
  conversion to PixlModel values fills Kotlin's defaults (`source` "LOCAL", ids/names "", null song ids dropped,
  unknown transition enums → OVERLAP/S_CURVE when converting, but the transitions restore rejects them like Room).
  `SongMetadataEntry` null strings compare as "" (Android would throw).
- **Playlist covers**: Android writes `playlist_cover_<id>.jpg` and stores its path; PixlBackup returns the decoded
  bytes and clears `coverImageUri` (a path from another device is meaningless) — the app writes the file and sets the URI.
- **Song ids**: Android resolves only playlist songs by metadata; PixlBackup applies the same resolver to favourites,
  lyrics, engagement, history and transition rules using the playlists' `songMetadata` (the only metadata in an Android
  backup), dropping and counting what it cannot match. Legacy (v1/v2) playlists keep their ids, as on Android.
- **Backups PixlAudio writes** stay readable by Android: stored ZIP entries, the same module JSON, plus a `pixlSongId`
  member on favourites/lyrics rows (Android's Gson ignores it) with a stable positive numeric `songId`
  (2⁵²…2⁵³−1 from FNV-1a 64), and `songMetadata` for every song any module references.
- **Settings**: preference entries are classified by `AndroidPreferenceCatalog`; only portable keys are applied, the
  rest are reported (Android-only, per-device state, id-keyed, unknown). Android applies every entry.
- **Containers**: the reader opens the archive once and uses the central directory (walking local headers only when
  there is none); `ZipInputStream` always walks local headers. They differ only for malformed archives. Archive-level
  error messages are PixlBackup's, not Java's.
- **`ContentSanitizer`**: a surrogate pair cut by the length limit loses its dangling high surrogate (Java keeps a lone
  surrogate, which Swift strings cannot hold).
- **`Float/Double.toString`** for subnormal values: Java's "two digits when the shortest has one" rule is not applied
  (`Double.MIN_VALUE` prints `5.0E-324`, Java `4.9E-324`); backups never contain subnormals.
- **Maps** in the array-of-pairs form with a null key are rejected (Gson would store a null key).
- **Restore plans** list modules as arrays in manifest order (Android: insertion-ordered sets); restore/inspect still
  process them in key order like Android.

## Integration B notes
- `ReplayGainValues` (defined in both PixlAudioCore and PixlTags) and `AiUsageRecord` (PixlNet and PixlBackup) now
  live once in PixlModel (`SharedRecords.swift`), so the app, which imports every module, never meets two same-named
  types. Each pair was the same Android entity; the merged types keep the superset (Codable, `id` defaulting to 0).
- No stage left a test disabled pending another stage. `InteropDumpTests` (PixlTags) stays opt-in by design
  (`PIXLTAGS_DUMP_DIR`).
- Full local PixlCore run after the merge: 953 tests (Foundation 29, Model 47, Lyrics 289, Library 122, AudioCore 105,
  Tags 73, Net 145, Backup 143), all passing on Windows.

## Stage 4 — album-art theme (PixlLibrary/ArtworkTheme)
Android has no unit tests for `ColorRoles.kt` / `ColorSchemeProcessor`; the port is checked against golden vectors
from the real Android classes instead (`tools/android-reference/ThemeGen.java` →
`Tests/PixlLibraryTests/Fixtures/theme-golden.jsonl`, 9446 lines). `ThemeGoldenTests` (11 tests, all bit-exact on
Windows and macOS):

| Swift test | Android code it is checked against |
|---|---|
| `hctMatchesAndroid` | `Hct.fromInt` hue/chroma/tone for 139 colours (±1e-9) |
| `solverMatchesAndroid` | `Hct.from(h, c, t)` (HctSolver) over a 24×16×21 grid, exact ARGB |
| `tonalPalettesMatchAndroid` | `TonalPalette.fromHueAndChroma` key colour + 27 tones for 10 palettes |
| `schemesMatchAndroid` | all 48 roles of `SchemeTonalSpot/Vibrant/Expressive/FruitSalad` × light/dark for 40 seeds |
| `monochromeSchemesMatchAndroid` | `SchemeMonochrome` (Android `generateMonochromeColorSchemeFromSeed`) |
| `neutralSchemeDecisionMatchesAndroid` | private `ColorRolesKt.shouldUseNeutralArtworkScheme` (+ the grey pair) |
| `grayscaleMatchesAndroidX` | `toGrayscaleColorScheme`'s convert (AndroidX `ColorUtils.colorToHSL` / `HSLToColor`) |
| `blendMatchesAndroid` | private `ColorRolesKt.blendArgb` (Float maths) |
| `quantizersMatchAndroid` | `QuantizerWu` and `QuantizerCelebi` (Wu + WSMeans) on 48 procedural images, colours and populations in order |
| `seedColorsMatchAndroid` | `ColorRolesKt.selectSeedColorArgbFromPixels` on 48 images × accuracy 0 / 4 / 10 |
| `publicAPIBasics` | Swift-only: storage keys, accuracy clamp, cache key format, RGBA → ARGB conversion, empty input fallback |

### Notes
- Ported from the colour utilities in `com.google.android.material:material` 1.14.0 (= upstream commit
  `03336bf6de`: on-container tones 30 in light, opacity on `DynamicColor`, `TonalPalette.KeyColor`), Apache-2.0
  (THIRD_PARTY_NOTICES.md). Upstream's k-means keeps its sorted distance rows and overwrites them by position on
  later iterations; the port keeps that quirk (results depend on it).
- Where WSMeans would index past its cluster array (more starting clusters than distinct pixels), Java throws and
  Android's `runCatching` returns `DarkColorScheme.primary` (`0xFFAB47BC`); the port returns the same seed.

## Stage 6 — library import (app)
Android's scan (`SyncWorker`, `MediaStoreSongRepository`) has no unit tests of its own; its pure parts are already
ported and tested in PixlLibrary (`ArtistParsingUtilsTest`, album grouping). Stage 6 adds app-level XCTest cases that
run the real importer over generated files (see the App tests table). Behaviour ported, with the Android source:
- `buildLocalAudioSelection`: minimum duration (`min_song_duration_ms`, default 10 s), non-empty title. MIDI's
  duration bypass is not ported (AVPlayer can't play MIDI, so MIDI isn't an imported type).
- `fetchMusicFromMediaStore`: blocked directories through `DirectoryRuleResolver` on the parent folder; MediaStore's
  defaults for untagged files (title = file name, album = folder name, artist "Unknown Artist").
- `processSongData`: tags read from the file (PixlTags = the TagLib path), `normalizeGenre`, `resolveAlbumArtist`,
  `dateAdded` from the modification time, kept for existing songs.
- Deletion phase: managed songs whose file disappeared are deleted with their artist links; albums and artists no
  song refers to are dropped (Android's `incrementalSyncMusicData` clean-up).
- `preProcessAndDeduplicateWithMultiArtist` (PixlLibrary `LibraryAssembler`): existing artist ids and album rows are
  passed in so ids stay stable across scans.
- MediaStore's `.nomedia` rule and hidden-folder skipping.
- Not ported here: Android's "preserve user-edited fields" merge in the processing phase (iOS keeps edits as
  `TagOverrideRecord`s that are re-applied on every scan) and the LRC auto-scan phase (it writes the lyrics table,
  stage 9's `LyricsService`).
## Stage 7a — Library and detail screens
| Android test (class) | Cases | Swift test | Module | Status | Notes |
|---|---|---|---|---|---|
| `ui/theme/GenreThemeUtilsTest` | 3 | `LibraryScreensTests.testGenreDetailScheme…` / `testUnknownGenreUsesTheMonochromeScheme` (+ Java `hashCode` index case) | App (`GenreTheme`) | ported | Compares all 48 roles through `ColorRoles` equality instead of a role list. |
| `presentation/viewmodel/PlayerViewModelTest` | — | — | — | n/a | Covers PlayerViewModel playback plumbing, not the Library screens; stage 5/8 territory. |

## Stage 11 — YouTube playback

Android has no unit tests for these classes; the Swift tests are their specification. PixlNet (Windows + macOS, no
network): `YouTubeStreamingTests.swift`; app (XCTest): `AppTests/YouTubeServicesTests.swift`.

| Android source | Swift test | Module | Status | Notes |
|---|---|---|---|---|
| `potoken/JavaScriptUtil.kt` + `PoTokenWebView` requests | `PoTokenJSTests` (8) | PixlNet | new | Scrambled / plain challenges, missing fields → null, URL-safe base64 both ways, integrity token, BotGuard headers, 10-minute expiry margin. |
| _iOS sparse stream cache (Android: ExoPlayer SimpleCache)_ | `ByteRangeSetTests` (6) | PixlNet | new | Merging, containment, gaps, completeness, Codable normalisation, Content-Range. |
| _iOS remote client table_ | `RemoteClientConfigTests` (5) | PixlNet | new | Built-in chain equals the resolver default; overrides and order; cookie / host invariants; malformed files; the repo's `remote/config.json` parses. |
| `YouTubeStreamResolver` (strategy source) | `ResolverStrategyProviderTests` | PixlNet | new | The resolver follows an injected (remote) chain and versions. |
| `PlaybackDiagnostics.kt` | `PlaybackDiagnosticsTests` (10) | PixlNet | new | Every step's pass/fail text; YouTube songs skip matching; Kotlin `%.2f` formatting. |
| _live services_ | `YouTubeLiveSmokeTests` (2) | PixlNet | new | Off unless `PIXL_LIVE_YOUTUBE=1`; CI runs them in a non-blocking step (search → VISIONOS → probe; BotGuard `Create`). Passed locally on Windows 2026-10-01 (VISIONOS, audio/mp4). |
| `YouTubeAuthManager` / login cookie handling, `SpotifyStreamProxy` ids | `YouTubeServicesTests` (11) | app | new | Bearer only for TVHTML5 `player` without cookie (key dropped), base.js disk cache, cookie normalisation / SAPISID / web-view cookie header, song identity, `yt:` song rows, URL expiry, sparse cache on disk (itag change resets), resolver order download → cache → stream. |

## Priority list (from architecture §4, must pass on Windows before UI work)
- ~~`LyricsEngineTest`, `LyricsClockTest`, `LyricsMotionMathTest`, `PreparedLyricsBuilderTest`,
  `LyricsBackgroundGradeTest` → PixlLyrics / PixlFoundation (stages 2b/2c).~~ Done (integration A).
- ~~`ArtistParsingUtilsTest`, album grouping, folder tree, queue utils → PixlLibrary (stage 3a).~~ Done (integration A).
- ~~Transition controller / curves, ReplayGain, sleep timer, audio-focus policy → PixlAudioCore (stage 3b).~~ Done (integration B).
- ~~TrackMatcher, InnerTube parsing, Spotify token rotation → PixlNet (stage 3c).~~ Done (integration B).
- ~~Backup validators/sanitizer → PixlBackup (stage 3e).~~ Done (integration B).

## App tests (XCTest, not ported from Android)
| Test | Covers |
|---|---|
| `LaunchConfigurationTests` | launch-argument parsing; every `DemoScreen` routes to exactly one destination with its ready id; settings sub-screens stack on Settings; router push/pop/select/bar visibility/sheets |
| `StoreTests` | demo library consistency; `LibraryStore` lookups; `PlaybackStore` + `DemoPlaybackEngine` (play, repeat-all wrap, pause, position ≤ duration); `SettingsStore` Android keys + defaults + persistence; `ArtworkSource` parsing; generated art → pixels → seed → coloured scheme; theme/type tokens; SwiftData round trip of the library and artwork themes |
| `TestToneWriterTests` | WAV header/size, tone not silent and not clipping |
| `KeychainStoreTests` | set/read/delete round trip (skips if the simulator build lacks keychain entitlement) |
| `ProcessingTapTests` (stage 5) | the processing tap offline (generated files through `AVAssetReaderAudioMixOutput` + the tap's audio mix): bypass is transparent; per-channel `vDSP_biquadm` (in place, stride 2) equals PixlAudioCore's `BiquadCascade` sample for sample; EQ boost/cut at 125 Hz / 1 kHz / 8 kHz within 0.5 dB of `EqualizerResponse` for the designed sections; coefficients redesigned when the published design rate differs from the tap's; bass-boost shelf; ReplayGain −6 dB and the unity cap (Android parity); **crossfade gain curves measured through the tap's meter log** (S-curve / exp / log / linear, incoming and outgoing, per-buffer RMS ratio vs `CrossfadeRamp`); mid/side removes the centre and keeps side content; virtualizer widens the side signal by `StereoWidth.maxWidth` |
| `PlaybackQueueTests` (stage 5) | Media3 next/previous/auto-advance per repeat mode, crossfade target never wraps; anchored shuffle equals `QueueUtils` with the same `KotlinRandom` seed, un-shuffle restores the order and keeps the current song; play next / add / move / remove / clear upcoming keep the current entry; edits made while shuffled survive un-shuffle; restore keeps the saved order |
| `SleepTimerControllerTests` (stage 5) | duration timer (clock checks and the sleeping wake-up task), end of track (engine flag, stop after the target song, cancel on a manual song change, no song), counted play (repeat-one forced, pause after the last play, user leaving repeat-one), queue end, cancel; Android's toast strings |
| `AudioSessionControllerTests` (stage 5) | interruptions through `AudioFocusResumeState` (resume only with `.shouldResume` and only if playing, both decks during a crossfade), route loss / reconnect (with and without resume-on-reconnect), media-services reset, parsing of real notification payloads, a posted interruption reaching the controller |
| `DualDeckEngineTests` (stage 5) | the real engine on the simulator with generated files: **gapless join** (hand-over planned, next item prepared on the idle deck, automatic advance, outgoing deck emptied, first item's tap reaches its last frame, the second's starts at frame 0, **no gap on the player clock** — A's end and B's start extrapolated from timebase samples, within 60 ms); **crossfade** (planned instead of a pre-insert, both decks overlap, outgoing deck emptied, both curves checked per buffer through the taps' meter logs); playlist NONE rule over a global crossfade and transition suspension; repeat-one loop; Media3 skips (next / previous within 3 s / restart past 3 s / queue item / no-op at the end); queue events reaching `PlaybackStore`; interruption pause/resume; ReplayGain from a WAV's ID3 `TXXX` tags (track and album gain) reaching the tap; queue snapshot save → `UserDefaults` → restore (paused, position kept) incl. songs unknown to the library. Skips (with a message) if the simulator renders no audio |
| `PlaybackClockTests` (stage 5) | `PlaybackStore.clock` reads position/duration from the engine on demand (no observation); fraction 0 without a duration, clamped to 1 |
| `GaplessDiagnosticsTests` (stage 5) | raw players on the simulator: AVQueuePlayer joins with/without the tap and the spectral pitch algorithm (printed; 0 s without a tap, ~0.45–0.5 s with one) and the scheduled two-player hand-over (asserted ≤ 30 ms on the player clock) |
| `LibraryImportTests` (stage 6) | the import on files generated at test time (MP3 with ID3v2 + APIC + SYLT, FLAC with Vorbis comments + STREAMINFO, untagged WAV, AAC M4A via `AVAudioFile`): tags, MediaStore-style defaults (file-name title, folder-name album, "Unknown Artist"), Android's genre placeholders, 10 s minimum, `.nomedia` / hidden / blocked folders, artist splitting with the delimiter settings, album grouping by folder, incremental rescan (unchanged files kept, changed + new read), deleted files and their orphan artists removed, favourites and date added kept, stable artist ids, rejected files re-read when the filters change, tag overrides set and cleared, write-back to MP3 / FLAC (PixlTags) and M4A (passthrough export), ReplayGain and embedded artwork read back, `LibraryStore.refresh` + snapshot cache |
| `LibraryScanLogicTests` (stage 6) | scan-plan diff by relative path + stamp (unchanged / changed / new / still rejected / iCloud placeholder, full rescan), id and library-path helpers, Android `normalizeGenre`, `LibraryScanOptions` from the Android keys (legacy delimiter list normalised, JSON string arrays), override JSON round trip |
| `SearchTests` | stage 7c: genre list from songs (split/trim/dedupe/sort/Unknown, Android `getGenres`/`buildGenre`), genre palette by Java `hashCode` (`GenreThemeUtils`), Oklab lerp ends, genre icon alias table (`GenreIconProvider`), title fit/break, `LibrarySearchProvider` on `SearchIndex` (filters, titles-only Songs, min tracks per album), section grouping/order/keys, `SearchModel` debounced library + remote searches (2-char minimum, blank clears, filter re-run, remote row removal), empty state, search-history DAO semantics |
| `UITests/SearchScreenshotTests` (extension of `ScreenshotTests`) | Search empty (browse grid), typing, results for All / Songs / Albums / Artists / Playlists, no results × light/dark |
| `UITests/ScreenshotTests` | shell: home, library, miniPlayer (album-tinted), miniPlayerAlone (bar hidden) × light/dark; search, settings, nowPlaying, diagnostics |
| `LibraryScreensTests` (stage 7a) | genre colours/schemes; `OrderedSelection` order and select-all; `LibraryPreferences` per-playlist song order (`playlist_song_order_modes`, `"manual"`), sort keys, storage-filter cycle; playlist cover form (saved fields per tab, edit-mode tab choice); `LibraryModel.compute` sorting/filtering/folder tree on the demo library; folder-playlist ids; artist album sections; genre list grouping; M3U file names |
| `UITests/LibraryScreenshotTests` (stage 7a) | Library tabs (playlists, albums grid/list, artists, folders, liked), selection, sort, reorder tabs, song multi-selection, creation chooser, add to playlist; song options (options + info pages); album, artist, genre (+ sort sheet), folder explorer; playlist detail (+ reorder/remove modes, options, add songs), playlist editor (create, edit with the Icon tab) |
| `HomeLogicTests` (stage 7b) | Android has no unit tests for these presentation helpers; the port is checked against the Kotlin source by hand: `HomeGreetingStateHolder` day phases, headline / subtitle / insight branches; `Formats.kt` long / compact / clock durations; `RecentlyPlayedSongUi.kt` id collection, dedup, newest-first ties, range bounds (Monday week start, 1st of month); `RecentlyPlayedScreen` timestamp groups (Today / Yesterday / `EEE, MMM d`, hour buckets); `RecentlyPlayedSection` pill widths and column-major rows; Stats hour / month labels and timeline chart sizing; `HomeStore.compute` over the demo library and history (mixes ≤ 3, shelves, daily / your mix, newest songs, recently played ≥ 4, week overview, evening greeting); today's saved daily mix is kept; empty library; history recording |
| `UITests/HomeStatsScreenshotTests` (stage 7b) | Home top / shelves / bottom / expanded insight, Daily Mix, Your Mix, Recently Played, Stats (top, scrolled, month), Beta / Changelog / Jobs sheets — compare with `pp_home`, `pp_shelf`, `pp_shelf2` |
| `SettingsFeatureTests` (stage 7d) | main settings order; equalizer: band moves switch to custom + clamp, save/update/rename/delete custom presets and pins, tabs = pinned built-ins + Custom, engine settings from the preferences (Android `EqualizerViewModel`); transitions: global duration from `crossfade_duration` clamped 1–12 s, global save round trip, playlist follow/override (Android `TransitionViewModel`), curve labels; update version comparison; delimiter defaults |
| `UITests/SettingsScreenshotTests` (stage 7d) | settings (dark) and every category × light/dark; experimental, artists, delimiters, word delimiters, transitions × 2, licences, easter egg (menu + playing), equalizer graph mode |
| `AITests` (stage 13) | Android has no unit tests for these (its AI tests — `AiProviderSupportTest`, `TaisIntentParserTest` — are ported in PixlNet, stage 3c); checked against the Kotlin source by hand: `TaisMediaRouter` genre `LIKE` arms, offline routes (genre / free text / both), exact library match before the catalogue, catalogue fallback through the Search seam; `TaisDjEngine` media vs conversation turns with the AI intro; `TaisChatModel` thinking-row replacement; `AiStateHolder` request context (candidate pool, digest), scripted generation end to end through `AiOrchestrator`, the error table, `generateShortAiTitle` / `resolveAiPlaylistName`; `buildAiPlaylistPrompt` + range validation; `translateLyrics` prompt, sentinel, validation, already-translated / not-found / not-configured outcomes; on-device prompt-shape detection; model display names |
| `UITests/AIScreenshotTests` (stage 13) | AI playlist sheet (empty × light/dark, prompt, error), TAIS DJ chat (empty × light/dark, scripted conversation × light/dark), AI Playlist Lab (top, scrolled) — scripted provider, no network |
| `LyricsSyncTests` (stage 10) | Android has no unit tests for `LyricsSyncEditorStateHolder`; checked against the Kotlin by hand: plain text of every lyrics shape (plain / synced / `LyricsDoc`), export file-name sanitising, preview line ↔ draft line mapping, the rough-line mark, the tap model's sung / next words, the music break before a gap line, and a session on the demo engine (open → tap → undo → close); 2026-10-07 entry fix: a `.viewGone` close never calls `onClosed` (and nothing is left to close after it), a user close navigates exactly once, Android's casting guard as the Spotify Connect guard (open refused with the message and nothing sent to the device; a mid-session takeover shows the error, ignores song changes behind it and never pauses the device — Android `LyricsSyncEditorStateHolder.kt:259-262`, `300-307`), and `ScreenAwake` keeping the screen on while any owner holds it |
| `UITests/LyricsSyncScreenshotTests` (stage 10) | sync editor: intro, words, resume, manage, tap (playing / paused / music break / notice / ended early / fix a line), preview (+ fix a line), light appearance staying dark, speed menu, a live tapping run on the demo engine |
| `UITests/LyricsSyncEntryTests` (2026-10-07) | iOS only (Android shows the editor as an overlay and has no UI test for it): the editor opened from the real entry points — the sync chip (twice), Lyrics options → "Sync the words yourself" on line- and word-synced lyrics — is still open 3 s later and closes back to the lyrics screen; Leave through the alert returns to lyrics; with the demo Spotify Connect session the editor shows the Connect message and Close dismisses it |
| `TaisModelTests` (stage 14) | the released `models-v1` archives downloaded in the simulator and installed (size + SHA-256 pin, ustar extract, `compileModel`): wav2vec2 gives one normalised row per 20 ms frame, alignment refuses lyrics over a pure tone, MDX-Net renders a complete peak-safe WAV, a wrong archive is refused before extraction, streamed SHA-256 equals CryptoKit's one-shot digest. Skips when the release can't be reached (~220 MB per app CI run) |
| `UITests/TaisScreenshotTests` (stage 14) | Experimental's Remaster Song card and on-device models panel (× light/dark), the song sheet's Remaster card (× light/dark), the lyrics screen's instrumental card (ready / rendering) and floating toggle (playing) |

### Stage 5 notes
Android has no unit tests for `DualPlayerEngine`, `TransitionController`, `MusicService`, `ListeningStatsTracker` or
`PlaybackStatsRepository.recordPlayback`; the app tests above are new. The pure decisions they rely on were ported with
golden vectors in stage 3b (PixlAudioCore) and 3a (PixlLibrary `QueueUtils`, `PlaybackHistoryCodec`).

## Stage 12 — Spotify

PixlNet gained the sync loop and the matcher pass that Android ran in `SpotifyRepository` and `SpotifyMatchWorker`,
behind `SpotifyLibraryStore` (Android `SpotifyDao`), so they run on Windows:

- `SpotifySnapshotRetentionTests` — Android `SpotifySnapshotRetentionTest`, 9 of 9 (row above).
- `SpotifyLibrarySyncTests` (Swift-only): re-import carries known matches and backfills genres in one batched
  `/v1/artists` call, drops podcast episodes and local files, parses `added_at`; `syncAll` flushes after Liked Songs
  and at the end, resumes past playlists fetched in the same pass and stops on `shouldContinue`; browse imports count
  only new tracks, `removeFromExploredCatalog` refuses tracks that are also in a real playlist; YouTube Music rows are
  stored MATCHED with 22-character synthetic ids; artist albums are distinct by name + track count and newest first
  (stable); the 30-minute resume window.
- `SpotifyMatchRunnerTests` (Swift-only, `SpotifyMatchWorker` has no Android test): matched / unmatched / errored
  (stays PENDING) per track, every row of a track updated, MANUAL never overridden, "Find audio" re-queues UNMATCHED,
  a fully failed batch stops the pass for a retry, the 8-minute budget, concurrency 2 while playing.
- App (`AppTests/SpotifyTests`, XCTest): unified-library rows (`sp:` songs, Spotify id bands for albums/artists,
  favourite and date kept, mirrored `SPOTIFY` playlists), the conservative artist delimiters, the SwiftData DAO and
  diffed unified write (in-memory container), resolver id parsing, the RFC 7636 vector through CryptoKit and the
  Keychain token round trip, demo states.


## Final review fixes (2026-10-03)

- `AutomaticStudioPolicyTests` (PixlLibrary) — Android `AutomaticStudioPolicyTest`, 10 of 10: features blocked
  independently, priority order, battery / charging, thermal and free space, duration limits, offline lyrics, the
  40-id candidate order, local audio for instrumentals, the persistent cooldown ledger and its bound.
- `DeezerArtistImagesTests` (PixlNet, Swift-only; `ArtistImageRepository` has no Android test of its lookup): the
  Retrofit-encoded search request, `picture_xl → big → medium → picture`, no match vs. error answers, the 1000×1000
  upgrade of Deezer artist URLs only.
- `MP4Tests.hugeSixtyFourBitSizesDoNotTrap` (PixlTags, Swift-only): a forged 64-bit box size after `ftyp`, inside
  `moov` and inside `ilst` fails or stops cleanly instead of overflowing.
- `ZipTests.fallbackWalkBoundsDataDescriptorEntries` (PixlBackup, Swift-only): without a central directory a
  data-descriptor entry inflates under a bound (64 MB by default) and reports `entryTooLarge` past it.
- `SpotifyTests.fullSignInFlow` now checks the English sign-in messages, including Cancel on Spotify's consent page
  ("Sign-in was cancelled").
- `LibraryImportTests` (app, Swift-only): `testHiddenSongsStayOutOfRescans` (a deleted song kept in `HiddenSongs`
  doesn't come back on an incremental or full rescan, and returns once un-hidden),
  `testForgedSixtyFourBitBoxSizeStopsTheMP4Walk` (the launch rescan's `TagRegionReader` stops at a forged 64-bit box
  size instead of trapping), `testOpenedFilesAreSortedByKind` (files opened from Files: backup, playlist, lyrics,
  audio, unsupported).
- `LyricsFeatureTests.testProbeLoadsLeaveTheMemoryCacheAlone` (app, Swift-only): the automatic runner's offline
  probe (`remember: false`) adds nothing to the lyrics memory cache; a normal load is still remembered.
- `TaisStudioTests.testUnattendedJobsAreTrackedAndCancelCleanly` (app, Swift-only; Android's WorkManager tags have
  no unit test): unattended jobs are tracked while running or queued, cancel cleanly from either state, and a second
  request keeps the existing job.

## Spotify Connect output (branch `spotify-connect`, Swift-only)
Android builds the same feature from the same spec in parallel; there is no Kotlin to port yet, so these are
Swift-only and define the behaviour both apps share.
- `PixlNetTests/SpotifyConnectTests` — scopes and old-login detection (scope kept across refreshes without one);
  every Player request byte for byte (method, URL, JSON body, empty body for bodiless commands); device and playback
  state decoding, display order and type → SF Symbol; error mapping (403 Premium by reason or message → "Spotify
  Connect needs Spotify Premium", 404 `NO_ACTIVE_DEVICE`, insufficient scope, restricted device, volume, 429
  Retry-After clamped, 5xx, other); real vs synthetic (YouTube Music) track ids; URI windows (skips, stop at an
  unresolved entry, the 100 cap, "has more", skipped count, duplicate URIs) and the skipped-songs toast text; the
  strict match (remaster/feat suffixes, live/remix mismatch, ±3 s, artists, accents, local files, ISRC hits) and
  queries; the resolver (direct ids skip search, ISRC before text, misses cached until the retry age, failed searches
  not cached, a tag change invalidates, persistence round trip, clear); the reducer (interpolation and no-write when
  nothing changed, scrubs/pauses/volume, track changes → queue indices, takeovers by another device / other content /
  204, grace after commands, end of queue incl. autoplay, next window once, next/previous decisions, optimistic
  commands); the client (401 → one refresh with the rotated token saved, 429 gate fails fast, transfer for inactive
  devices + one wake-up retry on `NO_ACTIVE_DEVICE`, Premium surfaced, 204 state, transport errors, search results).
- `PixlNetTests/SpotifyTests.authorizationURLUsesAndroidEncodingAndForcesTheDialog` now expects the two Connect
  scopes at the end of `scope` (Android must append them in the same order).
- `AppTests/SpotifyConnectStoreTests` — `PlaybackStore` with a fake `RemotePlaybackOutput`: transport forwarded,
  engine paused but `isPlaying`/position/duration from the remote, the model follows `remoteMoved`, queue edits and a
  new queue reported, `resumeLocally` hands back at the given entry and position.
- `UITests/SpotifyConnectScreenshotTests` — the section (light/dark), connect → stop on a demo device, playing state
  (light/dark), the hero with the device volume, reconnect row, empty hint, "Playing on" chip in the full (light/dark)
  and mini player.

## Streaming speed (2026-10-07, branch `wt/stream`; iOS first, Android later)
Android has no unit tests for `CloudStreamProxy`'s retry loop or chunking; `StreamUrlPrefetcherTest` (3) covers its
one-lookup prefetcher, whose rules (one task, a queue change cancels the obsolete one, pause cancels the latest,
a failure stays optional) the iOS prefetcher keeps in its own way (one task re-planned on change, cancelled on
pause; `try?` everywhere). PixlNet tests run on Linux, Windows and macOS; the app tests on CI.

| Android source | Swift test | Module | Status | Notes |
|---|---|---|---|---|
| `CloudStreamProxy.UPSTREAM_CHUNK_SIZE` (512 KB) | `StreamChunkPolicyTests` (3) | PixlNet | new (R2) | 128 KiB → 512 KiB → 2 MiB ramp and cap; the first request is `bytes=0-131071`; read-ahead never past the end or into cached bytes; fetch ends at size / end / cached start. |
| `MusicService.updateNextStreamPrefetch` (playing-only gate) | `StreamPrefetchPolicyTests` (4) | PixlNet | new (R3) | Wi-Fi/Ethernet 2, cellular / metered / unknown 1, offline / Low Data Mode / paused 0; skip-order indices with repeat-all wrap, never the current song; sizes and delays. |
| `CloudStreamProxy.fetch` (`MAX_UPSTREAM_ATTEMPTS = 4`, refresh first, `delay(250L * (attempt + 1))`) | `StreamRetryPolicyTests` (4) | PixlNet | ported (R5a) | Same client first, then switch (never with cached bytes); back-off 250/500/750 ms for 429/5xx; four attempts; other statuses fail at once. |
| _iOS only (R8)_ | `StreamHedgingTests` (5) | PixlNet | new | The `innertube.hedge` flag is off unless `"enabled": true` (the repo file ships it off), defaults and clamping; a slow client loses to the next after `afterSeconds`; a failure starts the next at once; all failing ends without waiting; off = strictly sequential. |
| `data/youtube/TrackMatcher.findMatch` | `TrackMatcherFanOutTests` (4) | PixlNet | new (R11) | `findMatchFanOut` gives exactly `findMatch`'s answer: the recorded `innertube-search.json` accepted on the first query with one search, a later answer never beating an earlier accept, the video shelf deciding, failures counted only where `findMatch` would have searched. |
| _iOS only (R12, R4)_ | `StreamingSpeedTests` (4) | app | new | Start timings record every step and only their own key's events; a prefetched resolution, local files, paused / failed / left starts, capacity; the resolve summary (winner detail, `n`); the client table's six-hour gate seeded from the saved file across relaunches, refreshed in the background when stale. |
| _iOS only (R7)_ | `DualDeckEngineTests.testASkipTakesOverTheCrossfadesPreparedItem`, `testASkipTakesOverTheGaplessHandOversPreparedItem` | app | new | A skip takes over the crossfade's (gain ramp cleared) or the hand-over's prepared item with no new resolution, manual transition, timed as a prepared skip; an unprepared target still loads. |
| _iOS only (R12 UI)_ | `YouTubeScreenshotTests.testPlaybackDiagnosticsTimingsLight/Dark` | UI | new | The Stream start timings card with demo starts. |


## On-device AI by default (2026-10-07, local AI phase 1, Swift-only)

Nothing here is ported: Android has no on-device paths for these features (its on-device provider is a MediaPipe
model behind the same orchestrator). The system language model can't run on CI's simulators, so every test stands
in for the model calls; the behaviour itself waits for Hoa's iPhone.

- `PixlNetTests/AiTests.customProviderChainKeepsOnDeviceRequestsLocal` — with the app's chain (`[ON_DEVICE]` when
  on-device is selected) a failure lists only ON_DEVICE and no HTTP request is made.
- `AppTests/OnDeviceAITests` (17 tests; also run on Linux against the pure files during development):
  on-device failure messages never contain a network/key word, never become "No Internet Connection" through
  `AiPlaylistPrompt.detailedErrorMessage` (the old "On-Device (Offline)" name did) and read back with `matching`;
  reply clean-up and token estimates (Latin, CJK, Vietnamese); the curator's prompt (1-based aliases, no ids, the
  taste line), the request-aware pool, the budget ladder with an injected counter, mapping back (dedupe, out of range,
  top-up), the curator end to end with a stand-in model (every other song, a too-long retry with half the pool, the
  guardrail retry as text, unavailability), long playlists (plan → fill → the first 40 ordered), plan parsing and
  fill; lyric translation (timestamps kept, each line translated once, already in the target language, plain lyrics,
  lines from the screen), its parser and chunks; Taizo's library lookup, prompts and the intro that arrives after the
  card (`TaizoOnDevice` stand-in); Home's greeting prompts (Android `HomeGreetingStateHolder`'s strings).
- `AppTests/AITests` (5 more): on-device failures resolve to their own message ahead of Android's error rows (and
  through the orchestrator's chain summary); the provider chain; the key-less Gemini rule; `AISettings` defaults
  (ON_DEVICE, the remembered cloud provider, the switch, a restore); the translator's on-device path only when
  selected.
- `UITests/SettingsScreenshotTests.testAICategoryCloudLight/Dark` (`settingsCategory.ai.cloud`),
  `testAICategoryAdvancedOnDeviceLight`; `UITests/LibraryScreenshotTests.testLibraryCreatePlaylistOnDeviceOffDark`
  (`libraryCreatePlaylist.onDeviceOff`).

## Accent colour (owner request 2026-10-07, iOS-only, Swift-only)
Android has no accent setting, so there is nothing to port; these define the iOS behaviour.
- `PixlLibraryTests/AccentPairTests` (7) — `ArtworkTheme.accentPair(seed:)`: WCAG AA (4.5:1) for `onPrimary` on
  `primary`, `primary` on the background and surface, and `onPrimaryContainer` on `primaryContainer`, light and dark,
  for every preset and a sweep of 606 custom picks (24 hues × 5 chromas × 5 tones plus black, white, mid grey and
  the RGB primaries); the light primaries (and four dark ones) equal Google's reference colour utilities
  (material-color-utilities, run once in the planning scratchpad: Red #BD0E12, Blue #005DB8, …); the primary's chroma
  is never below TonalSpot's and clearly above it for the saturated presets; Graphite is pure grey at the exact role
  tones with red errors; surfaces, secondary and tertiary equal TonalSpot's; the default `brandPair` is unchanged.
- `PixlBackupTests/ModuleTests` — `catalogueKinds` (accent_color_v1 is portable, every catalogue key listed once incl.
  `iosOnly`), `iosOnlyAccentColorRoundTripsAndOldBackupsClearIt` (export → restore keeps it; a backup without it
  restores with nothing skipped and clears it).
- `AppTests/AccentColorTests` (11) — hex parsing (with or without `#`, any case, spaces; empty / short / long / non-hex
  / signed → nil) and formatting; a picked `Color` → hex (opacity dropped, extended range clamped); the preset list and
  lookup by colour; `ThemeStore` keeps the violet by default, follows a picked accent live in light and dark, gives the
  player the accent when nothing plays, and registers observation even on a cached accent; persistence under
  `accent_color_v1` and `reload(from:)`; the window tint's light and dark colours.
- `AppTests/BackupServiceTests` — `testAccentColorIsExportedAndRestored` (exported as a string, restored into another
  store and reloaded live), `testOldBackupWithoutTheAccentRestoresTheDefault`.
- `AppTests/LaunchConfigurationTests.testAccentArgumentIsForUITestsOnly` — `-accent RRGGBB`.
- `UITests/SettingsScreenshotTests` — Appearance with Red (light, dark), Graphite (dark) and a custom colour (light),
  and a tap on Green that must select it (`isSelected`) and re-theme the page; `UITests/ScreenshotTests` — Home in
  Green (dark), Library in Blue (light), the settings list in Pink (light).

## Player fixes (2026-10-07, branch `wt/player`, Swift-only)
Nothing to port: Android has no tests for the full player's toggle row, the transport's press timing or the top bar.

- `AppTests/FavoriteObservationTests` — a favourite edit through `LibraryEditor` invalidates a reader of
  `LibraryStore.observedSong(id:)` and shows the new flag; a reader of the plain `song(id:)` is not invalidated (the
  root cause of the stale heart).
- `UITests/PlayerScreenshotTests` — `testFavoriteTogglesImmediately` (full player), `testSongInfoFavoriteTogglesImmediately`
  (song sheet) and `testLyricsOptionsFavoriteTogglesImmediately` (lyrics More sheet) tap the liked heart of demo song 0
  and expect the unliked state within 3 s without touching anything else; `testExpandedBluetoothLight`
  (`-screen nowPlaying.bluetooth`) expects "Playing on AirPods Pro" in the top bar and no "Now Playing" title.

## Cloud Studio worker (2026-10-07, branch `s19-cloud-worker`, Python, server side)
Nothing to port: Android's old RunPod worker (`tools/runpod-serverless`) has no tests. The worker's own suite is
pytest, CPU only (no torch, no weights), run by `cloud-worker-build` inside the image's `test` stage and locally
with `python -m pytest -q tests` in `cloud/runpod-worker/` (240 tests).

- `test_schema.py` — every golden example validates against its JSON Schema; the stdlib validator and jsonschema
  agree on good and broken inputs; caps, URL rules (host allowlist, https, signature, the job's own object keys).
- `test_storage.py` — streamed download with size and sha256 checks, status mapping (404 → `INPUT_MISSING`, 403 →
  `BAD_URL`), retries, the guard objects (an oversized one is unreadable, not a crash), the volume driver and sweep, the real HTTPS transport against a local TLS
  server (pinned IP, an unreachable first address falls through to the next, no redirects, wrong certificate
  refused).
- `test_audio.py` — ffprobe parsing (cover art ignored, video/hls/concat refused, caps) and real ffmpeg round trips.
- `test_pipeline.py` — `op: process` end to end with in-memory storage and fake models: uploads in order with the
  manifest last, the input deleted only after a usable result, duplicate and poisoned deliveries, partial results,
  `DEADLINE`, error manifests, the rejection manifest for jobs that fail validation; a lyrics-only job whose
  lyrics fail is an error that keeps its input (not `partial`); a 192 kHz input with AAC output fails before the
  separation, and with FLAC output keeps its rate; every document against its schema; sample counts equal to the
  decoded input (AAC and FLAC); a resend of a job whose input a finished `ok`/`partial` run already deleted hands
  that result back instead of overwriting it with `INPUT_MISSING`, while a missing input with no such result is
  still `INPUT_MISSING`.
- `test_lyrics_run.py`, `test_lyrics_windows.py`, `test_lyrics_postprocess.py` — VAD, the global offset check,
  synced and plain windows, token → UTF-16 offsets, line-timing fallback, the Whisper hook (a second backend takes
  the languages the first lacks), transcription; a job's deadline always comes off the shared aligner and
  transcriber afterwards (failures included).
- `test_handler.py` — dispatch, error strings, cold start reported once, the selftest answer (with caps) against its
  schema, no URL in any returned error; a bench on a worker whose aligner still holds an expired deadline runs.
- `test_ci_tools.py` — the Dockerfile and weights.lock agree (and each kind of disagreement fails), the small-file
  fetcher's size/sha checks and retries, the pip-check allowlist, fixture drift, the lock's base-package filter.
- `test_deploy.py` — REST v2 client retries and safe errors, desired state and the smallest valid PATCH (complete
  env, pools with exclusions), the deploy flow (auto vs by hand, private package, rollout, selftest gitSha retry),
  the concurrency check, jobs still queued when the deploy stops waiting are cancelled, the keepalive (restore
  only when healthy and the last deploy that ran passed: failed, cancelled and timed-out deploys block it,
  skipped deploy runs don't count; the spend alarm without printing money).
- `src/pixl_worker/smoke.py` (Docker `smoke` stage on CI, not pytest) — loads the real BS-RoFormer, aligner and
  htdemucs_ft weights on CPU and runs each once; the htdemucs_ft run goes through the progress hook (one total
  for the bag of models, never going backwards).
