# Streaming speed (2026-10-07, branch `wt/stream`)

Hoa asked for streamed songs (YouTube Music, and Spotify songs matched to YouTube) to start faster, on tap and on
skip. Plan: `plans/streaming-speed.json` (R-numbers); owner decisions: DECISIONS.md › Streaming speed. Everything is
**iOS first**; each change is listed for the Android port in `docs/parity.md` › iOS-first divergences.

## What changed (one commit each, in this order)

| Step | What | Where |
|---|---|---|
| R12 measure | Per-start timings: tap → URL → tracks → item → playing, resolution (client, `n`, remote-config wait), loader requests / cancellations, first network chunk, first answer. Signposts (category "Streaming"). | `App/Playback/PlaybackStartTimings.swift`, marks in `Deck`, `DualDeckEngine`, `InnerTubeService`, `StreamFetcher`, `YouTubeResourceLoader` |
| R2 first fetch | 128 KiB first GET answers AVFoundation's 2-byte request and the next request's start; fetches grow 128 KiB → 512 KiB → 2 MiB per loading request (was 1 MiB each). | PixlNet `StreamChunkPolicy`; `StreamFetcher.read`, the loader's ramp |
| R3 prefetcher v2 | While playing: next 2 songs on Wi-Fi, 1 on cellular, none in Low Data Mode — matched (Spotify), resolved, first 512 KiB cached after 3 s; the 1 MiB top-up 30 s before the end stays. Pause cancels. Off the main actor. | PixlNet `StreamPrefetchPolicy`; `YouTubePrefetcher`, `NetworkConditionsMonitor`, `PlaybackServices.onPlayStateChanged` |
| R4 client table | Resolution no longer waits for `remote/config.json`; background refresh; the saved file's date gates the 6 h refresh across launches. | `RemoteClientConfigStore`, `InnerTubeService.resolveFresh` |
| R5a retries | Android oct3's rules: 4 attempts, same client first, then the next (never once bytes are cached), 250 ms × attempt for 429/5xx. | PixlNet `StreamRetryPolicy`; `StreamFetcher.fetch` |
| R7 skip | A skip to the song already prepared on the idle deck takes it over (no new resolution / download). | `DualDeckEngine.adoptPreparedIncoming` |
| R11 matching | Play-time Spotify matching runs the searches after the first at once, judged in `findMatch`'s order (same video). | PixlNet `TrackMatcher.findMatchFanOut`; `SpotifyPlayableURLResolver` |
| R8 (flag, **off**) | Overlapping YouTube clients after 1.5 s, behind `innertube.hedge.enabled` in `remote/config.json` (the repo file ships `false`). | PixlNet `StreamHedging`, `ChainedYouTubeStreamResolver.resolveHedged`, `RemoteClientConfig.hedging` |
| R6 HTTP/3 | `assumesHTTP3Capable` on googlevideo range requests (trivially safe: TCP fallback). | `StreamFetcher.fetch` |
| Diagnostics | Test playback › "Stream start timings" card (last 8 starts), deep probe "Last start" + "Overlapping clients", Diagnostics › "Last Song Start". New demo screen `playbackDiagnosticsTimings`. | `PlaybackDiagnosticsView`, `DiagnosticsView`, `UITestLaunchRouter` |

Left out on purpose: R9 (cipher warm-up; only if the timings show `n` on VISIONOS URLs), R10 (delegate streaming;
only if first-byte latency remains), R5b (persisted URLs; owner: not now), client order unchanged.

## How it was verified (no Mac)

- **PixlCore** on Linux (Swift 6.4): `swift build` and the whole `swift test` pass (every module; PixlNet 253 tests),
  including the new
  `StreamChunkPolicyTests`, `StreamPrefetchPolicyTests`, `StreamRetryPolicyTests`, `StreamHedgingTests`,
  `TrackMatcherFanOutTests`.
- **App files**: `swiftc -parse` on every changed file; `bash ci/check-forbidden.sh` OK. The streaming files
  (`PlaybackStartTimings`, `StreamFetcher`, `StreamCache`, `YouTubeResourceLoader`, `YouTubePlayback`,
  `NetworkConditionsMonitor`, `RemoteClientConfigStore`) and the new app tests were also type-checked on Linux with
  the app's settings (Swift 6, default MainActor isolation, approachable concurrency) against small stand-ins for
  AVFoundation / Network / os. `DualDeckEngine`, `Deck`, the views and the router could only be syntax-checked.
- **Not yet run:** the iOS build, `AppTests` (`StreamingSpeedTests`, the two new `DualDeckEngineTests` cases) and the
  screenshots. CI does that after integration.

## CI to run after integration

- Build + unit tests (the `app` job). New/changed app tests: `StreamingSpeedTests`,
  `DualDeckEngineTests/testASkipTakesOverTheCrossfadesPreparedItem`,
  `DualDeckEngineTests/testASkipTakesOverTheGaplessHandOversPreparedItem`, and the existing engine/YouTube tests.
- Screenshots: `YouTubeScreenshotTests` (new `testPlaybackDiagnosticsTimingsLight/Dark`; the playback test screen
  gained a "Stream start timings" button) and `ScreenshotTests/testDiagnosticsLight` (new "Last Song Start" section).

## Waiting on Hoa's phone

docs/performance.md › Streaming start › Pending on-device checks: five cold starts and five skips (copy the Stream
start timings), cellular and Low Data Mode, and what the `n:` / cancelled / resolve lines say — they decide R9, R10
and whether to switch on `innertube.hedge` (edit `remote/config.json` on `main`; no release needed).

## Next step

Integrate `wt/stream`, run CI (build, unit tests, the shots above), fix anything the compiler finds, then hand Hoa a
test build with the checklist above.
