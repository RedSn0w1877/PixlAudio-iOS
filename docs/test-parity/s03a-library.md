# Test parity — stage 3a (PixlLibrary)

Rows to fold into `docs/test-parity.md`. Android tests live under `app/src/test/java/com/theveloper/pixelplay/`;
Swift tests under `Packages/PixlCore/Tests/PixlLibraryTests/` (Swift Testing). 123 tests, all passing on Windows.

| Android test (class) | Cases | Swift test | Module | Status | Notes |
|---|---|---|---|---|---|
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

### Golden vectors from the compiled Android code (new)
`tools/android-reference/LibGen.java` runs the app's compiled classes (`compileDebugKotlin/classes`, kotlin-stdlib
2.4.0, Gson 2.14.0, kotlinx-collections-immutable 0.5.0, kotlinx-coroutines 1.11.0, Timber 5.0.1, android.jar 37 for
class loading) and xerial sqlite-jdbc 3.41.2.2 on JDK 26, and writes `Tests/PixlLibraryTests/Fixtures/*-golden.jsonl`
plus `Sources/PixlLibrary/Unicode61Tables.swift`. Classpath and command are in the file's header comment (add a row to
`tools/android-reference/README.md` when integrating).

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
