# Stage 3d — PixlTags (test parity, to fold into `docs/test-parity.md`)

Tests in `Packages/PixlCore/Tests/PixlTagsTests/` (73 tests, 9 suites; the interop dump test is skipped unless
`PIXLTAGS_DUMP_DIR` is set). All pass on Windows (Swift 6.4).

Android has **no unit tests** for its tag code (`data/media/*`: `SongMetadataEditor`, `ReplayGainManager`,
`AudioMetadataReader`, `AudioMetadataUtils`); the tag I/O itself is TagLib (native, `com.kyant:taglib` 1.0.6, a
TagLib 2.x build), JAudioTagger 3.0.1 and vorbis-java. So parity comes from three sources: golden vectors from the
compiled Android helpers, the file-tag half of the one related app test, and Swift tests that pin TagLib 2's
behaviour (read from TagLib's source and checked against the strings in the app's `libtaglib.so`).

## Rows for the main table

| Android test (class) | Cases | Swift test | Module | Status | Notes |
|---|---|---|---|---|---|
| `presentation/viewmodel/MetadataEditLyricsPreservationTest` | 3 (file half) | `MetadataEditorTests.titleOnlySaveLeavesTheLyricsTagAlone`, `clearingTheLyricsFieldRemovesTheTag`, `editedLyricsAreWrittenTrimmed` | PixlTags | partial | The tag-file half of each case (nil lyrics keep the USLT frame, blank removes it, edited lyrics are trimmed and written). The Room/`lyrics/{id}.json` half (`resetLyrics`/`updateLyrics` calls) is the app's `MetadataEditStateHolder` (stage 7a). |
| _Android tag helpers (not an app test)_ | 1,103 vectors | `AndroidGoldenTests.everyVectorMatches` | PixlTags | new | `tools/android-reference/TagsGen.java` runs the app's compiled `ReplayGainManager.parseGainString`/`gainDbToVolume`/`getVolumeMultiplier`, `AudioMetadataReader.parseReplayGainDb`, `SongMetadataEditor.parseReplayGainUpdate`/`validateMetadataInput`/`detectContainerFormat`/`isProblematicFlacFile` (private methods via reflection, the editor allocated without its constructor), Kotlin `toFloatOrNull`/`toIntOrNull` and Java `URLConnection.guessContentTypeFromStream` (`guessImageMimeType`). Fixture `tags-android-golden.jsonl`. Floats compared bit for bit (`gainDbToVolume` included); all 1,103 identical on Windows. |
| _Real third-party files (not an app test)_ | 4 files | `RealWriterFixtureTests` | PixlTags | new | FFmpeg 8 (Lavf 62.12) output: ID3v2.4 MP3, ID3v2.3 MP3 + ID3v1, FLAC with PICTURE block and 8 KiB padding, M4A with `ilst`/`covr`. Read, mapped through `AudioMetadataMapper`, edited and re-read; the MP3 audio bytes are checked unchanged. |

## Golden generator
`tools/android-reference/TagsGen.java` (classpath and command in its header): the app's
`compileDebugKotlin/classes`, `android.jar` (platforms/android-37.0), kotlin-stdlib 2.4.0, Timber 5.0.1 and the
`com.kyant:taglib` 1.0.6 `classes.jar` (only for class loading; `libtaglib.so` is arm64-only and cannot run on the
JVM), JDK 26. Output: `Packages/PixlCore/Tests/PixlTagsTests/Fixtures/tags-android-golden.jsonl`, one
`{"fn","in","out"}` object per line. Add a row for it to `tools/android-reference/README.md` when folding.

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

## Interop check (manual, local)
`PIXLTAGS_DUMP_DIR=<dir> swift test --filter InteropDumpTests` writes PixlTags-written ID3v2.3/2.4 MP3s (UTF-16 /
UTF-8 text, APIC, USLT, SYLT, COMM, TXXX ReplayGain, TDRC→TYER/TDAT) and a rewritten FLAC. Checked on 2026-09-30 with
ffprobe 8.0 and JAudioTagger 3.0.1: every field, the picture, the USLT/SYLT frames and the FLAC comment read back as
written.

## Swift-only tests added in stage 3d
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

## Deviations (documented in the sources)
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
