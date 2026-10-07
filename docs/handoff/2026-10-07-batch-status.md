# 2026-10-07 batch: what's done, what's not, what's next

Hoa asked for 11 changes, then three more: the Android port, a new logo, and a RunPod cloud server.
Work was split into groups that ran in parallel. The cloud session stopped at a clean point on
Hoa's request (switching to local work). This page is the status of every item.

**Read first:** `AGENTS.md`, then `docs/handoff/2026-10-04-start-here.md`, then this page.

- Every owner decision is in [`2026-10-07-plans/DECISIONS.md`](2026-10-07-plans/DECISIONS.md). It is binding.
- The verified plan for each item is in `2026-10-07-plans/<item>.json`, with file:line refs against main `86a5cce`.
- Each finished group also left its own note in this folder (`2026-10-07-<group>.md`).

## ⚠️ Verification state: nothing has been compiled for iOS yet

There's no Mac, and the cloud session had no iOS SDK. The integrated branch was checked with:
- `swiftc -parse` (Swift 6.4, Linux) on all 113 changed Swift files: **0 failures**;
- `bash ci/check-forbidden.sh`: **OK**;
- `swift test` on `Packages/PixlCore` (Linux): see "PixlCore tests" below.

**CI is the first real compile.** Expect a round or two of compile fixes. Every group listed its risky
spots; they're collected at the bottom of this page.

## Status by item

| # | Request | Status | Where |
|---|---|---|---|
| 1 | Replace the Synced/Static buttons on the lyrics page (owner picked **Translate · Sing**) | ❌ **Not done.** Plan and decisions ready. | `2026-10-07-plans/lyrics-page.json`, DECISIONS › Lyrics page |
| 2 | Manual lyric sync screen "shows loading then disappears" on iPhone | ✅ Code done, ⏳ unverified | `2026-10-07-sync-editor.md` |
| 3 | Research and speed up streaming | ✅ Most done: R12 timings, R2 first chunk, R3 prefetch, R4 config, R5a retry, R7 skip into the prepared next song, R11 Spotify pre-match, R8 overlapping clients behind remote flag `innertube.hedge` (**off**). Not done: R9, R10, R6, R5b. | `2026-10-07-streaming-speed.md` |
| 4 | Local AI | ✅ **Phase 1 done:** Apple on-device model is the default for every AI feature; cloud is optional, off, never a fallback. ❌ **Phase 2 not started:** the downloadable Core ML LLM behind a "Use downloaded AI model" toggle (owner explicitly wants it). | `2026-10-07-local-ai.md`, plan `local-ai.json` option C |
| 5 | New logo, inspired by Android, on both apps (owner picked **C · Glyph**) | ✅ iOS done (merged here). ✅ Android done on its own branch (see the Android repo's handoff). | `2026-10-07-logo.md` |
| 6 | More Liquid Glass incl. the queue; prev/next morph as quick as play/pause | ✅ Done: see-through 92 % sheets, queue glass circles and morphing ⋯ menu, glass pills on floating bars, Stats frosted bar; prev/next timing in the player group | `2026-10-07-glass-expansion.md`, `2026-10-07-player-controls.md` |
| 7 | Heart button only updates after touching another button | ✅ Code done: root cause was `LibraryStore.songsById` being `@ObservationIgnored` | `2026-10-07-player-controls.md` |
| 8 | Volume buttons control the Spotify Connect device while in the app | ❌ **Not done.** Plan and decisions ready (option A: outputVolume KVO + hidden MPVolumeView, fallback B). | `2026-10-07-plans/connect-volume.json` |
| 9 | App-wide accent colour | ✅ Code done. **Pending:** regenerate `Localizable.xcstrings` (new keys fall back to their default values until then) | `2026-10-07-accent-color.md` |
| 10 | Remove "Now Playing" and the cloud icon; show the connected device's name | ✅ Code done: the output pill names AirPlay / Bluetooth / wired / car / Connect devices; the phone speaker is icon only | `2026-10-07-player-controls.md` |
| 11 | Keep the screen always on in lyrics (remove the toggle); add Liquid Glass to the lyrics page | ❌ **Not done.** Part of the lyrics-page work (item 1). | `lyrics-page.json` |
| — | **Cloud Studio:** RunPod serverless BS-RoFormer + AI lyrics, "process later" | 📝 **Design done and reviewed; nothing built.** The worker agent was stopped before committing anything. | `2026-10-07-plans/cloud-studio-design.md`, DECISIONS › Cloud Studio |
| — | **Android port** of all of the above | 📝 Investigation: 8 of 9 plans written (not yet double-checked). ✅ Logo done. Nothing else built. | Android repo: `handoff/2026-10-07-batch-status.md` |

### Cloud Studio decisions (owner)
- Storage: **Cloudflare R2** (presigned URLs; the worker holds no credentials).
- No Whisper in v1: songs in non-aligner languages get line timing.
- Streamed songs are **downloaded permanently** before upload.
- Everything else uses section 9's defaults.

**Owner setup still to do:**
- A GitHub secret `RUNPOD_API_KEY` on this repo (Hoa may already have added it).
- Then, once the worker exists, the about-15-minute checklist in design section 3.5:
  - $10 RunPod credit with auto-pay off;
  - an R2 bucket with lifecycle rules and a bucket-scoped token;
  - a Restricted RunPod key for the phone;
  - entering the keys in app Settings.
- Keys never go into chat.

## What to do next, in order

1. **Get CI green on the integrated branch** (`main-6hltyd`, PR to `main`).
   - Push it with a commit message containing:
     `[shots:LyricsSyncEntryTests,LyricsSyncScreenshotTests,LyricsScreenshotTests,PlayerScreenshotTests,SpotifyConnectScreenshotTests,GlassAccessibilityTests,SettingsScreenshotTests,LibraryScreenshotTests,AIScreenshotTests,HomeStatsScreenshotTests,YouTubeScreenshotTests,ScreenshotTests,TaisScreenshotTests,BackupOnboardingScreenshotTests]`.
   - Fix compile errors from `gh run view <id> --log-failed`. Start with the risky spots below.
2. **Look at the screenshots.** Especially:
   - the queue / songInfo / aiPlaylist / taisChat sheets at 92 %. If they render opaque, change `PresentationDetent.tallGlass` to 0.85;
   - the full-player top bar (no title, device pill);
   - the `-accent*` shots;
   - the AI settings shots;
   - the lyrics sync entry tests.
3. **Merge to `main` once green** (AGENTS.md: main must stay green), then tag or run `release.yml` for a test IPA.
4. **Regenerate the String Catalog:** `tools/localization/android_strings_to_xcstrings.py` (needs the Android res dir).
5. **Build what's left**, each from its plan plus DECISIONS:
   - lyrics page (items 1 + 11);
   - Connect volume buttons (8);
   - downloadable AI model (4, phase 2);
   - Cloud Studio worker, then app integration (design section 7.7 order);
   - then the Android port.
6. **Phone checklist for Hoa** (below).

## PixlCore tests (Linux)

See the results line in the commit that added this file, or rerun:
`swift test --package-path Packages/PixlCore`.

## Phone checklist (Hoa)

- **Sync editor:** open it from the sync chip, from ⋯ › "Sync the words yourself", and from Edit song › Fix timing / Change the words.
  - Tap along, Save, and check the lyrics screen comes back with "Saved".
  - With a Connect speaker playing, it should say "Syncing only works on this iPhone…".
- **Hearts** flip at once in the full player, the song sheet and the lyrics ⋯ sheet.
- **Prev/next** feel as quick as play/pause.
- **Top bar** names AirPods / car / AirPlay / Connect devices; long names truncate cleanly.
- **Queue and song options** look see-through; the ⋯ circle morphs into "Save as playlist". Check readability over bright album art.
- **Accent colour:** pick presets and a custom colour (it re-themes 180 ms after you stop dragging). Check system alerts follow the accent. Dark mode shows pastel tones (expected).
- **AI** (Apple Intelligence on): Settings › AI features shows "On-device model · in use".
  - Daily Mix sparkle "rainy day indie" works offline.
  - Playlist Lab with ~100 songs fills to 100.
  - Taizo answers "what are my top artists?" from the library and remembers follow-ups.
- **Streaming:** play 5 cold streamed songs and 5 skips, then copy Settings › Developer › Test playback › "Stream start timings". Repeat on cellular and in Low Data Mode. These numbers decide R8 (flip `innertube.hedge.enabled` in `remote/config.json`), R9 and R10.
- **Logo:** check the Home Screen in Default, Dark, Clear and Tinted, plus the launch screen. Reboot if iOS shows a cached icon.

## Risky compile spots (check first when CI fails)

**Player:**
- `NowPlayingView.swift:213-218`: an if-expression, and `connectingId.flatMap` comparing String?/String.
- `NowPlayingController.swift:102`: `withObservationTracking` with captured closures.
- `AppEnvironment.swift:182`: closures stored from the MainActor init.
- `LyricsMoreSheet.swift:47`: a new `@Environment(LibraryStore.self)`. Every presenter must inject it.

**Sync editor:**
- `LyricsMoreSheet.swift:208`: a `@ViewBuilder row()` with a `let button` declaration.
- `RouteDestinations.swift:75`: `@Environment(Router.self)` in CoverDestination.
- `LyricsSyncEditorView.swift:27`: relies on the memberwise init `(songId:entry:onClose:)`.
- `LyricsView.swift:198-210`: `.onChange(of: syncRequest == nil)` and `.fullScreenCover(item:)`.
- `AppTests/LyricsSyncTests.swift:167`: uses `SpotifyConnectStoreTests.FakeRemote` from another file.

**Glass:**
- `QueueSheet.swift:276-347`: first use of `glassEffectTransition(.materialize)`, plus `glassEffectID` with a nested nonisolated enum.
- `SheetScaffold.swift:52`: `nonisolated static var tallGlass: PresentationDetent`.
- `GenreDetailView.swift:290`: a `GlassCircleButton` memberwise init.

**Accent:**
- `AccentPalette.swift:76,87`: `Color.resolve(in:)` and `UIColor(dynamicProvider:)` in nonisolated code.
- `ThemeStore.swift:42`: a getter writes a cache.
- `RootView.swift:75`: `.onChange(of: themeStore.accentPair, initial: true)`.
- `AppTests/AccentColorTests.swift:160`: `@unchecked Sendable` flag.

**Streaming:**
- `PlaybackStartTimings.swift:158`: `OSSignposter.emitEvent(_:)` overload.
- `StreamFetcher.swift:82`: `@concurrent` on a struct method.
- `YouTubePlayback.swift:169`: `@concurrent nonisolated static`.
- `NetworkConditionsMonitor.swift:30`: `NWPathMonitor` Sendability.
- `DualDeckEngine.swift:479`: `adoptPreparedIncoming`.
- `PlaybackDiagnosticsView.swift:269`: the DeepProbeCard memberwise init changed.

**AI:**
- `OnDeviceAI.swift:191`: `respond(to: String, schema:options:)`.
- `OnDeviceAI.swift:300`: `LibraryLookupTool: Tool`.
- `OnDeviceModel.swift:47`: `tokenCount(for:)` behind iOS 26.4.
- `Compat27.swift:45`: iOS 27 error enums.
- `OnDeviceAI.swift:255`: continuation queue.
- `SettingsStore.swift:4`: `import PixlNet`.

Merge conflicts were resolved by hand in:
- `App/AppEnvironment.swift`: both the AI-cloud screenshot hook and the `-accent` hook kept;
- `UITests/SettingsScreenshotTests.swift`: `capture(… ready:extra:suffix: …)`;
- `App/Demo/UITestLaunchRouter.swift`: the case lists combined;
- `docs/parity.md`: the About/QuickFill row takes the logo's version.

The other conflicts were appended doc sections (both kept).

## Branches

- **iOS `main-6hltyd`:** all finished groups merged (stream, ai stage 1, accent, glass, player stage 1, lyrics stage 1 = sync editor, logo), plus these docs.
- The per-group branches (`wt/*`) lived only in the cloud container and weren't pushed. Everything in them is in `main-6hltyd`.
- **Android:** see the Android repo's `handoff/2026-10-07-batch-status.md` on its `main-6hltyd`.
