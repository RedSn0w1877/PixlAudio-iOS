# Android reference generators (dev tooling, never shipped)

PixlCore ports Android/Compose logic that must behave **exactly** like the original. These small Java
programs run the real Android implementations on a desktop JVM and write the fixtures the Swift tests compare
against. They are only needed when a fixture has to be regenerated (for example after a Compose upgrade on
Android).

| Program | Runs | Writes | Used by |
|---|---|---|---|
| `RefGen.java` | Compose `FloatSpringSpec` (value, velocity, `getDurationNanos`), `CubicBezierEasing`, `FloatExponentialDecaySpec` from `androidx.compose.animation:animation-core` | `Packages/PixlCore/Tests/PixlFoundationTests/Fixtures/compose-reference.txt` | `ComposeReferenceTests` |
| `DocGen.java` + `cases.txt` | The Android app's compiled `LyricsDocCodec.decode` / `encode` (kotlinx.serialization) over every line of `cases.txt` | `Packages/PixlCore/Tests/PixlModelTests/Fixtures/lyricsdoc-android-golden.txt` | `LyricsDocGoldenTests` |
| `LyricsGen.java` + `lyrics-cases.txt` (see [`LyricsGen.md`](LyricsGen.md)) | The app's compiled lyrics parsers: `LyricsUtils.parseLyrics`/`toLrcString`, `TtmlLyricsParser`, `WordSyncTranspilers`, `LyricsfileParser` (SnakeYAML), `LyricsImportSecurity`, `MultiLangRomanizer`, the `LyricsRepositoryImpl` matching helpers and the AMLL/NetEase matchers. `gen-romanizer-tables.js` generates `RomanizerTables.swift` from `LyricsUtils.kt`. | `Packages/PixlCore/Tests/PixlLyricsTests/Fixtures/parsing/lyrics-android-golden.txt` | `ParsingGoldenTests` |
| `EngineGen.java` + `lyrics-engine-cases.txt` | The app's compiled `PreparedLyricsBuilder`, `LyricsEngine`, `LyricsClock` and lyrics maths (springs, blur, cascade, emphasis, background grade, sprite baking) | `Tests/PixlLyricsTests/Fixtures/lyrics-prepared-golden.txt`, `lyrics-engine-golden.txt`, `lyrics-math-golden.txt` | `LyricsGoldenTests` |
| `TapSyncGen.java` | The app's compiled `LyricsTapSync`, `LyricsExport` and `LyricsSyncDraftStore` codec (all 500 property-test sessions hashed step by step); `java TapSyncGen debug <seed>` prints one seed | `Tests/PixlLyricsTests/Fixtures/tapsync-android-golden.txt` | `TapSyncGoldenTests` |
| `LibGen.java` | The app's compiled library logic (artist parsing, folder tree, random/shuffle, recommendations, stats, history codec) plus the real `songs_fts` SQL through xerial sqlite-jdbc | `Tests/PixlLibraryTests/Fixtures/*-golden.jsonl`, `Sources/PixlLibrary/Unicode61Tables.swift` | `GoldenVectorTests`, `ArtistParsingTests` |

## Classpath

The stage 2b–3a generators document their full classpath and command in their header comment (`LyricsGen` in
`LyricsGen.md`). `stubs/` holds minimal Android stand-ins (`Context`, `Uri`, `Parcel`/`Parcelable`, `LruCache`) that
are compiled and put before `android.jar` so app classes load on the JVM. The two stage 2a generators:

Everything comes from the Android project's Gradle cache (`~/.gradle/caches/modules-2/files-2.1`) and build output
(no downloads):

- `RefGen`: `classes.jar` extracted from `androidx.compose.animation/animation-core-android/<ver>/animation-core.aar`,
  `androidx.compose.ui/ui-graphics-android` (Bézier root finder) and `ui-util-android` (`fastCbrt`) the same way,
  `androidx.collection/collection-jvm`, `org.jetbrains.kotlin/kotlin-stdlib`.
- `DocGen`: the Android app's `app/build/intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes`,
  `kotlinx-serialization-json-jvm` and `kotlinx-serialization-core-jvm` (1.11.0, the app's version), `kotlin-stdlib`.

```sh
javac -cp "$CP" RefGen.java && java -cp "$CP;." RefGen > compose-reference.txt
javac -cp "$CP" DocGen.java && java -cp "$CP;." DocGen cases.txt > lyricsdoc-android-golden.txt
```

(`;` is the Windows classpath separator; use `:` elsewhere.) The 2a fixtures were generated with animation-core
1.12.1, ui-graphics/ui-util 1.12.1, kotlinx-serialization 1.11.0 and JDK 26.

## Fixture formats

- `compose-reference.txt`: one sample per line, floats as IEEE-754 bit patterns (`0x…`), times in nanoseconds.
  `S ζ k threshold initial target v0 nanos value velocity`, `D ζ k threshold initial target v0 durationNanos`,
  `B a b c d x y`, `X frictionMultiplier threshold initial v0 nanos value velocity`,
  `Y frictionMultiplier threshold initial v0 durationNanos target`.
- `lyricsdoc-android-golden.txt`: pairs of lines `IN <JSON string>` / `OUT <JSON string | null>`; `null` means
  Android rejected the input.
- `cases.txt`: one input per line; `\n`, `\t` and `\\` are unescaped before use.
