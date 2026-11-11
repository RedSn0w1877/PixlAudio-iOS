# iOS integration map: Spatial audio, Enhanced audio, Opus (2026-11-11)

For the four agents that build on branch `audio-foundation`: **ENGINE** (the on-device stage, playback, rendition
switching, route and level rules), **CLOUD** (library client, jobs, local store, background queue, caps), **UI**
(player sheet, settings, strings) and **OPUS** (play YouTube's Opus stream on iPhones). The contract is
[`cloud-audio-spec.md`](cloud-audio-spec.md); this page says where everything it touches lives in the iOS code.

Line numbers are those of commit `3670155` (branch `audio-foundation`), and still hold at the branch tip: later
commits changed only tests, fixtures, this page, the contract's own app files, files under `cloud/` (through a merge
of `audio-hq`) and two spots of `AppEnvironment.swift`, whose numbers below are the tip's. Paths are from the repo
root. Quotes are short on purpose: open the file for the rest.

Contents: [1 What is already there](#1-what-is-already-there-the-contract-code) ·
[2 Playback](#2-playback-decks-items-the-tap) · [3 The Sing swap](#3-the-sing-swap-the-alternate-rendition-mechanism) ·
[4 Source resolution](#4-source-resolution-video-ids-format-info) · [5 Gain](#5-gain-where-the-level-rule-lives) ·
[6 Route](#6-route) · [7 Cloud Studio](#7-cloud-studio) · [8 Settings and UI](#8-settings-and-ui) ·
[9 Opus](#9-opus) · [10 Tests and CI](#10-tests-and-ci) · [11 Who owns which file](#11-who-owns-which-file) ·
[12 Where the spec and the code disagree](#12-where-the-spec-and-the-code-disagree)

---

## 1. What is already there (the contract code)

Everything below compiles and is tested. The app behaves exactly as before, because both halves are no-ops until
ENGINE and CLOUD replace them.

### 1.1 PixlCore (compiles and tests on Windows)

| File | What |
|---|---|
| `Packages/PixlCore/Sources/PixlModel/CloudAudio/SpatialProfile.swift` | `SpatialProfile` (ids `studio wide intimate hall surround night`, `displayName`, `summary` = spec 6.5 one-liners), `SpatialSelection` (`.off` / `.profile(p)`, `storageValue`), `SpatialRouteMode`, `SpatialOutputKind`, `SpatialActivation.routePasses / isActive` (spec 6.3), `SpatialLevel.playbackGain(_:headroomDb:)` = `min(1, gain × 10^(dB/20))` |
| `…/CloudAudio/CloudAudioSettings.swift` | `CloudAudioSettingsKey` (the spec 6.1 names, used verbatim as `UserDefaults` keys), `CloudAudioStoredSettings` (nil = never set), `CloudAudioSettings(stored:builtInCloudKeys:)` (defaults, ranges) |
| `…/CloudAudio/Rendition.swift` | `RenditionKind` (`.spatial(profile)` / `.enhanced`, `slot` = `sp-<profile>` / `enhanced`), `RenditionKey(videoId:kind:)`, `RenditionStatus` (`none preview queued processing ready failed`), `RenditionRetry` (10 min, 1 h, 1 day) |
| `…/CloudAudio/CloudLibrary.swift` | `CloudLibrary.version` (1), `engineId`, `audioKey(_:)`, `manifestKey(_:)`, `parse(objectKey:)`, `isValidVideoId`; `CloudAudioLocalLayout` (`CloudAudio/<videoId>/<slot>.flac|.json`, `rendition(ofAudioFile:)`) |
| `…/CloudAudio/CloudLibraryManifest.swift` | The render manifest (spec 3.1) as `Codable`, `check(for:)` (the acceptance rule), `audioMatches(bytes:sha256:)`, `headroomDb`, `stemMode`, `restoreReason` |
| `…/CloudAudio/SpatialServices.swift` | The two seams: `SpatialLibrary` (CLOUD implements) and `SpatialPlayback` (ENGINE implements), `LocalRendition`, `RenditionRequest`, `CloudAudioUsage`, `SpatialLibraryEvent`, `SpatialPlaybackSnapshot`, `SpatialAudible`, `SpatialStatusLine` (the sheet's three sentences), `SpatialEventHub`, `NoopSpatialLibrary`, `NoopSpatialPlayback` |
| `Packages/PixlCore/Sources/PixlAudioCore/Spatial/SpatialPreviewTables.swift` | `SpatialPreviewTables.decode(_:)` for `spatial_preview_v1.json` (`table(for:sampleRate:)`, `headroomDb`, `ringCapacity` = 16384), `SpatialPreviewTable`, `SpatialSparseTap`, `SpatialPreviewGolden.decode(_:)` for the golden file. Decoding only |
| Tests | `Tests/PixlModelTests/CloudAudioContractTests.swift` (fixtures in `Fixtures/cloud-audio/`), `Tests/PixlAudioCoreTests/SpatialPreviewTablesTests.swift` (fixtures in `Fixtures/spatial/`, read through `SpatialFixtures.tables()` / `.golden()`: ENGINE's stage test starts from those two calls) |

Why PixlModel: it is the lowest module both PixlAudioCore (the stage) and PixlNet (the job builder) import, so
nobody needs a new module dependency. `Package.swift` is unchanged.

### 1.2 App target

| File | What | Owner from now on |
|---|---|---|
| `App/Services/Spatial/SpatialAudioModel.swift` | `env.spatial`: what the screens read and call (below) | foundation (ask the lead before changing) |
| `App/Services/Spatial/SpatialAudioContext.swift` | Every store either half may need, handed to the factories | foundation |
| `App/Services/Spatial/CloudAudioSettingsStore.swift` | The eight settings in `UserDefaults` (one setter per key) | foundation |
| `App/Services/Spatial/SpatialPreviewResource.swift` | `SpatialPreviewResource.load()` (off the caller's actor) / `loadNow()` for the bundled tables | ENGINE may extend |
| `App/Playback/Spatial/SpatialPlaybackFactory.swift` | `make(_ context:library:) -> any SpatialPlayback`, returns the no-op today | **ENGINE** |
| `App/Services/CloudAudio/SpatialLibraryFactory.swift` | `make(_ context:) -> any SpatialLibrary`, returns the no-op today | **CLOUD** |
| `App/Demo/SpatialDemo.swift` | `SpatialDemo.apply(launch:to:)`, called by `SpatialAudioModel.make` on UI-test launches; seeds nothing today | **UI** |
| `App/Resources/spatial_preview_v1.json` | Byte-identical copy of the worker's file (XcodeGen bundles everything under `App/`: `project.yml:46-47` `sources: - path: App`) | regenerate with `bash ci/check-spatial-fixtures.sh --sync` |
| `AppTests/SpatialAudioModelTests.swift` | The model with main-actor fakes of both protocols | foundation |

`App/AppEnvironment.swift` is wired once and for all: `let spatial: SpatialAudioModel` (line 93), built at lines
288-293 from one `SpatialAudioContext` (after Cloud Studio and Sing exist, before anything uses `self`), started at
line 401 (`spatial.start()`, real launches only). **Nobody needs to edit `AppEnvironment.swift` for this feature**:
plug in through your factory file.

`SpatialAudioContext` carries: `launch`, `defaults`, `settings` (`SettingsStore`), `library`, `playback`
(`PlaybackStore`), `playbackServices` (nil in UI tests), `youtube`, `spotify`, `tais`, `lyricsController`, `cloud`
(`CloudStudio`), `persistence`, `home`, `musicTaste`, `importedHistory`, `tasteAdjustments`, `health`, plus
`settingsStore` and `settingsNow`.

### 1.3 Who calls what

```
screens ──read/call──► SpatialAudioModel (env.spatial, @MainActor @Observable)
                         │ apply(settings) to both, in order, at start() and after every change
                         │ listens to both events() streams
                         │ the ONLY caller of library.request(...) for the playing song
              ┌──────────┴───────────┐
   any SpatialPlayback          any SpatialLibrary
   (ENGINE, from its factory)   (CLOUD, from its factory)
              │   library.localRendition(key)  when it builds an item   ▲
              └── library.events()  for a render that lands mid-song ───┘
```

- ENGINE gets the library as the factory's second argument. It asks `localRendition(_:)` whenever it builds an item
  and listens to `events()` for `.renditionReady` (and `.renditionRemoved`: a file that is playing may be deleted by
  "Remove downloaded renders"; the open item keeps playing, the next build must not find it). It calls
  `markPlayed(_:)` when a render or the Enhanced file starts playing (the store evicts the least recently played
  first). It never calls `request`.
- The model asks for a render when the player's snapshot says one is wanted: `SpatialPlaybackSnapshot.wantedRender`
  (Spatial active, a video id, and the selected profile's render is not what plays). Once per wanted render; again
  after the selection, the song or "Remove downloaded renders" changed things. So ENGINE's whole duty towards the
  cloud is to **publish truthful snapshots** (`songId`, `videoId`, `selection`, `output`, `routePasses`,
  `singInstrumentalOn`, `audible`).
- CLOUD decides whether anything leaves the phone (`spatial.cloud`, network, caps). With the cloud off `request`
  answers `.none`. CLOUD's background queue (spec 6.4) runs inside CLOUD and never goes through the model.
- `RenditionStatus.preview` is never the library's answer: the model derives it (`RenditionStatus.shown`).

### 1.4 Rules for implementations (Swift 6 pitfalls already paid for here)

- Every protocol requirement is `async`; every value crossing is `Sendable`. A `@MainActor final class` may conform:
  `FakeSpatialLibrary` and `FakeSpatialPlayback` in `AppTests/SpatialAudioModelTests.swift` are exactly that, and
  they compile and pass under this target's settings (CI run 43033433910, green). An `actor` or a
  `nonisolated struct` may conform too (the no-ops are structs).
- No requirement takes an `async` closure. The app target builds with approachable concurrency and default
  main-actor isolation; a closure type written in the package means something else there, and conformers then have
  to write `@concurrent` on it (see `App/Demo/DemoClaude.swift:9`). Use `events()` instead.
- `events()` returns a new stream per call. `SpatialEventHub<Event>` does that (`hub.stream(first:)`, `hub.send`).
- Other pitfalls of this target: no ternary that chooses between two closures (use `if`/`else`); a class that holds
  `UserDefaults` is `@unchecked Sendable` when it must be `Sendable`; unwrap optional services
  (`playbackServices` is nil in UI tests); a plain `nonisolated async` function runs on the caller's actor, so
  off-main work is `@concurrent` or `Task.detached`.
- In UI tests (`context.launch.isUITest`) a factory must return something that touches no audio, network or files.
  `SpatialAudioModel.setDemo(snapshot:libraryStatus:usage:)` pins a state for screenshots; it is called from
  `SpatialDemo.apply(launch:to:)` (`App/Demo/SpatialDemo.swift`, UI's file). `spatial.start()` never runs in UI
  tests, and the settings start from an emptied suite (`SettingsStore.ephemeral()`).
- Both factories run inside `AppEnvironment.init`; `apply(settings)` first arrives from `spatial.start()`, during
  `AppEnvironment.start()`, about when the saved queue is restored (paused). To start in the right state without
  waiting for it, read `context.settingsNow` in the factory.

### 1.5 What the screens get from `env.spatial`

Read: `settings` (all eight), `selection`, `snapshot`, `status` (spec 6.1, for the playing song and selected
profile), `statusLine` (`.onDeviceForNow` / `.cloudVersion` / `.headphonesOnly` carry the spec's sentences in
`.text`; `.onDeviceOnly`, `.pausedForSing`, `.none` have none), `isActive`, `usage` (`songsReady`, `bytes`,
`spentThisMonthMicroUSD`, `sentToday`), `isRemovingRenders`, `hasBuiltInCloudKeys`.

Call: `select(_:)`, `setCloud(_:)`, `setPrepareAhead(_:)`, `setEnhancedEnabled(_:)`, `setRoute(_:)`,
`setStorageMB(_:)`, `setMonthlyCapUSD(_:)` (nil = No limit), `setDailyAhead(_:)`, `refreshUsage()`,
`removeDownloadedRenders()`, `renditionsOfCurrentSong()` (manifests for Developer mode's per-song diagnostics),
`reloadSettings()`.

---

## 2. Playback: decks, items, the tap

Folder `App/Playback/` (22 files). The engine is `@MainActor final class DualDeckEngine: PlaybackEngine`
(`DualDeckEngine.swift:17`), built by `PlaybackServices` (`PlaybackServices.swift:47-50`; nil in UI tests, which use
`DemoPlaybackEngine`). Reach it from a factory as `context.playbackServices?.engine`.

### 2.1 Two decks

- `Deck` (`Deck.swift:178`) wraps one `AVQueuePlayer` (`Deck.swift:191`). The engine keeps `deckA`, `deckB`,
  `active` and `var idle: Deck { active === deckA ? deckB : deckA }` (`DualDeckEngine.swift:26-30`). `activeItem` is
  the current `DeckItem` (line 39).
- Every transition between two pieces of audio is a hand-over between the decks. Gapless: the next item is
  prerolled on the idle deck and started on the host clock at the current item's last frame
  (`DualDeckEngine+Crossfade.swift:233-268`, `Deck.start(rate:atHostTime:)` `Deck.swift:300-304`). Crossfade: both
  taps run a gain curve from their own media time (`perform`, `+Crossfade.swift:187-199`). The comment at
  `+Crossfade.swift:43-46` is why: an item with a tap does not join gaplessly inside one `AVQueuePlayer`.
- `fade: FadeRun?` (`DualDeckEngine.swift:61`) is the outgoing deck still finishing; `finishFadeNow()`
  (`+Crossfade.swift:309-316`) ends it and clears the active item's ramp.
- Deck events arrive in `handle(_:_:)` (`DualDeckEngine.swift:592-624`). Hooks the rest of the app uses are single
  closures set by `PlaybackServices.wireEngine()` (`PlaybackServices.swift:111-188`): `onItemTransition`,
  `onRepeatLoop`, `onQueueEnded`, `onPlayingChanged`, `onQueueChanged`, `onTimingChanged`. **They are taken.** Do not
  overwrite them; add your own hook next to them, or fan out from `PlaybackServices`. Likewise
  `PlaybackServices.onUpcomingChanged` / `onPlayStateChanged` belong to the YouTube prefetcher
  (`App/Services/YouTube/YouTubeServices.swift:84-85`).

### 2.2 How an item is made

`DeckItemFactory.makeItem(for:overrideURL:timing:)` (`Deck.swift:83-131`) is the one place:

```swift
var resolved = overrideURL                                   // Deck.swift:84
if resolved == nil { resolved = await resolver.playableURL(for: entry.song) }
…
streaming.attach(to: asset)                                  // :92  pixlstream:// resource loader
tracks = try await asset.loadTracks(withMediaType: .audio)   // :95
…
let parameters = TapItemParameters(logCapacity: tapLogCapacity)   // :122  per-item tap parameters
parameters.mediaDuration.store(seconds)
let item = AVPlayerItem(asset: asset)
item.audioTimePitchAlgorithm = .spectral                     // :126
item.audioMix = ProcessingTap.makeAudioMix(for: track, effects: effects, item: parameters)   // :127
return DeckItem(entry: entry, playerItem: item, asset: asset, tap: parameters, …, isLocalFile: activeURL.isFileURL)
```

Callers: `loadCurrent(at:)` (`DualDeckEngine.swift:398`, the song that starts now), `prepareIncoming`
(`+Crossfade.swift:145`, the next song, built ahead on the idle deck), and the switch (`+Instrumental.swift:125`,
with `overrideURL`). `DeckItem` (`Deck.swift:9-50`) carries `entry`, `playerItem`, `asset`, `tap`,
`durationSeconds`, `isLocalFile`.

**This is where "play the local render for this song" goes, and where the per-item bypass is decided.** The item's
tap parameters are created here, before the tap ever runs, so a flag set on them at this point holds for the whole
item (the bypass-for-render rule). `CloudAudioLocalLayout.rendition(ofAudioFile:)` says whether a URL is a spatial
render (`.spatial(p)`) or the Enhanced file (`.enhanced`).

> **Trap: do not put the rendition choice into `engine.factory.resolver`.** That resolver chain is also how the rest
> of the app finds a song's *own* audio: `TaisServices.audioSource` (`App/Services/ML/TaisServices.swift:40-43`:
> `if let url, url.isFileURL … { return url }`) feeds Sing's cloud jobs (`CloudStudioFactory.swift:22`), the
> on-device separator and lyric sync, and the prefetcher reads it too (`YouTubePlayback.swift:116`). If the resolver
> returned `CloudAudio/<videoId>/sp-studio.flac`, the next job would upload a binaural render as the song. Decide
> the rendition inside `makeItem` (or in a second hook on `DeckItemFactory` that only playback calls) and leave the
> resolver chain as it is. The same goes for the Enhanced file: jobs upload the original.

### 2.3 The processing tap

`ProcessingTap.swift`. One `MTAudioProcessingTap` per item, created `kMTAudioProcessingTapCreationFlag_PreEffects`
(line 66). The state object is `TapContext` (line 77): it holds `effects: AudioEffectsParameters` (one global
instance, `engine.effects`) and `item: TapItemParameters` (per item).

`prepare(maxFrames:format:)` (lines 149-162) runs off the render thread; allocation is allowed there and nowhere
later:

```swift
sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100        // :150  the ITEM's rate
channels = min(Int(format.mChannelsPerFrame), Self.maxChannels)          // :151
interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
isFloat32 = …                                                            // :153
item.sampleRate.store(sampleRate)                                        // :155  readable from the main actor
```

The tap sees the item's own decoded format: 44100 for today's AAC stream, 48000 for a 48 kHz file. That is the
"source rate" of spec section 7, so `SpatialPreviewTables.table(for:sampleRate:)` with this `sampleRate` picks the
table, and nil means bypass. `maxFrames` is the largest buffer `process` will get: size scratch buffers from it.

`process(_:frames:timeRange:endOfStream:)` (lines 230-315), in order:

| # | Lines | Stage |
|---|---|---|
| – | 233-253 | media time of the first frame, meters (`processedMediaTime`, `processedFrames`), `bindChannels` (strided pointers per channel; interleaved or planar) |
| 1 | 257-261 | ReplayGain: `applyGainRamp(from: currentReplayGain, to: replayGain, …)`, soft limiter only when boosting above unity |
| 2 | 263-293 | Equalizer chain: loudness pre-gain, 11 biquads per channel (`vDSP_biquadm`), `applyWidth` (the "virtualizer", line 290), `limit` when `needsLimiter` (line 291). Skipped while bypassed (`bypass`, `tailFrames`) |
| 3 | 295-297 | Mid/side vocal reducer (`effects.midSideAttenuation`, Magic Instrumentalize) |
| 4 | 299-307 | Crossfade ramp from this item's media time (`item.ramp`), then `item.fixedGain` |
| – | 309-314 | peak meter, Music Haptics analysis, optional test log |

Where the stage of spec section 7 fits: **after 3, before 4** (EQ and the vocal reducer work on the plain stereo
song; the crossfade and the deck gain stay last so every hand-over still fades what is heard), followed by a
`limit(frames:)` pass while the stage is active: spec 7 makes `SoftLimiter` "the only protection" after the stage,
and today the limiter only runs when the EQ or a boost asks for it (lines 261 and 291). While the stage is active,
skip `applyWidth` (line 290): spec 6.3 keeps the old width effect bypassed.

How to feed it, following the patterns already in `TapParameters.swift`:

- Global, changes rarely (the selected profile, active or not): add to `AudioEffectsParameters` (line 72) an
  `Atomic` or a `ParameterRing` (line 13) the render thread reads once per buffer, like `midSideAttenuation`
  (line 84). `ParameterRing` values must be trivial (no references): publish a profile index and an "active" flag,
  not arrays.
- Per item (bypass for a render, the level factor): add `Atomic`s to `TapItemParameters` (line 146), next to
  `replayGainVolume` (148) and `fixedGain` (152). They exist before the tap is created (`Deck.swift:122`).
- Coefficients: decode `SpatialPreviewTables` once (`SpatialPreviewResource.load()`), copy into buffers the tap
  owns in `prepare` (as `localBlock` is at lines 133-134 and 199-205). All twelve tables are 12 × (2×192 + 2×40×3)
  numbers: keep them all, so a change of profile is an index change and never an allocation.
- State per tap: FIR history, one delay ring of `tables.ringCapacity` (16384) frames per channel, four biquad
  states. Allocate in `init`/`prepare`, free in `deinit` (lines 120-145 show the pattern).
- Ramps: `applyGainRamp` (lines 370-383) is linear across one buffer. The spec's 80 ms wet/dry ramp is longer than
  a buffer at small IO sizes and shorter at large ones: carry the ramp position in the context (as
  `currentReplayGain` is carried, line 113) and count frames.
- Real-time rules (AGENTS.md): no allocation, locks, logging or Swift runtime work in `process`.
  `effects.settingsLock` (a `Mutex`, `TapParameters.swift:82`) is main-actor only: never take it on the render
  thread.
- The same tap runs offline (`AVAssetReaderAudioMixOutput`, see the header comment lines 16-17 and
  `AppTests/ProcessingTapTests.swift`): that is how to test the stage in the tap, on top of the PixlCore golden test.

Sample-rate changes of the output route do not change the tap's rate (the tap is before the mixer). They only
redesign the EQ (`handle(.routeChanged)`, `DualDeckEngine.swift:716-718`).

### 2.4 After a media-services reset

`rebuildAfterMediaServicesReset()` (`DualDeckEngine.swift:723-743`) throws both decks away and reloads the current
item through `loadCurrent`. Whatever the spatial side keeps per item is rebuilt by `makeItem`; whatever it keeps
globally lives in `effects`, which survives.

---

## 3. The Sing swap (the "alternate rendition" mechanism)

`App/Playback/DualDeckEngine+Instrumental.swift` (233 lines) is the mechanism spec 6.3 tells you to reuse.

### 3.1 API

```swift
func switchCurrentAudio(to url: URL?) async -> Bool                                   // :56   nil = the song's own audio
func switchCurrentAudio(to url: URL?, placement: SwitchPlacement?,
                        requireAligned: Bool = false) async -> SwitchOutcome          // :64
func switchCurrentAudio(toClip url: URL, offsetSeconds: Double,
                        placement: SwitchPlacement?) async -> SwitchOutcome           // :73   Sing's preview piece
typealias SwitchPlacement = @MainActor (_ earliestSeconds: Double)
                              -> (startSeconds: Double, fadeSeconds: Double)          // :34
enum SwitchOutcome { case switched, failed, abortedBySeek, misaligned }               // :19-29
```

### 3.2 What `switchAudio` does (lines 85-220)

1. Refuses when the song's own planned transition is too close (`transitionTooClose`, lines 94-100, 1 s clearance:
   `switchClearanceSeconds`, line 49). Then `finishFadeNow()` and `cancelCrossfadePlan()` (101-102).
2. Builds the other audio for the **same queue entry**: `factory.makeItem(for: outgoing.entry, overrideURL: url)`
   (line 125). `url == nil` goes through the resolver: "its own audio".
3. Guards: still the same item and no fade running (133-136); playhead not moved (`playheadMoved`, 114-116: a seek
   generation change, or more than 0.25 s backwards); with `requireAligned`, durations within 50 ms
   (`instrumentalAlignmentToleranceSeconds`, line 41; check at 138-141) or `.misaligned`.
4. Loads it on the idle deck 0.5 s ahead of the playhead (`switchLeadSeconds`, line 43; `deck.load(incoming, at:
   target)` line 145), waits until ready (`waitUntilReady`, ≤ 5 s, lines 223-232).
5. Paused: a silent swap at the current position (149-159).
6. Playing: asks the placement where to start (161-177), prerolls (up to three tries, 181-203), publishes two
   **linear** ramps (`CrossfadeRamp(role: .incoming/.outgoing, curve: .linear, …)`, 205-209), starts the idle deck at
   that media time on the host clock (`deck.start(rate:at:atHostTime:)`, 210-212), and swaps decks (213-219). The
   outgoing deck becomes `fade` and is torn down by the fade monitor.
7. Every exit but success re-plans the song's own next transition (`leave`, 105-112).

The queue entry never changes, so the queue, Now Playing, lyrics timing and stats do not notice: exactly what spec
6.3 asks.

### 3.3 What needs changing for renders

- **Fade length.** `clampedFade` (117-119) clamps to 0.3 … 0.7 s (`instrumentalMinCrossfadeMs = 300`, line 39;
  `instrumentalCrossfadeMs = 700`, line 37) and the default with no placement is 0.7 s. Spec 6.3 wants about 250 ms:
  give the render switch its own bounds instead of lowering Sing's.
- **"At least 20 s left"** is not checked here: only the clearance before the song's own transition. Add it at the
  call site.
- **"At a quiet moment when the app can tell":** that is what a `SwitchPlacement` is for. Sing's is
  `InstrumentalController.placeSwitch` (`App/Services/ML/InstrumentalController.swift:588-598`), built on
  `SingSwitchPlanner` and the word-timed lyrics (`gapIndex`, 582-585). Reuse it when lyrics are loaded
  (`context.lyricsController`: `prepared`, `preparedSongId`, `store.offsetMs`), else `placement: nil` (as soon as
  ready).
- **Bypass for the incoming item** must be set when it is built (section 2.2), before `deck.load`.
- **The level factor** changes with the same switch: ramp it with the crossfade (section 5).
- **Back to the stream** (Spatial switched off, headphones unplugged, profile changed with no local render):
  `switchCurrentAudio(to: nil, …)`. This works today for Sing's "Play original" (`playOriginal`,
  `InstrumentalController.swift:878-897`), so spec 6.3's "swapped back to the stream" is the easy branch on iOS.
  Note that unplugging headphones also pauses playback (`AudioSessionController.handleRouteChange`,
  `AudioSessionController.swift:210-215`): while paused the swap is the silent one of step 5.

### 3.4 Living next to Sing

`InstrumentalController` (`@MainActor @Observable`, `env.tais.instrumental`; file above, 925 lines) owns the Sing
state: `isAvailable` (203), `isActive` (205, the instrumental is what plays), `isSwitching` (206), `singPhase`
(208). It talks to the engine through `InstrumentalSwitching` (170-179), which `DualDeckEngine` already conforms to
(181).

- "Sing's instrumental mode is on" for `SpatialActivation.isActive` is `context.tais.instrumental.isActive`. It is
  observable: follow it with `withObservationTracking` as the controller itself does (290-302).
- Sing calls `switchCurrentAudio(to: nil, …)` to bring the vocals back (`playOriginal` 889, `leaveClip` 736). With
  the rendition choice inside `makeItem`, "its own audio" then correctly becomes the spatial render again when
  Spatial is active. While Sing is on, a render that lands must not switch in.
- Only one switch runs at a time per controller (`isSwitching`), but the engine itself does not serialise
  `switchAudio` calls from two owners. A second call while a fade runs fails at line 133 (`fade == nil`). The
  spatial side must check Sing's `isSwitching` / `singPhase` before switching and expect `.failed`.
- A new song always starts with its own audio (`apply`, 330-342). The spatial side has the opposite rule (a local
  render plays from the start), which again belongs in `makeItem`.

---

## 4. Source resolution, video ids, format info

### 4.1 The resolver chain (innermost first)

| Layer | File | What it returns |
|---|---|---|
| `DefaultPlayableURLResolver` | `App/Playback/PlayableURLResolver.swift:21-35` | `contentUriString` as a URL, or the file path |
| `StreamingPlayableURLResolver` | `App/Services/YouTube/YouTubePlayback.swift:8-22`, installed at `YouTubeServices.swift:80` | for a song with a video id: the downloaded file (`DownloadFiles.existingFile`, line 14), else the complete cache file (`cache.completeFileURL`, line 15), else `pixlstream://<videoId>` (line 16) |
| `SpotifyPlayableURLResolver` | `App/Services/Spotify/SpotifyYouTubeBridge.swift:80-156`, installed outermost at `AppEnvironment.swift:251` | for a Spotify song: its matched video (`videoId(for:)`, 124-129: the stored match, else an on-demand match with a 25 s cap), then the layer above for that video |

`PlayableURLResolving` is `playableURL(for:)` plus `recoverPlayableURL(for:afterFailedURL:)`
(`PlayableURLResolver.swift:7-17`): after a failed load `makeItem` asks once for another URL (`Deck.swift:98-113`),
which for a Spotify song means the next-best video. **A rendition belongs to one video**: after such a recovery the
video id changed and the old video's renders do not apply.

`pixlstream://` assets get their bytes from `YouTubeResourceLoader` (`App/Services/YouTube/YouTubeResourceLoader.swift`),
attached per asset by `StreamingResourceLoaderRegistry` (`PlayableURLResolver.swift:40-78`, `attach(to:)` line 67).

### 4.2 How the video id of a song is known

- **The playing item:** from its URL, in every case. Stream: `YouTubeSongIdentity.videoId(from: url)`
  (`App/Services/YouTube/InnerTubeService.swift:203-209`) reads `pixlstream://<videoId>`. Downloaded file:
  `Application Support/Downloads/<videoId>.m4a` (`DownloadFiles.fileURL`, `YouTubePlayback.swift:31`). Complete cache
  file: `Library/Caches/YouTube/streams/<videoId>.m4a` (`StreamCache.dataURL`, `StreamCache.swift:33`). For the two
  files the id is `url.deletingPathExtension().lastPathComponent`, checked with `CloudLibrary.isValidVideoId`. The
  item's URL is `deckItem.asset.url`. A render file gives it through
  `CloudAudioLocalLayout.rendition(ofAudioFile:)`.
- **A library song, without playing it:** `LiveCloudStudioHost.streamIdentity(for:)`
  (`App/Services/Cloud/CloudStudioDependencies.swift:196-200`): `YouTubeSongIdentity.videoId(for: song)` for `yt:`
  songs and `pixlstream://` URIs (`InnerTubeService.swift:190-200`), else the stored Spotify match
  (`persistence.matchedVideoId(spotifyId:)`, wired at `CloudStudioFactory.swift:25-27`). It returns nil for a
  Spotify song that was never matched: play-time matching (`SpotifyPlayableURLResolver.videoId(for:)`) is what
  creates a match on demand.
- **Before `makeItem` has a URL** (to look up a local render first): ask the same two functions in that order, and
  remember that the id can still change by recovery.
- A Cloud Studio job re-checks the id when its result lands (`CloudStudio.collect`,
  `App/Services/Cloud/CloudStudio.swift:2141-2148`: "This song now plays a different YouTube video…").

### 4.3 What format info exists

- `ResolvedStream` (`Packages/PixlCore/Sources/PixlNet/YouTube/InnerTubeModels.swift:88-98`) carries only `url`,
  `userAgent`, `strategyName`. The chosen `YouTubeAudioFormat` (`itag`, `mimeType`, `bitrate`, lines 28-52) is not
  kept past resolution.
- The itag is recoverable: from the googlevideo URL's `itag` parameter (`StreamFetcher.store`,
  `App/Services/YouTube/StreamFetcher.swift:160`), which is stored with the response's content type in
  `StreamCache.Meta` (`StreamCache.swift:10-17`: `contentLength`, `contentType`, `itag: String?`). So for a song that
  streamed or was cached: `await cache.meta(videoId)` gives itag and MIME type.
- A downloaded file (`Downloads/<videoId>.m4a`) has no recorded itag. Its codec and rate come from the asset
  (`CloudAudioPreparer.prepare` reads `mFormatID` and `mSampleRate`, `App/Services/Cloud/CloudAudioPreparer.swift:148-154`).
- `CloudJobRecord.itag` and `.contentLength` (`Packages/PixlCore/Sources/PixlNet/Cloud/CloudJobRecord.swift:20-21`)
  exist but nothing in the app sets them. The job's `library.source` (`itag`, `codec`; spec 4, "only recorded")
  needs one of the two sources above.
- Today's stream is AAC: `AudioFormatPolicy.iOS` (section 9). The player's "file info" chip reads the `Song`
  (`mimeType`, `bitrate`, `sampleRate`), not the stream.

### 4.4 Where a local render is returned for the next play

Section 2.2: in `makeItem`, before the resolver is asked. The three callers of `makeItem` then cover every case of
spec 6.3: the song that starts (`loadCurrent`), the next song prepared ahead (`prepareIncoming`: a streamed target
is built in the last 4.5 s, `handOverPrepareLeadMs`, `+Crossfade.swift:51`), and the in-song switch. Two details:

- `adoptPreparedIncoming` (`DualDeckEngine.swift:498-540`) lets a skip take over the item already prepared on the
  idle deck. If the selection or the route changed since it was built, that item has the wrong rendition or the
  wrong bypass flag: re-plan (`rescheduleNext()`, line 561) when the spatial state changes.
- `library.localRendition` is `async` and is awaited on the path to first audio. CLOUD answers from memory; still,
  skip the call entirely when Spatial is not active and Enhanced is off.

---

## 5. Gain: where the level rule lives

What exists:

- `TapItemParameters.replayGainVolume` (`TapParameters.swift:148`), written by `prepareReplayGain(_:)`
  (`DualDeckEngine.swift:749-765`):

  ```swift
  guard replayGainEnabled, item.isLocalFile else {      // :750
      item.tap.replayGainVolume.store(1)
      return
  }
  ```

  ReplayGain is read from a **local file's tags** only (`ReplayGainReader`, `App/Playback/ReplayGainReader.swift`;
  maths in `Packages/PixlCore/Sources/PixlAudioCore/ReplayGain.swift:92`). It is behind Developer mode
  (`PlaybackSettingsSection.swift:60-72`) and off by default (`SettingsStore.swift:477`).
- The tap applies it in `effectiveReplayGain()` (`ProcessingTap.swift:221-226`): clamped to 0 … 1 unless
  `effects.allowReplayGainBoost` (never set anywhere in the app, so always 0 … 1), ramped per buffer (lines 258-260).
- **There is no loudness normalisation for streams.** A streamed song, and its downloaded `.m4a`, carry no ReplayGain
  tags, so their gain is 1. In this Spotify-only app that is nearly every play.
- `SoftLimiter` is `Packages/PixlCore/Sources/PixlAudioCore/ReplayGain.swift:291-315` (`defaultThreshold` 0.891,
  `limit(_:)`), used by the tap's `limit(frames:)` (`ProcessingTap.swift:386-395`).
- The EQ's "loudness enhancer" is a make-up pre-gain inside stage 2 (`preGain`, lines 279-281), not normalisation.

So the rule `min(1.0, gain × 1.585)` has one natural home: **`effectiveReplayGain()`**. Give `TapItemParameters` a
per-item headroom factor (1 when no spatial rendition is audible for this item, `SpatialLevel.linear(db: headroomDb)`
when one is) and return `SpatialLevel.playbackGain(gain, headroomDb:)` there. Use `LocalRendition.headroomDb` (the
manifest's) for a render and `SpatialPreviewTables.headroomDb` for the stage. Consequences to know:

- With gain 1 (every stream today) the result is still 1: Spatial plays 4 dB under stereo, as the spec says it does
  without normalisation. The factor only does something for a local file with ReplayGain on.
- A render file is a local file: `prepareReplayGain` will read its tags (it has none: volume 1). Fine, but do not
  let "local file" be mistaken for "the song's ReplayGain applies".
- The stage's own on/off already ramps over 80 ms; the level factor must move with it (and with the 250 ms
  crossfade for a render), not jump at a buffer edge.

---

## 6. Route

- The engine side: `AudioSessionController` (`App/Playback/AudioSessionController.swift`). Category `.playback`,
  `.longFormAudio` (67-73). Route changes arrive in `handleRouteChange(reason:)` (208-226) and reach the engine as
  `Command.pauseForRouteLoss`, `.resumeForRouteReturn`, `.routeChanged` (12-23; handled at
  `DualDeckEngine.swift:703-720`). `session.onCommand` is a single closure owned by the engine (line 700): extend
  `handle(_ command:)`, do not replace the closure. `routeDescription` (185-187) prints ports for the Device
  capabilities screen.
- The UI side: `AudioRouteMonitor.shared` (`App/Features/NowPlaying/AudioRouteMonitor.swift`), `@Observable`, kinds
  `phone headphones bluetooth airPlay carAudio other` (12-19), refreshed on every route change (42-45). Its mapping
  (68-75):

  ```swift
  case .builtInSpeaker?, .builtInReceiver?, nil: newKind = .phone
  case .headphones?, .usbAudio?, .lineOut?: newKind = .headphones
  case .bluetoothA2DP?, .bluetoothLE?, .bluetoothHFP?: newKind = .bluetooth
  case .airPlay?: newKind = .airPlay
  case .carAudio?: newKind = .carAudio
  ```

  It is a view-layer singleton with a UI-test demo route (30-40): read the session directly in the engine.
- Spotify Connect is not an audio route: `PlaybackStore.remoteOutputName != nil` (`App/Stores/PlaybackStore.swift:36`)
  means another device plays and the local engine is paused.

What counts as headphones (spec 6.1) in `SpatialOutputKind` terms, as a suggested mapping of
`AVAudioSession.currentRoute.outputs.first?.portType`:

| Port | `SpatialOutputKind` | Passes `headphones` mode |
|---|---|---|
| `.headphones` | `.wiredHeadphones` | yes |
| `.usbAudio` | `.usbHeadset` | yes |
| `.bluetoothA2DP`, `.bluetoothLE` | `.bluetooth` | yes (a speaker counts, the phone cannot tell) |
| `.builtInSpeaker`, `.builtInReceiver`, none | `.phoneSpeaker` | no |
| `.airPlay` | `.airPlay` | no |
| `.carAudio` | `.car` | no |
| `.bluetoothHFP`, `.lineOut`, `.HDMI`, anything else | `.other` | no |
| Connect session active | `.remote` | never, in either mode |

`SpatialActivation.routePasses(mode:output:)` is the tested rule. Two things differ from `AudioRouteMonitor`'s
grouping on purpose: `.lineOut` (a dock or an amplifier, i.e. speakers) and `.bluetoothHFP` (a call route) are not
headphones here. A car over Bluetooth is `.bluetoothA2DP` and passes: the phone cannot tell it from a speaker.

---

## 7. Cloud Studio

### 7.1 The pieces

| Piece | Where | Reusable as is? |
|---|---|---|
| Orchestrator `CloudStudio` (`@MainActor @Observable`, `env.cloud`) | `App/Services/Cloud/CloudStudio.swift` (2439 lines) | the pump, the transfers, the priority lane and the budgets yes; it only knows the `instrumental` task: **needs a library job kind** (7.3) |
| Its seams (`Dependencies`: store, host, transfers, preparer, inspector, RunPod, objects, clock) | `CloudStudio.swift:174-201`; protocols in `CloudStudioDependencies.swift` | yes. AppTests drive the orchestrator with fakes (`AppTests/CloudStudioTests.swift`: `FakeRunPod` 1153, `FakeCloudObjects` 1214) |
| Assembly | `CloudStudioFactory.swift` (`CloudStudio.make`, 9-61) | yes |
| Settings: consent, keys, caps | `CloudSettings.swift` (keys `cloud_studio_*`, 15-56) | Sing's own; library jobs get their own caps (7.5) |
| Built-in keys | `CloudDefaults.swift`, `CloudCredentials.swift` (do not read `App/Resources/CloudDefaults.enc`) | yes: `settings.configInput` (`CloudSettings.swift:330-332`) |
| S3 signing | PixlNet `S3Signer.swift` (`presignedURL(method:key:query:expiresSeconds:)` 122, `signedRequest` 147); app `CloudPlatform.signer(_:)` (`CloudPlatform.swift:36`) | yes, any key including `lib/…` |
| Object client | PixlNet `CloudObjectStore.swift`: `CloudObjectStoring` (9-21: `presignedURL`, `head`, `get`, `put`, `delete`, `list`), `CloudObjectClient` (48) | yes: `get(key:)` returns nil for 404, which is spec 6.2 step 2's "is the manifest there" |
| RunPod client | PixlNet `RunPodJobsClient.swift`: `RunPodJobsAPI` (216-226: `run`, `status`, `cancel`, `health`, `selftest`) | yes |
| Job schema | PixlNet `CloudJobSchema.swift`: `CloudTask` (34-49: `instrumental vocals stems4 lyrics`), `CloudJobInput` (107-152), `CloudJobResult` (365), `CloudOutputFile` (472), `CloudTimings` (526), `CloudModelsInfo` (436) | **needs the spec 4 additions** (7.3) |
| Builder | PixlNet `CloudJobBuilder.swift`: `request(for:build:lyrics:lastInBatch:presign:)` (72-108), `outputSlots` (13-20), `objectKeys(for:)` (112-129) | **needs the `library` block** |
| Keys, limits, timing, cost, budget | PixlNet `CloudQueuePolicy.swift`: `CloudKeys` (10-58), `CloudLimits` (62-96), `CloudTiming` (100-143), `CloudJobMachine` (211), `CloudSelector` (350), `CloudCost` (475-546), `CloudBudget` (549-592), `CloudImportCheck` (663-690), `CloudRetention` (694-727) | mostly; see 7.3 |
| Job record | PixlNet `CloudJobRecord.swift` (one `Codable` struct, stored as one JSON file by `CloudJobStore`, `App/Services/Cloud/CloudJobStore.swift`) | **new fields must be optional** (comment at 93-95: a non-optional new field makes every stored list unreadable) |
| Priority lane | PixlNet `CloudPriorityLane.swift` | yes: spec 6.2 "A Sing job still has priority over library jobs" is its tiers (`tier(of:priorityKeys:)`, 47) |
| Preparer | `CloudAudioPreparer.swift` | yes, see 7.2 |
| Transfers (background `URLSession`) | `CloudTransfers.swift` (session id line 44; `upload` 112/118, `download` 144, staging 206-234) | yes, with one catch: `isSafeSlot` (247-251) allows only `a-z 0-9 _`, so the slot name `sp-studio` is refused. Use a transfer slot such as `sp_studio`, or widen the check |
| Background work | `CloudBackground.swift` (`BGAppRefresh` `…pixlaudio.refresh` line 23, `BGProcessing` `…cloud-processing` line 26, `registerProcessing(for:)` 68); planner PixlNet `CloudBackgroundPlanner.swift` | yes. Identifiers are already in `project.yml:95-100`: a new one means a `project.yml` change (7.6) |
| Device conditions | `CloudDeviceConditions.swift` (`autoConditions()` 51: Wi-Fi, battery, heat, free space, Low Power Mode); PixlNet `CloudAutoConditions` (`CloudAutoBudget.swift:104`) | yes: this is spec 6.4's "Wi-Fi only, battery not low, never in Low Data Mode" |
| Prepare ahead | `SingPrepareRunner.swift` (`evaluate()` 224-306); ranking PixlLibrary `SingPrepareRanker.rank(_:limit:)` (`Packages/PixlCore/Sources/PixlLibrary/SingPrepareRanker.swift:197`), inputs `SingPrepareInputs` (24) with an `excluded` set | the ranker yes (spec 6.4 "the same ranking"); the runner is Sing's: copy its shape, with `excluded` = songs that already have a local render of the selected profile |
| Auto budget | PixlNet `CloudAutoBudget.swift` (`CloudAutoLedger` 11, `affordableCount` 76); app `CloudStudio.startAuto` (693-722), ledger helpers 803-841 | the ledger type yes; the stored ledger and caps are Sing's |
| Local results | `App/Services/ML/InstrumentalFiles.swift` (`Stems/`), installed by `LiveCloudStudioHost.installInstrumental` (`CloudStudioDependencies.swift:249-257`) | pattern only. Renders go to `Application Support/CloudAudio/` (`CloudAudioLocalLayout`); `CloudStudio.moveAtomically` (2431) is the move to copy |
| Active jobs | `App/Services/ActiveJobs.swift` (`Sources` 27-36, rows from `CloudActiveJobMapper.rows` at 482, summary at 464); PixlNet `CloudActiveJobs.swift` (`weight` 11, `status` 31, `rows` 90); sheet `App/Features/Home/ActiveJobsSheet.swift` | yes: library jobs that are `CloudJobRecord`s show up by themselves, one row per batch. Their words come from `CloudActiveJobMapper.status` |
| Queue and settings screens | `App/Features/CloudStudio/CloudQueueView.swift`, `CloudProcessingSettingsView.swift` | Sing's screens; spec 6.4 wants library work silent ("only the Active jobs row") |
| Notifications | `CloudNotifier.swift`; `CloudStudio.send` asks permission for person-started batches only (888-896) | library jobs: none (spec 6.4) |

### 7.2 Preparing and uploading a song today

`CloudStudio.prepare(jobKey:)` (`CloudStudio.swift:1354-1415`):

```swift
let source = try await dependencies.host.audioSource(for: song)        // :1367  downloads a streamed song first
…
let prepared = try await dependencies.preparer.prepare(source: source, jobKey: jobKey,
                                                       forceDecode: record.isStreamed || record.isClip,   // :1377
                                                       paced: !isPriority, clip: record.clipRange)
```

- `host.audioSource` is `TaisServices.audioSource` (`App/Services/ML/TaisServices.swift:40-…`): a streamed song is
  **downloaded permanently** to `Downloads/<videoId>.m4a` first (up to three tries of 90 s), unless the resolver
  already returns a file (a download, or a stream cache file that is complete). Spec 6.4's "a song whose audio is
  not on the phone may be fetched for this (Wi-Fi only)" is this path. Mind the side effect for library jobs: a
  render asked for because a song merely *played* would leave a permanent download behind (it counts in Settings ›
  Offline storage and the song gets its "downloaded" badge, `DownloadBadges`). Sing does that on purpose, after a
  tap. For library jobs either wait for the song's cache file to be complete, or fill the cache instead
  (`StreamFetcher.fillCache`, `App/Services/YouTube/StreamFetcher.swift:96-106`, then `cache.completeFileURL`),
  from a source function of your own in `App/Services/CloudAudio/` so `TaisServices` stays untouched.
- `CloudAudioPreparer.prepare` (`CloudAudioPreparer.swift:138-215`) decides copy / passthrough / decode in `route`
  (121-127). **Every streamed song is force-decoded** to 44.1 kHz stereo 16-bit FLAC (`sampleRate` 64,
  `decodeToLossless` 234). AAC passthrough only ever applied to local AAC files, which this Spotify-only app no
  longer has. See 12.1.
- The record then holds `inputExt`, `sha256`, `bytes`, `durationMs`, `decodedFrames`, `sampleRate`, `videoId`
  (1392-1404), and the upload goes out through a presigned PUT valid 24 h (`startUpload`, 1418-1442).
- The import check compares the result's frame count with the phone's own decode (`samplesLineUp`, 2317;
  `CloudImportCheck.samplesMatch`, PixlNet `CloudQueuePolicy.swift:683`). A render has "the input's sample rate and
  frame count" (spec 3), so the same check applies to it: `audio.samples` against `record.decodedFrames`.

### 7.3 What a library job needs (spec 4)

Nothing below exists yet. In PixlNet:

- `CloudTask` gains `spatial` and `enhance`. `outputSlots` for them are the library slots (`RenditionKind.slot`),
  but those go into `library.renders[].audioPut` / `manifestPut`, **not** into `output.put`: `output.put` keeps only
  `manifest` (the job's own, still required).
- `CloudJobInput` gains `library` (optional, `Codable`): `v` (= `CloudLibrary.version`), `videoId`,
  `source {itag, codec}`, `restore` (`auto` / `off`), `renders: [{profile, audioPut, manifestPut, manifestGet}]`,
  `enhanced {audioPut, manifestPut, manifestGet}`. Keys come from `CloudLibrary.audioKey` / `manifestKey`; sign
  them with the same `CloudPresign` closure the builder already takes (`CloudJobBuilder.swift:8`) and
  `CloudTiming.workerPresignSeconds` (line 108).
- `CloudJobResult` gains `library` (`videoId`, `libV`, `renders: [profile: state]`, `enhanced`, `restore`,
  `stemMode`), the output slots `sp-<profile>` and `enhanced` in `outputs`, `timings.restoreMs / stems6Ms /
  renderMs`, `models.stems6 / restorer`. Per-output states: `ok`, `exists`, `failed`, and `not_needed` for
  `enhanced`. All optional.
- Progress strings `restore:NN`, `stems6:NN`, `render:NN`: `CloudProgress.parse` (`RunPodJobsClient.swift:43`) and
  the words in `CloudActiveJobMapper.status` (`CloudActiveJobs.swift:31`).
- `CloudTiming.executionTimeoutMs` is 900 000 (line 104) and rides in every `/run` body
  (`CloudJobBuilder.swift:105-106`). Spec 5 raises the endpoint's timeout to 1800 s for library jobs: the request
  policy must follow for those jobs, or RunPod kills them at 15 minutes.
- `CloudCost.estimatedSeconds` (509) knows `warmSecondsStandard` 33 s and extras for stems: a library job's
  estimate is new (six-stem cascade plus one render per profile). It feeds the cap check before sending.
- `CloudJobRecord`: a job kind, the library request (profile list, whether `enhance` is asked), and per-output
  results. All new fields optional (93-95).
- Fixtures: the worker's examples for the new shapes go to `Tests/PixlNetTests/Fixtures/cloud/` with
  `bash ci/check-cloud-fixtures.sh --sync <worker ref>`; every `.json` there must be a worker example
  (`ci/check-cloud-fixtures.sh`). Hand-written ones go to `Fixtures/cloud-phone/`. Spec 8: "builder output equals
  the examples".

In the app (`CloudStudio.swift`), a library job differs from an instrumental job in these places:

- **Before sending** (`preview` 474-505, `startNow` 510-534, `send` 856-898): `CloudSelector.select` (PixlNet 363)
  skips songs that already have an instrumental and plans the `instrumental` task. A library job has its own
  "already there" checks: the local store, then `objects.get(key: manifestKey)` (spec 6.2 steps 1-2), and those are
  cheap and allowed before any job exists.
- **Submit** (`submitReadyBatches` 1705, `submit` 1858-1911): builds the body through `CloudJobBuilder.request`.
- **Result** (`take` 2049-2070): `record.takeResult` and `result.hasResults`.
- **Collect** (`collect` 2132-2171): only knows the `instrumental` slot and insists that the output key is inside
  the job's own folder (`output.key.hasPrefix(CloudKeys.outputPrefix(jobKey:))`, line 2155). Library outputs live
  under `lib/`: check them against `CloudLibrary.audioKey(_:)` instead, fetch the render manifest
  (`sp-<profile>.json`), run `CloudLibraryManifest.check(for:)`, download the FLAC, verify with
  `audioMatches(bytes:sha256:)` (`CloudPlatform.fileDigest`, `CloudPlatform.swift:15`), then move it into the store
  with its manifest beside it.
- **Cleanup** (`cleanUpLocal` 2395, `deleteRemote` 2401, `CloudJobBuilder.objectKeys`): delete `in/` and
  `out/<jobKey>/` as today; **never** a `lib/` key (spec 6.2 step 4). `objectKeys(for:)` already refuses keys
  outside the job's folder (118-126): keep it that way.
- **Step 2 without a job** (the render is already in the shared library): a download with no upload and no RunPod.
  The transfer layer keys everything by a job key (`CloudTransfers.taskDescription`, 238; staging 220-225), so
  either give library downloads a record of their own with a synthetic job key, or fetch through a separate small
  path. Either way it must survive a relaunch (background session, `reconcileTransfers` 1289).

### 7.4 Sing's rules that carry over

- Consent: nothing is sent while `settings.isEnabled` is false (`CloudSettings.swift:77-83`; default on exactly
  when built-in keys are available, `CloudKeyChoice.defaultEnabled`). `spatial.cloud` has the same default but is a
  separate switch. The spec does not say whether Cloud Studio's own switch also gates library jobs: see 12.4.
- Network: `networkAllowsUpload()` (845-853), `useCellular`; auto work is unmetered only (`autoMayUseNetwork`,
  753; `transfers.allowsCellular`, 1437).
- Heavy work: `HeavyWorkGate`, `HeavyJobGovernor` (1315-1319); safe mode holds preparations back.
- Order: `CloudPriorityLane.ordered` (1328). Library jobs sit below Sing and below anything sent by hand.
- Endpoint: three GPU workers on the built-in endpoint (`CloudKeyChoice.parallelWorkers`), batches gated by
  `CloudBatchGate` (PixlNet `CloudQueuePolicy.swift:402`), the last job of a burst marked `last_in_batch`
  (`markingLastInBatch`, `CloudJobBuilder.swift:135`).

### 7.5 Caps

Sing: `monthlyCapMicroUSD` (default $3, `CloudCost.defaultMonthlyCapMicroUSD`, PixlNet `CloudQueuePolicy.swift:483`),
capped at $3 with the built-in keys (`CloudKeyChoice.effectiveMonthlyCap`, PixlNet `CloudDefaults.swift:163`),
checked through `committedThisMonthMicroUSD` (`CloudStudio.swift:348`) and `CloudBudget.allows`. Auto-prepare: its
own budget and daily count in `CloudAutoLedger` (`CloudSettings.swift:44-51`, `reserve` / `settle` / `refund` at
`CloudStudio.swift:819-841`).

Library jobs (spec 6.1): `cloudAudio.monthlyCapUSD` (30, separate from Sing's; `CloudAudioSettings.monthlyCapMicroUSD`,
nil = no limit) and `cloudAudio.dailyAhead` (25). They arrive through `SpatialLibrary.apply(_:)`. **The month's
spend must be counted apart from Sing's**: today every record's cost counts against the one cap
(`CloudBudget.committedMicroUSD`, PixlNet 560), and `effectiveMonthlyCap` clamps to $3 with built-in keys. A library
record needs to be left out of Sing's sum and counted in its own. `CloudAudioUsage.spentThisMonthMicroUSD` and
`.sentToday` report it to Settings.

Storage (spec 6.1, 6.2): `cloudAudio.storageMB` (3072), least recently played removed first
(`SpatialLibrary.markPlayed`). `StreamCache.evictIfNeeded` (`StreamCache.swift:137-154`) is the house pattern for an
LRU by a stored access time.

### 7.6 Background

- A background relaunch never runs `AppEnvironment.start()` (comment at `AppEnvironment.swift:82`): Cloud Studio is
  built in `init` and registers its `BGProcessing` handler there (`CloudStudioFactory.swift:59`). The library
  factory also runs in `init` (`AppEnvironment.swift:288`), so it may register there too, but `apply(settings)`
  only arrives from `spatial.start()`: read `context.settingsNow` in the factory if you need settings earlier.
- `BGTaskSchedulerPermittedIdentifiers` are listed in `project.yml:95-100`. Reusing Cloud Studio's two identifiers
  (the pump already runs under them) needs no `project.yml` change.

---

## 8. Settings and UI

### 8.1 Where settings live

- App settings: `SettingsStore` (`App/Stores/SettingsStore.swift:227-264`), one `@Observable` object per category,
  keys in `PreferenceKeys` (12-205), values in `UserDefaults` with `didSet` writes. Reading helpers at 268-273.
- Spatial and Enhanced do **not** go in there: `env.spatial.settings` is the one source, stored by
  `CloudAudioSettingsStore` under `spatial.profile`, `spatial.route`, `spatial.cloud`, `spatial.prepareAhead`,
  `enhanced.enabled`, `cloudAudio.storageMB`, `cloudAudio.monthlyCapUSD`, `cloudAudio.dailyAhead`. Bind a control
  with `Binding(get: { env.spatial.settings.cloud }, set: { env.spatial.setCloud($0) })`.
- Developer mode: `settings.experimental.developerMode` (`SettingsStore.swift:822`, key `developer_mode_enabled`).
  `SettingsStore.ephemeral()` (UI tests) starts with it on (255-263).
- Backups: PixlBackup's catalogue does not know the eight keys, so they are not exported, like `cloud_studio_*`.

### 8.2 Settings screens

- Main list: `SettingsMainEntry` (`App/Features/Settings/SettingsView.swift:55-80`); a category's page is picked at
  280-290. Spec 6.5 says "a **Sound** group": Settings › Playback already has one,
  `SettingsSubsection(title: L10n.settingsSectionSound)` (`Categories/PlaybackSettingsSection.swift:41-52`, today
  only "Streaming audio quality"). The Developer block of that page is `SettingsAdvancedSubsection`
  (60-72): route mode, caps, storage budget and per-song diagnostics go there.
- Components (`Features/Settings/Components/SettingsRows.swift`): `SettingsSubsection` (57),
  `SettingsAdvancedSubsection` (83, drawn only in developer mode), `SettingsItemRow` (163, chevron row),
  `SwitchSettingRow` (210), `ThemeSelectorRow` (258, a value capsule opening `SettingsOptionSheet` 314: right for the
  profile picker), `SliderSettingRow` (377), `ActionSettingRow` (427), `SettingsFillButton` (472),
  `SettingsPanel` (578), `SettingsValueChip` (592). Scaffold: `SettingsCategoryScaffold`
  (`SettingsView.swift:256`) on `SettingsScaffold` (`Components/SettingsScaffold.swift:16`), toast `settingsToast`
  (`SettingsScaffold.swift:270`).
- The closest existing page to copy for "prepare ahead + caps + status" is Sing's
  (`Categories/SingSettingsSection.swift`: `SingPrepareAheadSection` 124, `SingPrepareDailyCapRow` 182, helpers
  233-260).

### 8.3 The full player

`App/Features/NowPlaying/NowPlayingView.swift` (444 lines), drawn inside `PlayerSheetHost`. Layout, top to bottom:

| Part | Lines | Notes |
|---|---|---|
| `PlayerTopBar` | 202-325 | collapse circle (220-230); right cluster in one `GlassEffectContainer(spacing: 3)`: the **output pill** (266-324, names the route, opens `AppSheet.devices`) and the queue pill (237-250) |
| `AlbumCarousel` | 69-89 | |
| `PlayerMetadataRow` | 349-436 | title / artist, then a cluster of 48 pt glass circles in `GlassEffectContainer(spacing: 6)` (378-401): the loading chip, **Lyrics** (393-395), **Ask Taizo** (397-399) |
| `PlayerSeekBar` | 93-97 | |
| `controls` | 132-146 | transport, then `PlayerToggles` → `PlayerToggleRow` (shuffle · repeat · favourite, `PlayerToggleRow.swift`) |

Where a "Spatial audio" entry can sit (spec 6.5: "a chip/button near the other player actions"):

1. A third pill in the top bar's right cluster, between the output pill and the queue pill. It sits next to the
   thing it depends on (the output), costs the title no width, and the cluster already hugs its content
   (`layoutPriority(1)`, line 255).
2. A third circle in the metadata row's cluster (helper `circle(systemImage:label:identifier:…)`, 407-420). Costs
   the title 60 pt; with the loading chip showing there would be four items.
3. A fourth segment in `PlayerToggleRow`. It is a row of toggles with a fixed colour role each; a sheet opener is
   the odd one there.

This is a port (AGENTS.md decision 10): the place must be the one the Android player uses. Settle it with the lead
before building. Use `playerGlass(in:tint:)` (438-444) with `theme.onPrimary.opacity(GlassTint.playerChrome)` like
the neighbours, inside the neighbours' `GlassEffectContainer`.

Performance rules that bite here: `NowPlayingView.body` must not read fast-changing or unrelated state (see
`PlayerToggles`, 327-346, a tiny view so that a favourite edit redraws only the row). Read `env.spatial` in a small
view of its own.

### 8.4 Sheets

- A sheet is an `AppSheet` case (`App/Core/Routes.swift:207-241`, with its `id` at 226-240), mapped to a view in
  `SheetDestination` (`App/Shell/RouteDestinations.swift:49-70`), presented with `router.present(AppSheet.x)`.
  Detents: `.pixlSheet()` (`App/DesignSystem/Components/SheetScaffold.swift:37`, default medium + large),
  `.tallGlass` (line 52, 92 % of the height, stays see-through) for tall sheets, or a sheet that sizes itself (`DevicesSheet`,
  `App/Features/NowPlaying/FittedSheetDetent.swift`). Layout inside: `SheetScaffold` (line 7). Never override
  `presentationBackground`.
- The player's sheets open over the expanded player. The devices sheet
  (`App/Features/NowPlaying/DevicesSheet.swift`) is the closest relative of the Spatial audio sheet: a list of
  choices with one selected, plus a status line.
- UI tests: every sheet needs a `DemoScreen` case (`App/Demo/UITestLaunchRouter.swift:6`; `sheet` mapping at 267,
  `opensOverPlayer` at 287, covers at 317) so `-uiTest -screen <id>` reaches it. Demo state: switch on
  `launch.screen` in `SpatialDemo.apply(launch:to:)` (`App/Demo/SpatialDemo.swift`) and call `model.select(_:)` /
  `model.setDemo(…)` there, as `TaisDemo.apply` does for Sing (`App/Demo/TaisDemo.swift:7`).

### 8.5 Strings

- English only. New strings are written in Swift, not in the catalog:
  `String(localized: "<key>", defaultValue: "<English>")`, collected as `nonisolated extension L10n { static let … }`
  in a file next to the feature (pattern: `App/Features/Settings/SettingsReorgStrings.swift`, and its header
  comment on why changed texts get new keys). `App/Resources/Localizable.xcstrings` (314 KB) is generated from the
  Android strings (`tools/localization/android_strings_to_xcstrings.py`) and is not hand-edited: **nobody needs to
  touch it**.
- The canonical English texts are in PixlModel so both apps and the tests agree: `SpatialProfile.displayName`,
  `.summary`, `SpatialStatusLine.text`. Wrap them: `String(localized: "spatial_profile_hall_name", defaultValue:
  String.LocalizationValue(profile.displayName))`, or simply repeat the literal with the PixlModel test as the guard.
- Never in a user-visible string, changelog or doc: *lossless*, *hi-res*, *Dolby*, *Atmos*, *360 Reality*, the
  cloud AI's model name or maker, the lyrics source's old name; and (CI-enforced, `ci/check-forbidden.sh` rule 5)
  "Apple". The feature names are "Spatial audio" and "Enhanced audio".
- Outside developer mode no row says codec, bitrate, GPU, stems or LUFS (the settings reorganisation's rule).

### 8.6 Changelog

`HomeChangelog.versions` (`App/Features/Home/HomeInfoSheet.swift:440-…`), newest first; the top entry today is
`HomeChangelogVersion(version: "Beta 1", date: "2026-10-26", …)` (442). The sheet is `AppSheet.changelog`.

### 8.7 Design system

`App/DesignSystem/` (AGENTS.md "Liquid Glass rules" and `docs/design.md`): `GlassPillButton`, `GlassCircleButton`
(`Components/GlassButtons.swift:5`, 44), `GlassCard` (`Components/GlassCard.swift:6`), `GlassPillRow`
(`Components/GlassPillRow.swift:10`), `LiquidTabCapsule` (`Components/LiquidTabCapsule.swift:8`), `SheetScaffold`,
`pixlGlass(in:tint:interactive:)` (`GlassStyle.swift:24`), `GlassTint` (`prominent` 0.85, `container` 0.62,
`surface` 0.28, `playerChrome` 0.14; `GlassStyle.swift:8-18`), `PressScaleButtonStyle` (31) for fills that sit on
glass, `PixlMotion` (45-52), `pixlFont(_:)` (`Typography.swift`), colours from `@Environment(\.appTheme)` /
`\.playerTheme`. One glass layer per row, no glass on glass, real `glassEffect` only (CI forbids blur materials).

---

## 9. Opus

The work item: play itag 251 (Opus, about 160 kbps, full band) instead of itag 140 (AAC 128 kbps, cut off at about
16 kHz), by repackaging WebM/Opus into something AVPlayer opens.

### 9.1 Why iPhones play AAC today

- `AudioFormatSelection` (`Packages/PixlCore/Sources/PixlNet/YouTube/AudioFormatSelection.swift`): header comment
  lines 1-2, "AVPlayer cannot play Opus in WebM, so on iOS only AAC … is eligible". `isPlayableOnIOS` (31-36)
  accepts `audio/mp4` with `mp4a` and the muxed itag 18; `pickBestIOSAudio` (40-54) ranks 141 → 140 → 139, then 18.
  `pickBestAudio` (14-27) is Android's rule and is checked against Android's golden file: do not change it.
- `AudioFormatPolicy` (`…/YouTube/StreamResolution.swift:25-36`): `.android` → `pickBestAudio`, `.iOS` →
  `pickBestIOSAudio`. It is the default of `YouTubeStreamStrategy.resolve` (line 64) and of
  `ChainedYouTubeStreamResolver` (219), and the app passes `.iOS` at `App/Services/YouTube/InnerTubeService.swift:46`.
- Piped fallback: `PipedStreamResolver(http:aacOnly: true)` (`InnerTubeService.swift:44`; `Piped.swift:66-85`).
- The cap: `StreamingAudioQuality.maxBitrateKbps` (`InnerTubeService.swift:174-183`: LOW 96, STANDARD 160, HIGH
  256, ULTRASOUND none).

### 9.2 Clients and what they return

`InnerTubeContexts` (`…/YouTube/InnerTubeContexts.swift`): `playerProfiles = [visionOS, iOS, tvHTML5, webRemix]`
(line 120). `VISIONOS` (68-72) leads because it needs neither a PoToken nor the JS player and returns direct URLs;
`IOS` (83-88) and `ANDROID_VR` (75-80) need a streaming PoToken (their audio is cut at about 50 s without one), so
without a token only the muxed itag 18 is eligible (`eligibleFormats`, `AudioFormatSelection.swift:58-63`);
`TVHTML5` / `WEB_REMIX` come ciphered and need base.js (the JavaScriptCore cipher). The order can be overridden by
`remote/config.json` (`RemoteClientConfig.swift`). Formats are parsed by `InnerTubeParsing.parseFormat`
(`InnerTubeParsing.swift:43-66`): every `audio/*` format with a URL or a cipher is kept (WebM included), plus
itag 18; so the Opus formats are already in `YouTubePlayerResponse.formats` and are only filtered out by the policy.
Which itags `VISIONOS` really returns for a given video is not recorded anywhere in the repo. The sample response
the tests parse (`Tests/PixlNetTests/Fixtures/innertube-player.json`, hand-made) has 18 (muxed), 140
(`audio/mp4; codecs="mp4a.40.2"`, 130 kbps), 251 (`audio/webm; codecs="opus"`, 160 kbps), 139 (ciphered) and 141
(256 kbps, which ordinary accounts do not get). For a real answer use the phone: Settings › Developer › Test
playback prints every client's attempt (`PlaybackDiagnostics.swift`). CI cannot tell you: the non-blocking
`YouTubeLiveSmokeTests` step fails on GitHub's runners with `LOGIN_REQUIRED — Sign in to confirm you're not a bot`
from every client (run 43033433910), which is YouTube refusing a datacentre address, not a broken client table.

### 9.3 The byte-range model

- AVPlayer asks the resource loader for content information and byte ranges of the resource. `YouTubeResourceLoader.serve`
  (`App/Services/YouTube/YouTubeResourceLoader.swift:68-109`) answers with the remote file's own values:

  ```swift
  contentRequest.contentType = info.uniformTypeIdentifier      // :73
  contentRequest.contentLength = info.contentLength
  contentRequest.isByteRangeAccessSupported = true
  …
  let (data, fromNetwork) = try await fetcher.read(videoId: videoId, from: position, upTo: end, fetchSize: fetchSize)   // :88
  dataRequest.respond(with: data)
  ```

  Byte N of what AVPlayer sees **is** byte N of the googlevideo file. `Info.uniformTypeIdentifier`
  (`StreamFetcher.swift:39-41`) knows only M4A and MP4.
- `StreamFetcher` (`App/Services/YouTube/StreamFetcher.swift`): ranged GETs with the resolving client's User-Agent
  (132-133), retries and re-resolution (119-150), the first GET of 128 KiB (`info`, 51-61), growing fetches
  (`StreamChunkPolicy`, PixlNet `Stream/StreamingPolicies.swift`). The response check accepts any `audio/*`
  (`CloudStreamSecurity.isSupportedAudioContentType`, PixlNet `Stream/CloudStreamSecurity.swift:79-83`), so
  `audio/webm` passes.
- `StreamCache` (`App/Services/YouTube/StreamCache.swift`): one sparse file per video named `<videoId>.m4a`
  (line 33) plus `<videoId>.json` (`Meta`: `contentLength`, `contentType`, `itag`, `ranges`), 1 GB LRU (19,
  137-154). A different length or itag for the same video drops the old bytes (`setInfo`, 48-61), and mid-play that
  surfaces as `Failure.formatChanged` (`StreamFetcher.swift:176-181`). **Switching a video from itag 140 to 251
  invalidates its cached bytes**, and the retry rule "never move to another client once bytes are cached"
  (`StreamRetryPolicy`, used at 140-148) exists for the same reason.
- A complete cache file is played straight from disk (`completeFileURL`, 69-73, via the resolver) and copied by
  downloads (`copyComplete`, 120-127). Both assume the cached bytes are a file AVPlayer can open.

### 9.4 Where a remuxed file or another renderer could slot in

- **A virtual file in the loader.** The loader would report the remuxed container's type and length and translate
  ranges. The length and every sample's offset must be known before the first byte is answered, which for WebM
  means parsing the index (and for most target containers, every packet size) first. This keeps one byte cache but
  breaks the "byte N is byte N" assumption in `serve`, `StreamCache` and `fillCache`.
- **A remuxed local file.** Fetch the WebM (the cache and `StreamFetcher.fillCache`, 96-106, already do whole
  files), write the repackaged file beside it, and play it as a local file: a third lookup in
  `StreamingPlayableURLResolver.playableURL` (`YouTubePlayback.swift:12-17`), next to the downloaded file and the
  complete cache file. First play of a song then needs the whole file before it starts, unless it starts on the AAC
  stream and switches: that switch is the mechanism of section 3 (`switchCurrentAudio(to: url, requireAligned:
  true)`), and "the song's file improves while it plays" is exactly what the spatial render does too. **ENGINE owns
  that mechanism this round**: OPUS should produce the file and a resolver hit, and agree with the lead before
  touching the switch.
- **Another renderer** (decode Opus yourself and feed sample buffers): it leaves `AVPlayerItem`, and with it the
  processing tap (EQ, crossfades, the gapless hand-over, Sing, the spatial stage) and both decks. Not a slot: a
  second engine.
- **Downloads.** `DownloadManager` (`App/Services/YouTube/DownloadManager.swift`) saves `Downloads/<videoId>.m4a`
  from the resolved URL in a background session (59, 105), with a ranged foreground fallback and a copy of a
  complete cache file (253). A downloaded file is what plays offline **and what cloud jobs read**
  (`TaisServices.audioSource` → `CloudAudioPreparer`, `AVAssetReader`) **and what the on-device models read**
  (`App/Services/ML/AudioPCMReader.swift`). Whatever container the Opus ends up in, all three readers must open it;
  the file extension is baked into `DownloadFiles.fileURL` (`YouTubePlayback.swift:31`) and `downloadedIds()` (39-43).
- **Timeline.** Renders and instrumentals are lined up against the phone's own decode of the uploaded audio
  (`decodedFrames`, section 7.2), and the in-song switch requires durations within 50 ms. Opus has a pre-skip and
  end padding: the repackaged file must decode to the same frames every time, in the player and in `AVAssetReader`.
  A song whose instrumental or render was made from the AAC stream will not line up with the Opus one to the
  sample; `requireAligned` only checks the length.
- **Sample rate.** Opus is 48 kHz. The tap then runs at 48000 (section 2.3): the EQ redesigns itself per item rate
  (`blockForThisRate`, `ProcessingTap.swift:199-205`) and the spatial tables exist for 48000. Uploads are resampled
  to 44.1 kHz by the preparer (section 7.2) whatever the source.
- **Measuring.** `PlaybackStartTimings` (`App/Playback/PlaybackStartTimings.swift`) records every start (resolve,
  first fetch, first audio); Settings › Developer › Test playback shows it. Use it for before/after.

### 9.5 What the tests assume

- `Packages/PixlCore/Tests/PixlNetTests/YouTubeTests.swift:309-357` (`AudioFormatSelectionTests`):
  `iOSPicksAACOnlyThenTheMuxedFallback` (322-340) asserts `pickBestIOSAudio(response.formats)?.itag == 140` where
  Android picks 251, `pickBestIOSAudio([set[0]]) == nil` for Opus alone, and `!isPlayableOnIOS(…opus…)`. Line 9-10
  pin the profile order and that the first profile needs no streaming PoToken.
- `NetGoldenTests.swift:43-56`: `pickBestAudio` against the Android golden file. Leave it.
- `YouTubePipelineTests.swift:224-234`: the same response resolved under `.iOS` and `.android`.
- `YouTubeStreamingTests.swift`, `StreamingPolicyTests.swift`: chunk, retry and prefetch policies (PixlNet).
- App: `AppTests/YouTubeServicesTests.swift`, `AppTests/StreamingSpeedTests.swift`, `AppTests/CloudAudioPreparerTests.swift`
  (the copy / passthrough / decode routes).
- The Android behaviour (`.android` policy, the golden file) must stay bit for bit: add an iOS choice, do not edit
  the shared one.

---

## 10. Tests and CI

### 10.1 `.github/workflows/ci.yml`

Runs on every push to any branch, except pushes that only touch `docs/**`, `**/*.md`, `LICENSE`, `cloud/**` or the
`cloud-*` workflows (`paths-ignore`, lines 6-14). **`concurrency: cancel-in-progress` per branch** (30-32): a new
push cancels the run of the previous one. A docs-only push starts nothing and cancels nothing.

| Job | Runner | What | Time on a branch (run 42957638049) |
|---|---|---|---|
| `core` | `ubuntu-latest`, `swift:6.4-noble` | `ci/check-cloud-fixtures.sh`, `ci/check-spatial-fixtures.sh`, `swift test --package-path Packages/PixlCore --parallel`, a non-blocking YouTube live smoke | about 3 min (tests 141 s) |
| `app` | `xcode-27` (macOS) | `ci/check-forbidden.sh`, built-in keys from secrets, XcodeGen, `build-for-testing` (229 s), boot a simulator (406 s), unit tests `PixlAudioTests` (346 s) | about 18 min |
| `app` + screenshots | same job | only on `main`, or with `[shots]` / `[shots:ClassA,ClassB]` in the commit message, or a manual run | a few minutes per class; a full run is about 100 min |
| `ipa` | `xcode-27` | only on `main`, tags, `[ipa]`, or a manual run | up to 60 min |

So a normal branch push is green or red in about **18 minutes**, not an hour (this branch's first run,
43033433910: `core` 3 min, `app` about 16 min: build 212 s, simulator 303 s, 585 unit tests in 315 s). `main` runs take
about 150 minutes and its screenshot step is red at the moment (run 42952869050), unrelated to this work. `[perf]`
and `[record:Class]` exist for performance numbers and videos.

A push that touches `cloud/runpod-worker/**` (a merge of `audio-hq` does) also starts `cloud-worker-build`: on a
branch that is only its `test` job (the worker's CPU tests on a free Linux runner); no image is pushed and nothing
is deployed without `[image]` in the commit message.

**When the worker's tables are regenerated** (it happened once already, `0a295e6` on `audio-hq`): the three app
copies must follow in the same change, with `bash ci/check-spatial-fixtures.sh --sync`. A push that only touches
`cloud/**` does not run `ci.yml`, so nothing catches the drift until the next app push, where `core` then fails on
"Spatial table files match the worker's". No test writes a generated number down: the stage's golden test reads
whatever the two files hold.

Loop: `gh run list --repo RedSn0w1877/PixlAudio-iOS --branch <branch>`, `gh run watch <id> --repo … --exit-status`,
`gh run view <id> --repo … --log-failed` (the job summary lists `file:line: error`). Logs are public: never print a
secret.

### 10.2 PixlCore locally (Windows)

```
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter PixlAudioCoreTests"
```

`ci/swiftw.cmd` sets `SDKROOT`, the toolchain path and the MSVC environment for Swift 6.4 on this PC. A first build
of the package in a fresh worktree took 12 minutes and about 750 MB (`Packages/PixlCore/.build`, ignored by git);
later runs are incremental. `--filter <TestTarget>` or `--filter <SuiteName>` keeps a run short; `--skip-build`
reuses the last build. **One Swift build at a time on this PC**: four agents share it, so write
`.swiftbuild.lock` in your worktree root while you build, look for a running `swift-build.exe` first
(`tasklist | grep -i swift-build`), and prefer the `core` CI job (3 minutes) when someone else is building.

Tests use Swift Testing (`@Suite`, `@Test`, `#expect`). Fixtures live in `Tests/<Module>Tests/Fixtures/…` and are
read with `Bundle.module.url(forResource:withExtension:subdirectory: "Fixtures/<folder>")`.

### 10.3 The app target

Cannot be compiled here. Before pushing:

- `powershell -NoProfile -ExecutionPolicy Bypass -File ci/parse-check.ps1 <files>` (or no arguments for
  everything changed against `origin/main`): `swiftc -parse`, syntax only. It does not find type errors, missing
  imports or isolation errors: CI does.
- `bash ci/check-forbidden.sh` (Git Bash): imports limited to system frameworks and PixlCore modules, no remote
  packages, no app extensions, no leftover component names from the Android design system or blur materials in
  `App/`, no "Apple" in string literals, iOS 27 availability checks only in `App/DesignSystem/Compat27.swift`, no
  fonts, and the three generated stubs in `App/Generated/` untouched. It does **not** check the forbidden feature
  words of section 8.5: that is on you.
- `bash ci/check-cloud-fixtures.sh` and `bash ci/check-spatial-fixtures.sh`: fixture copies identical to the
  worker's files.

App tests are XCTest, `@MainActor final class …: XCTestCase`, `@testable import PixlAudio`, hosted in the app (so
`Bundle.main` is the app bundle). Useful starting points: `AppTests/ProcessingTapTests.swift` (the tap offline),
`AppTests/DualDeckEngineTests.swift`, `AppTests/DualDeckEngineInstrumentalTests.swift` (the switch, with real
decks), `AppTests/InstrumentalControllerTests.swift` (a fake `InstrumentalSwitching`), `AppTests/CloudStudioTests.swift`
(the orchestrator on fakes), `AppTests/SingPrepareRunnerTests.swift`, `AppTests/ActiveJobsTests.swift`,
`AppTests/SettingsFeatureTests.swift`, `AppTests/PlaybackTestSupport.swift` and `TestAudioFiles.swift` (generated
audio files). UI screenshot classes are in `UITests/` (`PlayerScreenshotTests`, `SettingsScreenshotTests`, …).

Every system API used for the first time goes into `docs/api-notes.md` with its documentation URL and minimum OS
(AGENTS.md). Deployment target is iOS 26.0 (`project.yml:8`, 22).

---

## 11. Who owns which file

One owner per file. If you need a change in a file that is not yours, ask its owner through the lead; do not edit it.

### 11.1 Existing files

| Area | Files | Owner |
|---|---|---|
| Tap and items | `App/Playback/ProcessingTap.swift`, `TapParameters.swift`, `Deck.swift` | ENGINE |
| Engine | `App/Playback/DualDeckEngine.swift`, `DualDeckEngine+Crossfade.swift`, `DualDeckEngine+Instrumental.swift`, `PlaybackServices.swift`, `AudioSessionController.swift` | ENGINE |
| Sing's controller | `App/Services/ML/InstrumentalController.swift` | ENGINE (only if the switch API changes; keep Sing's behaviour and tests) |
| Engine tests | `AppTests/ProcessingTapTests.swift`, `DualDeckEngine*Tests.swift`, `InstrumentalControllerTests.swift`, `AudioSessionControllerTests.swift` | ENGINE |
| Cloud Studio (app) | `App/Services/Cloud/*` | CLOUD |
| Cloud Studio (PixlNet) | `Packages/PixlCore/Sources/PixlNet/Cloud/*` and their tests `Tests/PixlNetTests/Cloud*Tests.swift`, `Fixtures/cloud/`, `Fixtures/cloud-phone/` | CLOUD |
| Prepare-ahead ranking | `Packages/PixlCore/Sources/PixlLibrary/SingPrepareRanker.swift` | CLOUD |
| Active jobs model | `App/Services/ActiveJobs.swift`, `Packages/PixlCore/Sources/PixlModel/ActiveJob.swift`, `App/Demo/ActiveJobsDemo.swift`, `App/Demo/CloudDemo.swift` | CLOUD |
| Cloud tests | `AppTests/Cloud*Tests.swift`, `SingPrepare*Tests.swift`, `ActiveJobsTests.swift` | CLOUD |
| Player UI | `App/Features/NowPlaying/*` (incl. `AudioRouteMonitor.swift`: ENGINE reads the session itself) | UI |
| Settings UI | `App/Features/Settings/*` | UI |
| Routes and sheets | `App/Core/Routes.swift`, `App/Shell/RouteDestinations.swift` | UI |
| UI-test plumbing | `App/Demo/UITestLaunchRouter.swift`, `App/Demo/SpatialDemo.swift`, `UITests/*` | UI |
| Active jobs and cloud screens | `App/Features/Home/*` (changelog, Active jobs sheet), `App/Features/CloudStudio/*` | UI |
| Design system | `App/DesignSystem/*` | UI |
| Stream format choice | `Packages/PixlCore/Sources/PixlNet/YouTube/*`, `…/PixlNet/Stream/*` and their tests | OPUS |
| Streaming (app) | `App/Services/YouTube/*` (loader, fetcher, cache, resolver, downloads, InnerTube service) | OPUS |
| Streaming tests | `AppTests/YouTubeServicesTests.swift`, `StreamingSpeedTests.swift` | OPUS |
| Contract | `Packages/PixlCore/Sources/PixlModel/CloudAudio/*`, `Tests/PixlModelTests/CloudAudioContractTests.swift`, `App/Services/Spatial/SpatialAudioModel.swift`, `SpatialAudioContext.swift`, `CloudAudioSettingsStore.swift`, `AppTests/SpatialAudioModelTests.swift` | foundation: frozen. A needed change goes to the lead, who makes it once for everybody |
| Table decoder | `Packages/PixlCore/Sources/PixlAudioCore/Spatial/SpatialPreviewTables.swift`, its test, `App/Services/Spatial/SpatialPreviewResource.swift` | ENGINE may add to them (not change what is there) |

### 11.2 New files

| Agent | Creates |
|---|---|
| ENGINE | `Packages/PixlCore/Sources/PixlAudioCore/Spatial/*` (the stage: pure Swift, no allocation while processing) and `Tests/PixlAudioCoreTests/Spatial*Tests.swift` (golden test: start from `SpatialFixtures`); `App/Playback/Spatial/*` (the `SpatialPlayback` implementation, the rendition choice, the route watcher); `AppTests/Spatial{Stage,Playback,…}Tests.swift` |
| CLOUD | `Packages/PixlCore/Sources/PixlNet/Cloud/CloudLibrary*.swift` (job block, result block, client, state machine) and tests; `App/Services/CloudAudio/*` (the `SpatialLibrary` implementation, the local store, the queue); `AppTests/CloudAudio*Tests.swift` |
| UI | `App/Features/Spatial/*` (the sheet, the player entry's view, the settings rows as views, `SpatialStrings.swift`); `UITests/SpatialScreenshotTests.swift` |
| OPUS | `Packages/PixlCore/Sources/PixlNet/YouTube/Opus*.swift` or a `PixlNet/Remux/` folder (the WebM reader and the container writer: pure Swift, testable on Windows with small fixtures); `App/Services/YouTube/Opus*.swift`; tests beside them |

### 11.3 Shared files and their single owner

| File | Owner | Rule for the others |
|---|---|---|
| `App/AppEnvironment.swift` | foundation (done) | do not edit; use your factory file and `SpatialAudioContext`. If the context lacks something, ask the lead |
| `project.yml` | nobody this round | resources under `App/` are bundled automatically; background task identifiers: reuse Cloud Studio's (7.6). A real need goes to the lead |
| `App/Resources/Localizable.xcstrings` | nobody | strings are written in Swift (8.5) |
| `App/Resources/spatial_preview_v1.json` and `Tests/PixlAudioCoreTests/Fixtures/spatial/*` | the worker's generator | only `bash ci/check-spatial-fixtures.sh --sync` |
| `Packages/PixlCore/Package.swift` | nobody | no new module is needed |
| `.github/workflows/ci.yml`, `ci/*` | lead | |
| `App/Stores/SettingsStore.swift` | UI, and only for something that is not one of the eight settings | the eight settings live in `env.spatial` |
| `App/Features/Home/HomeInfoSheet.swift` (changelog) | UI | ENGINE, CLOUD and OPUS send their changelog line to the lead |
| `docs/api-notes.md`, `docs/parity.md`, `docs/design.md` | each agent appends its own section at the end of the file | no reflowing of other sections |
| `App/Services/ML/TaisServices.swift` (`audioSource`) | OPUS if the download's container changes; otherwise nobody | CLOUD calls it through `host.audioSource` |
| `cloud/**`, `.github/workflows/cloud-*` | the worker agent | none of the four touches them |

Two overlaps to watch, both about the in-song switch:

- ENGINE and OPUS both want "a better file for the playing song arrives, switch to it". ENGINE owns
  `DualDeckEngine+Instrumental.swift`; OPUS stays out of `App/Playback/` (9.4).
- ENGINE needs the playing item's video id from stream, cache and download URLs (4.2), which are OPUS's files. If
  OPUS changes a file name or extension there, the id must still be the last path component without its extension.

---

## 12. Where the spec and the code disagree

Found while mapping. None is resolved here: the contract code takes no side unless it says so.

1. **"AAC-LC is passed through" (spec 6.2 step 3) is not what happens.** Every streamed song is force-decoded to
   44.1 kHz stereo 16-bit FLAC before upload (`CloudStudio.swift:1373-1378`, `CloudAudioPreparer.swift:64`), and
   every song in this app is streamed. So `library.source` should name the stream (`itag`, `codec`) while the upload
   is FLAC, and a render comes back at 44.1 kHz even for a 48 kHz source (the spec's example manifest shows 48000).
   Lining up by media time still works; frame counts are those of the 44.1 kHz decode.
2. **The level rule is a no-op for streams** (section 5): there is no loudness normalisation for streamed songs, so
   their gain is 1 and `min(1, 1 × 1.585)` is 1. Spatial therefore plays 4 dB under stereo for nearly every song,
   which the spec allows ("without it, Spatial is up to 4 dB quieter") but may not be what was pictured.
3. **The switch's fade is 300-700 ms, not about 250 ms** (section 3.3), and the "20 s left" rule does not exist yet.
4. **Two consent switches.** Cloud Studio has "Process songs in the cloud" (`cloud_studio_enabled`); the spec adds
   `spatial.cloud` with the same default. Whether turning Cloud Studio's switch off also stops library jobs is not
   said. The contract passes `spatial.cloud` to the library and leaves the rule to CLOUD and the lead.
5. **Sing's $3 cap with built-in keys** clamps every job's budget today (`CloudKeyChoice.effectiveMonthlyCap`):
   library jobs need their own sum and cap (section 7.5), otherwise the first few renders of a month use up Sing's
   budget and `cloudAudio.monthlyCapUSD` never applies.
6. **`executionTimeout` is 900 s in every `/run` body** (`CloudTiming.executionTimeoutMs`); spec 5 raises the
   endpoint to 1800 s. The request policy overrides the endpoint's, so it must be raised for library jobs.
7. **Slot names with a hyphen** (`sp-studio`) are refused by the transfer layer (`CloudTransfers.isSafeSlot`).
8. **Enhanced without Spatial.** Spec 6.2 only describes `enhance` riding on a `spatial` job; spec 6.1 says Enhanced
   is asked for "when `spatial.cloud` is on". Whether a song gets an `enhance`-only job while Spatial is off is not
   said. The contract allows a `RenditionRequest` of kind `.enhanced`; the model never sends one by itself
   (`wantedRender` is spatial only).
9. **Not in the spec, chosen here and to be confirmed (Android must match):** "No limit" is stored as `-1` under
   `cloudAudio.monthlyCapUSD`; `cloudAudio.storageMB` is kept within 256 … 65536 and `cloudAudio.dailyAhead` within
   1 … 100; a stored `spatial.route = always` is honoured whether or not Developer mode is on (the row is only
   shown there); `SpatialOutputKind` treats line-out and the Bluetooth call route as not headphones (section 6).
10. **Status line.** The spec has three sentences. A selected profile with the cloud off, a failed render, and Sing
    playing have none: `SpatialStatusLine.onDeviceOnly` / `.pausedForSing` return no text.
11. **AGENTS.md is behind:** it says deployment target 26.1 and a different `Co-Authored-By` line; `project.yml` and
    `Package.swift` say 26.0.
