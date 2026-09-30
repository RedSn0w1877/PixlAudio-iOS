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
| `View.searchable(text:prompt:)` | 15 | /documentation/swiftui/view/searchable(text:placement:prompt:)-18a8f | `RootTabView` | Applied to the search tab's `NavigationStack` (on the `TabView` it showed no field on iOS 27 — verified in CI screenshots). |
| `View.tabBarMinimizeBehavior(_:)`, `.onScrollDown` | 26.0 | /documentation/swiftui/view/tabbarminimizebehavior(_:) | `RootTabView` | |
| `View.tabViewBottomAccessory(isEnabled:content:)` | **26.1** | /documentation/swiftui/view/tabviewbottomaccessory(isenabled:content:) | `RootTabView` | Reason for the 26.1 deployment target. |
| `EnvironmentValues.tabViewBottomAccessoryPlacement`, `TabViewBottomAccessoryPlacement.inline/.expanded` | 26.0 | /documentation/swiftui/tabviewbottomaccessoryplacement | `MiniPlayerAccessory` | Optional value (nil outside an accessory). |
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

## Testing and tooling
| API / tool | Docs | Notes |
|---|---|---|
| Swift Testing (`@Test`, `@Suite`, `#expect`, `#require`) | /documentation/testing | PixlCore (Windows + macOS). |
| `XCUIApplication.launchArguments`, `XCTAttachment(screenshot:)`, `.lifetime = .keepAlways`, `swipeUp(velocity:)` | /documentation/xctest/xctattachment | `UITests/ScreenshotTests`. |
| `xcrun xcresulttool export attachments` / `get test-results summary` | `man xcresulttool` (Xcode 16+) | `ci/export-shots.sh`, `ci/xcerrors.sh`. |
| `xcrun simctl list -j`, `boot`, `bootstatus -b`, `status_bar … override` | `xcrun simctl help` | `ci/pick-sim.sh`, shots job. |
