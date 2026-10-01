# Stage 3e — PixlBackup (API ledger additions, to fold into docs/api-notes.md)

Rows for "Foundation and the standard library in PixlCore (Windows + macOS)". All verified on Windows (Swift 6.4,
143 PixlBackup tests) and on the macOS `core` CI lane.

| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `withUnsafeTemporaryAllocation(of:capacity:_:)` | — (Swift 5.6 stdlib) | /documentation/swift/withunsafetemporaryallocation(of:capacity:_:) | `SHA256` message schedule (PixlBackup) | Stack scratch space for the 64-word schedule (no heap allocation per block). |
| `String(decoding:as:)` with `UTF16` | — (stdlib) | /documentation/swift/string/init(decoding:as:) | `ContentSanitizer.sanitizeString` | Rebuilds a string from Kotlin-style UTF-16 truncation. |
| `Float.description`, `Double.description` | — (stdlib) | /documentation/swift/double/description | `JavaNumberText` | Shortest round-trip digits, laid out like Java's `Float/Double.toString` (Gson writes floats that way). |
| `String.replacingOccurrences(of:with:)` | 2 | /documentation/foundation/nsstring/replacingoccurrences(of:with:) | `JavaNumbers.parseDouble`, `JavaNumberText.format` | ASCII literal tidy-up only (as in `ParseKit`). |
| `JSONDecoder` (`Codable`) | 7 | /documentation/foundation/jsondecoder | `PreferencesModule.customPresets/pinnedPresets` | Reads the equalizer module's kotlinx-encoded preset list into PixlModel's `EqualizerPreset` (Codable keys match). Already in the ledger for PixlModel. |
| `String.data(using:)` | 2 | /documentation/foundation/nsstring/data(using:) | `PreferencesModule` (UTF-8 for `JSONDecoder`) | |
| `Data(base64Encoded:)` | 7 | /documentation/foundation/data/init(base64encoded:options:) | tests only (inflate fixtures) | PixlBackup's own Base64 (`BackupBase64`) follows `android.util.Base64` and is what the sources use. |
| `NSString.deletingPathExtension`, `.pathExtension` | 2 | /documentation/foundation/nsstring/deletingpathextension | tests only (fixture names) | |
| `String.range(of:)`, `replacingCharacters(in:with:)` | 2 | /documentation/foundation/nsstring/range(of:) | tests only (masking a clock value) | |
| `Date()`, `Date.timeIntervalSince(_:)` | 2 | /documentation/foundation/date/timeintervalsince(_:) | tests only (inflate timing bound) | |

Deliberately **not** used in PixlBackup:
- **zlib / the Compression framework** (the architecture first planned to inject inflate from the app): Swift on
  Windows has neither, so PixlBackup has its own RFC 1951 inflater (`Archive/Inflate.swift`, checked against 44 JDK
  `Deflater` streams) and writes stored ZIP/gzip entries. The app can keep using it on iOS (backups are small JSON).
- **CryptoKit**: module checksums use a pure-Swift SHA-256 (`Archive/Checksums.swift`, NIST vectors); the app may inject
  CryptoKit's through `SHA256Hasher` (`BackupManager(hasher:)`, `BackupReader(hasher:)`, `BackupWriter.write(hasher:)`).
- `JSONSerialization` / `JSONEncoder` for the wire format: Gson's field order, escaping and number printing are
  reproduced by `GsonWriter`/`JavaNumberText` instead.
