# Test parity — stage 2b (PixlLyrics parsers)

Rows to fold into [`docs/test-parity.md`](../test-parity.md). Swift tests live in
`Packages/PixlCore/Tests/PixlLyricsTests/Parsing*.swift`; fixtures in `Tests/PixlLyricsTests/Fixtures/parsing/`
(the four Android `app/src/test/resources/lyrics/*` files copied verbatim, plus the golden file below).

| Android test (class) | Cases | Swift test | Module | Status | Notes |
|---|---|---|---|---|---|
| `utils/LyricsUtilsTest` | 23 | `ParsingLyricsUtilsTests` (+8 Swift-only: empty input, plain text, metadata/offset, Kugou, JSON/richsync/YRC dispatch, Korean romanisation, injected Japanese provider, `toLrcString`) | PixlLyrics | ported | |
| `utils/LyricsImportSecurityTest` | 12 | `ParsingImportSecurityTests` (+4 Swift-only: MIME/extension tables, empty/malformed payloads, local file sanitising, messages) | PixlLyrics | ported | `validateLocalLyricsFile_rejectsBinaryPayload` uses a temp file via `validateLocalLyricsFile(at:)`. |
| `data/network/lyrics/WordSyncTranspilersTest` | 12 | `ParsingWordSyncTests` (+2 Swift-only: YRC metadata/limits, richsync rounding and numeric strings) | PixlLyrics | ported | Completes the 2a partial row (2a ported the two pure `LyricsDoc` cases model-side; they are repeated here next to the transpilers). |
| `data/network/lyrics/LyricsfileParserTest` | 7 | `ParsingLyricsfileTests` (+4 Swift-only: YAML scalars stay strings, block scalars/folding, collections/anchors/limits, Lyricsfile edge rules) | PixlLyrics | ported | Includes the AMLL `matchesMetadata` case. |
| `data/network/lyrics/NeteaseLyricsSourceTest` | 3 | `ParsingCatalogTests` (+3 Swift-only: NetEase requests/response checks, AMLL lookups/parse, bounded bodies) | PixlLyrics | ported | The OkHttp fixture replies are fed as the same JSON through the pure functions PixlNet will call (`LyricsHTTP.decodeBody`, `NeteaseLyricsMatching.candidateTracks/trackId/lyrics`). The HTTP 403 sub-case has no parsing half (PixlNet never decodes a failed response). |
| `data/repository/LyricsRepositoryImplTest` | 9 | `ParsingRepositoryTests` | PixlLyrics | partial | Ported: `parseBestEmbeddedLyricsField_prefersSyncedLyricsWhenLyricsFieldIsPlain`, `fetchFromRemote_rejectsDurationOnlySearchMatch`, `fetchFromRemote_rejectsOriginalLyricsForRemix`, `fetchFromRemote_acceptsMatchingRemixVariant`, `fetchFromRemote_doesNotTreatArtistNameInFilePathAsVariant` (candidate-mode search then automatic exact match, as `fetchFromRemote` does). The four storage-order cases (`getLyrics_storageProbeFailure…`, `getLyrics_returnsSongLyricsBeforeNeedingStorageRead`, `getLyrics_apiFirst_usesStoredLyricsBeforeCallingLrcLib`, `fetchFromRemote_returnsStoredLyricsWithoutCallingApi`) test caching/DAO order and belong to the iOS `LyricsService` (stage 9); their parsing halves are `storedSongLyricsParseAsLocalLyrics`. |
| `data/repository/StreamingLyricsPersistenceTest` | 2 | — | PixlLyrics | n/a | JSON-cache file persistence is stage 9. The pure part (a torn `{"wordByWordLyrics":` cache is a miss) is in `rawContentCacheRecordAndUserSync`. |
| _Android lyrics parsers (not an app test)_ | 553 vectors | `ParsingGoldenTests` | PixlLyrics | new | Every case of `tools/android-reference/lyrics-cases.txt` run through the compiled Android `LyricsUtils.parseLyrics`/`toLrcString`, `TtmlLyricsParser`, `WordSyncTranspilers.yrc/richSync`, `LyricsfileParser` (SnakeYAML 2.4), `LyricsImportSecurity`, `MultiLangRomanizer` (pinyin4j 2.5.1 readings injected), the `LyricsRepositoryImpl` matching/ranking/raw-content helpers and the AMLL/NetEase matchers by `tools/android-reference/LyricsGen.java`; fixture `lyrics-android-golden.txt`. All 553 are identical on Windows. |

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
