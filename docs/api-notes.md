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

For the app (stage 9, done — see "Stage 9" below): the lyrics engine's intended driver is a `CADisplayLink`
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

For the app (stage 6), from PixlTags (stage 3d): MP4/M4A tag write-back goes through AVFoundation
(`AVAssetExportSession` passthrough with `metadata`). Stage 6 reads tags with PixlTags first (over the file's tag
region only) and uses `AVURLAsset` for duration, format and formats PixlTags can't read — see the Stage 6 section.

## Stage 4 — design system, shell, persistence, artwork
Proven on the `xcode-27` lane by the stage-4 build (fallback lane: its next weekly run).

### Liquid Glass and SwiftUI
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `View.glassEffect(_:in:)` | 26.0 | /documentation/swiftui/view/glasseffect(_:in:) | `pixlGlass`, every design-system component | Default shape is a capsule; we always pass the shape. |
| `Glass` `.regular`, `.tint(_:)` (`Color?`), `.interactive(_:)` | 26.0 | /documentation/swiftui/glass | `GlassStyle.swift` | Tint = the PixlAudio role Android filled with (`GlassTint` strengths). |
| `GlassEffectContainer(spacing:content:)` | 26.0 | /documentation/swiftui/glasseffectcontainer | `GlassPillRow`, Home quick actions, Library action row | Spacing below the visual gap so capsules never blend at rest. |
| `View.glassEffectID(_:in:)` (`(some Hashable & Sendable)?`) | 26.0 | /documentation/swiftui/view/glasseffectid(_:in:) | `GlassPillRow` | One shared id for the selected capsule → its tinted glass morphs to the new selection. The id enum is `nonisolated` (Sendable under default MainActor isolation). |
| `@Namespace`, `View.matchedGeometryEffect(id:in:properties:anchor:isSource:)` | 14 | /documentation/swiftui/view/matchedgeometryeffect(id:in:properties:anchor:issource:) | (formerly `GlassNavBar`) | The iOS-style tab bar (2026-10-01) moves one pill with `offset` instead. |
| `UnevenRoundedRectangle(topLeadingRadius:bottomLeadingRadius:bottomTrailingRadius:topTrailingRadius:style:)` | 16 | /documentation/swiftui/unevenroundedrectangle | `MiniPlayerBar`, player sheet morph | Per-corner radii of the mini player card while it morphs into the full player. |
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
| `AVQueuePlayer` `insert(_:after:)`, `canInsert(_:after:)`, `remove(_:)`, `removeAllItems()`, `advanceToNextItem()` | 4.1 | /documentation/avfoundation/avqueueplayer/insert(_:after:) | `Deck` | Each deck holds its current item (and `advanceToNextItem` for skips). **Not used for gapless joins**: with a processing tap on the items, AVQueuePlayer leaves ~0.45–0.5 s of silence between them (measured, `GaplessDiagnosticsTests`); see the hand-over row. |
| `AVPlayer` `playImmediately(atRate:)`, `defaultRate` (16), `rate`, `pause()`, `timeControlStatus`, `actionAtItemEnd`, `allowsExternalPlayback`, `automaticallyWaitsToMinimizeStalling`, `seek(to:toleranceBefore:toleranceAfter:)` | 6–16 | /documentation/avfoundation/avplayer/defaultrate | `Deck` | `allowsExternalPlayback = false` keeps the taps running on AirPlay. KVO on `currentItem` / `timeControlStatus` with `@Sendable` handlers hopping to the main queue. |
| `AVPlayerItem(asset:)`, `audioMix`, `audioTimePitchAlgorithm` + `.spectral`, `status`, `error`, `timebase`, `currentTime()`, `didPlayToEndTimeNotification`, `failedToPlayToEndTimeNotification` | 4–7 | /documentation/avfoundation/avplayeritem/audiotimepitchalgorithm | `DeckItemFactory`, `Deck` | Spectral = pitch-preserving rate for the sync editor (0.75 / 0.5). Seeks before `readyToPlay` are deferred. |
| `AVPlayer.preroll(atRate:) async -> Bool`, `setRate(_:time:atHostTime:)` (needs `automaticallyWaitsToMinimizeStalling = false`, else it raises), `CMClockGetHostTimeClock()`, `CMClockGetTime(_:)`, `CMTimeAdd(_:_:)` | 6 / 15 (async) | /documentation/avfoundation/avplayer/setrate(_:time:athosttime:) | `Deck.preroll` / `Deck.start`, `DualDeckEngine.fireHandOver` | **Gapless hand-over**: the next item is prerolled on the idle deck and started at the host time of the current item's last frame (`now + remaining / rate`); measured within 30 ms on the player clock. Stall waiting is restored when the deck is next loaded or the start is cancelled. preroll raises unless player and item are `readyToPlay` (checked first). |
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
- **Gapless = host-clock hand-over, not an AVQueuePlayer pre-insert** (deviation from architecture §2): every item
  carries an `MTAudioProcessingTap`, and with a tap AVQueuePlayer drains the old item's queue before starting the next
  (~0.45–0.5 s of silence, measured on the player clock; 0 s without a tap). The engine prerolls the next item on the
  idle deck and starts it with `setRate(_:time:atHostTime:)` at the current item's last frame, 1 s ahead; if it is not
  ready in time, the item's end loads the next one (a short gap).
- **ReplayGain duplication** (PixlAudioCore `ReplayGain` vs PixlTags `ReplayGainTags`): playback uses PixlAudioCore's
  `ReplayGain.values(fromTags:)` fed with PixlTags' property map (`AudioTagReader.read(_:).properties.dictionary`),
  in `ReplayGainReader`. PixlTags reads every container; PixlAudioCore owns the maths (incl. the R128 Q7.8
  conversion PixlTags' Android-exact copy lacks). PixlTags' `ReplayGainTags.values(from:)` stays for the tag editor.
- ReplayGain is applied per item inside the tap (not as one shared player volume), so `ReplayGainVolumeController`'s
  volume bookkeeping is not used: the crossfade's incoming curve × the item's ReplayGain gain equals Android's
  `volIn × incomingTrackReplayGainVolume`. Boosts stay capped at unity (Android parity; `allowReplayGainBoost`).
- The crossfade countdown and the fade monitor only run while playing (no timers while paused).
## Stage 6 — library import
Signatures checked against Apple's documentation JSON (developer.apple.com/tutorials/data/documentation/…); proven on
CI by the stage-6 build. Paths are under https://developer.apple.com.

| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `FileManager.enumerator(at:includingPropertiesForKeys:options:errorHandler:)`, `.skipsPackageDescendants`, `DirectoryEnumerator.nextObject()`, `.level`, `.skipDescendants()` | 8 / 4 | /documentation/foundation/filemanager/enumerator(at:includingpropertiesforkeys:options:errorhandler:) | `AudioFileEnumerator` | Synchronous (`makeIterator` is unavailable in async contexts, so the walk is a sync function). `level` gives the relative path without resolving symlinks. |
| `URL.resourceValues(forKeys:)`, `URLResourceKey.isRegularFileKey / isDirectoryKey / contentModificationDateKey / fileSizeKey / isUbiquitousItemKey / ubiquitousItemDownloadingStatusKey`, `URLUbiquitousItemDownloadingStatus.current` | 4–8 | /documentation/foundation/urlresourcekey/ubiquitousitemdownloadingstatuskey | `AudioFileEnumerator` | Modification time + size are the rescan stamp. |
| `FileManager.startDownloadingUbiquitousItem(at:)` | 5 | /documentation/foundation/filemanager/startdownloadingubiquitousitem(at:) | `AudioFileEnumerator` | iCloud placeholders (`.name.icloud`, or status not current): download requested, imported on a later scan. |
| `FileHandle(forReadingFrom:)`, `read(upToCount:)`, `seek(toOffset:)`, `seekToEnd()`, `close()` | 4 / 13.4 | /documentation/foundation/filehandle/read(uptocount:) | `TagRegionReader`, `MPEGDuration` | Reads only the tag region (ID3v2, FLAC metadata blocks, MP4 `ftyp`+`moov`, WAV `id3 `, ID3v1). |
| `FileManager.url(for: .itemReplacementDirectory, in:appropriateFor:create:)` | 4 | /documentation/foundation/filemanager/url(for:in:appropriatefor:create:) | `TagWriteBack.replace` | Falls back to `temporaryDirectory`; `replaceItemAt` (already in the ledger) then swaps the file in, with a plain atomic write if that fails. |
| `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)` stale refresh, `bookmarkData(options: .minimalBookmark, …)`, `start/stopAccessingSecurityScopedResource()` | 4 / 8 | /documentation/foundation/url/bookmarkdata(options:includingresourcevaluesforkeys:relativeto:) | `FolderBookmarks`, `FolderAccessRegistry` | Already ledgered for Diagnostics; stage 6 stores bookmarks in `FolderSourceRecord` and keeps each root's scope open for the process. |
| `AVURLAsset(url:)`, `load(_:)` / `load(_:_:)` (`.duration`, `.commonMetadata`, `.metadata`) | 15 (async loading) | /documentation/avfoundation/avasynchronouskeyvalueloading/load(_:isolation:) | `AudioMetadataReader`, `EmbeddedArtworkReader`, `TagWriteBack` | |
| `AVAsset.loadTracks(withMediaType:)`, `AVAssetTrack` `.estimatedDataRate`, `.formatDescriptions` | 15 | /documentation/avfoundation/avasset/loadtracks(withmediatype:completionhandler:) | `AudioMetadataReader` | Bitrate (bit/s) and sample rate. |
| `CMAudioFormatDescriptionGetStreamBasicDescription(_:)` | 4 | /documentation/coremedia/cmaudioformatdescriptiongetstreambasicdescription(_:) | `AudioMetadataReader` | `mSampleRate`. |
| `AVMetadataItem.metadataItems(from:filteredByIdentifier:)`, `load(.stringValue / .dataValue)`, `identifier` | 8 / 15 | /documentation/avfoundation/avmetadataitem/metadataitems(from:filteredbyidentifier:) | reader, artwork, write-back | |
| `AVMetadataIdentifier.commonIdentifierTitle / Artist / AlbumName / Type / CreationDate / Artwork`, `.iTunesMetadataSongName / Artist / Album / AlbumArtist / UserGenre` | 8 | /documentation/avfoundation/avmetadataidentifier/commonidentifiertitle | reader, `TagWriteBack` | |
| `AVMutableMetadataItem` (`identifier`, `value`) | 4 / 8 | /documentation/avfoundation/avmutablemetadataitem | `TagWriteBack` | |
| `AVAssetExportSession(asset:presetName:)`, `AVAssetExportPresetPassthrough`, `metadata`, `export(to:as:isolation:)`, `AVFileType.m4a` | 4 / 13 (back-deployed) | /documentation/avfoundation/avassetexportsession/export(to:as:isolation:) | `TagWriteBack` | M4A write-back without re-encoding; the export's `metadata` replaces the file's, so existing items are carried over minus the edited ones. |
| `MPMediaLibrary.authorizationStatus()`, `requestAuthorization() async`, `default().lastModifiedDate`, `beginGeneratingLibraryChangeNotifications()`, `Notification.Name.MPMediaLibraryDidChange` | 9.3 / 3 / 2 | /documentation/mediaplayer/mpmedialibrary/requestauthorization(_:) | `MediaLibraryImporter`, `LibraryAutoRefresh` | Access is requested only from the UI, never at launch. |
| `MPMediaQuery.songs()`, `MPMediaItem` `assetURL`, `hasProtectedAsset`, `persistentID`, `albumPersistentID`, `playbackDuration`, `dateAdded`, `releaseDate`, `title` / `artist` / `albumTitle` / `albumArtist` / `genre` / `albumTrackNumber` / `discNumber` / `artwork` | 3–10 | /documentation/mediaplayer/mpmediaitem/hasprotectedasset | `MediaLibraryImporter` | Only `assetURL != nil && !hasProtectedAsset` items (DRM-free, on the device). |
| `NotificationCenter.addObserver(forName:object:queue:using:)`, `UIApplication.willEnterForegroundNotification` | 4 | /documentation/foundation/notificationcenter/addobserver(forname:object:queue:using:) | `LibraryAutoRefresh` | Handlers on `.main`, bodies in `MainActor.assumeIsolated`. |
| `Task.sleep(for:)` | 16 | /documentation/swift/task/sleep(for:tolerance:clock:) | `LibraryAutoRefresh` | Debounce of rescan requests. |
| `AVAudioFile(forWriting:settings:commonFormat:interleaved:)`, `AVAudioPCMBuffer`, `kAudioFormatMPEG4AAC` | 8 | /documentation/avfaudio/avaudiofile/init(forwriting:settings:commonformat:interleaved:) | AppTests (`TestAudioFiles`) | Generates an AAC `.m4a` at test time. |
| `FileManager.setAttributes([.modificationDate: …], ofItemAtPath:)` | 2 | /documentation/foundation/filemanager/setattributes(_:ofitematpath:) | AppTests | Marks a file as changed. |

## Stage 7a — Library, detail and playlist screens
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `View.containerRelativeFrame(_:)`, `scrollTargetLayout()`, `scrollTargetBehavior(.paging)`, `scrollPosition(id:anchor:)` | 17 | /documentation/swiftui/view/scrollposition(id:anchor:) | `LibraryView` pager | Android `HorizontalPager` of the tab pages; the selected tab and the page stay in sync through the bound id. |
| `ScrollViewReader` / `ScrollViewProxy.scrollTo(_:anchor:)` | 14 | /documentation/swiftui/scrollviewreader | tab row, pager, locate button, breadcrumbs | |
| `View.onScrollGeometryChange(for:of:action:)`, `ScrollGeometry` (`contentOffset`, `contentInsets`) | 18 | /documentation/swiftui/view/onscrollgeometrychange(for:of:action:) | `trackingHeaderScroll` (detail headers) | Only the header reads the offset (`HeaderScrollState`), so scrolling never re-renders the list. |
| `View.onScrollVisibilityChange(threshold:_:)` | 18 | /documentation/swiftui/view/onscrollvisibilitychange(threshold:_:) | Songs page | Shows the locate button only while the current song is off screen (Android `LibraryActionRow`). |
| `View.refreshable(action:)` | 15 | /documentation/swiftui/view/refreshable(action:) | Library pages | Android pull-to-refresh → `LibraryStore.refresh()`. |
| `View.fileImporter(isPresented:allowedContentTypes:onCompletion:)`, `UTType.m3uPlaylist`, `.plainText`, `URL.startAccessingSecurityScopedResource()` | 14 | /documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:oncompletion:) | Library › Playlists › Import | M3U import (PixlLibrary `M3U.parse`). |
| `ShareLink(item:label:)`, `ShareLink(items:label:)` | 16 | /documentation/swiftui/sharelink | song options, multi-selection, playlist options | Share song files / export `.m3u` (temporary file). |
| `View.draggable(_:)`, `View.dropDestination(for:action:isTargeted:)` | 16 | /documentation/swiftui/view/dropdestination(for:action:istargeted:) | playlist custom order, tab reorder, playlist song reorder | Android `ReorderableItem` drag handles; the payload is the item id (`String` is `Transferable`). |
| `View.confirmationDialog(_:isPresented:titleVisibility:actions:)`, `alert(_:isPresented:actions:message:)` with a `TextField` | 15 / 16 | /documentation/swiftui/view/alert(_:ispresented:actions:message:)-8dvt8 | delete confirmations, merge / new playlist names | Android `AlertDialog`s. |
| `contentTransition(.numericText())`, `contentTransition(.symbolEffect(.replace))` | 16 / 17 | /documentation/swiftui/contenttransition | selection count, storage-filter icon | |
| `Color.mix(with:by:in:)` | 18 | /documentation/swiftui/color/mix(with:by:in:) | genre header | Android `lerp` of the header content colour. |
| `LazyVGrid`, `GridItem(.flexible / .adaptive)` | 14 | /documentation/swiftui/lazyvgrid | albums grid, quick-fill genres, editor colours/icons | Android `LazyVerticalGrid` / `FlowRow`. |
| `View.photosPicker(isPresented:selection:matching:)`, `PhotosPickerItem.loadTransferable(type:)` (PhotosUI) | 16 | /documentation/swiftui/view/photospicker(ispresented:selection:matching:preferreditemencoding:) | playlist editor cover | Android `GetContent()`; the data is copied to Application Support/PlaylistCovers. No photo-library permission is needed (out-of-process picker). |
| `Slider(value:in:step:)`, `ProgressView(value:)`, `Toggle` | 13–14 | /documentation/swiftui/slider | shape parameters, lyric-sync card, sort sheet toggles | System controls (Material `Slider` / `Switch` → native). |
| `View.scrollDismissesKeyboard(_:)`, `submitLabel(_:)`, `monospacedDigit()` | 16 / 15 / 15 | /documentation/swiftui/view/scrolldismisseskeyboard(_:) | song picker, editor | |
| `View.onLongPressGesture(minimumDuration:perform:)` | 13 | /documentation/swiftui/view/onlongpressgesture(minimumduration:maximumdistance:perform:onpressingchanged:) | song cards, album cards, playlist rows | Android long press → multi-selection. |

## Stage 7b — Home, Stats, mixes
Proven on the `xcode-27` lane by the stage-7b build.

| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `View.onScrollGeometryChange(for:of:action:)`, `ScrollGeometry` (`contentOffset`, `contentInsets`) | 18 | /documentation/swiftui/view/onscrollgeometrychange(for:of:action:) | Home top-bar scrim, Stats collapsing header | The transform returns a `Bool` / a fraction rounded to 0.01, so the action fires only on real changes. |
| `View.visualEffect(_:)`, `VisualEffect.offset(x:y:)` / `.opacity(_:)`, `GeometryProxy.frame(in: .scrollView)` | 17 | /documentation/swiftui/view/visualeffect(_:) | Mix and Recently Played header parallax | Scroll-driven effect without state updates (no re-render while scrolling). |
| `Text.fontWidth(_:)` (`Font.Width.expanded`) | 16 | /documentation/swiftui/text/fontwidth(_:) | YOUR MIX / Recently Played titles | SF Pro's wide width for Android's wide variable-font titles. |
| `Text.lineLimit(_:reservesSpace:)` | 16 | /documentation/swiftui/view/linelimit(_:reservesspace:) | mix cards, shelf cards | Android's `minLines = maxLines = 2`. |
| `RadialGradient(colors:center:startRadius:endRadius:)`, `LinearGradient(stops:startPoint:endPoint:)` | 13 | /documentation/swiftui/radialgradient | greeting washes, scrims, YOUR MIX header | Content colour (Android's own gradients), never a glass substitute. |
| `TimelineView(.animation(minimumInterval:paused:))`, `Canvas` | 15 | /documentation/swiftui/timelineview | `HomeSineWaveLine` in the Beta / Changelog sheets | Only that small canvas redraws; paused with Reduce Motion. |
| `EnvironmentValues.accessibilityReduceMotion`, `EnvironmentValues.openURL` | 13 / 14 | /documentation/swiftui/environmentvalues/openurl | sheets | |
| `ProgressView(value:total:)`, `ProgressView().controlSize(.large)` | 14 / 15 | /documentation/swiftui/progressview | jobs sheet, loading states | Android `LoadingIndicator` / `LinearProgressIndicator`. |
| `View.refreshable(action:)` | 15 | /documentation/swiftui/view/refreshable(action:) | Stats | Android `PullToRefreshBox`. |
| Swift Charts `Chart`, `BarMark(x:yStart:yEnd:width:)`, `MarkDimension.fixed(_:)`, `ChartContent.cornerRadius(_:style:)`, `.foregroundStyle(_:)` | 16 | /documentation/charts/barmark | Stats timeline | One capsule track + one capsule value bar per segment, numeric x (`chartXScale(domain: -0.5...n-0.5)`) so labels laid out at `itemWidth + 10` line up exactly. |
| `chartXScale(domain:)`, `chartYScale(domain:)`, `chartXAxis(.hidden)`, `chartYAxis(.hidden)`, `chartLegend(.hidden)` | 16 | /documentation/swiftui/view/chartxscale(domain:type:) | Stats charts | Axes drawn as SwiftUI text, like Android. |
| `SectorMark(angle:innerRadius:outerRadius:angularInset:)`, `MarkDimension.ratio(_:)` / `.inset(_:)` | 17 | /documentation/charts/sectormark | Track concentration donut | 18 pt ring of rounded sectors (Android `drawArc` with round caps). |
| `DateFormatter.dateFormat(fromTemplate:options:locale:)` | 4 | /documentation/foundation/dateformatter/dateformat(fromtemplate:options:locale:) | `HomeLogic.uses24HourClock` | Android `DateFormat.is24HourFormat`. |
| `Layout` (`sizeThatFits(proposal:subviews:cache:)`, `placeSubviews(in:proposal:subviews:cache:)`), `LayoutSubview.sizeThatFits(_:)` / `.place(at:anchor:proposal:)`, `ProposedViewSize` | 16 | /documentation/swiftui/layout | `StatsFlowLayout` (Stats metric / dimension chips) | Compose `FlowRow`; declared `nonisolated` (same shape as stage 7c's `SearchFlowLayout`, proven on CI). |
| `String(format:locale:_:)` | 2 | /documentation/swift/string/init(format:locale:_:) | Stats ("%.1f", Locale.US like Android) | |

## Stage 7c — Search
Proven on the `xcode-27` lane by the stage-7c build (fallback lane: its next weekly run).

| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `TextField(_:text:prompt:)`, `@FocusState`, `View.focused(_:)`, `submitLabel(.search)`, `onSubmit(of:_:)` | 15 | /documentation/swiftui/textfield | `SearchView` field | Prompt styled with `foregroundStyle` (Android `primary` placeholder). |
| `autocorrectionDisabled(_:)`, `textInputAutocapitalization(_:)` | 13 / 15 | /documentation/swiftui/view/textinputautocapitalization(_:) | `SearchView` field | Android `KeyboardOptions` default (no capitalisation). |
| `Layout` (`sizeThatFits(proposal:subviews:cache:)`, `placeSubviews(in:proposal:subviews:cache:)`), `LayoutSubview.sizeThatFits(_:)` / `place(at:anchor:proposal:)` | 16 | /documentation/swiftui/layout | `SearchFlowLayout` | Compose `FlowRow` for the filter chips. `Layout` is `Sendable`, so the type is `nonisolated`. |
| `LazyVGrid`, `GridItem(.flexible(), spacing:)` | 14 | /documentation/swiftui/lazyvgrid | `GenreBrowseView` | 2 / 1 columns (grid / list toggle). |
| `View.onGeometryChange(for:of:action:)` | 16 | /documentation/swiftui/view/ongeometrychange(for:of:action:) | `GenreCard` | Card width → title typography, once per width. |
| `Font.width(_:)`, `Font.Width` (`.compressed/.condensed/.standard/.expanded`), `View.fontWidth(_:)`, `italic(_:)`, `tracking(_:)` | 16 | /documentation/swiftui/font/width | genre titles | SF Pro stand-ins for Google Sans Flex's width / slant axes. |
| `UIFont.systemFont(ofSize:weight:width:)`, `UIFont.Width`, `UIFontDescriptor.withSymbolicTraits(.traitItalic)`, `UIFont(descriptor:size:)`, `lineHeight` | 16 / 7 | /documentation/uikit/uifont/systemfont(ofsize:weight:width:) | `GenreTitleTypography` | Measuring only. |
| `NSString.size(withAttributes:)` (`.font`, `.kern`) | 7 | /documentation/foundation/nsstring/size(withattributes:) | `GenreTitleTypography` | Port of Compose's `TextMeasurer` checks. |
| `LinearGradient(stops:startPoint:endPoint:)`, `Gradient.Stop` | 13 | /documentation/swiftui/lineargradient | Search bottom scrim | Android's bottom gradient. Not glass — a scrim like Android's. |
| `ProgressView()`, `controlSize(_:)` | 14 / 15 | /documentation/swiftui/progressview | catalogue / YouTube Music rows | Android `CircularProgressIndicator` while importing. |
| `AnyTransition.asymmetric(insertion:removal:)`, `.offset(x:y:)`, `.opacity`, `.scale`, `.combined(with:)` | 13 | /documentation/swiftui/anytransition | browse ↔ results, clear button | Android `AnimatedContent` fade + 1/10 slide. |
| `rotationEffect(_:anchor:)` | 13 | /documentation/swiftui/view/rotationeffect(_:anchor:) | category cards | Glyph at −14°. |
| `Image(_:)` from an asset catalog with SVG + `preserves-vector-representation` + `template-rendering-intent` | 13 (SVG in catalogs: Xcode 12) | /documentation/xcode/asset-management | `GenreArt.xcassets` | Genre glyphs converted from the Android vector drawables (`renderingMode(.template)`). |
| `XCUIElement.typeText(_:)`, `XCUIApplication.textFields` | — | /documentation/xctest/xcuielement/typetext(_:) | `UITests/SearchScreenshotTests` | Typing screenshot. |
| `View.onReceive(_:perform:)`, `NotificationCenter.publisher(for:object:)`, `UIResponder.keyboardWillShowNotification` / `keyboardWillHideNotification` | 13 / 13 / 2 | /documentation/swiftui/view/onreceive(_:perform:), /documentation/uikit/uiresponder/keyboardwillshownotification | `RootView` (shared shell, small change) | Bars step aside while the keyboard is up instead of riding above it — on Android they stay under the IME. |

## Stage 7d — settings, equalizer, transitions, about, easter egg
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `View.onScrollGeometryChange(for:of:action:)`, `ScrollGeometry.contentOffset/contentInsets` | 18 | /documentation/swiftui/view/onscrollgeometrychange(for:of:action:) | `SettingsScaffold` | Collapsing header offset; read only by the header. |
| `ScrollTargetBehavior.updateTarget(_:context:)`, `View.scrollTargetBehavior(_:)` | 17 | /documentation/swiftui/scrolltargetbehavior | `SettingsHeaderSnap` | Snap a mid-collapse release to expanded/collapsed (Android `animateTo`). |
| `UIViewControllerRepresentable`, `UINavigationController.interactivePopGestureRecognizer`, `UIGestureRecognizerDelegate.gestureRecognizerShouldBegin(_:)` | 13 / 7 | /documentation/uikit/uinavigationcontroller/interactivepopgesturerecognizer | `SettingsBackSwipeEnabler` | Keeps the edge back swipe with the system bar hidden. |
| `Group(subviews:transform:)`, `Subview` | 18 | /documentation/swiftui/group/init(subviews:transform:) | `SettingsGroup` | Corner radii by position in a group. |
| `Layout` (`sizeThatFits`, `placeSubviews`) | 16 | /documentation/swiftui/layout | `FlowChips` | Android `FlowRow`. |
| `Toggle(_:isOn:)`, `Slider(value:in:step:onEditingChanged:)`, `.labelsHidden()` | 13 | /documentation/swiftui/slider | settings rows | System controls on glass rows (no glass on glass). |
| `View.alert(_:isPresented:actions:message:)` with a `TextField` | 16 | /documentation/swiftui/view/alert(_:ispresented:actions:message:)-8dvt8 | `EqualizerView` (save / rename preset) | Android `SavePresetDialog` / `RenamePresetDialog`. |
| `List` + `ForEach.onMove(perform:)`, `moveDisabled(_:)`, `EnvironmentValues.editMode` | 13 | /documentation/swiftui/dynamicviewcontent/onmove(perform:) | `ReorderPresetsView` | Drag to reorder pinned presets. |
| `TabView` + `.tabViewStyle(.page(indexDisplayMode:))` | 14 | /documentation/swiftui/pagetabviewstyle | EQ slider pages, hybrid band pages | Android `HorizontalPager`. |
| `Canvas`, `GraphicsContext` | 15 | /documentation/swiftui/canvas | EQ sliders, response curve, wavy arc, Brick Breaker | |
| `TimelineView(.animation(minimumInterval:paused:))` | 15 | /documentation/swiftui/animationtimelineschedule | `EasterEggView` | Frames only while the ball flies or particles fall. |
| `View.onGeometryChange(for:of:action:)` | 16 (back-deployed) | /documentation/swiftui/view/ongeometrychange(for:of:action:) | `WavyArcSlider`, Brick Breaker | |
| `View.accessibilityAdjustableAction(_:)` | 13 | /documentation/swiftui/view/accessibilityadjustableaction(_:) | EQ band sliders, effect arcs | VoiceOver swipe up/down. |
| `View.onLongPressGesture(minimumDuration:perform:)` | 13 | /documentation/swiftui/view/onlongpressgesture(minimumduration:maximumdistance:perform:onpressingchanged:) | About version capsule | Opens the easter egg. |
| `ShareLink(item:subject:message:label:)` | 16 | /documentation/swiftui/sharelink | Device Capabilities report | Android share intent. |
| `UIPasteboard.general.string` | 3 | /documentation/uikit/uipasteboard | Device Capabilities report | Copy. |
| `View.textSelection(.enabled)` | 15 | /documentation/swiftui/view/textselection(_:) | report, notices | Android `SelectionContainer`. |
| `EnvironmentValues.openURL` | 14 | /documentation/swiftui/openurlaction | About (release page), licences | |
| `UIApplication.openSettingsURLString` | 8 | /documentation/uikit/uiapplication/opensettingsurlstring | Appearance › App language | iOS sets the app language in system Settings. |
| `MPVolumeView(frame:)` | 2 | /documentation/mediaplayer/mpvolumeview | EQ volume card | Apps can't set the system volume; the system slider can. |
| `AVAudioSession.outputVolume` (KVO), `NSObject.observe(_:options:changeHandler:)` | 6 / Swift 4 | /documentation/avfaudio/avaudiosession/outputvolume | `SystemVolumeObserver` | Handler built nonisolated; hops to the main actor. |
| `AVAudioSession.sampleRate`, `ioBufferDuration`, `currentRoute.outputs` (`portName`, `portType`) | 6 | /documentation/avfaudio/avaudiosession/currentroute | Device Capabilities | |
| `AudioFormatGetPropertyInfo` / `AudioFormatGetProperty`, `kAudioFormatProperty_Decoders`, `AudioClassDescription`, `kAppleHardwareAudioCodecManufacturer` | 2 | /documentation/audiotoolbox/1503220-audioformatgetproperty | Device Capabilities | Installed decoders per format; hardware codec flag. |
| `os_proc_available_memory()` | 13 | /documentation/os/3191911-os_proc_available_memory | Device Capabilities | |
| `ProcessInfo.physicalMemory`, `activeProcessorCount`, `thermalState`, `isLowPowerModeEnabled`; `uname(_:)` | 2–11 | /documentation/foundation/processinfo | Device Capabilities, report | |
| `URLResourceValues.volumeAvailableCapacityForImportantUsage`, `volumeTotalCapacity` | 11 | /documentation/foundation/urlresourcevalues/volumeavailablecapacityforimportantusage | Device Capabilities | |
| `URLSession.data(for:delegate:)` | 15 | /documentation/foundation/urlsession/data(for:delegate:) | `AppUpdateChecker` | GitHub latest release, once per visit (not in UI tests). |
| `UIImpactFeedbackGenerator(style:)`, `impactOccurred()` | 10 | /documentation/uikit/uiimpactfeedbackgenerator | Brick Breaker | Respects the haptics setting. |
| `DateFormatter.setLocalizedDateFormatFromTemplate(_:)`, `ISO8601DateFormatter` | 8 / 10 | /documentation/foundation/dateformatter/setlocalizeddateformatfromtemplate(_:) | diagnostics expiry, report | |

## Stage 8 — player sheet, full player, queue, timer, song editor, devices
Signatures checked against Apple's documentation JSON (developer.apple.com/tutorials/data/documentation/…) before use;
proven by the s08-player CI build. Paths are under https://developer.apple.com.

| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `Animatable` (`animatableData`) on a `ViewModifier` | 13 | /documentation/swiftui/animatable | `PlayerSheetMorph` | The sheet's springs interpolate the expansion fraction; frame, corners, glass/fill fades and the layers' fades (published through `playerSheetMetrics`) follow Android's curves every frame. `animatableData` is a `nonisolated` stored property (SE-0434) so the MainActor modifier satisfies the nonisolated protocol. |
| `Animation.interpolatingSpring(mass:stiffness:damping:initialVelocity:)` | 13 | /documentation/swiftui/animation/interpolatingspring(mass:stiffness:damping:initialvelocity:) | `PlayerSheetMotion`, playback controls, carousel | Compose `spring(dampingRatio, stiffness)` maps 1:1 with unit mass (`damping = 2ζ√k`); the drag's release velocity carries over. |
| `Transaction.disablesAnimations`, `withTransaction(_:_:)` | 13 | /documentation/swiftui/transaction/disablesanimations | `PlayerSheetController` | Drag frames set the fraction without animation. |
| `DragGesture(minimumDistance:coordinateSpace:)`, `Value.translation` / `.velocity` / `.location` | 13 (velocity 17) | /documentation/swiftui/draggesture/value/velocity | sheet drag, edge swipe, seek bar, queue handle and swipe-to-remove, crop | `velocity` in points per second feeds Android's 150 px/s (≈ 55 pt/s) threshold. |
| `View.simultaneousGesture(_:including:)`, `View.gesture(_:including:)`, `Optional: Gesture` | 13 | /documentation/swiftui/view/simultaneousgesture(_:including:) | sheet card, queue rows | The sheet's vertical drag runs alongside the carousel and buttons; it locks to an axis on its first movement and stands aside while the seek bar scrubs. |
| `MagnifyGesture`, `Gesture.simultaneously(with:)` | 17 / 13 | /documentation/swiftui/magnifygesture | `CoverArtCropperSheet` | Pinch (1–4×) + pan, clamped like Android's `clampOffset`. |
| `ScrollTargetBehavior.viewAligned` (`ViewAlignedScrollTargetBehavior`) | 17 | /documentation/swiftui/scrolltargetbehavior/viewaligned | `AlbumCarousel` | One cover per swipe for all three peek styles. |
| `View.contentMargins(_:_:for:)` (`CGFloat?` length, `.scrollContent`) | 17 | /documentation/swiftui/view/contentmargins(_:_:for:) | `AlbumCarousel` | Focused cover at the start (one peek) or centred (two peeks). |
| `View.onScrollPhaseChange(_:)`, `ScrollPhase` (`.interacting`, `.idle`) | 18 | /documentation/swiftui/view/onscrollphasechange(_:) | `AlbumCarousel` | Only a settle after a real user drag plays the entry (Android `userDragSettlePending`). |
| `View.scrollDisabled(_:)` | 16 | /documentation/swiftui/view/scrolldisabled(_:) | queue | No scrolling while a row is dragged. |
| `TimelineView(.animation(minimumInterval: 0.25, paused:))` | 15 | /documentation/swiftui/animationtimelineschedule | `PlayerSeekBar`, ambient backgrounds | The seek bar samples `PlaybackStore.clock` at most 4×/s while playing; paused = no ticks. Ambient styles at 30 fps only while playing and visible. |
| `Canvas`, `GraphicsContext.fill/stroke`, `.radialGradient` | 15 | /documentation/swiftui/canvas | seek bar, ambient backgrounds, crop grid | |
| `Glass.clear` | 26.0 | /documentation/swiftui/glass/clear | `playerGlass(in:tint:)`, transport | The player sits over media (orchestrator notes: clear only over media). |
| `PrimitiveButtonStyle.glass` / `.glassProminent` | 26.0 | /documentation/swiftui/primitivebuttonstyle/glass | timer custom duration, crop dialog | Dialog actions. |
| `View.accessibilityAction(_:_:)` (`.escape`), `accessibilityAction(named:_:)`, `accessibilityAdjustableAction(_:)` | 13 | /documentation/swiftui/view/accessibilityaction(_:_:) | full player (escape collapses), queue rows, seek bar | |
| `AVRouteDetector` (`isRouteDetectionEnabled`, `multipleRoutesDetected`), `.AVRouteDetectorMultipleRoutesDetectedDidChange` | 11 | /documentation/avfoundation/avroutedetector | `AudioRouteMonitor` | "Available" outputs in the devices sheet; detection runs only while the sheet is open. |
| `AVAudioSession.Port` `.builtInSpeaker/.builtInReceiver/.headphones/.usbAudio/.lineOut/.bluetoothA2DP/.bluetoothLE/.bluetoothHFP/.airPlay/.carAudio` | 7 | /documentation/avfaudio/avaudiosession/port | `AudioRouteMonitor` | Output kind and name for the player's output pill and the devices hero (with `routeChangeNotification`, already ledgered). |
| `AVRoutePickerView` (stage 5's `AirPlayRoutePicker`) | 11 | /documentation/avkit/avroutepickerview | `DevicesSheet` | Placed visibly (the picker circles) and invisibly over the tiles/rows (tint `.clear`) so they open the system picker. |
| `MPVolumeView(frame:)` | 2 | /documentation/mediaplayer/mpvolumeview | devices hero | The phone-volume slider (apps can't set the volume). |
| `CIImage(cgImage:)`, `clampedToExtent()`, `applyingGaussianBlur(sigma:)`, `cropped(to:)`, `CIContext(options:)` + `.cacheIntermediates`, `createCGImage(_:from:)` | 8–10 | /documentation/coreimage/ciimage/applyinggaussianblur(sigma:) | `BlurredArtworkCache` | The blended-cover background is blurred once off the main thread (128 px, σ 14) — no live blur while the sheet moves. |
| `Picker` + `.pickerStyle(.wheel)` | 13 | /documentation/swiftui/wheelpickerstyle | custom timer duration | Android's `TimePicker` used as a duration. |
| `Slider(value:in:step:onEditingChanged:)`, `Toggle` | 13 | /documentation/swiftui/slider | `SleepTimerSheet` | Discrete stops; commits on release like Android's `onValueChangeFinished`. |
| `PresentationDetent.height(_:)` | 16 | /documentation/swiftui/presentationdetent/height(_:) | timer sheet, custom duration | |
| `View.fullScreenCover(isPresented:onDismiss:content:)` | 14 | /documentation/swiftui/view/fullscreencover(ispresented:ondismiss:content:) | song editor, save queue as playlist | Android full-screen dialogs. |
| `TextEditor`, `View.scrollContentBackground(_:)`, `View.keyboardType(_:)` | 14 / 16 / 13 | /documentation/swiftui/texteditor | song editor lyrics / numeric fields | |
| `UIGraphicsImageRenderer(size:format:)`, `UIGraphicsImageRendererFormat.scale`, `UIImage.draw(in:)`, `UIImage.jpegData(compressionQuality:)`, `UIImage(data:)` | 10 / 2 | /documentation/uikit/uigraphicsimagerenderer | `CoverArtCropperSheet` | The crop renders at 1000 px, JPEG 95 % (orientation handled by `UIImage.draw`). |
| `Data(contentsOf:options: .mappedIfSafe)` | 7 | /documentation/foundation/data/init(contentsof:options:) | `SongEditForm.embeddedMetadata` | Composer, ReplayGain and embedded lyrics (PixlTags `AudioMetadataMapper.read`) for the editor, read off the main thread. |

### Stage 8 decisions
- **The player is not a full-screen cover.** `AppCover.nowPlaying` is a request the sheet consumes (the shell's cover
  binding skips it), so the mini player morphs into the full player in place, the drag follows the finger, and other
  covers (lyrics, the sync editor) open above the expanded player and return to it.
- **Edge swipe = predictive back.** iOS has no back gesture for an overlay: a 20 pt leading strip collapses the
  expanded player interactively (Android's `PlayerSheetPredictiveBackHandler`).
- **Seek bar without the wave.** Android's wavy slider animates every frame; the port uses Android's glass-mode
  scrubber shape with the wavy slider's geometry, redrawn at most 4×/s (performance rules).
- **Audio waveform background** shows Android's idle bars: iOS offers no capture of the app's own output outside the
  processing tap.

## Stage 9 — karaoke lyrics, lyrics services
Signatures checked against the developer.apple.com documentation JSON (`/tutorials/data/documentation/...`) before use.

| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `CADisplayLink(target:selector:)`, `preferredFrameRateRange`, `CAFrameRateRange(minimum:maximum:preferred:)`, `add(to:forMode:)`, `isPaused`, `targetTimestamp`, `invalidate()` | 3.1 / 15 | /documentation/quartzcore/cadisplaylink | `LyricsDriver` | Up to 120 Hz (`CADisableMinimumFrameDurationOnPhone`); paused while playback is paused and the engine is at rest; invalidated on disappear (the link retains its target). |
| `OSSignposter(subsystem:category:)`, `beginInterval(_:)`, `endInterval(_:_:)` | 15 | /documentation/os/ossignposter | `LyricsDriver` | Interval "LyricsEngine.step" (target < 0.5 ms); Instruments › os_signpost. |
| `Timer(timeInterval:repeats:block:)`, `RunLoop.main.add(_:forMode: .common)` | 10 | /documentation/foundation/timer/init(timeinterval:repeats:block:) | `LyricsDriver` | 150 ms poll only while visible, paused and settled (Android `IDLE_POLL_MS`). |
| `TextRenderer` (`draw(layout:in:)`, `displayPadding`), `View.textRenderer(_:)` | 18 | /documentation/swiftui/textrenderer | `KaraokeTextRenderer` | `nonisolated struct` (Animatable with empty data). Only hot lines change renderer inputs per frame. |
| `TextAttribute`, `Text.customAttribute(_:)`, `Text.Layout.Run[_:]` (attribute subscript) | 18 | /documentation/swiftui/textattribute | `KaraokePieceAttribute` | Each syllable / emphasis grapheme is its own tagged run, so the renderer finds its glyphs without character offsets. |
| `Text.Layout`, `.Line`, `.Run`, `typographicBounds.rect` | 18 | /documentation/swiftui/text/layout | `KaraokeTextRenderer` | Sweep box = the syllable's runs on one visual line. |
| `GraphicsContext.draw(_: Text.Layout.Line / Run, options:)`, `drawLayer(content:)`, `blendMode = .destinationIn`, `fill(_:with: .linearGradient(...))`, `addFilter(.shadow(color:radius:x:y:))`, `opacity`, `translateBy`, `scaleBy` | 15 / 18 | /documentation/swiftui/graphicscontext | `KaraokeTextRenderer` | Soft edge = destination-in ramp over the run; glow = white shadow, radius = CSS blur / 2. |
| `LocalizedStringKey` interpolation of `Text` (`Text("\(a)\(b)")`) | 14 | /documentation/swiftui/localizedstringkey/stringinterpolation | `KaraokeModel` | Concatenates the tagged runs (`Text + Text` is deprecated in the iOS 26 SDK). |
| `ShaderLibrary` dynamic member → `ShaderFunction`, `Shader.Argument.image(_:)` / `.float(_:)` / `.float2(_:_:)` / `.float4(_:_:_:_:)`, `Rectangle().fill(Shader)` | 17 | /documentation/swiftui/shader | `LyricsArtworkBackground`, `LyricsScene.metal` | Fill signature `[[ stitchable ]] half4 name(float2 position, args...)`; the image arrives as `texture2d<half>` (one 2×2 sprite atlas, so a single texture argument). Returns premultiplied colour in the destination's colour space. |
| `TimelineView(.animation(minimumInterval:paused:))`, `TimelineView(.periodic(from:by:))` | 15 | /documentation/swiftui/timelineview | background (30 fps), spinning art, playing bars, seek bar (4 Hz) | Paused when hidden / Low Power Mode / frozen UI tests. |
| `Glass.clear` | 26.0 | /documentation/swiftui/glass/clear | lyrics chrome | Clear glass over the artwork (HIG: media); black 35 % tint over bright art. |
| `View.blur(radius:opaque:)` | 13 | /documentation/swiftui/view/blur(radius:opaque:) | karaoke rows | Radius = the engine's σ in points (`rowBlurSigma`), quantised to 0.3 pt so layers aren't re-rasterised every frame. |
| `View.blendMode(.plusLighter)`, `compositingGroup()`, `mask(alignment:_:)` | 13 / 15 | /documentation/swiftui/blendmode/pluslighter | `KaraokeLyricsView` | One offscreen group for all lines; normal blending over bright art / increased contrast. |
| `Animatable` on a `View` (`animatableData`) | 13 | /documentation/swiftui/animatable | edge-fade masks | The bottom fade follows the hiding control cluster. |
| `DragGesture.Value.velocity`, `.time` | 17 / 13 | /documentation/swiftui/draggesture/value/velocity | `KaraokeLyricsView` | Fling velocity for the engine's decay. |
| `View.accessibilityAction(named:_:)`, `accessibilityScrollAction(_:)`, `accessibilityAdjustableAction(_:)` | 13 | /documentation/swiftui/view/accessibilityaction(named:_:) | rows ("Play from here"), seek bar | |
| `EnvironmentValues.colorSchemeContrast` (`.increased`), `accessibilityReduceMotion`, `scenePhase` | 13 / 14 | /documentation/swiftui/environmentvalues/colorschemecontrast | `LyricsView` | Increased contrast → §1.2 high-contrast lyrics. |
| `UIApplication.isIdleTimerDisabled` | 2 | /documentation/uikit/uiapplication/isidletimerdisabled | `LyricsView` | "Keep screen on" (Android `keep_screen_on_lyrics`), reset when the app goes to the background. |
| `FileDocument`, `View.fileExporter(isPresented:document:contentType:defaultFilename:onCompletion:)`, `View.fileImporter(isPresented:allowedContentTypes:onCompletion:)`, `UTType(filenameExtension:)` | 14 | /documentation/swiftui/view/fileexporter(ispresented:document:contenttype:defaultfilename:oncompletion:) | Save lyrics (.lrc), import lyrics | Imports go through PixlLyrics' `LyricsImportSecurity`. |
| `TranslationSession.Configuration(source:target:)`, `invalidate()`, `View.translationTask(_:action:)`, `TranslationSession.translations(from:)`, `Request(sourceText:clientIdentifier:)`, `Response.targetText` / `.clientIdentifier` | 18 | /documentation/translation/translationsession | "Translate lyrics" in the More sheet | On-device; the system asks to download languages. The action closure is `(TranslationSession) async -> Void` (not Sendable) and main-actor isolated (formed in `body`); `TranslationSession` and `Request` are not Sendable, so the session is passed as a `nonisolated(unsafe)` local into the `@concurrent` `LyricsTranslator.translate`, which builds the requests itself. |
| `CFStringTokenizerCreate`, `CFStringTokenizerAdvanceToNextToken`, `CFStringTokenizerCopyCurrentTokenAttribute(_:kCFStringTokenizerAttributeLatinTranscription)` | 3 | /documentation/corefoundation/cfstringtokenizer | `AppleCJKRomanization` | Japanese romaji for PixlLyrics' romaniser (Android kuromoji). |
| `String.applyingTransform(.mandarinToLatin / .stripDiacritics, reverse:)` | 9 | /documentation/foundation/stringtransform/mandarintolatin | `AppleCJKRomanization` | Toneless pinyin, `ü` → `u:` (pinyin4j form). |
| `UnevenRoundedRectangle`, `.contentTransition(.symbolEffect(.replace))`, `sensoryFeedback(_:trigger:)` | 16 / 17 | (see stage 4) | lyrics chrome | |

## Stage 10 — lyrics sync editor
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `UIResponder.touchesBegan(_:with:)` / `touchesEnded` / `touchesCancelled`, `UIView.isMultipleTouchEnabled` | 2 | /documentation/uikit/uiresponder/touchesbegan(_:with:) | `TapPadTouchView` (in a `UIViewRepresentable`) | The tap pad stamps on touch *down*; extra fingers during a hold are taps too (Android `awaitEachGesture`). SwiftUI gestures carry neither the touch timestamp nor extra fingers. |
| `UITouch.timestamp`, `ProcessInfo.systemUptime` | 2 / 4 | /documentation/uikit/uitouch/timestamp | `LyricsSyncSession.onTapDown` | Same clock (seconds since boot): `now − timestamp` is the touch's latency, removed from the player position like Android's `uptimeMillis` (`LyricsTapSync.rawTapPositionMs`). |
| `Layout` (`sizeThatFits`, `placeSubviews`), `LayoutValueKey`, `View.layoutValue(key:value:)` | 16 | /documentation/swiftui/layoutvaluekey | `SyncWeightedColumn`, `SyncFlowLayout` | Compose `Modifier.weight` (context 1, pad 1.25 with a 200 pt minimum) and `FlowRow`. |
| `View.scrollBounceBehavior(_:axes:)`, `.basedOnSize` | 16.4 | /documentation/swiftui/view/scrollbouncebehavior(_:axes:) | `SyncCardScreen` | Short screens only scroll when their content is taller than the screen. |
| `Animation.timingCurve(_:_:_:_:duration:)` | 13 | /documentation/swiftui/animation/timingcurve(_:_:_:_:duration:) | `SyncWordChip` | Compose `FastOutSlowInEasing` = cubic-bézier(0.4, 0, 0.2, 1), 260 ms word fill sweep. |
| `Animation.snappy(duration:extraBounce:)`, `contentTransition(.numericText(value:))` | 17 | /documentation/swiftui/contenttransition/numerictext(value:) | nudge value | |
| `Shape.trim(from:to:)`, `StrokeStyle(lineWidth:lineCap:)` | 13 | /documentation/swiftui/shape/trim(from:to:) | music-break ring | Ring redrawn from a `TimelineView(.animation(minimumInterval:paused:))` only while the break shows. |
| `Menu(content:label:)` with `Label(_:systemImage:)` items | 14 | /documentation/swiftui/menu | speed pill | Android `DropdownMenu` with a check on the current speed. |
| `UTType(filenameExtension:conformingTo:)` | 14 | /documentation/uniformtypeidentifiers/uttype-swift.struct/init(filenameextension:conformingto:) | share `.ttml` | `.lrc` goes out as `.plainText`, like stage 9's Save Lyrics. |
| `DualDeckEngine.beginExactTimingSession()` / `endExactTimingSession()` (ours) | — | — | `LyricsSyncPlayer` | No hand-over or crossfade into the next song; at the end the engine reloads the song paused at its end and calls `onExactTimingItemEnded` (Android `beginExactTimingSession`). |

## Stage 11 — YouTube playback
Signatures checked against the developer.apple.com documentation JSON (2026-10-01).

### Streaming (resource loader, cache, transport)
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `AVAssetResourceLoaderDelegate.resourceLoader(_:shouldWaitForLoadingOfRequestedResource:)`, `resourceLoader(_:didCancel:)` | 6 / 7 | /documentation/avfoundation/avassetresourceloaderdelegate | `YouTubeResourceLoader` | Registered for `pixlstream` through stage 5's `StreamingResourceLoaderRegistry` (callbacks on its serial queue); one task per loading request, cancelled on `didCancel`. |
| `AVAssetResourceLoadingRequest.request`, `contentInformationRequest`, `dataRequest`, `finishLoading()`, `finishLoading(with:)` | 6–7 | /documentation/avfoundation/avassetresourceloadingrequest | `YouTubeResourceLoader` | Answered from a detached task (the request objects are wrapped `@unchecked Sendable`). |
| `AVAssetResourceLoadingContentInformationRequest.contentType` / `contentLength` / `isByteRangeAccessSupported` | 7 | /documentation/avfoundation/avassetresourceloadingcontentinformationrequest | `YouTubeResourceLoader` | Type = `AVFileType.m4a` (AAC) or `AVFileType.mp4` (muxed itag 18). |
| `AVAssetResourceLoadingDataRequest.requestedOffset` / `requestedLength` / `currentOffset` / `requestsAllDataToEndOfResource` (9) / `respond(with:)` | 7 | /documentation/avfoundation/avassetresourceloadingdatarequest | `YouTubeResourceLoader` | Answered in ≤ 1 MiB pieces (cache or network). |
| `AVFileType.m4a`, `.mp4` | 4 | /documentation/avfoundation/avfiletype | `StreamFetcher.Info` | |
| `URLSessionConfiguration.ephemeral`, `httpCookieStorage = nil`, `httpShouldSetCookies`, `httpCookieAcceptPolicy`, `urlCache`, `requestCachePolicy`, `httpMaximumConnectionsPerHost` | 7 | /documentation/foundation/urlsessionconfiguration | `YouTubeNetwork.makeSession` | No cookie jar: a cookie must never reach the native InnerTube clients (HTTP 400). |
| `URLSession.data(for:delegate:)` | 15 | /documentation/foundation/urlsession/data(for:delegate:) | `StreamFetcher` | Ranged GETs with the client's User-Agent. |
| `FileHandle(forUpdating:)`, `seek(toOffset:)` (13), `write(contentsOf:)` (13.4), `read(upToCount:)` (13.4), `close()` (13) | 4–13.4 | /documentation/foundation/filehandle | `StreamCache` | Sparse file written at the requested offsets. |

### Downloads
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `URLSessionConfiguration.background(withIdentifier:)`, `isDiscretionary`, `sessionSendsLaunchEvents` | 8 / 7 | /documentation/foundation/urlsessionconfiguration/background(withidentifier:) | `DownloadManager` | Identifier `io.github.redsn0w1877.pixlaudio.downloads`; recreated at launch to collect finished transfers. |
| `URLSession.downloadTask(with:)` (URLRequest), `URLSessionTask.taskDescription`, `URLSession.allTasks` (async, 15), `getAllTasks(completionHandler:)` | 7 / 9 / 15 | /documentation/foundation/urlsession/getalltasks(completionhandler:) | `DownloadManager` | The video id travels in `taskDescription`. |
| `URLSessionDownloadDelegate.urlSession(_:downloadTask:didFinishDownloadingTo:)`, `…didWriteData:totalBytesWritten:totalBytesExpectedToWrite:`, `URLSessionTaskDelegate.urlSession(_:task:didCompleteWithError:)` | 7 | /documentation/foundation/urlsessiondownloaddelegate | `DownloadManager.DownloadDelegate` | The file is moved before `didFinishDownloadingTo` returns; state hops to the main actor. |

### JavaScript, BotGuard, sign-in
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `JSVirtualMachine()`, `JSContext(virtualMachine:)`, `evaluateScript(_:)`, `JSContext.exception`, `JSValue.toString()` / `isUndefined` / `isNull` | 7 | /documentation/javascriptcore/jscontext | `JavaScriptCoreEvaluator` | Signature / `n` functions from base.js (Android `JsEvaluator`). One VM, a fresh context per call, serialised by an actor. |
| `WKWebView(frame:configuration:)`, `WKWebViewConfiguration.websiteDataStore`, `WKWebsiteDataStore.nonPersistent()`, `customUserAgent` | 8–9 | /documentation/webkit/wkwebview | `PoTokenGenerator`, `YouTubeSignInWebView` | Private data store per use. |
| `WKWebView.loadHTMLString(_:baseURL:)`, `WKNavigationDelegate.webView(_:didFinish:)` / `didFail` / `didFailProvisionalNavigation` | 8 | /documentation/webkit/wkwebview/loadhtmlstring(_:baseurl:) | `PoTokenGenerator.PageLoader` | `po_token.html` with the www.youtube.com origin (Android `loadDataWithBaseURL`). |
| `WKWebView.callAsyncJavaScript(_:arguments:in:contentWorld:) async throws -> Any?`, `WKContentWorld.page` | 15 | /documentation/webkit/wkwebview/callasyncjavascript(_:arguments:in:contentworld:) | `PoTokenGenerator` | `runBotGuard` (awaits its promise), the integrity token as `[Int]` → `Uint8Array`, `obtainPoToken` → `Array.from(token)` (`[NSNumber]`). Replaces Android's `@JavascriptInterface` callbacks. |
| `WKWebView.evaluateJavaScript(_:in:contentWorld:) async throws -> Any?` | 15 | /documentation/webkit/wkwebview/evaluatejavascript(_:in:contentworld:) | `YouTubeSignInWebView` | Reads `window.yt.config_.VISITOR_DATA`. |
| `WKHTTPCookieStore.allCookies() async` (`getAllCookies(_:)`) | 11 | /documentation/webkit/wkhttpcookiestore/getallcookies(_:) | `YouTubeSignInWebView` | Android `CookieManager.getCookie`; accepted only once `SAPISID` is present. |
| `WKWebView.allowsBackForwardNavigationGestures`, `load(_:)` | 8 | /documentation/webkit/wkwebview | `YouTubeSignInWebView` | |
| `UIWindowScene.keyWindow` (15), `UIView.addSubview(_:)` | 15 | /documentation/uikit/uiwindowscene/keywindow | `PoTokenGenerator.hostWindow` | The 1×1 BotGuard web view sits in the window (alpha 0.01) so its page is not treated as hidden. |
| `UIPasteboard.general.string` (get/set) | 3 | /documentation/uikit/uipasteboard/string | device-code sheet, cookie sheet, playback test | Copy code / paste cookie / copy report. |
| `TextEditor(text:)`, `scrollContentBackground(.hidden)`, `textInputAutocapitalization(.never)`, `autocorrectionDisabled()` | 14–16 | /documentation/swiftui/texteditor | `CookiePasteSheet` | |
| `ProgressView(value:total:)`, `.progressViewStyle(.linear)`, `controlSize(.small)` | 14 | /documentation/swiftui/progressview | `OfflineDownloadCard`, playback test | Android `LinearProgressIndicator` / `CircularProgressIndicator`. |
| `UIViewRepresentable` (`makeCoordinator`, `makeUIView`, `updateUIView`) | 13 | /documentation/swiftui/uiviewrepresentable | `YouTubeSignInWebView` | |
| `Environment.init(_:)` for an optional `Observable` object (`@Environment(T.self) var x: T?`) | 17 | /documentation/swiftui/environment/init(_:)-8slkf | `SongCard` (`DownloadBadges`) | nil where no badge model is injected (previews). |

## Stage 12 — Spotify
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `EnvironmentValues.webAuthenticationSession`, `WebAuthenticationSession.authenticate(using:callbackURLScheme:preferredBrowserSession:)`, `WebAuthenticationSession.BrowserSession.shared` | 16.4 | /documentation/authenticationservices/webauthenticationsession/authenticate(using:callbackurlscheme:preferredbrowsersession:) | `SpotifyDashboardView`, `AccountsView` | ASWebAuthenticationSession through SwiftUI (no presentation anchor). Callback scheme `pixlaudio` (`pixlaudio://spotify-callback`); the shared browser session keeps the user's Spotify login like Android's Custom Tabs. Throws on cancel. |
| `Scene.backgroundTask(_:action:)`, `BackgroundTask.appRefresh(_:)` | 16 | /documentation/swiftui/scene/backgroundtask(_:action:) | `PixlAudioApp` | Handler for `io.github.redsn0w1877.pixlaudio.spotify-sync` (listed in `BGTaskSchedulerPermittedIdentifiers`; needs `UIBackgroundModes: fetch`). SwiftUI registers the identifier — no `BGTaskScheduler.register`. |
| `BGTaskScheduler.shared.submit(_:)`, `cancel(taskRequestWithIdentifier:)`, `BGAppRefreshTaskRequest(identifier:)`, `BGTaskRequest.earliestBeginDate` | 13 | /documentation/backgroundtasks/bgtaskscheduler/submit(_:) | `SpotifyService.scheduleBackgroundRefresh` | Next refresh ≥ 6 h out; a sync runs only when the last complete one is > 12 h old (~22 s budget per run). |
| `SecRandomCopyBytes(_:_:_:)`, `kSecRandomDefault` | 2 | /documentation/security/secrandomcopybytes(_:_:_:) | `SpotifyPlatform.randomBytes` | PKCE verifier and `state`. |
| `SHA256.hash(data:)` (CryptoKit) | 13 | /documentation/cryptokit/sha256 | `SpotifyPlatform.sha256` | PKCE `code_challenge` (RFC 7636 vector in `SpotifyTests`) and synthetic YouTube Music ids, injected into PixlNet. |
| `ModelContext.transaction(block:)` | 17 | /documentation/swiftdata/modelcontext/transaction(block:) | `PersistenceActor.replaceSongs(playlistId:with:)` | Delete + insert of a playlist's rows commit together (Android `@Transaction replaceSongsForPlaylist`). |
| `LazyHStack(alignment:spacing:)` in a horizontal `ScrollView` | 14 | /documentation/swiftui/lazyhstack | `SpotifyBrowseView` artist bubbles | Android `LazyRow`. |
| `Animation.repeatForever(autoreverses:)` | 13 | /documentation/swiftui/animation/repeatforever(autoreverses:) | `SpotifyIndeterminateProgress` | Runs only while the loading line is on screen. |
| `InsettableShape.strokeBorder(_:lineWidth:antialiased:)` | 17 | /documentation/swiftui/insettableshape/strokeborder(_:linewidth:antialiased:) | `SpotifyOutlinedButton` | Material `OutlinedButton` outline. |

## Stage 13 — AI (services, AI playlist sheet and Lab, TAIS DJ chat)
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `LanguageModelSession(instructions:)` (String overload), `respond(to:options:)` → `Response<String>.content` | 26.0 | /documentation/foundationmodels/languagemodelsession | `OnDeviceAiClient` | One fresh session per request; the orchestrator's layered system prompt is the instructions. Signatures from Apple's sample on the page (`LanguageModelSession(instructions: "…")`, `session.respond(to: prompt)` with a `String`). |
| `respond(to:generating:includeSchemaInPrompt:options:)` with a `@Generable` type | 26.0 | /documentation/foundationmodels/languagemodelsession/respond(to:generating:includeschemainprompt:options:) | `OnDeviceAiClient` | Guided generation for playlist / Daily Mix prompts (`OnDevicePlaylistSelection.songIds`), re-serialised to the JSON array PixlNet parses. |
| `@Generable(description:)`, `@Guide(description:)` | 26.0 | /documentation/foundationmodels/generable(description:) | `OnDevicePlaylistSelection` | Declared `nonisolated` so its generated conformances aren't main-actor isolated. |
| `GenerationOptions(sampling:temperature:maximumResponseTokens:)` | 26.0 | /documentation/foundationmodels/generationoptions/init(sampling:temperature:maximumresponsetokens:) | `OnDeviceAiClient` | `sampling: nil` passed explicitly (the current page shows no default for it). Temperature from the AI settings; tokens capped 256…4096. |
| `LanguageModelSession.GenerationError` (`.exceededContextWindowSize`, `.guardrailViolation`, `.refusal`, `.unsupportedLanguageOrLocale`, `.assetsUnavailable`, `.rateLimited`, `.concurrentRequests`) | 26.0 | /documentation/foundationmodels/languagemodelsession/generationerror | `OnDeviceAiClient` | Mapped to user-facing provider errors (no vendor names). |
| `View.keyframeAnimator(initialValue:repeating:content:keyframes:)`, `KeyframeTrack`, `CubicKeyframe` | 17 | /documentation/swiftui/view/keyframeanimator(initialvalue:repeating:content:keyframes:) | `AIBadge` | Spin (3 s) + breathe while generating; `repeating: false` parks it at rest. Content closure is `@Sendable` (modifiers are `nonisolated`). |
| `TimelineView(.animation)` | 15 | /documentation/swiftui/timelineschedule/animation | `ThinkingDots` | Only while a DJ prompt is in flight (the row exists only then). |
| `View.defaultScrollAnchor(_:)` | 17 | /documentation/swiftui/view/defaultscrollanchor(_:) | DJ chat list | Opens at the latest message; `ScrollViewReader.scrollTo` follows new ones. |
| `View.interactiveDismissDisabled(_:)` | 15 | /documentation/swiftui/view/interactivedismissdisabled(_:) | AI Playlist Lab | Android ignores dismiss while generating. |
| `TextField(_:text:prompt:axis:)`, `lineLimit(_:)` (range) | 16 | /documentation/swiftui/textfield/init(_:text:prompt:axis:) | AI playlist prompt | Android `minLines = 2, maxLines = 4`. |
| `View.keyboardType(_:)` (`.numberPad`) | 13 | /documentation/swiftui/view/keyboardtype(_:) | min / max songs | Android `KeyboardType.Number`; input also filtered to digits. |
| `Bindable(_:)` (wrapping an `@Observable` from the environment) | 17 | /documentation/swiftui/bindable | DJ chat field | Binding to `TaisChatModel.inputText`. |
| `Locale.localizedString(forLanguageCode:)`, `Locale.Language.languageCode` | 2 / 16 | /documentation/foundation/locale/localizedstring(forlanguagecode:) | `AILyricsTranslator` | Android `locales[0].displayLanguage` (the translation target). |
| `JSONSerialization.data(withJSONObject:)` / `jsonObject(with:)` | 5 | /documentation/foundation/jsonserialization | `AIPromptShape` | Id arrays for guided output, the scripted provider's candidate pool. |

## Testing and tooling
| API / tool | Docs | Notes |
|---|---|---|
| Swift Testing (`@Test`, `@Suite`, `#expect`, `#require`) | /documentation/testing | PixlCore (Windows + macOS). |
| `XCUIApplication.launchArguments`, `XCTAttachment(screenshot:)`, `.lifetime = .keepAlways`, `swipeUp(velocity:)` | /documentation/xctest/xctattachment | `UITests/ScreenshotTests`. |
| `XCUIElement.coordinate(withNormalizedOffset:)`, `XCUICoordinate.press(forDuration:thenDragTo:)`, `XCUIElement.frame` | /documentation/xctest/xcuicoordinate/press(forduration:thendragto:) | `UITests/LibraryImportScreenshotTests`: short drags that bring a row clear of the floating mini player before tapping it. |
| `xcrun xcresulttool export attachments` / `get test-results summary` | `man xcresulttool` (Xcode 16+) | `ci/export-shots.sh`, `ci/xcerrors.sh`. |
| `xcrun simctl list -j`, `boot`, `bootstatus -b`, `status_bar … override` | `xcrun simctl help` | `ci/pick-sim.sh`, shots job. |

## Stage 15 — backup, onboarding, updates, localisation
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `UTType(exportedAs:conformingTo:)` | 14 | /documentation/uniformtypeidentifiers/uttype-swift.struct/init(exportedas:conformingto:) | `BackupDocument` | `io.github.redsn0w1877.pixlaudio.backup` (`.pxpl`), declared in `project.yml` `UTExportedTypeDeclarations`. |
| `UTType.gzip`, `.json`, `.data` | 14 | /documentation/uniformtypeidentifiers/uttype-swift.struct/gzip | backup file picker | Android v1 `.json.gz` / `.json` backups; the reader sniffs the bytes. |
| `FileDocument` (`readableContentTypes`, `init(configuration:)`, `fileWrapper(configuration:)`), `FileWrapper(regularFileWithContents:)` | 14 | /documentation/swiftui/filedocument | `BackupFileDocument` | Value type, `nonisolated` (SwiftUI calls it off the main actor). |
| `fileExporter(isPresented:document:contentType:defaultFilename:onCompletion:)` | 14 | /documentation/swiftui/view/fileexporter(ispresented:document:contenttype:defaultfilename:oncompletion:) | `BackupExportFlowView` | Cancel arrives as `CocoaError.userCancelled` and is ignored. |
| `fileImporter(isPresented:allowedContentTypes:onCompletion:)` (single URL) | 14 | /documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:oncompletion:) | backup picker, setup | `Result<URL, any Error>`; the URL is security-scoped (`startAccessingSecurityScopedResource`). |
| `CryptoKit.SHA256.hash(data:)` | 13 | /documentation/cryptokit/sha256/hash(data:) | `BackupService.sha256` | Injected into PixlBackup as its `SHA256Hasher` (module-qualified: PixlBackup has its own `SHA256`). |
| `withObservationTracking(_:onChange:)` | 17 | /documentation/observation/withobservationtracking(_:onchange:) | `BackupService` | Re-registers after each change to retry the pending playlist restore after library scans. |
| `AsyncStream.makeStream(of:bufferingPolicy:)` | 17 | /documentation/swift/asyncstream/makestream(of:bufferingpolicy:) | `BackupService.export` | Progress from the detached export task to the main actor. |
| `UserDefaults.dictionaryRepresentation()` | 2 | /documentation/foundation/userdefaults/dictionaryrepresentation() | `SettingsBackup` | Filtered to Android-named portable keys only. |
| `uname(_:)` / `utsname.machine` | 2 | /documentation/kernel/1387506-uname | `BackupService` | Device model in the backup manifest (`iPhone17,1`). |
| `DateFormatter.setLocalizedDateFormatFromTemplate(_:)` | 8 | /documentation/foundation/dateformatter/setlocalizeddateformatfromtemplate(_:) | `BackupDates` | Android's "MMM d, yyyy 'at' h:mm a" in the device locale. |
| `UnevenRoundedRectangle(cornerRadii:style:)`, `RectangleCornerRadii` | 16 | /documentation/swiftui/unevenroundedrectangle | `SetupBottomBar` | Animatable: the next button's circle → rounded square → leaf. |
| `GlassEffectContainer(spacing:content:)` + `glassEffect(_:in:)` with rotated shapes | 26 | /documentation/swiftui/glasseffectcontainer | `SetupIconCollage` | The five collage tiles render together. |
| `DragGesture(minimumDistance:)` + `onEnded` | 13 | /documentation/swiftui/draggesture | `SetupView` | Swipe right = Android's back between setup pages. |
| `Canvas` + `Path.addCurve(to:control1:control2:)` | 15 | /documentation/swiftui/canvas | `WelcomeArt` | The Android vector `welcome_art` (16 paths of M/C/Z) parsed once, filled with palette roles. |
| `MPMediaLibrary.requestAuthorization()` (async), `authorizationStatus()` | 9.3 | /documentation/mediaplayer/mpmedialibrary/requestauthorization(_:) | setup | Through `MediaLibraryImporter`. |
| `UIApplication.openSettingsURLString` + `openURL` | 8 | /documentation/uikit/uiapplication/opensettingsurlstring | setup | Music-library access was declined: open the app's Settings page. |
| `AVAudioSession.routeChangeNotification` via `NotificationCenter.publisher(for:)` + `onReceive` | 6 / 13 | /documentation/avfaudio/avaudiosession/routechangenotification | `DeviceCapabilitiesView` | Re-measures route and sample rate live (`receive(on: RunLoop.main)`). |
| String Catalog (`Localizable.xcstrings`) with `String(localized:defaultValue:)` keys | 16 / Xcode 15 | /documentation/xcode/localizing-and-varying-text-with-a-string-catalog | all screens | Generated by `tools/localization/android_strings_to_xcstrings.py` from Android's 11 translated locales. |

## Integration (wave A)
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `View.onOpenURL(perform:)` | 14 | /documentation/swiftui/view/onopenurl(perform:) | `PixlAudioApp` → `AppEnvironment.open(_:)` | Files opened in PixlAudio (declared document types, `LSSupportsOpeningDocumentsInPlace`): `.pxpl` / `.json.gz` backups open the restore flow; the URL is security-scoped (`BackupService.inspect` brackets the read). |

## iOS-style tab bar (2026-10-01)
| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `DragGesture(minimumDistance: 0)` with `onChanged` / `onEnded` | 13 | /documentation/swiftui/draggesture | `GlassNavBar` | One gesture handles taps and press-and-drag along the bar; tab items are plain views with `accessibilityAction` + `.isButton`. |
| `Animation.interactiveSpring(response:dampingFraction:blendDuration:)` | 13 | /documentation/swiftui/animation/interactivespring(response:dampingfraction:blendduration:) | `GlassNavBar` | The pill trails the finger; retargets smoothly on every drag update. |
| `glassEffect(_:in:)` with `Glass.regular.tint(_:)` on a `Capsule` | 26.0 | /documentation/swiftui/view/glasseffect(_:in:) | `GlassNavBar` | Bar = untinted regular glass; pill = accent-tinted glass drawn on it (owner-requested exception to "no glass on glass"). |
| `View.safeAreaBar(edge:alignment:spacing:content:)` (`VerticalEdge`) | 26.0 | /documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:) | `RootView` | Like `safeAreaInset`, and it extends the scroll edge effect of scroll views under the bar — content softly fades beneath the tab bar and mini player (replaces Home's and Search's Android gradients). |
