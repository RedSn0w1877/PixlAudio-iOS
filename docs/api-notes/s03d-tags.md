# Stage 3d — PixlTags (API-ledger additions, to fold into `docs/api-notes.md`)

PixlTags uses no Apple-only API: everything is the Swift standard library and swift-corelibs-foundation, verified on
Windows (Swift 6.4) and by the macOS `core` CI job. New rows for "Foundation and the standard library in PixlCore":

| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `Data(base64Encoded:)` (from `Data`), `Data.base64EncodedString()` | 7 | /documentation/foundation/data/init(base64encoded:options:) | `VorbisComment` (`METADATA_BLOCK_PICTURE`, `COVERART`), `FLACPicture.vorbisPictureBlock` | Android's `Base64.NO_WRAP` = no options (no line breaks). |
| `String(decoding:as:)` with `UTF16.self` / `UTF8.self` | — (stdlib) | /documentation/swift/string/init(decoding:as:) | `TagText` (ID3v2/Vorbis/MP4 text) | Replacement-character decoding like TagLib's lenient `String` constructors; results are cut at the first NUL like TagLib. |
| `Float(_: String)` with hexadecimal literals | — (stdlib) | /documentation/swift/float/init(_:)-5wmm8 | `KotlinText.toFloatOrNull` | Needs a lower-case `0x` prefix (Java accepts `0X`): normalised before parsing. Out-of-range decimals fall back to `Double` → ±∞/±0 like Java. |
| `Double.description` (shortest round-trip digits) | — (stdlib) | /documentation/swift/double/description | `KotlinText.formatFixed` | Digits for Java's `String.format("%.2f")` (`FormattedFloatingDecimal` half-up rounding on the shortest digits); 100 % match with the JVM vectors. |
| `ProcessInfo.processInfo.environment` | 2 | /documentation/foundation/processinfo/environment | `InteropDumpTests` (**tests only**) | Enables the dev-only interop dump. |
| `String(format:)` | 2 | /documentation/foundation/nsstring/init(format:_:) | test helpers (**tests only**) | Hex dumps in failure messages. |

`Foundation.pow` (already in the ledger) is used by `ReplayGainTags.gainDbToVolume`; bit-identical to the JVM on
Windows for all 494 vectors.

Deliberately **not** used in PixlTags: `NSRegularExpression`/`Regex` (the two ReplayGain regexes are hand-written in
`KotlinText`), `replacingOccurrences`/`components(separatedBy:)` on user text (canonical-equivalence matching differs
from Kotlin's per-char replace), zlib/Compression (compressed ID3v2 frames stay opaque).

For the app (stage 6): MP4/M4A tag write-back is meant to go through AVFoundation (`AVAssetExportSession` passthrough
with `metadata`), and reading normally through `AVURLAsset.load(.metadata)` with PixlTags as the fallback for FLAC,
SYLT and ReplayGain; neither is used yet, add the rows when stage 6 does.
