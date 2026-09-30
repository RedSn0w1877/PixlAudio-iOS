# Apple official docs research — Liquid Glass, SwiftUI, platform APIs (verified 2026-09-30)

All from developer.apple.com / HIG / WWDC pages. **[UNVERIFIED]** = not confirmed from an official source.
Relative paths are under https://developer.apple.com.

## 1. Current state
- iOS 27.0.1 (24A446) shipped 2026-09-28; iOS 27.2 beta 2 on 2026-09-21; iOS 26.6.2 still patched. iOS 27 announced WWDC26.
- Xcode 27 (27A266a) shipped 2026-09-14: Swift 6.4, iOS 27 SDK, needs macOS Tahoe 26.6+, deployment targets iOS 17+. Xcode 27.1/27.2 in beta.
- iOS 27 Liquid Glass changes (automatic, "without even needing to recompile"): stronger diffusion of complex content behind glass, darker edges, brighter speculars, user Settings slider "ultra clear"→"fully tinted"; a uniform top toolbar appears when content scrolls under floating bars (adjust via scroll edge effect APIs); sharper app icons with refraction; Icon Composer 2.0.
- `UIDesignRequiresCompatibility` is ignored when building for iOS 27+ (no opting out of Liquid Glass).
- Apps built with the iOS 27 SDK must use the scene-based life cycle (SwiftUI App does).
- Recommendation: build with Xcode 27; deployment target iOS 26.1 (for `tabViewBottomAccessory(isEnabled:)`); gate iOS 27 APIs with `if #available(iOS 27, *)`.

## 2. SwiftUI Liquid Glass APIs (min iOS 26.0 unless noted)
- `glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View` — default Capsule; apply after other appearance modifiers. `/documentation/swiftui/view/glasseffect(_:in:)`
- `Glass`: `.regular`, `.clear`, `.identity`; `.tint(Color?)`, `.interactive(Bool)`. `/documentation/swiftui/glass`
- `GlassEffectContainer(spacing: CGFloat?, content:)` — larger spacing = shapes blend/morph sooner. `/documentation/swiftui/glasseffectcontainer`
- `glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID)` — morphing with `@Namespace`.
- `glassEffectUnion(id:namespace:)` — merges effects with same ID/shape/variant into one shape.
- `GlassEffectTransition`: `.matchedGeometry` (default within spacing), `.materialize` (farther apart), `.identity`; via `glassEffectTransition(_:)`.
- Button styles: `.glass`, `.glassProminent`, `.glass(_ glass: Glass)` e.g. `.buttonStyle(.glass(.clear))`.
- `backgroundExtensionEffect()` — mirrors/blurs a view into surrounding safe areas; use with discretion, usually one background view.
- `scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set)` e.g. `.hard`; custom bars: `safeAreaBar(edge:alignment:spacing:content:)`.
- `ToolbarSpacer(SpacerSizing, placement:)` with `.fixed`/`.flexible`; `sharedBackgroundVisibility(.hidden)` gives an item its own glass group; `DefaultToolbarItem(kind: .search, placement: .bottomBar)`.
- `tabBarMinimizeBehavior(_:)` e.g. `.onScrollDown`.
- `tabViewBottomAccessory(content:)` — on iPhone sits above the tab bar, moves inline when the tab bar collapses. `tabViewBottomAccessory(isEnabled:content:)` **iOS 26.1**. `TabViewBottomAccessoryPlacement` `.inline`/`.expanded` via `@Environment(\.tabViewBottomAccessoryPlacement)` — Apple's own example is a MusicPlaybackView that swaps compact controls for a slider.
- `Tab(role: .search)` + `.searchable(text:)` — search tab at the trailing end; `searchToolbarBehavior(_:)` minimizes the bottom search field (WWDC code `.minimize` vs docs `.minimized` — check which compiles).
- Zoom transition: `navigationTransition(.zoom(sourceID:in:))` + `matchedTransitionSource(id:in:)` (iOS 18) — pushes and sheets from toolbar buttons.
- Sheets: half sheets inset, larger corner radii, more opaque at full height; remove custom sheet/popover backgrounds; `.presentationDetents([.height(180), .medium, .large])`.
- **iOS 27 additions:** `toolbarMinimizationBehavior(_:for:)` (the video says `toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)` but the doc symbol is `toolbarMinimizationBehavior`), `TabRole.prominent` (one tab, trailing), `ToolbarContent.visibilityPriority(_:)`, `ToolbarOverflowMenu`, `.topBarPinnedTrailing`, `NavigationTransition.crossFade` for sheets, `swipeActionsContainer()`, `reorderable()`, `@State` as a macro, `ContentBuilder`. Sept 2026 SDK also mentions `ArrangementView`/hinge/vertical toolbar APIs ("iPhone Duo") [UNVERIFIED which release].
- UIKit equivalents only if SwiftUI lacks something: `UIGlassEffect(style:)` (+ `.tintColor`, `.isInteractive`), `UIGlassContainerEffect`, `UIButton.Configuration.glass()/.prominentGlass()/.clearGlass()/.prominentClearGlass()`, `UIBackgroundExtensionView`, `UIScrollEdgeEffect`.

## 3. HIG guidance
- Liquid Glass = functional layer for controls/navigation floating above content. **"Don't use Liquid Glass in the content layer."** Exception: transient controls (sliders, toggles) turn to glass while touched. Tables/lists are not glass.
- **No glass on glass**: elements on glass use fills, transparency, vibrancy instead. Use glass sparingly.
- Regular vs clear: never mix. Regular is default/adaptive. Clear only when over media-rich content, a dimming layer won't hurt it, and foreground is bold/bright. Over bright content add a dark dimming layer ~35% opacity (not needed over dark content or with AVKit controls).
- Tint only primary actions; tint the background, not the symbol/text; don't tint several controls. Over colourful content prefer monochrome tab bars/toolbars. Custom colours need light/dark/increased-contrast variants.
- Accessibility adapts automatically for standard glass: Reduce Transparency (frostier), Increase Contrast (black/white + border), Reduce Motion (less elastic). Test custom elements; `@Environment(\.accessibilityReduceTransparency)`.
- Toolbars: group by function, SF Symbols with accessibility labels, don't mix text and icons in one group, hide with `.hidden(_:)`.
- App icon: Icon Composer layers (≤4 groups), `.icon` file; variants default/dark/clear/tinted; refraction only on OS 27+.

## 4. Apple Music (documented)
- Tab bar floats, shrinks while browsing, expands on scroll up. MiniPlayer = tab-bar accessory that moves inline when the tab bar minimizes. Accessories are for persistent features "like media playback controls". Lyrics opens from the MiniPlayer; iOS 26 added Lyrics Translation, Pronunciation, AutoMix.
- [UNVERIFIED] no official description of Now Playing layout or lyrics styling.
- Sample code: **Landmarks: Building an app with Liquid Glass** (`/documentation/swiftui/landmarks-building-an-app-with-liquid-glass`) — backgroundExtensionEffect, grouped toolbars, glassEffect, GlassEffectContainer + glassEffectID morphing, 4-layer icon.

## 5. Platform APIs
- AVFoundation: `AVAudioSession.sharedInstance().setCategory(.playback, …)` then `setActive` (defer until playback). Background Modes "Audio, AirPlay, and Picture in Picture". `/documentation/avfoundation/configuring-your-app-for-media-playback`. AVQueuePlayer `init(items:)`, `advanceToNextItem()`, `insert(_:after:)`, `remove(_:)`.
- MediaPlayer: `MPNowPlayingInfoCenter.default().nowPlayingInfo` (Lock Screen/Control Center/AirPlay), animated artwork keys; `MPRemoteCommandCenter.shared()` play/pause/next/previous/changePlaybackPosition/shuffle/repeat/like. Sample "Becoming a now playable app". `MPMediaLibrary.requestAuthorization()`; `MPMediaItem.hasProtectedAsset` flags DRM.
- MusicKit: `ApplicationMusicPlayer.shared` (iOS 15+), `MusicLibraryRequest<T>` (iOS 16+).
- Files: `fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:onCompletion:)` → security-scoped URLs (`startAccessingSecurityScopedResource`/`stop…`).
- SwiftData (iOS 17+): `@Model`, `ModelContainer`, `@Query`, `.modelContainer(_:)`.
- Keychain: `SecItemAdd` with `kSecClassGenericPassword`.
- OAuth: `ASWebAuthenticationSession(url:callback:completionHandler:)` with `Callback.customScheme(_:)` (iOS 17.4+; older `callbackURLScheme:` init deprecated); `prefersEphemeralWebBrowserSession`; implement PKCE yourself.

## 6. Performance guidance
- Custom glass inside `GlassEffectContainer`; limit on-screen glass effects; don't create many containers; `backgroundExtensionEffect` on one view.
- Instruments SwiftUI template (Update Groups, Long View Body Updates, Cause & Effect). Keep work out of `body`, cache formatters, fine-grained `@Observable` per-item models, no fast-changing values in the environment. Xcode 27 adds "Summary of Updates".
- iOS 27: nested stack layouts up to 2× faster; `@State` initializes classes lazily once (back-deployed to iOS 17 with Xcode 27 — remove default values you also assign in `init`); `AsyncImage` HTTP caching by default.

## Sources
/news/releases/ · /documentation/xcode-release-notes/xcode-27-release-notes · /documentation/bundleresources/information-property-list/uidesignrequirescompatibility · /videos/play/wwdc2026/102/ (State of the Union) · /videos/play/wwdc2026/269/ (What's new in SwiftUI) · /documentation/updates/swiftui · /documentation/updates/uikit · /documentation/swiftui/applying-liquid-glass-to-custom-views · /documentation/technologyoverviews/adopting-liquid-glass · /videos/play/wwdc2025/323/ (Build a SwiftUI app with the new design) · /videos/play/wwdc2025/219/ (Meet Liquid Glass) · /videos/play/wwdc2025/356/ (Get to know the new design system) · /design/human-interface-guidelines/materials · …/tab-bars · …/color · /documentation/xcode/creating-your-app-icon-using-icon-composer · /videos/play/wwdc2025/306/ (Optimize SwiftUI performance with Instruments) · /documentation/mediaplayer/mpnowplayinginfocenter · /documentation/mediaplayer/mpremotecommandcenter · /documentation/authenticationservices/aswebauthenticationsession · /documentation/swiftdata
