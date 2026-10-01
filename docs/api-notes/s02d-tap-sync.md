# API ledger additions — stage 2d (PixlLyrics tap-sync, export, draft store)

To be folded into `docs/api-notes.md` (section "Foundation and the standard library in PixlCore") by the integrator.
Paths are under https://developer.apple.com. All compile and pass on Windows (swift-corelibs-foundation, Swift 6.4)
except where noted; macOS is proven by the `core` CI job.

| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `FileManager.fileExists(atPath:isDirectory:)` (`ObjCBool`) | 2 | /documentation/foundation/filemanager/fileexists(atpath:isdirectory:) | `LyricsSyncDraftStore` | Paths from `URL.path`; works on Windows. |
| `FileManager.createDirectory(at:withIntermediateDirectories:attributes:)` | 5 | /documentation/foundation/filemanager/createdirectory(at:withintermediatedirectories:attributes:) | `LyricsSyncDraftStore.save` | |
| `FileManager.createFile(atPath:contents:attributes:)` | 2 | /documentation/foundation/filemanager/createfile(atpath:contents:attributes:) | `LyricsSyncDraftStore.save` | Creates the `draft-<uuid>.tmp` file. |
| `FileHandle(forWritingTo:)`, `write(contentsOf:)`, `synchronize()`, `close()` | 4 / 13.4 / 13 / 13 | /documentation/foundation/filehandle/write(contentsof:) | `LyricsSyncDraftStore.save` | Throwing variants; `synchronize()` is the fsync Android does before the rename. |
| `FileManager.replaceItemAt(_:withItemAt:backupItemName:options:)` | 4 | /documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:) | `LyricsSyncDraftStore.replace` | Atomic replace of the draft. **Not implemented in swift-corelibs-foundation on Windows (traps)** — `#if os(Windows)` uses remove + move there (tests only). |
| `FileManager.moveItem(at:to:)`, `removeItem(at:)` | 4 | /documentation/foundation/filemanager/moveitem(at:to:) | `LyricsSyncDraftStore` | |
| `FileManager.attributesOfItem(atPath:)`, `FileAttributeKey.size`, `.modificationDate` | 2 | /documentation/foundation/filemanager/attributesofitem(atpath:) | `LyricsSyncDraftStore` | Size read as `NSNumber` (portable across Darwin and corelibs). |
| `FileManager.contentsOfDirectory(atPath:)` | 2 | /documentation/foundation/filemanager/contentsofdirectory(atpath:) | `LyricsSyncDraftStore.pruneOlderThan` | |
| `FileManager.setAttributes(_:ofItemAtPath:)` | 2 | /documentation/foundation/filemanager/setattributes(_:ofitematpath:) | tests | Back-dates a draft for the prune test (works on Windows). |
| `FileManager.temporaryDirectory` | 10 | /documentation/foundation/filemanager/temporarydirectory | tests | Per-test temp folders. |
| `Data(contentsOf:)`, `Data.write(to:)` | 7 | /documentation/foundation/data/init(contentsof:options:) | store, tests | |
| `URL.appendingPathComponent(_:isDirectory:)`, `URL.lastPathComponent` | 2 | /documentation/foundation/url/appendingpathcomponent(_:isdirectory:) | `LyricsSyncDraftStore` | |
| `UUID().uuidString` | 6 | /documentation/foundation/uuid/uuidstring | temp file names | |
| `XMLParser(data:)`, `shouldProcessNamespaces`, `XMLParserDelegate` (`didStartElement…namespaceURI:qualifiedName:attributes:`, `didEndElement`, `foundCharacters`) | 2 | /documentation/foundation/xmlparser | `LyricsExportTests` (`XMLTree`) | Tests only. `import FoundationXML` under `#if canImport(FoundationXML)` (Windows/Linux). Namespaced attribute keys are looked up by qualified name with a local-name fallback. |
| `Float(_: String)` (`LosslessStringConvertible`), `Float.description` | — (stdlib) | /documentation/swift/float/init(_:)-5wmm8 | `LyricsSyncDraftCodec` | Decimal parsing for kotlinx `decodeFloat` (Java `parseFloat` subset); `description` gives the shortest round-trip digits that `javaFloatString` lays out like Java's `Float.toString`. |

No CryptoKit: draft file names use a plain-Swift SHA-1 (`Sync/SHA1.swift`, internal) — a name hash identical to
Android's `sha1(songId)`, not a security primitive.
