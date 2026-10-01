# Apple API ledger

Every Apple API the app uses, with its documentation page and minimum OS. Add a row the first time you use
an API (AGENTS.md). "CI" = proven to compile on the `xcode-27` lane (Xcode 27.0, iOS 27 SDK) and the
`fallback-xcode26` lane (Xcode 26.6) unless noted. Paths are under https://developer.apple.com.

## App structure and navigation (SwiftUI)
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `App`, `WindowGroup`, `@main` | 14 | /documentation/swiftui/app | `PixlAudioApp` | Scene life cycle (required by the iOS 27 SDK). |
| `@Observable` macro, `@ObservationIgnored` | 17 | /documentation/observation/observable() | stores, `DiagnosticsModel` | Fine-grained stores. |
| `View.environment(_:)` (Observable object), `@Environment(T.self)`, `@Bindable` | 17 | /documentation/swiftui/view/environment(_:)-4516h | shell | |
| `TabView(selection:)` + `Tab(_:systemImage:value:content:)` | 18 | /documentation/swiftui/tab | `RootTabView` | |
| `Tab(value:role:content:)`, `TabRole.search` | 18 | /documentation/swiftui/tabrole/search | `RootTabView` | Search tab sits at the trailing end, glass search field. |
| `View.searchable(text:isPresented:prompt:)` | 17 | /documentation/swiftui/view/searchable(text:ispresented:placement:prompt:) | `RootTabView` | On the `TabView` (WWDC25 session 323 code). **iOS 27.0 simulator: a search-role tab shows no idle search field** (with or without the bottom accessory, on the TabView or the tab's stack — CI experiments on s00-bootstrap); the field appears only while search is presented, so selecting the Search tab sets `isPresented = true`. |
| `View.tabBarMinimizeBehavior(_:)`, `.onScrollDown` | 26.0 | /documentation/swiftui/view/tabbarminimizebehavior(_:) | `RootTabView` | |
| `View.tabViewBottomAccessory(isEnabled:content:)` | **26.1** | /documentation/swiftui/view/tabviewbottomaccessory(isenabled:content:) | `RootTabView` | Reason for the 26.1 deployment target. |
| `EnvironmentValues.tabViewBottomAccessoryPlacement`, `TabViewBottomAccessoryPlacement.inline/.expanded` | 26.0 | /documentation/swiftui/tabviewbottomaccessoryplacement | `MiniPlayerAccessory` | Optional value (nil outside an accessory). |
| `View.onChange(of:initial:_:)` (two-parameter closure) | 17 | /documentation/swiftui/view/onchange(of:initial:_:)-4psgg | `RootTabView` | |
| `NavigationStack(path:)`, `navigationDestination(for:destination:)`, `NavigationLink(value:)` | 16 | /documentation/swiftui/navigationstack | shell | Value types used as routes are `nonisolated` so `Hashable` isn't main-actor isolated. |
| `ToolbarItem(placement: .topBarTrailing)`, `Menu` | 17 / 14 | /documentation/swiftui/toolbaritemplacement/topbartrailing | Home, Library | Toolbar items get system glass. |
| `List`, `Section(_:content:)`, `Section(content:header:footer:)`, `Form`, `LabeledContent` | 13–16 | /documentation/swiftui/list | screens | Content layer, never glass. |
| `LazyVGrid`, `GridItem` | 14 | /documentation/swiftui/lazyvgrid | Search | |
| `ContentUnavailableView`, `.search(text:)` | 17 | /documentation/swiftui/contentunavailableview | Library, Search | |
| `swipeActions(edge:content:)`, `contextMenu(menuItems:)` | 15 / 13 | /documentation/swiftui/view/swipeactions(edge:allowsfullswipe:content:) | `SongRow` | |
| `Button(_:systemImage:role:action:)` | 17 | /documentation/swiftui/button | screens | |
| `symbolEffect(_:isActive:)`, `.variableColor.iterative` | 17 | /documentation/swiftui/view/symboleffect(_:options:isactive:) | `SongRow` | Now-playing indicator. |
| `contentTransition(.symbolEffect(.replace))` | 17 | /documentation/swiftui/contenttransition/symboleffect(_:options:) | mini player | |
| `fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:onCompletion:)` | 14 | /documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:allowsmultipleselection:oncompletion:) | Diagnostics | Result is `Result<[URL], any Error>`. |
| `UTType.folder` | 14 | /documentation/uniformtypeidentifiers/uttype-swift.struct/folder | Diagnostics | |
| `preferredColorScheme(_:)` | 13 | /documentation/swiftui/view/preferredcolorscheme(_:) | UI-test appearance | |
| `accessibilityIdentifier(_:)`, `accessibilityLabel(_:)` | 14 / 13 | /documentation/swiftui/view/accessibilityidentifier(_:) | UI tests, VoiceOver | |

## Playback, Now Playing, audio session
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `AVAudioSession.setCategory(_:mode:policy:options:)`, `.playback`, `.longFormAudio` | 13 | /documentation/avfaudio/avaudiosession/setcategory(_:mode:policy:options:) | Diagnostics tone | Architecture: `.longFormAudio` (fallback `.default` if AirPlay misbehaves). |
| `AVAudioSession.setActive(_:options:)`, `.notifyOthersOnDeactivation` | 6 | /documentation/avfaudio/avaudiosession/setactive(_:options:) | Diagnostics tone | |
| `AVQueuePlayer`, `AVPlayerItem(url:)`, `AVPlayerLooper(player:templateItem:)`, `disableLooping()` | 10 | /documentation/avfoundation/avplayerlooper | Diagnostics tone | |
| `MPNowPlayingInfoCenter.default().nowPlayingInfo` | 5 | /documentation/mediaplayer/mpnowplayinginfocenter | Diagnostics tone | Keys: `MPMediaItemPropertyTitle`, `MPMediaItemPropertyArtist`, `MPNowPlayingInfoPropertyIsLiveStream` (10.0), `MPNowPlayingInfoPropertyPlaybackRate`. |
| `MPRemoteCommandCenter.shared()`, `playCommand`/`pauseCommand`/`togglePlayPauseCommand`, `addTarget(handler:)`, `removeTarget(_:)` | 7.1 | /documentation/mediaplayer/mpremotecommandcenter | Diagnostics tone | Handler bodies wrapped in `MainActor.assumeIsolated` (delivered on main). |
| Info.plist `UIBackgroundModes: audio` | — | /documentation/bundleresources/information-property-list/uibackgroundmodes | project.yml | Also `fetch`, `processing` + `BGTaskSchedulerPermittedIdentifiers`. |

## Storage, security, files
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`, `kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock` | 2 / 4 | /documentation/security/secitemadd(_:_:) | `KeychainStore` | No access group (sideloaded builds). |
| `URL.bookmarkData(options: .minimalBookmark, …)`, `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)` | 4 | /documentation/foundation/url/bookmarkdata(options:includingresourcevaluesforkeys:relativeto:) | Diagnostics | iOS has no `.withSecurityScope`; pattern from "Providing access to directories" (/documentation/uikit/providing-access-to-directories). |
| `URL.startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` | 8 | /documentation/foundation/url/startaccessingsecurityscopedresource() | Diagnostics | |
| `UserDefaults` | 2 | /documentation/foundation/userdefaults | Diagnostics | Bookmark storage for the diagnostics check only. |

## Device, intelligence
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `UIWindowScene.screen`, `UIScreen.maximumFramesPerSecond` | 13 / 10.3 | /documentation/uikit/uiscreen/maximumframespersecond | Diagnostics | 120 on ProMotion with `CADisableMinimumFrameDurationOnPhone`. |
| Info.plist `CADisableMinimumFrameDurationOnPhone` | 15 | /documentation/quartzcore/optimizing-promotion-refresh-rates-for-iphone-13-pro-and-ipad-pro | project.yml | Unlocks >60 Hz for custom animations. |
| `SystemLanguageModel.default.availability` (`.available`, `.unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)`) | 26.0 | /documentation/foundationmodels/systemlanguagemodel/availability-swift.enum | Diagnostics | Runtime-gated; UI text never names the vendor. |
| `UIDevice.current.systemVersion` | 2 | /documentation/uikit/uidevice/systemversion | Diagnostics | |

## Info.plist keys (project.yml)
| Key | Docs | Notes |
|---|---|---|
| `CFBundleURLTypes` (`pixlaudio`) | /documentation/bundleresources/information-property-list/cfbundleurltypes | Spotify redirect `pixlaudio://spotify-callback`. |
| `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace` | /documentation/bundleresources/information-property-list/uifilesharingenabled | Documents folder in Files. |
| `CFBundleDocumentTypes`, `UTImportedTypeDeclarations`, `UTExportedTypeDeclarations` | /documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app | Audio, .lrc, .ttml, .m3u/.m3u8, .pxpl (exported). |
| `NSAppTransportSecurity.NSAllowsArbitraryLoads` | /documentation/bundleresources/information-property-list/nsapptransportsecurity | **Deviation:** `NSAllowsLocalNetworking` omitted — when present, iOS ignores `NSAllowsArbitraryLoads`, which would block user-typed HTTP AI endpoints. |
| `NSAppleMusicUsageDescription`, `NSLocalNetworkUsageDescription` | /documentation/bundleresources/information-property-list/nsapplemusicusagedescription | Strings never say "Apple Music". |
| `UILaunchScreen`, `UIApplicationSceneManifest` | /documentation/bundleresources/information-property-list/uilaunchscreen | |

## Foundation and the standard library in PixlCore (Windows + macOS)
PixlCore must build on swift-corelibs-foundation, so it sticks to these. Swift Testing is listed under Testing.
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `exp`, `log`, `sin`, `cos`, `acos`, `pow`, `cbrt` (C math re-exported by Foundation) | 2 | /documentation/foundation (Darwin libm) | `PixlFoundation` springs, Bézier, decay | Windows uses the UCRT libm; the Compose reference vectors are bit-identical on Windows (720/720 springs, 2508/2508 Bézier samples). |
| `Date().timeIntervalSince1970` | 2 | /documentation/foundation/date/timeintervalsince1970 | `currentTimeMillis()` (PixlModel) | Kotlin `System.currentTimeMillis()` defaults. |
| `JSONEncoder` / `JSONDecoder` (`Codable`) | 7 | /documentation/foundation/jsondecoder | PixlModel Codable conformances, tests | Not used for the Android wire format (key order and escaping are not guaranteed): `JSONWriter`/`JSONParser` in PixlFoundation do that. |
| `Bundle.module`, `Bundle.url(forResource:withExtension:subdirectory:)`, `String(contentsOf:encoding:)` | 2 | /documentation/foundation/bundle/url(forresource:withextension:subdirectory:) | PixlCore test fixtures | Verified on Windows (stage 2a). |
| `Unicode.Scalar.Properties.generalCategory`, `Character` (extended grapheme clusters) | — (stdlib) | /documentation/swift/unicode/scalar/properties-swift.struct/generalcategory | `TextScripts`, `TextSegmentation` | The stdlib has no Script or Bidi_Class property: those ranges are tabulated in `TextScripts`. |
| `cbrt`, `pow`, `log` (C math via Foundation) | 2 | (Darwin libm) | `PaletteExtractor` (Oklab), recommendation scores (PixlLibrary) | Recommendation scores are bit-identical to the JVM on Windows (stage 3a). |
| `Unicode.Scalar.Properties`: `isAlphabetic`, `isLowercase`, `isUppercase`, `isCased`, `isCaseIgnorable`, `lowercaseMapping`, `uppercaseMapping`, `titlecaseMapping`, `numericValue` | — (stdlib) | /documentation/swift/unicode/scalar/properties-swift.struct | PixlLyrics `ParseKit`, romanisers, `capitalizeFirstLetter`; PixlLibrary `KotlinText`, `SearchIndex.queryTokens` | Java `Character.getType`/`isLetterOrDigit`/`isLowerCase`/`titlecase`/`Character.digit`/`toUpperCase`/`toLowerCase`, Kotlin `lowercase()` with Java's Final_Sigma rule, `equals(ignoreCase)`, regex UNICODE_CASE folding, Java `\p{L}\p{N}`. |
| `String.decomposedStringWithCanonicalMapping` (NFD) | 2 | /documentation/foundation/nsstring/decomposedstringwithcanonicalmapping | `LrcLibMatching.normalizeForMatch` | Java `Normalizer.normalize(…, NFD)`. Hangul syllables decompose to conjoining jamo, as on Android. |
| `String.decomposedStringWithCompatibilityMapping` (NFKD) | 2 | /documentation/foundation/nsstring/decomposedstringwithcompatibilitymapping | `CatalogText.normalized` (AMLL/NetEase matching) | Java `Normalizer.normalize(…, NFKD)`. |
| `String.precomposedStringWithCanonicalMapping` / `precomposedStringWithCompatibilityMapping` | 2 | /documentation/foundation/nsstring/precomposedstringwithcanonicalmapping | `KotlinText.nfc` / `nfkc` (metadata repair, recommendation keys) | Java `Normalizer` NFC/NFKC; ASCII strings skip the call. |
| `String.replacingOccurrences(of:with:)` | 2 | /documentation/foundation/nsstring/replacingoccurrences(of:with:) | `ParseKit.parseDouble` (ASCII literal tidy-up only) | Not used on user text (it compares by canonical equivalence). |
| `String(validating:as:)` (`UTF8`, `UTF16`) | 18 (Swift 6.0 stdlib) | /documentation/swift/string/init(validating:as:) | `LyricsImportSecurity.decodeText` | Strict decoding (malformed input → nil), like Java's `CharsetDecoder` with `REPORT`. |
| `String.withUTF8(_:)`, `Hasher.combine(bytes:)`, `memcmp` | — (stdlib / C library) | /documentation/swift/string/withutf8(_:) | `KotlinKey`, `KotlinText.equals` | Code-unit string equality/hashing (Kotlin semantics) without per-byte overhead. |
| `Float(_: String)` (`LosslessStringConvertible`), `Float.description` | — (stdlib) | /documentation/swift/float/init(_:)-5wmm8 | `LyricsSyncDraftCodec` | Decimal parsing for kotlinx `decodeFloat` (Java `parseFloat` subset); `description` gives the shortest round-trip digits that `javaFloatString` lays out like Java's `Float.toString`. |
| `SIMD4<Float>` | — (stdlib) | /documentation/swift/simd4 | `LyricsBackgroundGrade`, `LyricsBackgroundMotion.shaderUniforms` | CPU reference of the lyrics background shader's float4 maths and uniforms. |
| `Synchronization.Mutex` (`withLock`) | 18 (Swift 6 stdlib; also on Windows) | /documentation/synchronization/mutex | `LyricsSprings.normal(gapMs:)` | Guards the process-wide normal-spring cache, which mirrors Android's `normalCache`. Not on a per-frame path except a line change. |
| `Task.yield()` | — (Swift concurrency) | /documentation/swift/task/yield() | `QueueUtils` async shuffle | Cooperative yield every 512 steps (Kotlin `yield()`). |
| `TimeZone(identifier:)`, `TimeZone.secondsFromGMT(for:)` | 2 | /documentation/foundation/timezone/secondsfromgmt(for:) | `ZoneClock` (stats day boundaries) | Only offsets are read; java.time's gap/overlap rules for `atStartOfDay` are implemented on top. IANA zones incl. historical rules (São Paulo 2018, Lord Howe, Chatham) match java.time on Windows. |
| `UUID().uuidString` | 6 | /documentation/foundation/uuid/uuidstring | `LyricsSyncDraftStore` temp file names | |
| `Data(contentsOf:)`, `Data.write(to:)` | 7 | /documentation/foundation/data/init(contentsof:options:) | `LyricsSyncDraftStore`, tests | |
| `URL.appendingPathComponent(_:isDirectory:)`, `URL.lastPathComponent` | 2 | /documentation/foundation/url/appendingpathcomponent(_:isdirectory:) | `LyricsSyncDraftStore` | |
| `FileManager.fileExists(atPath:isDirectory:)` (`ObjCBool`) | 2 | /documentation/foundation/filemanager/fileexists(atpath:isdirectory:) | `LyricsSyncDraftStore` | Paths from `URL.path`; works on Windows. |
| `FileManager.isReadableFile(atPath:)` | 2 | /documentation/foundation/filemanager/isreadablefile(atpath:) | `LyricsImportSecurity.validateLocalLyricsFile(at:)` | |
| `FileManager.attributesOfItem(atPath:)`, `FileAttributeKey.size`, `.modificationDate` | 2 | /documentation/foundation/filemanager/attributesofitem(atpath:) | `LyricsImportSecurity.validateLocalLyricsFile(at:)`, `LyricsSyncDraftStore` | `.size` read as `NSNumber` (both Foundations box it). |
| `FileManager.createDirectory(at:withIntermediateDirectories:attributes:)` | 5 | /documentation/foundation/filemanager/createdirectory(at:withintermediatedirectories:attributes:) | `LyricsSyncDraftStore.save` | |
| `FileManager.createFile(atPath:contents:attributes:)` | 2 | /documentation/foundation/filemanager/createfile(atpath:contents:attributes:) | `LyricsSyncDraftStore.save` | Creates the `draft-<uuid>.tmp` file. |
| `FileManager.contentsOfDirectory(atPath:)` | 2 | /documentation/foundation/filemanager/contentsofdirectory(atpath:) | `LyricsSyncDraftStore.pruneOlderThan` | |
| `FileManager.moveItem(at:to:)`, `removeItem(at:)` | 4 | /documentation/foundation/filemanager/moveitem(at:to:) | `LyricsSyncDraftStore` | |
| `FileManager.replaceItemAt(_:withItemAt:backupItemName:options:)` | 4 | /documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:) | `LyricsSyncDraftStore.replace` | Atomic replace of the draft. **Not implemented in swift-corelibs-foundation on Windows (traps)** — `#if os(Windows)` uses remove + move there (tests only). |
| `FileManager.setAttributes(_:ofItemAtPath:)`, `FileManager.temporaryDirectory` | 2 / 10 | /documentation/foundation/filemanager/setattributes(_:ofitematpath:) | tests | Back-dates a draft for the prune test; per-test temp folders (both work on Windows). |
| `FileHandle(forReadingFrom:)`, `read(upToCount:)`, `close()` | 13.4 | /documentation/foundation/filehandle/read(uptocount:) | `LyricsImportSecurity.validateLocalLyricsFile(at:)` | Reads at most the size cap + 1 byte. |
| `FileHandle(forWritingTo:)`, `write(contentsOf:)`, `synchronize()` | 4 / 13.4 / 13 | /documentation/foundation/filehandle/write(contentsof:) | `LyricsSyncDraftStore.save` | Throwing variants; `synchronize()` is the fsync Android does before the rename. |
| `XMLParser(data:)`, `shouldProcessNamespaces`, `XMLParserDelegate` | 2 | /documentation/foundation/xmlparser | `LyricsExportTests` (`XMLTree`), **tests only** | `import FoundationXML` under `#if canImport(FoundationXML)` (Windows/Linux). Namespaced attribute keys are looked up by qualified name with a local-name fallback. |

Deliberately **not** used in PixlCore sources:
- FoundationXML `XMLParser` (libxml2 on Windows, a different engine on Apple platforms, and neither rejects a DOCTYPE
  the way the Android configuration does): PixlLyrics has its own strict XML reader (`LyricsXML.swift`).
- Swift `Regex` / `NSRegularExpression` (ICU/JDK regex semantics differ in places): every pattern is hand-written in
  `ParseKit`, the parsers, `ArtistParsing` and `LyricsSheetLogic`, with the Java/device semantics documented there.
- CryptoKit: tap-sync draft file names use a plain-Swift SHA-1 (`Sync/SHA1.swift`, internal), a name hash identical
  to Android's `sha1(songId)`, not a security primitive.

For the app (stage 9): the lyrics engine's intended driver is a `CADisplayLink`
(/documentation/quartzcore/cadisplaylink) calling `LyricsEngine.step(frameNanos:positionMs:offsetMs:)`, pushing
`changedRows` into per-row observable state, then `clearChanges()` and pausing the link while `needsFrame` is false.
`rowBlurSigma` is meant for SwiftUI `View.blur(radius:opaque:)` (radius treated as σ in points; calibrate against
Android screenshots on device). Neither is in the ledger yet: add them when stage 9 first uses them.

## Testing and tooling
| API / tool | Docs | Notes |
|---|---|---|
| Swift Testing (`@Test`, `@Suite`, `#expect`, `#require`) | /documentation/testing | PixlCore (Windows + macOS). |
| `XCUIApplication.launchArguments`, `XCTAttachment(screenshot:)`, `.lifetime = .keepAlways`, `swipeUp(velocity:)` | /documentation/xctest/xctattachment | `UITests/ScreenshotTests`. |
| `xcrun xcresulttool export attachments` / `get test-results summary` | `man xcresulttool` (Xcode 16+) | `ci/export-shots.sh`, `ci/xcerrors.sh`. |
| `xcrun simctl list -j`, `boot`, `bootstatus -b`, `status_bar … override` | `xcrun simctl help` | `ci/pick-sim.sh`, shots job. |
