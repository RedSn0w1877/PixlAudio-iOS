# API ledger additions — stage 2b (PixlLyrics parsers)

Rows to fold into [`docs/api-notes.md`](../api-notes.md), section "Foundation and the standard library in PixlCore
(Windows + macOS)". All verified on Windows (Swift 6.4, swift-corelibs-foundation) by `swift test`; macOS by CI.
Paths are under https://developer.apple.com.

| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `String.decomposedStringWithCanonicalMapping` (NFD) | 2 | /documentation/foundation/nsstring/decomposedstringwithcanonicalmapping | `LrcLibMatching.normalizeForMatch` | Java `Normalizer.normalize(…, NFD)`. Hangul syllables decompose to conjoining jamo, as on Android. |
| `String.decomposedStringWithCompatibilityMapping` (NFKD) | 2 | /documentation/foundation/nsstring/decomposedstringwithcompatibilitymapping | `CatalogText.normalized` (AMLL/NetEase matching) | Java `Normalizer.normalize(…, NFKD)`. |
| `String.replacingOccurrences(of:with:)` | 2 | /documentation/foundation/nsstring/replacingoccurrences(of:with:) | `ParseKit.parseDouble` (ASCII literal tidy-up only) | Not used on user text (it compares by canonical equivalence). |
| `String(validating:as:)` (`UTF8`, `UTF16`) | 18 (Swift 6.0 stdlib) | /documentation/swift/string/init(validating:as:) | `LyricsImportSecurity.decodeText` | Strict decoding (malformed input → nil), like Java's `CharsetDecoder` with `REPORT`. |
| `FileManager.isReadableFile(atPath:)`, `attributesOfItem(atPath:)` (`.size`) | 2 | /documentation/foundation/filemanager/isreadablefile(atpath:) | `LyricsImportSecurity.validateLocalLyricsFile(at:)` | `.size` read as `NSNumber` (both Foundations box it). |
| `FileHandle(forReadingFrom:)`, `read(upToCount:)`, `close()` | 13.4 | /documentation/foundation/filehandle/read(uptocount:) | `LyricsImportSecurity.validateLocalLyricsFile(at:)` | Reads at most the size cap + 1 byte. |
| `Unicode.Scalar.Properties`: `generalCategory`, `isAlphabetic`, `isLowercase`, `isUppercase`, `isCased`, `isCaseIgnorable`, `titlecaseMapping`, `numericValue` | — (stdlib) | /documentation/swift/unicode/scalar/properties-swift.struct | `ParseKit`, romanisers, `capitalizeFirstLetter` | Java `Character.getType`/`isLetterOrDigit`/`isLowerCase`/`titlecase`/`Character.digit`, and Java's Final_Sigma rule in `ParseKit.lowercased`. |

Deliberately **not** used: FoundationXML `XMLParser` (libxml2 on Windows, a different engine on Apple platforms, and
neither rejects a DOCTYPE the way the Android configuration does) — PixlLyrics has its own strict XML reader
(`LyricsXML.swift`); Swift `Regex`/`NSRegularExpression` (ICU/JDK regex semantics differ in places — every pattern
is hand-written in `ParseKit`/the parsers with the device (ICU) semantics documented there).
