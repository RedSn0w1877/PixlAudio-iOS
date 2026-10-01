# PixlAudio for iOS — architecture (binding unless the orchestrator notes override)

## 0. Decisions at a glance
| Decision | Choice |
|---|---|
| Minimum iOS | **26.1**, built with Xcode 27 on `xcode-27`. iOS 27-only code in one `DesignSystem/Compat27.swift` behind `#if compiler(>=6.4)` + `if #available(iOS 27, *)`, so a fallback lane on `macos-26` (Xcode 26.6) still builds. |
| Bundle ID / scheme | `io.github.redsn0w1877.pixlaudio` / `pixlaudio://` (Spotify redirect `pixlaudio://spotify-callback`) |
| Persistence | SwiftData as a **store only** (no relationships, string IDs). The app works from an in-memory `LibrarySnapshot` of value types; search uses an in-memory index from PixlCore. |
| Playback | Two AVPlayer "decks" (AVQueuePlayer each), `MTAudioProcessingTap` on every item; all DSP in the tap via vDSP. |
| Streaming | Custom-scheme `AVAssetResourceLoaderDelegate` fetching byte ranges from googlevideo into a disk cache. |
| Lyrics | Pure SwiftUI. Ported `LyricsEngine` driven by `CADisplayLink`; word fill via `TextRenderer`; background = SwiftUI Metal shader at 30 fps. |
| Concurrency | Swift 6 language mode; app target `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`; PixlCore nonisolated, Sendable value types. |
| Tests | Swift Testing for PixlCore (Windows + macOS); XCTest/XCUITest for the app. |

## 1. Repo layout
```
project.yml   AGENTS.md   README.md   .gitignore (PixlAudio.xcodeproj, build/, .build/, DerivedData)   .gitattributes (LF)
App/
  PixlAudioApp.swift, AppEnvironment.swift, Info.plist (generated from project.yml)
  Assets.xcassets (AppIcon 1024 PNG, AccentColor)
  Resources/Localizable.xcstrings, Shaders/LyricsScene.metal
  Shell/ (RootTabView, MiniPlayerAccessory, Router, PresentationState)
  Features/{Home,Library,Detail,Search,NowPlaying,Queue,Lyrics,LyricsSync,Settings,Equalizer,Transitions,
            Accounts,Spotify,YouTube,AI,Stats,Onboarding,Backup,Developer}
  Playback/ (AudioSessionController, Deck, ProcessingTap, DualDeckEngine, NowPlayingController,
             StreamingResourceLoader, SleepTimerController, PlaybackClock)
  Library/ (FolderSources+Bookmarks, LibraryScanner, MetadataReader(AVAsset), MediaLibraryImporter, TagWriteBack)
  Persistence/ (SchemaV1 @Models, PersistenceActor(@ModelActor), SnapshotLoader, MigrationPlan)
  Services/ (URLSessionHTTPClient, KeychainStore, LyricsService, YouTube/{InnerTubeService, CipherJS(JSContext),
             PoTokenWebView}, SpotifyAuth(ASWebAuthenticationSession), AIService(+FoundationModels),
             TranslationService, ModelManager(CoreML), ArtworkPipeline(ImageIO), ColorExtractor)
  DesignSystem/ (Tokens, ArtworkView, GlassTransportCluster, Compat27.swift)
  Demo/ (DemoLibrary, DemoPlaybackEngine, UITestLaunchRouter)
Packages/PixlCore/  Package.swift (swift-tools 6.2, ZERO dependencies)
  Sources/PixlFoundation  spring solver matching Compose FloatSpringSpec, CubicBezier, ExponentialDecay,
                          grapheme/word segmentation, CJK/RTL detection
          PixlModel       Song/Album/Artist/Playlist/LyricsDoc+Codec/Transition/SmartRule/SortOption/EQPreset
                          (Codable keys match Android JSON)
          PixlLyrics      parsers, PreparedLyrics(+Builder), LyricsEngine, EmphasisMath, InterludeTimeline, LyricsClock,
                          LyricsTapSync, LyricsExport, ImportSecurity, provider parsers + ranking
          PixlLibrary     ArtistParsing, AlbumGrouping, FolderTree, SearchIndex, sort/filter, smart rules, M3U, QueueUtils,
                          recommendation/DailyMix, stats aggregation, playback-history codec, k-means palette
          PixlAudioCore   transition rules/curves/gain(t), crossfade scheduler, ReplayGain, RBJ biquad design, EQ response
                          curve, sleep-timer state machine, Fft, CtcAlignmentCore, mid/side math
          PixlTags        ID3v2 read/write incl. SYLT, FLAC Vorbis/PICTURE read/write, MP4 atom read
          PixlNet         HTTPClient protocol, InnerTube contexts/requests/parsing, AAC format selection, TrackMatcher,
                          cipher-regex extraction, Piped, Spotify endpoints/PKCE (SHA-256 injected), token rotation,
                          Google device flow, AMLL/NetEase/LRCLIB, Gemini/OpenAI codecs, prompt engine, DJ intent parser
          PixlBackup      Android .pxpl manifest/modules, validators, sanitizer, zip/gzip containers (pure-Swift inflate)
  Tests/<Module>Tests + Fixtures/ (copied from Android app/src/test/resources where relevant)
AppTests/   UITests/ (ScreenshotTests, PerfTests)
ci/ (parse-check.ps1, check-forbidden.sh, xcerrors.sh, make-ipa.sh, export-shots.sh, frames.swift, ml/*.py)
.github/workflows/ (ci.yml, release.yml, fallback-xcode26.yml, ml-convert.yml)
docs/ (research/*, specs/karaoke-lyrics-ios.md, parity.md, test-parity.md, api-notes.md, design.md)
remote/config.json (InnerTube client profiles, announcements; fetched from raw.githubusercontent)
```
**project.yml essentials:** deploymentTarget iOS 26.1, iPhone family, local package only (CI-enforced). `SWIFT_VERSION 6`, `SWIFT_APPROACHABLE_CONCURRENCY YES`, `SPOTIFY_CLIENT_ID $(inherited)` (CI secret, overridable in-app). Targets: PixlAudio (app), PixlAudioTests, PixlAudioUITests. **No extensions.**
**Info.plist:** `UIBackgroundModes [audio, fetch, processing]` + `BGTaskSchedulerPermittedIdentifiers`; `NSAppleMusicUsageDescription`; `NSLocalNetworkUsageDescription` (Ollama on LAN); `NSAppTransportSecurity {NSAllowsArbitraryLoads: YES, NSAllowsLocalNetworking: YES}` (user-typed AI endpoints may be HTTP; built-ins are HTTPS); `CFBundleURLTypes [pixlaudio]`; `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`; `CFBundleDocumentTypes`/`UTImportedTypeDeclarations` for audio, .lrc, .ttml, .m3u/.m3u8, .pxpl; `CADisableMinimumFrameDurationOnPhone YES` (120 Hz); `UILaunchScreen`; generated scene manifest.

## 2. Architecture
- **State:** `AppEnvironment` built in `App.init`, passed with `.environment(...)`; small `@Observable @MainActor` stores: `LibraryStore` (snapshot + cached sorted views), `PlaybackStore` (current item, isPlaying, queue IDs, shuffle/repeat — **never position**), `PlaybackClock` (read on demand from `CMTimebaseGetTime(item.timebase)`; scrubber via `TimelineView(.periodic(by: 0.25))`, lyrics via display link), `SettingsStore` (per-category objects on UserDefaults), `AccountsStore`, `LyricsStore`. Services are actors (persistence, scanner, lyrics, YouTube, Spotify, AI, model manager, artwork cache). Playback behind `PlaybackEngine` protocol (real + `DemoPlaybackEngine` for UI tests).
- **Persistence (SwiftData VersionedSchema v1):** one model per Room table, string IDs: `SongRecord` (`f:<bookmark>/<relPath>`, `mp:<persistentID>`, `yt:`, `sp:`), `AlbumRecord`, `ArtistRecord`, `SongArtistLink`, `FavoriteRecord`, `PlaylistRecord` (smart-rules JSON, optional transition override), `PlaylistEntryRecord(position)`, `LyricsRecord` (LyricsDoc JSON, source, offset), `EngagementRecord`, `TransitionRuleRecord`, `SearchHistoryRecord`, `ArtworkThemeRecord`, `SpotifyTrackRecord(matchedVideoId, matchScore)`, `SpotifyPlaylistRecord`, `AICacheRecord`, `AIUsageRecord`, `StreamCacheRecord`, + iOS `TagOverrideRecord`, `FolderSourceRecord(bookmark Data)`. `#Index` hot fields; batch writes of 500; `playback_history.json` in Application Support (Android schema); launch reads a binary-plist snapshot cache first then reconciles in background; SQLite3 escape hatch behind the repository protocol.
- **Playback (AVPlayer decks + taps, not AVAudioEngine):** AVAudioEngine can't stream progressive HTTP without a decoder, can't play `ipod-library://`, and needs manual Now Playing/interruption/restart handling; AVPlayer gives those + pitch-preserving rate for the sync editor.
  - Tap chain per item (`MTAudioProcessingTap` via `AVAudioMix`): ReplayGain pre-gain + soft limiter → 10-band EQ (31 Hz–16 kHz) + preamp as `vDSP_biquadm` (RBJ coefficients from PixlAudioCore, smoothed with `vDSP_biquadm_SetTargetsDouble`) → bass boost (low shelf) → virtualizer (crossfeed/width) → mid/side instrumental fallback → transition gain g(t) computed from the item's media time (buffer timeRange), interpolated per sample. Real-time safe: `Synchronization.Atomic` params, preallocated buffers, no locks/allocations, context via `Unmanaged`.
  - DualDeckEngine: NONE = gapless by pre-inserting the next item on the active deck's queue; FADE_IN_OUT/OVERLAP/SMOOTH = preroll idle deck, start at `end − overlap`, run both gain curves, swap. Rules per playlist → global default (ported TransitionController).
  - `AVAudioSession(.playback, policy: .longFormAudio)` (fallback default policy if AirPlay misbehaves); interruptions via ported AudioFocusResumePolicy; pause on `oldDeviceUnavailable`; rebuild on media-services reset; `allowsExternalPlayback = false` so taps run on AirPlay; manual Now Playing + remote commands (play/pause/toggle/next/prev/changePlaybackPosition/shuffle/repeat/like, `MPMediaItemArtwork`); `AVRoutePickerView`; `MPVolumeView`.
- **YouTube streaming:** `yt:<id>` → item URL `pixlstream://<id>` → resource loader → `InnerTubeService` (VISIONOS first with fresh visitorData, no cookies to non-cookie clients, then other clients, then Piped) → only `mp4a` formats (itags 140/141/139, 18 last) → cipher via base.js cached per player version + `JSContext` → PoToken only for fallback clients via off-screen `WKWebView` (`callAsyncJavaScript`) → range requests with matching client UA into a sparse cache file (`ByteRangeSet`), 403 → re-resolve + retry → fully cached/downloaded songs play from a local file; prefetch 30 s before track end; client profiles also from `remote/config.json`.
- **Spotify:** PKCE (CryptoKit SHA-256 injected into PixlNet) via `ASWebAuthenticationSession(callbackURLScheme: "pixlaudio")`; Keychain (`kSecClassGenericPassword`, `AfterFirstUnlock`, no access group); refresh through one actor that writes the rotated refresh token **before** using the new access token; sync me/tracks, me/playlists + items → YouTube Music search + TrackMatcher → same YouTube pipeline. Google sign-in: device-code flow; cookie paste fallback.
- **Library import:** folders via `.fileImporter([.folder], multiple)` → bookmark in `FolderSourceRecord`; resolve at launch (refresh stale), keep security scope open per root; incremental rescans on foreground/pull/manual (enumerate with mtime/size/type, diff by relative path, `AVURLAsset.load(.commonMetadata, .metadata, .duration)`, PixlTags fallback for FLAC/SYLT/ReplayGain, 4 files at a time, iCloud placeholders downloaded or marked). Documents folder included automatically. `MPMediaQuery.songs()` keeping non-nil `assetURL` and `!hasProtectedAsset`; library-change notifications. Tag edits → `TagOverrideRecord`; optional write-back (m4a passthrough export, mp3/FLAC via PixlTags then `replaceItemAt`; media-library items overrides only).

## 3. Liquid Glass UI
- Shell: `TabView` Home, Library, `Tab(role: .search)`; `.tabBarMinimizeBehavior(.onScrollDown)`; `.tabViewBottomAccessory(isEnabled: hasItem) { MiniPlayer }` — `.expanded`: 40 pt art, title/artist, play/pause, next; `.inline`: art, title, play/pause; no glass inside the accessory (system provides it), nothing updating per second. Settings from a Home toolbar button (`sharedBackgroundVisibility(.hidden)`) → pushed `Form`.
- Now Playing: `.fullScreenCover` + `.navigationTransition(.zoom(sourceID: "player", in: ns))` from `matchedTransitionSource` on the accessory (fallback large sheet); always dark; background = lyrics sprite shader in a calmer preset (shared with lyrics); content layer: paging artwork carousel (prev/current/next, `.scrollTargetBehavior(.paging)`, art springs to 0.85 when paused), title/artist (marquee), favourite, `Menu` "…", custom non-glass scrubber, `MPVolumeView`; control layer: transport in one `GlassEffectContainer(spacing: 16)` — prev/next `.clear.interactive()`, play/pause `.clear.tint(artAccent.opacity(0.35)).interactive()` (only tinted control); bottom cluster lyrics · AirPlay · queue joined with `glassEffectUnion`; 35% dimming under glass when art luma > 0.6. Lyrics = a mode inside Now Playing (artwork shrinks to a header row, `KaraokeLyricsView` fills the middle, glass controls stay).
- Sheets (queue, song info/tag edit, create/edit playlist, sleep timer, DJ chat, lyrics search): `.presentationDetents([.medium, .large])`, glass automatically — never override `presentationBackground`. System menus/dialogs/alerts.
- Details (album/artist/genre/playlist/mix): hero art `.ignoresSafeArea(.top)` + `.backgroundExtensionEffect()`; Play `.glassProminent` tinted with the art accent, Shuffle `.glass`; plain `List` body; glass toolbar grouped with `ToolbarSpacer`.
- Lists = content layer: plain `List`/`LazyVGrid`, stable IDs, swipe actions (Play Next, Queue, Like), `contextMenu`, multi-select via `List(selection:)` + bottom-bar actions, now-playing indicator `waveform` with `.symbolEffect(.variableColor.iterative)`. **Never `glassEffect` inside rows/cards** (CI grep).
- Settings: native `Form`, no custom glass.
- Album-art colour: `ColorExtractor` (ImageIO 32×32 → PixlCore k-means), cached in `ArtworkThemeRecord`; used for the play tint, mix cards, header fallback gradients.
- Accessibility: Dynamic Type (lyrics have their own size), VoiceOver labels, 44 pt targets, Reduce Motion (cross-fade instead of zoom, no stagger/emphasis), standard glass adapts itself; light/dark everywhere except Now Playing/lyrics (always dark).

| Android | iOS |
|---|---|
| Setup | Onboarding cover (add folders, Music library, import Android backup) |
| Home | Greeting large title, quick actions, Your Mix/Daily Mix shelves, Recently Played/Added, stats card |
| Daily/Your Mix, Recently Played | Pushed list views |
| Stats | Swift Charts, segmented day/week/month/year/all |
| Library tabs + reorder | Library category list (Playlists, Artists, Albums, Songs, Genres, Folders, Liked, Downloaded, Spotify), Edit to reorder/hide, sort `Menu` |
| Search | Search tab: `.searchable` + `.searchScopes` (Library/Spotify/YouTube Music) + suggestions/history; genre grid when empty |
| Player/queue/cast/song info/artist picker/DJ | Now Playing, queue sheet, AirPlay picker, info sheet, `Menu`, DJ sheet |
| Lyrics sheet + editor | Lyrics mode + menus; sync editor as a full-screen cover |
| Accounts, Spotify dashboard/browse, YouTube login | Settings › Accounts |
| Settings categories, EQ, transitions, delimiters, easter egg | `Form` pages; EQ with custom vertical sliders + response curve |

## 4. Karaoke lyrics on iOS
- **Engine:** port `LyricsEngine`, `LyricsClock`, `PreparedLyricsBuilder`, `EmphasisMath`, `InterludeTimeline` line-for-line into PixlLyrics. `FloatSpringSpec` → `PixlFoundation.Spring` (closed-form damped oscillator, unit mass, ζ/stiffness per spec); port `CubicBezierEasing`, `FloatExponentialDecaySpec`. Android test vectors (LyricsEngineTest, LyricsClockTest, LyricsMotionMathTest, PreparedLyricsBuilderTest, LyricsBackgroundGradeTest) must pass on Windows before UI work. Output: flat per-row buffers + change flags, same epsilons (y 0.25 pt, scale 0.0005, blur quantum, activeness 0.002).
- **Driver:** `@MainActor LyricsDriver` owns a `CADisplayLink` (`preferredFrameRateRange(60,120,120)` while moving; paused when playback paused and at rest). Tick: `t = CMTimebaseGetTime(timebase) + offset`, monotonic guard, `engine.step`, push only changed values into per-row `@Observable LineState {y, scale, blur, activeness, hot, expand}` and one `HotClock.nowMs` read only by hot lines. Scroll uses engine springs (not SwiftUI animations).
- **View tree:** `ZStack` of `LyricRow`; each row reads only its `LineState`: `.scaleEffect(s, anchor: .leading/.trailing)`, `.blur(radius: σ)` (calibrate vs Android screenshots), `.opacity` for line-only lines, `.offset(y:)`; an `EquatableView` child with non-per-frame inputs. Rows outside viewport ±300 pt: blur 0, opacity 0. Container: `userOffset`, `.compositingGroup().blendMode(.plusLighter)` (`.normal` for bright art / increased contrast), `.mask(edge fade 10%/12%)`. Anchor 25%; rows start at 2×H and cascade in.
- **Word fill:** one `Text` per word-synced line from syllable `Text`s tagged with a custom `TextAttribute` (`SyllableAttribute(i)`); `.textRenderer(KaraokeRenderer(now, activeness, timings, fade: 0.5·lineHeight))` walks `Text.Layout` lines→runs: solid sung/unsung alpha via `context.opacity`; the active syllable through `clipToLayer` with a 4-stop linear-gradient mask; `translateBy(y: −lift·a)`; emphasis words per glyph slice with scale/translate + `addFilter(.shadow(...))` only in their window; `displayPadding` for lift/glow. Only hot lines re-render per frame.
- **Measurement:** SwiftUI layout at fixed content width (padding 24/44 pt, 15% duets); `.onGeometryChange(for: CGFloat.self)` reports row heights to the engine (once per song/width/size change).
- **Other rows:** interlude dots row (`expand` + `HotClock`); background vocals + duets per spec; translation/romanisation inside the row; plain lyrics in `LazyVStack`, 20 pt medium, white 0.85.
- **Background:** `ArtworkSpriteBaker` actor: ImageIO → 96 px → CIGaussianBlur per padded sprite → one 2×2 atlas + luma; LRU of 4. `TimelineView(.animation(minimumInterval: 1/30, paused: hidden || lowPower))` → `Rectangle().fill(ShaderLibrary.lyricsScene(size, time, seeds, .image(atlas)))`; Metal: twist, composite, grade (sat 2.75 → contrast 1.9 → brightness 0.7), overlays, dither; 1.7 s two-layer crossfade; CPU reference of the grade in PixlCore for tests.
- **Interaction:** tap line → seek (slow spring); `DragGesture` user scroll (blur → 0), ported decay fling, snap-back 500 ms / 4.5 s rules; each line an accessibility element with "Play from here"; `isIdleTimerDisabled` while visible; **never "Apple"/"Apple Music" in UI strings**.
- **Sync editor:** full-screen cover: Intro → Words (`TextEditor`, tokenised by ported LyricsTapSync) → Tap (big `.glassProminent` Tap button, `sensoryFeedback`, undo, rewind 5 s, speed 1/0.75/0.5 with pitch-preserving `AVPlayer` rate, reaction-offset setting, crossfade off; white box = word being sung, accent fill sweep = tapped words) → Preview (real `KaraokeLyricsView`) → Save (`LyricsDoc`, `source = "user"`) / Share (.lrc/.ttml via `ShareLink`/`fileExporter`); drafts as JSON.

## 5. Feature parity
| Android | iOS |
|---|---|
| Media3 service + notification | AVAudioSession + background audio; system Now Playing (Lock Screen, Dynamic Island, Control Center) |
| Dual-ExoPlayer crossfade 4×4 + per-playlist rules | DualDeckEngine + tap gain curves + TransitionRuleRecord |
| ReplayGain, EQ/BassBoost/Virtualizer, presets | Tap chain with vDSP biquads; 10-band UI + response curve |
| Surround downmix, hi-res cap, offload, decoder policy | N/A (iOS handles); route/sample rate shown under Device capabilities |
| Sleep timer (time/count/end of track), queue/shuffle/repeat | PixlAudioCore state machines + QueueUtils |
| Audio focus / noisy | Interruption + route-change handling |
| MediaStore | Folder bookmarks + Documents + MPMediaLibrary (DRM-free) |
| Delimiters, grouping, folders, favourites, playlists, smart rules, M3U | PixlLibrary |
| FTS search | In-memory SearchIndex (diacritic-folded, prefix) |
| Tag editing | Overrides + m4a passthrough export + PixlTags writers |
| Room v5 + history JSON | SwiftData v1 + same JSON |
| Spotify (all) | §2; playback via YouTube match |
| YouTube (InnerTube, matcher, cipher, PoToken, Piped, downloads, diagnostics, login) | §2; **NewPipe dropped** (Java) |
| Local HTTP stream/cast proxy | Resource loader |
| Lyrics providers/tags/cache/parsers/export/import | PixlLyrics + LyricsService (parallel TaskGroup; embedded via AVMetadata + PixlTags SYLT) |
| Translation | Apple Translation framework (on device) or AI |
| Romanisation | `CFStringTokenizer` Latin transcription (Japanese); `applyingTransform(.toLatin)` otherwise |
| Karaoke view, tap-sync editor | §4 |
| Forced alignment (wav2vec2 ONNX) | Core ML: CI converts the PyTorch checkpoint with coremltools (fp16 mlprogram ~190 MB, fixed 10 s chunks) → GitHub Release asset → downloaded on demand → `MLModel.compileModel`; PCM via AVAssetReader 16 kHz; CTC core ported |
| Instrumental (MDX-Net) | Try CI conversion to Core ML with a numeric parity gate; STFT via vDSP; fallbacks cloud BS-Roformer + tap mid/side; switch via the idle deck |
| AI Gemini/OpenAI-compatible/Gemma | URLSession REST (keys in Keychain) / Foundation Models (`@Generable` playlists; availability-gated) |
| AI playlists, daily mix, DJ, usage, cache | Ported prompt engine + intent parser; AICache/AIUsage records |
| Stats, recommendations, Daily Mix | PixlLibrary + Swift Charts |
| Backup/restore | PixlBackup; **imports Android .pxpl** (zip/gzip and inflate in pure Swift: no zlib/Compression on Windows) |
| Cast | AirPlay (`AVRoutePickerView`) |
| Wear OS | Apple Watch built-in Now Playing; watchOS app deferred |
| Glance widgets, QS tile | Deferred (extensions unreliable under free signing); system Now Playing + **App Intents** shortcuts (no extension) |
| Android Auto | **Not possible** (CarPlay entitlement) |
| External player intent | Document types + `onOpenURL` |
| Self-updater | Notify-only check against GitHub Releases |
| Plus / checkout | N/A — everything unlocked |
| Palette style / nav-bar radius (Material) | Removed; Appearance keeps accent source, lyrics size/blur |
| QuickFill, easter egg, device capabilities, developer, about, localisation | Ported (String Catalog; 12 Android locales converted by script late) |

## 6. Build and verification
- `ci.yml` (push/PR, path filters, concurrency cancel-in-progress): (1) `core` on macos-26: `swift test --package-path Packages/PixlCore --parallel`; (2) `app` on `xcode-27` (xcode-select pinned to 27.0): `ci/check-forbidden.sh` (local packages only; import allow-list of Apple frameworks; no `glassEffect` in rows; no "Apple Music" strings) → pinned XcodeGen binary → `xcodegen generate` → cached DerivedData → `xcodebuild build-for-testing -quiet` (iPhone 17 Pro, iOS 27) → unit tests → `ci/xcerrors.sh` writes `file:line: error` to `$GITHUB_STEP_SUMMARY`; (3) `shots` (PRs or commit message contains `[shots]`): boot sim, status_bar override, UI tests with `-uiTest -screen <id> -appearance dark|light -lyricsFreezeMs 42300` + demo data (in-memory ModelContainer, generated gradient art, DemoPlaybackEngine) → `xcresulttool export attachments` → `simctl io recordVideo` of the lyrics cascade → `ci/frames.swift` contact sheet → artifact; PerfTests with `XCTOSSignpostMetric` (engine step < 0.5 ms) + hitch metrics (regression tracking only).
- `release.yml` (tag/manual): archive `CODE_SIGNING_ALLOWED=NO` → `ci/make-ipa.sh` → artifact + Release asset. `fallback-xcode26.yml` (nightly/manual) on macos-26. `ml-convert.yml` (manual): Python venv coremltools/torch/transformers/onnx2torch → convert → parity checks → `models-v1` Release.
- Agents: PixlCore via local `swift test --package-path Packages/PixlCore`; app code via local `ci/parse-check.ps1` (`swiftc -parse`) → push stage branch → `gh run watch --exit-status` → `gh run view --log-failed` + summary → `gh run download -n shots-<sha> -D shots/` → view PNGs. Batch changes per push.
- Branches: trunk-based; `main` green; stage branches `sNN-name` merged by the orchestrator after CI passes (tag `stage-NN`).

## 7. Stage list (size S=1 M=2 L=4 XL=8)
0 Bootstrap (M) · 1 optional phone check (S) · 2a PixlFoundation+PixlModel (M) · 2b lyrics parsers (L) ∥ 2c lyrics engine (L) ∥ 2d tap-sync+export (M) · 3a PixlLibrary (L) ∥ 3b PixlAudioCore+DSP (M) ∥ 3c PixlNet (L) ∥ 3d PixlTags (M) ∥ 3e PixlBackup (M) · 4 app foundation (M) · 5 playback (XL) · 6 library import (L) · 7a Library+details (L) ∥ 7b Home/Stats/mixes (M) ∥ 7c Search (M) ∥ 7d Settings/EQ/transitions/delimiters (M) · 8 Now Playing/accessory/zoom/queue/info (L) · 9 karaoke lyrics + LyricsService (XL) · 10 sync editor (L) · 11 YouTube (XL) · 12 Spotify (L) · 13 AI (M) · 14 ML (L) · 15 backup/onboarding/accounts/rest/localisation (M) · 16 reviews (HIG fidelity, performance, parity, security, accessibility) · 17 fix + v1.0.0 IPA + install guide (L).

## 8. Risks → mitigations
Invented APIs → CI compile on every push, local `swiftc -parse`, `docs/api-notes.md` ledger with developer.apple.com links, small commits · `xcode-27` preview changes → pinned Xcode path, macos-26 lane, Compat27, target 26.1 · SwiftData limits → store-only, in-memory index/snapshot, VersionedSchema from day one, SQLite3 escape hatch · tap on streams/AirPlay → progressive MP4 via resource loader, `allowsExternalPlayback = false`, fallback download-then-play · YouTube breakage → VISIONOS first, remote client config, fallbacks + Piped, diagnostics · glass fidelity in CI sims → layout on CI, fidelity on device · free-signing limits → no extensions, same bundle ID, re-login on lost tokens · perf regressions → rules in AGENTS.md, signposts, review · Core ML conversion → fixed chunks, fp16, numeric gate, fallbacks · Swift-on-Windows gaps (FoundationXML, ICU) → Swift-native APIs, `#if canImport(FoundationXML)`, macOS CI authoritative · Google blocks embedded web sign-in → device-code flow · Spotify redirect → owner adds `pixlaudio://spotify-callback` · licences → constants only from AMLL/Apple, system font only.
