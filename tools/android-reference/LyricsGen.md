# LyricsGen — Android golden vectors for the PixlLyrics parsers (dev tooling, never shipped)

`LyricsGen.java` runs the Android app's compiled lyrics code on a desktop JVM over every line of
`lyrics-cases.txt` and writes `Packages/PixlCore/Tests/PixlLyricsTests/Fixtures/parsing/lyrics-android-golden.txt`,
which `ParsingGoldenTests` compares with the Swift ports byte for byte.

Covered: `LyricsUtils.parseLyrics` / `toLrcString`, `TtmlLyricsParser.parseToEnhancedLrc`,
`WordSyncTranspilers.yrc` / `richSync`, `LyricsfileParser.parse`, `LyricsImportSecurity`, `MultiLangRomanizer`
(Chinese, Korean, Hindi, Punjabi, Cyrillic), `parseBestEmbeddedLyricsField`, and the private `LyricsRepositoryImpl`
matching helpers (`normalizeForMatch`, `baseTitleForMatching`, `timingVariantTokens`, `cleanTitleSmart`,
`romanizeForMatch`, `titleMatchScore`, `artistMatchScore`, `rankRemoteLyricsMatches`, `remoteRawLyrics`,
`lyricsToRawContent`, `looksLikeFlattenedWordByWordCache`) plus `AmllLyricsSource.matchesMetadata` and
`NeteaseLyricsSource.matchesRecording`. Private members are reached by reflection on an instance allocated without
its constructor (only the pure helpers are called).

## Cases file

One case per line: a kind, a TAB, TAB-separated arguments (`\n` `\r` `\t` `\\` `\uXXXX` unescaped, `@path` reads a
file relative to the cases file, `<null>` passes null). The kinds are listed at the top of `lyrics-cases.txt` and in
`LyricsGen.run`. Output: a `PINYIN {…}` line (pinyin4j's first toneless reading for every Han character used, which
the Swift test injects as its `CJKRomanizationProvider`), then `IN <kind> <json args>` / `OUT <json>` pairs.

Japanese romanisation is `null` on the generator (the app reads `android.os.Build`, absent on a desktop JVM, and
returns null), which matches PixlCore's default provider.

## Classpath and running

From the Android project's Gradle cache and build output (no downloads), plus the stubs in `stubs/` (`android.os.
Parcelable`/`Parcel` so `Song` loads; `android.content.Context`, `android.net.Uri`, `android.util.LruCache` so
reflection over `LyricsRepositoryImpl` resolves):

- `app/build/intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes`
- `org.jetbrains.kotlin:kotlin-stdlib:2.4.0`, `org.jetbrains.kotlinx:kotlinx-serialization-{json,core}-jvm:1.11.0`
- `com.google.code.gson:gson:2.14.0`, `org.yaml:snakeyaml:2.4`, `com.atilika.kuromoji:kuromoji-{core,ipadic}:0.9.0`,
  `com.belerweb:pinyin4j:2.5.1`, `com.squareup.okhttp3:okhttp` (any 4.x; only the class must resolve)

```sh
javac -d out stubs/android/*/*.java stubs/android/os/*.java
javac -cp "$CP;out" -d out LyricsGen.java
java -XX:+UnlockDiagnosticVMOptions -XX:-BytecodeVerificationRemote --enable-final-field-mutation=ALL-UNNAMED \
     -cp "$CP;out" LyricsGen lyrics-cases.txt > lyrics-android-golden.txt
```

`-XX:-BytecodeVerificationRemote` skips verifying app classes against Android types the stubs do not provide (they
are never executed). The 2b fixture was generated with JDK 26.0.1. JVM regex differs from Android's ICU regex only for
`\b` next to non-ASCII letters; the cases avoid that (see `ParseKit.swift`).

`gen-romanizer-tables.js` (Node) regenerates `Sources/PixlLyrics/Parsing/RomanizerTables.swift` from the Android
`utils/LyricsUtils.kt`: `node gen-romanizer-tables.js <LyricsUtils.kt> <RomanizerTables.swift>`.
