# Test parity — stage 2d (tap-sync editor core + export, PixlLyrics)

To be folded into `docs/test-parity.md` by the integrator. Swift tests live in
`Packages/PixlCore/Tests/PixlLyricsTests/Sync/`.

| Android test (class) | Cases | Swift test | Module | Status | Notes |
|---|---|---|---|---|---|
| `data/lyrics/sync/LyricsTapSyncTest` | 36 of 36 | `LyricsTapSyncTests` | PixlLyrics | ported | Same inputs and expected values case for case (tokenize ×7, buildDraft ×5, tap ×4, release, undo ×3, rewind, jumpToLine ×2, fixLine, skipLine, fillRest, nudge/offset learning, deriveEnds ×4, toLyricsDoc ×5). Seeded cases use a port of Kotlin's `Random(seed)` (`KotlinRandom`, XorWow), so `Random(3)`, `Random(7)` and the 500 property-test seeds produce the same inputs as on Android. `toLyricsDoc_isAlwaysValidForRandomSessions` (~500 random tap sequences: tap/release/undo/rewind/jump/fix/skip/fill/nudge/clear, every step checked for consistency, validity, line preservation and codec round trip) → `toLyricsDocIsAlwaysValidForRandomSessions` (session generator shared in `RandomSessions.swift`; it also checks the initial draft). `assertSame` (identity) → value equality. |
| `data/lyrics/sync/LyricsExportTest` | 8 of 8 (3 disabled) | `LyricsExportTests` | PixlLyrics | partial | LRC headers/word tags/closing tag, `lrcTime` rounding, empty headers + newline flattening, TTML well-formedness/escaping/agents/nested background, flush syllables + clock format, dropped control characters + no `dur` — all ported; the TTML is parsed with Foundation `XMLParser` (namespace-aware, FoundationXML off Apple platforms) into a tiny DOM instead of `DocumentBuilder`. **Disabled until the s02b parser lands:** `lrc_roundTripsThroughTheAppParser`, `lrc_roundTripsTappedDrafts`, `ttml_readsBackThroughTheAppParser` (fully ported bodies; integrator sets `LyricsExportTests.parseLyrics` to the Swift `LyricsUtils.parseLyrics` port and removes the three `.disabled` traits). |
| `data/lyrics/sync/LyricsSyncDraftStoreTest` | 5 of 5 | `LyricsSyncDraftStoreTests` | PixlLyrics | ported | JUnit `@TempDir` → a fresh folder under the temp directory per test; `runBlocking` → `async` tests against the `LyricsSyncDraftStore` actor; `setLastModified` → `FileManager.setAttributes([.modificationDate:])`. Passes on Windows. |
| _Android tap-sync/export/draft codec (not an app test)_ | 9 + 461 + 500 + 61 + 8 + 10 vectors | `TapSyncGoldenTests` | PixlLyrics | new | `tools/android-reference/TapSyncGen.java` runs the app's compiled `LyricsTapSync`, `LyricsExport` and `LyricsSyncDraftStore` codec on the JVM (fixture `tapsync-android-golden.txt`): Kotlin `Random` outputs; `tokenize` over 461 inputs (the test's samples and 400-line fuzz plus edge cases: ZWJ before a non-emoji, marks after controls, small kana, half-width kana, Ext-B ideographs, RTL/Indic/Thai, NBSP/U+3000/U+0085); **all 500 property-test sessions hashed step by step** (stored draft JSON, `SyncStep` seek/cleared/flags, `isConsistent`, the built document JSON + rough lines, and the final LRC/TTML) — byte-identical; the stored draft JSON byte for byte; 60 decode cases (quoted numbers and booleans, `TRUE`, float spellings, non-finite and zero speeds, missing/null fields, duplicate keys, trailing garbage…); SHA-1 file names; LRC/TTML of 5 documents byte for byte. |

### Swift-only tests added in stage 2d
`kotlinLinesSplitsLikeKotlin`, `tokenizeSplitsOnScalarSpacesEvenBeforeCombiningMarks` (a space before a combining
mark is one Swift `Character` but two Kotlin chars), `isConsistentRejectsBrokenDrafts`,
`buildDraftFromSongUsesItsMetadata` (the `Song` overload, `displayArtist`), `lrcAndTtmlHandleBackgroundOnlyAndLineOnlyParagraphs`,
`saveCreatesTheDirectoryAndPrunesStrayTempFiles`, `oversizedFilesAreDiscarded` (8 MiB cap), `nonFiniteSpeedsAreNotSaved`,
`javaFloatStrings` (Java `Float.toString` layout incl. the two-digit minimum, `parseFloat` subset).

### Notes for the integrator
- The full PixlLyrics run takes ~80 s in a Windows debug build, almost all in the two 500-seed tests (they run in
  parallel). They are the Android property test plus its golden replay; keep both.
- To regenerate the fixture: see the header of `tools/android-reference/TapSyncGen.java` (classpath = the stage-2a
  `DocGen` classpath + `kotlinx-collections-immutable-jvm` 0.5.0, timber's `classes.jar` and the SDK's `android.jar`
  for `Parcelable`). `java TapSyncGen debug <seed>` prints every step of one seed; on a hash mismatch
  `TapSyncGoldenTests` writes Swift's replay of the first three failing seeds to the temp directory for diffing.
