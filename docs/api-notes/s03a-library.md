# API ledger additions — stage 3a (PixlLibrary)

Rows to fold into `docs/api-notes.md` ("Foundation and the standard library in PixlCore"). All verified on Windows
(swift-corelibs-foundation, Swift 6.4) by the stage 3a tests; macOS on CI.

| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `String.precomposedStringWithCanonicalMapping` / `precomposedStringWithCompatibilityMapping` | 2 | /documentation/foundation/nsstring/precomposedstringwithcanonicalmapping | `KotlinText.nfc` / `nfkc` (metadata repair, recommendation keys) | Java `Normalizer` NFC/NFKC; ASCII strings skip the call. |
| `TimeZone(identifier:)`, `TimeZone.secondsFromGMT(for:)` | 2 | /documentation/foundation/timezone/secondsfromgmt(for:) | `ZoneClock` (stats day boundaries) | Only offsets are read; java.time's gap/overlap rules for `atStartOfDay` are implemented on top. IANA zones incl. historical rules (São Paulo 2018, Lord Howe, Chatham) match java.time on Windows. |
| `String.withUTF8(_:)`, `Hasher.combine(bytes:)` | — (stdlib) | /documentation/swift/string/withutf8(_:) | `KotlinKey`, `KotlinText.equals` | Code-unit string equality/hashing (Kotlin semantics) without per-byte overhead. |
| `memcmp` | — (C library via Foundation) | — | `KotlinText.equals` | |
| `Unicode.Scalar.Properties.lowercaseMapping` / `uppercaseMapping` / `titlecaseMapping`, `.isCased`, `.isCaseIgnorable`, `.generalCategory` | — (stdlib) | /documentation/swift/unicode/scalar/properties-swift.struct | `KotlinText` case mapping, `SearchIndex.queryTokens` | Kotlin `lowercase()` (with final sigma), `equals(ignoreCase)`, regex UNICODE_CASE folding, Java `\p{L}\p{N}`. |
| `Task.yield()` | — (Swift concurrency) | /documentation/swift/task/yield() | `QueueUtils` async shuffle | Cooperative yield every 512 steps (Kotlin `yield()`). |
| `cbrt`, `pow`, `log` (C math via Foundation) | 2 | — | `PaletteExtractor` (Oklab), recommendation scores | Recommendation scores are bit-identical to the JVM on Windows. |

No Apple-only API is used: PixlLibrary stays Foundation-core + stdlib.
