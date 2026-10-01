# Android reference generators (dev tooling, never shipped)

PixlCore ports Android/Compose logic that must behave **exactly** like the original. These two small Java
programs run the real Android implementations on a desktop JVM and write the fixtures the Swift tests compare
against. They are only needed when a fixture has to be regenerated (for example after a Compose upgrade on
Android).

| Program | Runs | Writes | Used by |
|---|---|---|---|
| `RefGen.java` | Compose `FloatSpringSpec` (value, velocity, `getDurationNanos`), `CubicBezierEasing`, `FloatExponentialDecaySpec` from `androidx.compose.animation:animation-core` | `Packages/PixlCore/Tests/PixlFoundationTests/Fixtures/compose-reference.txt` | `ComposeReferenceTests` |
| `DocGen.java` + `cases.txt` | The Android app's compiled `LyricsDocCodec.decode` / `encode` (kotlinx.serialization) over every line of `cases.txt` | `Packages/PixlCore/Tests/PixlModelTests/Fixtures/lyricsdoc-android-golden.txt` | `LyricsDocGoldenTests` |

## Classpath

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
