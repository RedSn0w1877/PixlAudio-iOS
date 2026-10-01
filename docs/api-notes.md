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
| `TabView(selection:)` + `Tab(_:systemImage:value:content:)` | 18 | /documentation/swiftui/tab | `RootTabView` |  **No longer used since stage 4** (decision 10: PixlAudio's custom shell and screens replace the system tab bar, accessory and plain lists; kept as the record of stage 0). |
| `Tab(value:role:content:)`, `TabRole.search` | 18 | /documentation/swiftui/tabrole/search | `RootTabView` | Search tab sits at the trailing end, glass search field.  **No longer used since stage 4** (decision 10: PixlAudio's custom shell and screens replace the system tab bar, accessory and plain lists; kept as the record of stage 0). |
| `View.searchable(text:isPresented:prompt:)` | 17 | /documentation/swiftui/view/searchable(text:ispresented:placement:prompt:) | `RootTabView` | On the `TabView` (WWDC25 session 323 code). **iOS 27.0 simulator: a search-role tab shows no idle search field** (with or without the bottom accessory, on the TabView or the tab's stack — CI experiments on s00-bootstrap); the field appears only while search is presented, so selecting the Search tab sets `isPresented = true`.  **No longer used since stage 4** (decision 10: PixlAudio's custom shell and screens replace the system tab bar, accessory and plain lists; kept as the record of stage 0). |
| `View.tabBarMinimizeBehavior(_:)`, `.onScrollDown` | 26.0 | /documentation/swiftui/view/tabbarminimizebehavior(_:) | `RootTabView` |  **No longer used since stage 4** (decision 10: PixlAudio's custom shell and screens replace the system tab bar, accessory and plain lists; kept as the record of stage 0). |
| `View.tabViewBottomAccessory(isEnabled:content:)` | **26.1** | /documentation/swiftui/view/tabviewbottomaccessory(isenabled:content:) | `RootTabView` | Reason for the 26.1 deployment target.  **No longer used since stage 4** (decision 10: PixlAudio's custom shell and screens replace the system tab bar, accessory and plain lists; kept as the record of stage 0). |
| `EnvironmentValues.tabViewBottomAccessoryPlacement`, `TabViewBottomAccessoryPlacement.inline/.expanded` | 26.0 | /documentation/swiftui/tabviewbottomaccessoryplacement | `MiniPlayerAccessory` | Optional value (nil outside an accessory).  **No longer used since stage 4** (decision 10: PixlAudio's custom shell and screens replace the system tab bar, accessory and plain lists; kept as the record of stage 0). |
| `View.onChange(of:initial:_:)` (two-parameter closure) | 17 | /documentation/swiftui/view/onchange(of:initial:_:)-4psgg | `RootTabView` | |
| `NavigationStack(path:)`, `navigationDestination(for:destination:)`, `NavigationLink(value:)` | 16 | /documentation/swiftui/navigationstack | shell | Value types used as routes are `nonisolated` so `Hashable` isn't main-actor isolated. |
| `ToolbarItem(placement: .topBarTrailing)`, `Menu` | 17 / 14 | /documentation/swiftui/toolbaritemplacement/topbartrailing | Home, Library | Toolbar items get system glass. |
| `List`, `Section(_:content:)`, `Section(content:header:footer:)`, `Form`, `LabeledContent` | 13–16 | /documentation/swiftui/list | screens | Content layer, never glass.  **No longer used since stage 4** (decision 10: PixlAudio's custom shell and screens replace the system tab bar, accessory and plain lists; kept as the record of stage 0). |
| `LazyVGrid`, `GridItem` | 14 | /documentation/swiftui/lazyvgrid | Search |  **No longer used since stage 4** (decision 10: PixlAudio's custom shell and screens replace the system tab bar, accessory and plain lists; kept as the record of stage 0). |
| `ContentUnavailableView`, `.search(text:)` | 17 | /documentation/swiftui/contentunavailableview | Library, Search |  **No longer used since stage 4** (decision 10: PixlAudio's custom shell and screens replace the system tab bar, accessory and plain lists; kept as the record of stage 0). |
| `swipeActions(edge:content:)`, `contextMenu(menuItems:)` | 15 / 13 | /documentation/swiftui/view/swipeactions(edge:allowsfullswipe:content:) | `SongRow` |  **No longer used since stage 4** (decision 10: PixlAudio's custom shell and screens replace the system tab bar, accessory and plain lists; kept as the record of stage 0). |
| `Button(_:systemImage:role:action:)` | 17 | /documentation/swiftui/button | screens | |
| `symbolEffect(_:isActive:)`, `.variableColor.iterative` | 17 | /documentation/swiftui/view/symboleffect(_:options:isactive:) | `SongRow` | Now-playing indicator.  **No longer used since stage 4** (decision 10: PixlAudio's custom shell and screens replace the system tab bar, accessory and plain lists; kept as the record of stage 0). |
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
| `JSONEncoder` / `JSONDecoder` (`Codable`) | 7 | /documentation/foundation/jsondecoder | PixlModel Codable conformances, `PreferencesModule.customPresets/pinnedPresets` (PixlBackup: kotlinx-encoded EQ presets into `EqualizerPreset`), tests | Not used for the Android wire format (key order and escaping are not guaranteed): `JSONWriter`/`JSONParser` in PixlFoundation do that. |
| `Bundle.module`, `Bundle.url(forResource:withExtension:subdirectory:)`, `String(contentsOf:encoding:)` | 2 | /documentation/foundation/bundle/url(forresource:withextension:subdirectory:) | PixlCore test fixtures | Verified on Windows (stage 2a). |
| `Unicode.Scalar.Properties.generalCategory`, `Character` (extended grapheme clusters) | — (stdlib) | /documentation/swift/unicode/scalar/properties-swift.struct/generalcategory | `TextScripts`, `TextSegmentation` | The stdlib has no Script or Bidi_Class property: those ranges are tabulated in `TextScripts`. |
| `cbrt`, `pow`, `log` (C math via Foundation) | 2 | (Darwin libm) | `PaletteExtractor` (Oklab), recommendation scores (PixlLibrary) | Recommendation scores are bit-identical to the JVM on Windows (stage 3a). |
| `cos`, `sin`, `pow`, `log`, `log10`, `exp`, `tanh` (C math via Foundation) | 2 | (Darwin libm) | `TransitionEnvelope` (S-curve), `ReplayGain.gainDbToVolume`, `BiquadDesigner`, `EqualizerResponse`, `SoftLimiter`, `Fft` twiddles (PixlAudioCore); `ReplayGainTags.gainDbToVolume` (PixlTags) | FFT, envelope and ReplayGain vectors are bit-identical to the JVM on Windows (UCRT libm) and macOS arm64; tests allow 2 ulps where `cos`/`pow` feed the result. PixlTags' `gainDbToVolume` is bit-identical for all 494 vectors. |
| `Unicode.Scalar.Properties`: `isAlphabetic`, `isLowercase`, `isUppercase`, `isCased`, `isCaseIgnorable`, `lowercaseMapping`, `uppercaseMapping`, `titlecaseMapping`, `numericValue` | — (stdlib) | /documentation/swift/unicode/scalar/properties-swift.struct | PixlLyrics `ParseKit`, romanisers, `capitalizeFirstLetter`; PixlLibrary `KotlinText`, `SearchIndex.queryTokens` | Java `Character.getType`/`isLetterOrDigit`/`isLowerCase`/`titlecase`/`Character.digit`/`toUpperCase`/`toLowerCase`, Kotlin `lowercase()` with Java's Final_Sigma rule, `equals(ignoreCase)`, regex UNICODE_CASE folding, Java `\p{L}\p{N}`. |
| `String.decomposedStringWithCanonicalMapping` (NFD) | 2 | /documentation/foundation/nsstring/decomposedstringwithcanonicalmapping | `LrcLibMatching.normalizeForMatch` | Java `Normalizer.normalize(…, NFD)`. Hangul syllables decompose to conjoining jamo, as on Android. |
| `String.decomposedStringWithCompatibilityMapping` (NFKD) | 2 | /documentation/foundation/nsstring/decomposedstringwithcompatibilitymapping | `CatalogText.normalized` (AMLL/NetEase matching), `TrackMatcher.normalize` (PixlNet) | Java `Normalizer.normalize(…, NFKD)`. |
| `String.precomposedStringWithCanonicalMapping` / `precomposedStringWithCompatibilityMapping` | 2 | /documentation/foundation/nsstring/precomposedstringwithcanonicalmapping | `KotlinText.nfc` / `nfkc` (metadata repair, recommendation keys) | Java `Normalizer` NFC/NFKC; ASCII strings skip the call. |
| `String.replacingOccurrences(of:with:)` | 2 | /documentation/foundation/nsstring/replacingoccurrences(of:with:) | `ParseKit.parseDouble`, `JavaNumbers.parseDouble`, `JavaNumberText.format` (ASCII literal tidy-up only); PixlNet parsing helpers and AI response cleaner | Not used on user text in PixlLyrics/PixlTags/PixlBackup (it compares by canonical equivalence). |
| `String(decoding:as:)` (`UTF8`, `UTF16`) | — (stdlib) | /documentation/swift/string/init(decoding:as:) | `TagText` (ID3v2/Vorbis/MP4 text, PixlTags), `ContentSanitizer.sanitizeString` (PixlBackup) | Replacement-character decoding like TagLib's lenient `String` constructors (results cut at the first NUL like TagLib); rebuilds strings after Kotlin-style UTF-16 truncation. |
| `String(validating:as:)` (`UTF8`, `UTF16`) | 18 (Swift 6.0 stdlib) | /documentation/swift/string/init(validating:as:) | `LyricsImportSecurity.decodeText` | Strict decoding (malformed input → nil), like Java's `CharsetDecoder` with `REPORT`. |
| `String.withUTF8(_:)`, `Hasher.combine(bytes:)`, `memcmp` | — (stdlib / C library) | /documentation/swift/string/withutf8(_:) | `KotlinKey`, `KotlinText.equals` | Code-unit string equality/hashing (Kotlin semantics) without per-byte overhead. |
| `Float(_: String)` (`LosslessStringConvertible`), `Float.description`, `Double.description` | — (stdlib) | /documentation/swift/float/init(_:)-5wmm8 | `LyricsSyncDraftCodec`; `KotlinText.toFloatOrNull` (ReplayGain tags, PixlAudioCore + PixlTags); `KotlinText.formatFixed` (PixlTags); `JavaNumberText` (PixlBackup) | Decimal parsing for kotlinx `decodeFloat` (Java `parseFloat` subset) and Kotlin `toFloatOrNull` (correctly rounded; out-of-range literals fall back to `Double` → ±∞/±0 like Java). **Hex literals need a lower-case `0x…p…`: on Windows "0X1P-2" reads as 0**, so literals are lower-cased first. `description` gives the shortest round-trip digits, laid out like Java's `Float/Double.toString` and Java's `%.2f` (`FormattedFloatingDecimal` half-up on the shortest digits). |
| `SIMD4<Float>` | — (stdlib) | /documentation/swift/simd4 | `LyricsBackgroundGrade`, `LyricsBackgroundMotion.shaderUniforms` | CPU reference of the lyrics background shader's float4 maths and uniforms. |
| `Synchronization.Mutex` (`withLock`) | 18 (Swift 6 stdlib; also on Windows) | /documentation/synchronization/mutex | `LyricsSprings.normal(gapMs:)`; `Fft` Bluestein plan cache (PixlAudioCore) | Guards the process-wide normal-spring cache, which mirrors Android's `normalCache`. Not on a per-frame path except a line change. |
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
| `Unicode.Scalar.Properties.generalCategory` (`.spaceSeparator`, `.lineSeparator`, `.paragraphSeparator`) | — (stdlib) | /documentation/swift/unicode/scalar/properties-swift.struct/generalcategory | `KotlinText.isWhitespace` (Kotlin `trim()`, PixlAudioCore) | |
| `Array.withUnsafeMutableBufferPointer`, `UnsafeMutablePointer<Float>` | — (stdlib) | /documentation/swift/array/withunsafemutablebufferpointer(_:) | `BiquadCascade`, `Fft.Workspace`, per-buffer processors (PixlAudioCore) | Per-buffer functions take caller buffers and never allocate (uniquely owned storage). |
| `withUnsafeTemporaryAllocation(of:capacity:_:)` | — (Swift 5.6 stdlib) | /documentation/swift/withunsafetemporaryallocation(of:capacity:_:) | `SHA256` message schedule (PixlBackup) | Stack scratch space for the 64-word schedule (no heap allocation per block). |
| `CancellationError`, `withCheckedThrowingContinuation(_:)`, `withTaskCancellationHandler(operation:onCancel:)`, `withThrowingTaskGroup`, `withTaskGroup`, `Task.sleep(nanoseconds:)`, `Task.checkCancellation()` | 13 | /documentation/swift/withcheckedthrowingcontinuation(isolation:function:_:) | `CtcAlignmentCore.align(checkCancelled:)` callers (PixlAudioCore); `URLSessionHTTPClient`, `withTimeout(seconds:_:)`, `LrcLibClient.runStrategiesFast`, retries (PixlNet) | Kotlin `withTimeoutOrNull`, `suspendCancellableCoroutine`, `CancellationException` and the "first non-empty batch wins" channel race. The app passes `{ try Task.checkCancellation() }` to the CTC aligner. |
| `URLSession.dataTask(with:completionHandler:)`, `URLRequest` (`httpMethod`, `addValue(_:forHTTPHeaderField:)`, `httpBody`, `timeoutInterval`), `HTTPURLResponse.statusCode`/`allHeaderFields`, `URLSessionTask.cancel()` | 7 | /documentation/foundation/urlsession/datatask(with:completionhandler:) | `URLSessionHTTPClient` (PixlNet) | Imported via `#if canImport(FoundationNetworking)` off Apple platforms. Completion-handler API (not `data(for:)`) so it builds on corelibs too; cancellation bridged with `withTaskCancellationHandler`. The app may use it directly or inject its own `HTTPClient`. Tests never touch the network. |
| `NSRegularExpression(pattern:options:)`, `firstMatch(in:options:range:)`, `NSTextCheckingResult.range(at:)`, `NSRegularExpression.escapedPattern(for:)`, `NSString.substring(with:)` | 4 | /documentation/foundation/nsregularexpression | `SignatureCipher` (base.js extraction, PixlNet) | Android's patterns used verbatim (ICU and java.util.regex agree on them for ASCII JavaScript; golden vectors pass). UTF-16 ranges, like Kotlin indices. |
| `NSLock` | 2 | /documentation/foundation/nslock | `URLSessionHTTPClient` task box (PixlNet) | Only in synchronous helpers (Swift 6 forbids `lock()` in async contexts). |
| `String.trimmingCharacters(in:)`, `CharacterSet(charactersIn:)`, `String.components(separatedBy:)`, `String.range(of:options:)` | 2 | /documentation/foundation/nsstring/trimmingcharacters(in:) | org.json number coercion, parsing helpers, AI response cleaner (PixlNet) | |
| `Data(base64Encoded:)`, `Data.base64EncodedString()` | 7 | /documentation/foundation/data/init(base64encoded:options:) | `VorbisComment` (`METADATA_BLOCK_PICTURE`, `COVERART`), `FLACPicture.vorbisPictureBlock` (PixlTags); PixlBackup tests (inflate fixtures) | Android's `Base64.NO_WRAP` = no options. PixlBackup's sources use their own `BackupBase64` (follows `android.util.Base64`). |
| `String.data(using:)` | 2 | /documentation/foundation/nsstring/data(using:) | `PreferencesModule` (UTF-8 for `JSONDecoder`, PixlBackup) | |
| `ProcessInfo.processInfo.environment` | 2 | /documentation/foundation/processinfo/environment | `InteropDumpTests` (PixlTags, **tests only**) | Enables the dev-only interop dump. |
| `String(format:)`, `NSString.deletingPathExtension`/`.pathExtension`, `String.range(of:)`/`replacingCharacters(in:with:)`, `Date.timeIntervalSince(_:)` | 2 | /documentation/foundation/nsstring/init(format:_:) | **tests only** (PixlTags hex dumps; PixlBackup fixture names, clock masking, inflate timing bound) | |

Deliberately **not** used in PixlCore sources:
- FoundationXML `XMLParser` (libxml2 on Windows, a different engine on Apple platforms, and neither rejects a DOCTYPE
  the way the Android configuration does): PixlLyrics has its own strict XML reader (`LyricsXML.swift`).
- Swift `Regex` / `NSRegularExpression` (ICU/JDK regex semantics differ in places): every pattern is hand-written in
  `ParseKit`, the parsers, `ArtistParsing`, `LyricsSheetLogic`, PixlTags' `KotlinText` (the two ReplayGain regexes)
  and PixlNet's `NetText` (java.util.regex ASCII classes), with the Java/device semantics documented there.
  **One exception:** PixlNet's `SignatureCipher` runs Android's base.js patterns through `NSRegularExpression`
  (see the table).
- CryptoKit: tap-sync draft file names and SAPISIDHASH use a plain-Swift SHA-1 (internal), not a security primitive.
  SHA-256 is injected by the app where it matters (PixlNet `SHA256Function` for PKCE, synthetic YouTube ids and AI
  cache keys, plus `randomBytes`); PixlBackup has a pure-Swift SHA-256 (`Archive/Checksums.swift`, NIST vectors) for
  module checksums, replaceable through `SHA256Hasher` (`BackupManager(hasher:)`, `BackupReader(hasher:)`,
  `BackupWriter.write(hasher:)`).
- **zlib / the Compression framework** (the architecture first planned to inject inflate from the app): Swift on
  Windows has neither, so PixlBackup has its own RFC 1951 inflater (`Archive/Inflate.swift`, checked against 44 JDK
  `Deflater` streams) and writes stored ZIP/gzip entries; PixlTags keeps compressed ID3v2 frames opaque. The app can
  keep using the inflater on iOS (backups are small JSON).
- `JSONSerialization` / `JSONEncoder` for Android wire formats: Gson's field order, escaping and number printing are
  reproduced by `GsonWriter`/`JavaNumberText` (PixlBackup), org.json's by `OrgJSONWriter` (PixlNet).
- `replacingOccurrences`/`components(separatedBy:)` on user text in PixlTags (canonical-equivalence matching differs
  from Kotlin's per-char replace).

For the app (stage 9): the lyrics engine's intended driver is a `CADisplayLink`
(/documentation/quartzcore/cadisplaylink) calling `LyricsEngine.step(frameNanos:positionMs:offsetMs:)`, pushing
`changedRows` into per-row observable state, then `clearChanges()` and pausing the link while `needsFrame` is false.
`rowBlurSigma` is meant for SwiftUI `View.blur(radius:opaque:)` (radius treated as σ in points; calibrate against
Android screenshots on device). Neither is in the ledger yet: add them when stage 9 first uses them.

For the app (playback stage 5, EQ screen 7d), from PixlAudioCore (stage 3b):
- `BiquadCoefficients.vDSPOrder` is `[b0, b1, b2, a1, a2]` normalised by a0 (ledgered in "Stage 5": the Float setup
  is `vDSP_biquadm_CreateSetup`, and multichannel coefficients are transposed per coefficient).
- `CrossfadeRamp.apply` / `ReplayGainStage.process` / `EqualizerProcessor.process` / `MidSideVocal.process` operate in
  place on interleaved (or planar) Float buffers from a processing tap; state structs must be uniquely owned by the tap
  context so array storage is never copied on the render thread.

For the app (stages 11–13), from PixlNet (stage 3c): SHA-256 and random bytes are injected (`SHA256Function`,
`randomBytes`); JavaScript (signature/`n` functions) runs through `JavaScriptEvaluating` (JavaScriptCore `JSContext` in
stage 11). PixlNet deviations from Android:
- Gson/kotlinx DTO decoding is lenient: a field of the wrong JSON type reads as absent instead of failing the whole
  response (Spotify, Google OAuth, AI responses). Gemini/OpenAI responses whose required fields are missing are still
  treated as failures, with the same error classes.
- `HTTPResponse` has no reason phrase: provider errors use the standard HTTP/1.1 phrase (`HTTPReason`) as OkHttp's
  `response.message` fallback.
- LRCLIB User-Agent is `PixlAudio/1.0 (iOS; Music Player)` (Android's OkHttp interceptor sent
  `PixelPlayer/1.0 (Android; Music Player)` to every non-YouTube host); AMLL/NetEase send `LyricsHTTP.userAgent`.
- Spotify redirect is `pixlaudio://spotify-callback` (`SpotifyAuth.redirectURI`); Android's is kept as
  `androidRedirectURI`. `SpotifyTrackRecord.toSong()` ids use the iOS `sp:` prefix.
- Formats: `AudioFormatPolicy.iOS` (default for `ChainedYouTubeStreamResolver`) only picks AAC/MP4 (141/140/139) then
  itag 18; Piped picks AAC audio streams by default (`aacOnly`). Android's `pickBestAudio` is kept as `.android`.
- `InnerTubeRequests.nextBody`/`browseBody` are Swift-only builders (Android never called `next`/`browse`).
- The Spotify session keeps a rotated refresh token in memory when persisting it fails (and reports the failure), so the
  next refresh in the same process still uses the newest token.
- User-facing diagnostic strings keep Android's wording (some Spanish, e.g. "respondió HTTP 400", "Refresco de token
  fallido"); the UI stages decide what to show.

For the app (stage 6), from PixlTags (stage 3d): MP4/M4A tag write-back is meant to go through AVFoundation
(`AVAssetExportSession` passthrough with `metadata`), and reading normally through `AVURLAsset.load(.metadata)` with
PixlTags as the fallback for FLAC, SYLT and ReplayGain; neither is used yet, add the rows when stage 6 does.

## Stage 4 — design system, shell, persistence, artwork
Proven on the `xcode-27` lane by the stage-4 build (fallback lane: its next weekly run).

### Liquid Glass and SwiftUI
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `View.glassEffect(_:in:)` | 26.0 | /documentation/swiftui/view/glasseffect(_:in:) | `pixlGlass`, every design-system component | Default shape is a capsule; we always pass the shape. |
| `Glass` `.regular`, `.tint(_:)` (`Color?`), `.interactive(_:)` | 26.0 | /documentation/swiftui/glass | `GlassStyle.swift` | Tint = the PixlAudio role Android filled with (`GlassTint` strengths). |
| `GlassEffectContainer(spacing:content:)` | 26.0 | /documentation/swiftui/glasseffectcontainer | `GlassPillRow`, Home quick actions, Library action row | Spacing below the visual gap so capsules never blend at rest. |
| `View.glassEffectID(_:in:)` (`(some Hashable & Sendable)?`) | 26.0 | /documentation/swiftui/view/glasseffectid(_:in:) | `GlassPillRow` | One shared id for the selected capsule → its tinted glass morphs to the new selection. The id enum is `nonisolated` (Sendable under default MainActor isolation). |
| `@Namespace`, `View.matchedGeometryEffect(id:in:properties:anchor:isSource:)` | 14 | /documentation/swiftui/view/matchedgeometryeffect(id:in:properties:anchor:issource:) | `GlassNavBar` | Glides the glass selection bubble between bar items. |
| `UnevenRoundedRectangle(topLeadingRadius:bottomLeadingRadius:bottomTrailingRadius:topTrailingRadius:style:)` | 16 | /documentation/swiftui/unevenroundedrectangle | `GlassNavBar`, `MiniPlayerBar` | PixlAudio's 32 / 10 pt corners where the mini player meets the bar. |
| `RoundedRectangle(cornerRadius:style: .continuous)`, `Capsule`, `Circle`, `contentShape(_:)` | 13 | /documentation/swiftui/roundedrectangle | components | |
| `@Entry` (custom `EnvironmentValues`), `View.environment(_:_:)` (key path) | 13 (macro back-deploys; Xcode 16+) | /documentation/swiftui/entry() | `\.appTheme`, `\.playerTheme` | Change only on song / scheme change. |
| `View.safeAreaInset(edge:alignment:spacing:content:)` | 15 | /documentation/swiftui/view/safeareainset(edge:alignment:spacing:content:)-6gwby | `RootView` | Mini player + bar float over content; scroll views inset automatically. |
| `View.sheet(item:onDismiss:content:)`, `View.fullScreenCover(item:onDismiss:content:)` | 14 | /documentation/swiftui/view/sheet(item:ondismiss:content:) | `RootView` | `AppSheet` / `AppCover` are `Identifiable`. |
| `presentationDetents(_:)`, `presentationDragIndicator(_:)` | 16 | /documentation/swiftui/view/presentationdetents(_:) | `.pixlSheet()` | The system sheet keeps its glass background. |
| `View.sensoryFeedback(_:trigger:)` (`.selection`, `.impact(weight:)`) | 17 | /documentation/swiftui/view/sensoryfeedback(_:trigger:) | bar, pill row, mini player | Android `TextHandleMove` haptics. |
| `symbolEffect(.variableColor.iterative.reversing, isActive:)` | 17 | /documentation/swiftui/view/symboleffect(_:options:isactive:) | `PlayingIndicator` | System-driven: no per-frame view updates. |
| `View.scrollClipDisabled(_:)`, `scrollIndicators(_:)` | 17 / 16 | /documentation/swiftui/view/scrollclipdisabled(_:) | pill rows | Glass edges aren't clipped by the horizontal scroll view. |
| `toolbar(_:for:)` (`.hidden`, `.navigationBar`), `navigationBarTitleDisplayMode(_:)`, `ToolbarItem(placement: .cancellationAction / .confirmationAction)` | 16 / 14 | /documentation/swiftui/view/toolbar(_:for:) | tab roots, placeholders | Root screens draw PixlAudio's own headers. |
| `EnvironmentValues.dynamicTypeSize`, `DynamicTypeSize` | 15 | /documentation/swiftui/dynamictypesize | `PixlFontModifier` | sp-like scaling of PixlAudio's fixed sizes (cap 1.6×). |
| `Font.system(size:weight:)`, `tracking(_:)`, `lineSpacing(_:)`, `minimumScaleFactor(_:)` | 13–16 | /documentation/swiftui/font/system(size:weight:design:) | `Typography.swift`, headers | SF Pro only. |
| `Image(decorative:scale:orientation:)` (CGImage), `interpolation(_:)` | 13 | /documentation/swiftui/image/init(decorative:scale:orientation:) | `ArtworkView` | |
| `View.task(id:priority:_:)` | 15 | /documentation/swiftui/view/task(id:priority:_:) | `ArtworkView`, `RootView` theme update | Cancelled when the id changes. |
| `ButtonStyle` (`configuration.isPressed`) | 13 | /documentation/swiftui/buttonstyle | `PressScaleButtonStyle` | Press feedback for fills sitting on glass. |
| `accessibilityElement(children:)`, `accessibilityAddTraits(_:)`, `accessibilityHint(_:)` | 14 | /documentation/swiftui/view/accessibilityaddtraits(_:) | components | |

### SwiftData
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `VersionedSchema` (`versionIdentifier`, `models`), `Schema.Version`, `Schema(versionedSchema:)` | 17 | /documentation/swiftdata/versionedschema | `SchemaV1` | Store-only models, string ids. |
| `SchemaMigrationPlan` (`schemas`, `stages`), `MigrationStage` | 17 | /documentation/swiftdata/schemamigrationplan | `PixlMigrationPlan` | Empty until v2. |
| `@Model`, `@Attribute(.unique)` | 17 | /documentation/swiftdata/model() | `SchemaV1` | Models are `nonisolated` (SE-0449) so the model actor can use them under default MainActor isolation. |
| `#Index<T>(_:)` | 18 | /documentation/swiftdata/index(_:)-74ia2 | hot fields (title, albumId, playlistId, …) | |
| `ModelContainer(for:migrationPlan:configurations:)` | 17 | /documentation/swiftdata/modelcontainer | `PersistenceActor.makeContainer` | |
| `ModelConfiguration(_:schema:isStoredInMemoryOnly:allowsSave:groupContainer:cloudKitDatabase:)` | 17 | /documentation/swiftdata/modelconfiguration | same | `groupContainer: .none`, `cloudKitDatabase: .none` (free signing); in memory for UI tests. |
| `@ModelActor` / `ModelActor` (`modelContext`, `init(modelContainer:)`) | 17 | /documentation/swiftdata/modelactor() | `PersistenceActor` | All reads/writes off the main thread; hands out value types only. |
| `FetchDescriptor(predicate:sortBy:)`, `fetchLimit`, `#Predicate`, `SortDescriptor`, `ModelContext.fetch/insert/save`, `delete(model:where:includeSubclasses:)` | 17 | /documentation/swiftdata/fetchdescriptor | `PersistenceActor` | Saves every 500 inserts. |

### Images, colour, caches
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `CGImageSourceCreateWithURL` / `CreateWithData`, `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceCreateThumbnailFromImageAlways`, `…WithTransform`, `kCGImageSourceShouldCacheImmediately`, `kCGImageSourceThumbnailMaxPixelSize` | 4 | /documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:) | `ArtworkPipeline` | Decode at display size, off the main thread. |
| `CGImageDestinationCreateWithURL`, `CGImageDestinationAddImage`, `CGImageDestinationFinalize`, `kCGImageDestinationLossyCompressionQuality` | 4 | /documentation/imageio/cgimagedestinationcreatewithurl(_:_:_:_:) | disk cache (JPEG thumbnails in Caches/Artwork) | |
| `CGContext(data:width:height:bitsPerComponent:bytesPerRow:space:bitmapInfo:)`, `draw(_:in:)`, `makeImage()`, `drawLinearGradient`, `drawRadialGradient`, `strokeEllipse(in:)`, `CGGradient(colorsSpace:colors:locations:)`, `CGColor(srgbRed:green:blue:alpha:)`, `CGColorSpace(name: CGColorSpace.sRGB)` | 2–13 | /documentation/coregraphics/cgcontext | `ArtworkPipeline.argbPixels`, `GeneratedArtwork` | RGBA8 premultiplied → ARGB for the ported seed selection. |
| `UTType.jpeg` | 14 | /documentation/uniformtypeidentifiers/uttype-swift.struct/jpeg | disk cache | |
| `SHA256.hash(data:)` (CryptoKit) | 13 | /documentation/cryptokit/sha256 | disk-cache file names | Not a security use. |
| `Synchronization.Mutex` (`withLock`) | 18 | /documentation/synchronization/mutex | `ArtworkPipeline.MemoryCache` | Synchronous memory-cache hits for a cell's first frame. |
| `URLSession.data(from:delegate:)` | 15 | /documentation/foundation/urlsession/data(from:delegate:) | remote artwork | |
| `PropertyListEncoder` (`outputFormat = .binary`) / `PropertyListDecoder` | 8 | /documentation/foundation/propertylistencoder | `SnapshotLoader` | Launch reads the binary-plist snapshot before SwiftData. |
| `UserDefaults(suiteName:)`, `removePersistentDomain(forName:)`, `object(forKey:)` | 7 | /documentation/foundation/userdefaults | `SettingsStore` | Android preference keys; isolated suite for UI tests. |
| `AsyncStream.makeStream(of:bufferingPolicy:)` | 17 (Swift 5.9) | /documentation/swift/asyncstream/makestream(of:bufferingpolicy:) | `DemoPlaybackEngine` | Engine → store events. |

## Stage 5 — playback engine
Signatures checked against developer.apple.com (the JSON behind each page) before use; proven by the stage-5 CI build.

### Audio session
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `AVAudioSession.setCategory(_:mode:policy:options:)`, `.playback`, `.default`, `RouteSharingPolicy.longFormAudio` | 11 | /documentation/avfaudio/avaudiosession/setcategory(_:mode:policy:options:) | `AudioSessionController.configure` | Falls back to `setCategory(_:mode:options:)` if long-form is refused. |
| `AVAudioSession.setActive(_:options:)`, `.notifyOthersOnDeactivation` | 6 | /documentation/avfaudio/avaudiosession/setactive(_:options:) | activate / deactivate | |
| `AVAudioSession.interruptionNotification`, `AVAudioSessionInterruptionTypeKey`, `AVAudioSessionInterruptionOptionKey`, `InterruptionType`, `InterruptionOptions.shouldResume` | 6 | /documentation/avfaudio/avaudiosession/interruptionnotification | interruptions → `AudioFocusResumeState` | Observed with `queue: .main` + `MainActor.assumeIsolated`; payload parsed in a `nonisolated` helper. |
| `AVAudioSession.routeChangeNotification`, `AVAudioSessionRouteChangeReasonKey`, `RouteChangeReason.oldDeviceUnavailable / .newDeviceAvailable` | 6 | /documentation/avfaudio/avaudiosession/routechangenotification | pause on unplug, optional resume | Android "becoming noisy" + `resume_on_headset_reconnect`. |
| `AVAudioSession.mediaServicesWereResetNotification` | 6 | /documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification | `rebuildAfterMediaServicesReset` | New decks, taps and items; position and play state kept. |
| `AVAudioSession.sampleRate`, `currentRoute.outputs` (`portName`, `portType`) | 6 | /documentation/avfaudio/avaudiosession/currentroute | EQ design rate, route description | |

### Players, items, taps
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `AVQueuePlayer` `insert(_:after:)`, `canInsert(_:after:)`, `remove(_:)`, `removeAllItems()`, `advanceToNextItem()` | 4.1 | /documentation/avfoundation/avqueueplayer/insert(_:after:) | `Deck` | Gapless: the next item is pre-inserted on the active deck. |
| `AVPlayer` `playImmediately(atRate:)`, `defaultRate` (16), `rate`, `pause()`, `timeControlStatus`, `actionAtItemEnd`, `allowsExternalPlayback`, `automaticallyWaitsToMinimizeStalling`, `seek(to:toleranceBefore:toleranceAfter:)` | 6–16 | /documentation/avfoundation/avplayer/defaultrate | `Deck` | `allowsExternalPlayback = false` keeps the taps running on AirPlay. KVO on `currentItem` / `timeControlStatus` with `@Sendable` handlers hopping to the main queue. |
| `AVPlayerItem(asset:)`, `audioMix`, `audioTimePitchAlgorithm` + `.spectral`, `status`, `error`, `timebase`, `currentTime()`, `didPlayToEndTimeNotification`, `failedToPlayToEndTimeNotification` | 4–7 | /documentation/avfoundation/avplayeritem/audiotimepitchalgorithm | `DeckItemFactory`, `Deck` | Spectral = pitch-preserving rate for the sync editor (0.75 / 0.5). Seeks before `readyToPlay` are deferred. |
| `CMTimebaseGetTime(_:)` | 6 | /documentation/coremedia/cmtimebasegettime(_:) | `DeckItem.positionSeconds` | Position read on demand, never observed. |
| `AVURLAsset(url:)`, `loadTracks(withMediaType:)` (async, 15), `load(.duration)` (15), `resourceLoader`, `AVAssetResourceLoader.setDelegate(_:queue:)` | 6–15 | /documentation/avfoundation/avasset/loadtracks(withmediatype:completionhandler:) | `DeckItemFactory`, `StreamingResourceLoaderRegistry` | The registry is stage 11's hook (custom schemes); no YouTube code here. |
| `AVMutableAudioMixInputParameters(track:)`, `audioTapProcessor`, `AVMutableAudioMix.inputParameters` | 4 / 6 | /documentation/avfoundation/avmutableaudiomixinputparameters/audiotapprocessor | `ProcessingTap.makeAudioMix` | One new tap per item. |
| `MTAudioProcessingTapCreate(_:_:_:_:)` (`tapOut: UnsafeMutablePointer<MTAudioProcessingTap?>`), `MTAudioProcessingTapCallbacks(version:clientInfo:init:finalize:prepare:unprepare:process:)`, `kMTAudioProcessingTapCallbacksVersion_0`, `kMTAudioProcessingTapCreationFlag_PreEffects`, `MTAudioProcessingTapGetStorage(_:)`, `MTAudioProcessingTapGetSourceAudio(_:_:_:_:_:_:)` (with `CMTimeRange` out) | 6 | /documentation/mediatoolbox/mtaudioprocessingtapcreate(_:_:_:_:) | `ProcessingTap`, `TapContext` | `import MediaToolbox` (added to the CI allow-list). Callbacks are closure literals in a `nonisolated` function (C function pointers); the context is `Unmanaged.passRetained` and released in `finalize`. Pre-effects, so the time range is the item's own media time. |
| `UnsafeMutableAudioBufferListPointer`, `AudioStreamBasicDescription`, `kAudioFormatLinearPCM`, `kAudioFormatFlagIsFloat`, `kAudioFormatFlagIsNonInterleaved` | 2 | /documentation/coreaudio/unsafemutableaudiobufferlistpointer | `TapContext` | Interleaved and planar float layouts both handled (strided channel views). |
| `vDSP_biquadm_CreateSetup` (double coefficients → **Float** setup; `CreateSetupD` is the double-precision setup for `vDSP_biquadmD`), `vDSP_biquadm`, `vDSP_biquadm_SetTargetsDouble`, `vDSP_biquadm_ResetState`, `vDSP_biquadm_DestroySetup` | 7–9 | /documentation/accelerate/vdsp_biquadm_createsetup | `TapContext` | **One single-channel setup per channel** (`__N = 1`), whose coefficient order is unambiguous: section → b0 b1 b2 a1 a2, i.e. PixlAudioCore's mono block as is. The first stage-5 CI run used one 2-channel setup with the order Apple's page documents (section → coefficient → channel) and the filters blew up (identity sections turned into 1 + z⁻¹ on one channel and silence on the other — the behaviour of section → channel → coefficient), so the multichannel layout is avoided. Swift types: `X: UnsafeMutablePointer<UnsafePointer<Float>>`, `Y: UnsafeMutablePointer<UnsafeMutablePointer<Float>>`; in place, stride = channels for interleaved audio. `SetTargetsDouble` (rate 0.25 per call, threshold 1e-6) glides to new EQ settings without clicks and does not allocate. `ProcessingTapTests.testPerChannelBiquadmMatchesTheReferenceCascade` pins this against `BiquadCascade`. Corrects the stage-3b note that named `CreateSetupD`. |
| `kMTAudioProcessingTapFlag_EndOfStream` (`MTAudioProcessingTapFlags`) | 6 | /documentation/mediatoolbox/kmtaudioprocessingtapflag_endofstream | `ProcessingTap` process callback | The player keeps pulling silent buffers after an item's last frame; the meters count only frames inside the item's duration (or, without one, not flagged end-of-stream). |
| `AVPlayer.seek(to:toleranceBefore:toleranceAfter:completionHandler:)` (`@Sendable (Bool) -> Void`) | 5 | /documentation/avfoundation/avplayer/seek(to:tolerancebefore:toleranceafter:completionhandler:) | `Deck.seek` | Position reports the seek target until the completion (generation-checked, hopped to the main queue): a paused item's timebase only moves once the seek lands. |
| `Synchronization.Atomic` (`load(ordering:)`, `store(_:ordering:)`, `wrappingAdd(_:ordering:)`), `Mutex` | 18 | /documentation/synchronization/atomic | `TapParameters` | Render-thread reads are atomics or slots of preallocated rings published with release/acquire. |
| `mach_absolute_time()`, `mach_timebase_info(_:)` | 2 | /documentation/kernel/1462446-mach_absolute_time | tap meter log, gapless test | |
| `AVAssetReader(asset:)`, `AVAssetReaderAudioMixOutput(audioTracks:audioSettings:)`, `audioMix`, `copyNextSampleBuffer()`, `CMSampleBufferGetDataBuffer`, `CMBlockBufferCopyDataBytes` | 4.1 | /documentation/avfoundation/avassetreaderaudiomixoutput/audiomix | AppTests (`TapOfflineRenderer`) | The tap also runs offline on the reader's audio mix: the tests measure the DSP chain without an audio device. |

### Now Playing and routes
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `MPNowPlayingInfoCenter.default().nowPlayingInfo` with `MPMediaItemPropertyTitle/Artist/AlbumTitle/AlbumArtist/Genre/PlaybackDuration/Artwork`, `MPNowPlayingInfoPropertyElapsedPlaybackTime/PlaybackRate/DefaultPlaybackRate/MediaType/PlaybackQueueIndex/PlaybackQueueCount/ExternalContentIdentifier` | 3–10 | /documentation/mediaplayer/mpnowplayinginfocenter | `NowPlayingController.update` | Published on changes only; the system extrapolates elapsed time from the rate. |
| `MPMediaItemArtwork(boundsSize:requestHandler:)` | 10 | /documentation/mediaplayer/mpmediaitemartwork/init(boundssize:requesthandler:) | `NowPlayingController.makeArtwork` | Built in a `nonisolated` function: the handler runs on a system queue. |
| `MPRemoteCommandCenter.shared()` play / pause / togglePlayPause / nextTrack / previousTrack / changePlaybackPosition (`MPChangePlaybackPositionCommandEvent.positionTime`) / changeShuffleMode (`shuffleType`, `currentShuffleType`) / changeRepeatMode (`repeatType`, `currentRepeatType`) / like (`MPFeedbackCommand.isActive`, `localizedTitle`); `addTarget(handler:)`, `removeTarget(_:)`, `isEnabled` | 7.1–8 | /documentation/mediaplayer/mpremotecommandcenter | `NowPlayingController.install` | `@Sendable` handlers extract the event's values, then `MainActor.assumeIsolated` (handlers arrive on the main queue, as in `DiagnosticsModel`). Like stays disabled until a favourites API exists (`onLike`). |
| `AVRoutePickerView` (`prioritizesVideoDevices`, `activeTintColor`, `tintColor`) | 11 / 13 | /documentation/avkit/avroutepickerview | `AirPlayRoutePicker` (stage 8 places it) | The cast-button equivalent. |
| `UIApplication.didEnterBackgroundNotification` / `willEnterForegroundNotification` / `willTerminateNotification` | 4 | /documentation/uikit/uiapplication/didenterbackgroundnotification | `PlaybackServices` | Snapshot save, sleep-timer clock check, final stats session. |
| `withObservationTracking(_:onChange:)` | 17 | /documentation/observation/withobservationtracking(_:onchange:) | `PlaybackServices.observeSettings` | Re-arms itself on the main actor after each change. |

### Stage 5 decisions
- **ReplayGain duplication** (PixlAudioCore `ReplayGain` vs PixlTags `ReplayGainTags`): playback uses PixlAudioCore's
  `ReplayGain.values(fromTags:)` fed with PixlTags' property map (`AudioTagReader.read(_:).properties.dictionary`),
  in `ReplayGainReader`. PixlTags reads every container; PixlAudioCore owns the maths (incl. the R128 Q7.8
  conversion PixlTags' Android-exact copy lacks). PixlTags' `ReplayGainTags.values(from:)` stays for the tag editor.
- ReplayGain is applied per item inside the tap (not as one shared player volume), so `ReplayGainVolumeController`'s
  volume bookkeeping is not used: the crossfade's incoming curve × the item's ReplayGain gain equals Android's
  `volIn × incomingTrackReplayGainVolume`. Boosts stay capped at unity (Android parity; `allowReplayGainBoost`).
- The crossfade countdown and the fade monitor only run while playing (no timers while paused).

## Testing and tooling
| API / tool | Docs | Notes |
|---|---|---|
| Swift Testing (`@Test`, `@Suite`, `#expect`, `#require`) | /documentation/testing | PixlCore (Windows + macOS). |
| `XCUIApplication.launchArguments`, `XCTAttachment(screenshot:)`, `.lifetime = .keepAlways`, `swipeUp(velocity:)` | /documentation/xctest/xctattachment | `UITests/ScreenshotTests`. |
| `xcrun xcresulttool export attachments` / `get test-results summary` | `man xcresulttool` (Xcode 16+) | `ci/export-shots.sh`, `ci/xcerrors.sh`. |
| `xcrun simctl list -j`, `boot`, `bootstatus -b`, `status_bar … override` | `xcrun simctl help` | `ci/pick-sim.sh`, shots job. |
