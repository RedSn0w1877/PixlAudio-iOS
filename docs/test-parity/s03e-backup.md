# Stage 3e — PixlBackup (test parity, to fold into docs/test-parity.md)

Tests in `Packages/PixlCore/Tests/PixlBackupTests/` (143 tests in 23 suites, all passing on Windows). Android tests
live under `app/src/test/java/com/theveloper/pixelplay/data/backup/`.

## Rows for the main table

| Android test (class) | Cases | Swift test | Module | Status | Notes |
|---|---|---|---|---|---|
| `data/backup/model/BackupSectionTest` | 9 of 9 | `BackupSectionTests` | PixlBackup | ported | |
| `data/backup/format/BackupFormatDetectorTest` | 7 of 7 | `BackupFormatDetectorTests` | PixlBackup | ported | |
| `data/backup/format/LegacyPayloadAdapterTest` | 5 of 5 | `LegacyPayloadAdapterTests` | PixlBackup | ported | The test's Gson is `setPrettyPrinting()` without `serializeNulls`; the Swift adapter always uses the backup Gson's output (pretty + nulls), which is what `BackupReader` passes on Android. |
| `data/backup/validation/ContentSanitizerTest` | 9 of 9 | `ContentSanitizerTests` | PixlBackup | ported | Lengths are UTF-16 units, as in Kotlin. |
| `data/backup/validation/ManifestValidatorTest` | 9 of 9 | `ManifestValidatorTests` | PixlBackup | ported | `System.currentTimeMillis()` → injected clock (`ManifestValidator(now:)`). |
| `data/backup/validation/ModuleSchemaValidatorTest` | 15 of 15 | `ModuleSchemaValidatorTests` (+ `tooManyEntriesIsFatal`) | PixlBackup | ported | |
| `data/backup/module/EngagementStatsModuleHandlerTest` | 3 of 3 | `EngagementStatsModuleHandlerTests` | PixlBackup | ported | Supersedes the stage-3a "n/a (stage 3e)" row. The DAO mock is replaced by the pure `EngagementStatsModule.restore/export`. |
| `data/backup/module/FavoritesModuleHandlerTest` | 2 of 2 | `FavoritesModuleHandlerTests` | PixlBackup | ported | `FavoritesModule.restore/export`. |
| `data/backup/restore/RestoreExecutorTest` | 3 of 3 | `RestoreExecutorTests` | PixlBackup | ported | MockK handlers → the `RecordingHandler` actor; the mocked `BackupReader`/`ValidationPipeline` are replaced by real archives built with `BackupWriter` (so validation runs for real). |
| `data/backup/BackupManagerTest` | 3 of 3 | `BackupManagerTests` | PixlBackup | ported | Real archives instead of mocks. The first case's warning is the validator's real message ("File extension is not .pxpl. The file may not be a valid backup."), the mock used a shortened one. |
| _Android backup code (not an app test)_ | 764 vectors | `BackupGoldenTests` (15 tests) | PixlBackup | new | See below. |
| _JDK `Deflater` (not an app test)_ | 44 streams | `InflateTests.inflatesJavaDeflaterOutput` | PixlBackup | new | Fixture `inflate-cases.jsonl`. |

## Golden vectors from the compiled Android code (new)

`tools/android-reference/BackupGen.java` (classpath and command in its header; it also needs `javax.inject-1.jar`)
runs the app's compiled `data/backup` classes with Gson 2.14.0 on JDK 26 and writes
`Tests/PixlBackupTests/Fixtures/` — please add a `BackupGen.java` row to `tools/android-reference/README.md` when
folding:

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

## Swift-only tests added in stage 3e
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

## Deviations (documented in the sources)
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
