# Test parity (Android unit tests → Swift)

Every Android unit test that is ported gets a row. Android tests live in the read-only Android repo under
`app/src/test/java/com/theveloper/pixelplay/` (fixtures in `app/src/test/resources/`); Swift tests live in
`Packages/PixlCore/Tests/<Module>Tests/` (Swift Testing) or `AppTests/` (XCTest). Copy fixtures into
`Tests/<Module>Tests/Fixtures/` — the folder is already bundled (`Bundle.module`, subdirectory `Fixtures`).

Status: **ported** (all cases) · **partial** (list what's missing) · **n/a** (reason) · **todo**.

| Android test (class) | Cases | Swift test | Module | Status | Notes |
|---|---|---|---|---|---|
| _stage 0: no Android tests ported yet_ | | `<Module>ModuleTests` (placeholders: module linked, fixtures bundled) | all | — | |

## Priority list (from architecture §4, must pass on Windows before UI work)
- `LyricsEngineTest`, `LyricsClockTest`, `LyricsMotionMathTest`, `PreparedLyricsBuilderTest`,
  `LyricsBackgroundGradeTest` → PixlLyrics / PixlFoundation (stages 2b/2c).
- `ArtistParsingUtilsTest`, album grouping, folder tree, queue utils → PixlLibrary (stage 3a).
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
