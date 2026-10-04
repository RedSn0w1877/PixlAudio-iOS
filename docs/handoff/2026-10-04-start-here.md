# Start here: PixlAudio iOS, current state (2026-10-04)

`AGENTS.md` has the **rules**. This page has the **current state**: what's built, what's in
flight, what's waiting on Hoa, and where to look. Read `AGENTS.md` first and this second. Then
open only the docs your task needs (map in §6).

---

## 1. What this is

- **PixlAudio for iOS** is a native Swift 6 / SwiftUI port of the Android app PixlAudio (aka
  PixelPlayer). It uses Liquid Glass in place of Material and only Apple frameworks. It's a
  **port, not a remake**: every screen copies the Android one, and only Material elements
  become glass (`AGENTS.md`, decision 10).
- **Owner:** Hoa (`RedSn0w1877`), 19. Loves features and polish, codes a little, works on a
  **Windows PC with no Mac**. Explain in plain language, and lead with the fix, not the alarm.
  This is the project Hoa mainly works in now. The Android app is the reference.
- **Phone:** iPhone on iOS 27, 120 Hz. Installs come from the unsigned IPA through an IPA
  installer app (`docs/INSTALL.md`, option A).
- **Version:** `v1.0.0` tagged at `fb30d73` (2026-10-03). `main` has moved on since then (§3).
- **Size:** ~600 Swift files, ~135k lines. Eight PixlCore modules (`PixlAudioCore`, `PixlBackup`,
  `PixlFoundation`, `PixlLibrary`, `PixlLyrics`, `PixlModel`, `PixlNet`, `PixlTags`) plus the app
  target in `App/`.

## 2. How work gets done here (no Mac)

- **Nothing in `App/` compiles locally.** GitHub Actions on `xcode-27` / `macos-26` runners is
  the compiler, simulator and packager. Locally you can only:
  - run `pwsh ci/parse-check.ps1`, a syntax check;
  - test PixlCore with `cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore"` on Hoa's PC,
    or `swift test --package-path Packages/PixlCore` where Swift works. Only one Swift build at a
    time (`.swiftbuild.lock`).
- **Loop:** push a branch → `gh run watch --exit-status` → on red, `gh run view <id> --log-failed`
  (the summary lists `file:line: error`). Batch changes per push, because each CI round costs real
  minutes.
- **Commit-message switches:** `[shots]` or `[shots:ClassName,Class/testName]` runs the
  screenshot tests (artifact `shots-<sha>`). `[ipa]` builds the unsigned IPA. `main` and `v*`
  tags always build both.
- **Look at your UI change:** `gh run download <id> -n shots-<sha> -D shots/`, then open the
  PNGs and compare with `docs/design-refs/` and the Compose code.
- **Releasing:** tag `vX.Y.Z` on a green `main` → `release.yml` publishes
  `PixlAudio-unsigned.ipa` to Releases. Running `release.yml` by hand with a blank tag makes a
  prerelease `build-<run>`. That's the quick way to get Hoa a test build of a branch.
- **In a cloud session without `gh`:** use the GitHub MCP tools (`actions_list`, `get_job_logs`, …)
  for the same loop.

## 3. Where things stand

### `main` (`c7dee2d`, 2026-10-03), the latest

Since `v1.0.0` it has picked up the 10-03 integration (`40ca233`):

- **BiniLyrics** as the first online lyrics source: ISRC lookup, strict matching, TTML storage.
- **Taizo redesign**, plus an always-dark palette for the lyrics screen's sheets.
- **Tab bar minimizes on scroll**, and **LOCAL / CLOUD** sits on the liquid lens.
- **Spotify Connect output**: the devices sheet lists Connect devices and sends the queue to
  them. This is a shared spec with Android. ⚠️ It hasn't been verified on a real device yet
  (needs Spotify Premium and a Connect speaker).
- Sheet tab capsules on the liquid lens (devices, song options, song picker).

### `perf-transitions`, open and NOT merged (14 commits ahead of `main`)

This is the fix for Hoa's "a few noticeable stutters between menu or page transitions" report.
Most of the transition work is **already in `main`**: it merged through `review-fixes` at
`bfe98d8` (stuck full player, AI status cache, audio session). Hoa says the stutter is now
"mostly fixed". The branch still carries:

- the settings header snap acting only on the user's release;
- the collapse fade no longer widening the player card, with an expand taking over the fade
  in one transaction;
- the full player fading out on collapse as on `main`;
- opt-in recording tests, plus lots of `docs/performance.md`.

**Merge gate (from `docs/performance.md` › Pending on-device checks), all needing Hoa's phone:**

1. Instruments › Hitches over the transitions (needs a Mac, so in practice Hoa's eye on a test build)
2. pressed settings rows look as on `main`
3. VoiceOver labels and traits
4. tap-to-expand fade versus `main`
5. idle cost of the pre-built hidden full player

The "settings pages at rest" change explicitly **needs Hoa's OK**. Ask before merging.
Don't re-audit transitions from scratch. Read `docs/performance.md` first: it holds the full
table of what was slow, and the rules.

### Experiment branches (never merge)

`perf-x-*`, `perf-after`, `perf-baseline`, `perf-x1`, `perf-x3` are throwaway probes and
measurements. Their commits say "Experiment (do not merge)" or "Measurement only".
Every other branch (`s00`–`s15` stage branches, `int-*`, `navbar-*`, `liquid-tabs`, `binilyrics`,
`spotify-connect`, `taizo-lyrics`, `review-fixes`, `ci-*`) is **already fully merged into
`main`**. That makes ~60 of the 67 branches clutter, and Hoa may want them deleted. Ask; don't
delete on your own.

### Parity

`docs/parity.md` is the source of truth. Short version: nearly every row is **wip** (built and
CI-green, but the row stays wip until the feel is checked on the phone). The not-possible
items are **n/a** (Wear OS, Android Auto, widgets/QS under free signing). Glance-style widgets
are **todo** (App Intents only). Update the row whenever you land something.

## 4. Open threads

| Thread | State | Next step |
| --- | --- | --- |
| `perf-transitions` merge | Waiting on Hoa's on-device checks (§3) | Make a prerelease build from the branch, then hand Hoa a short checklist |
| Spotify Connect | Built, CI-green, never run on real hardware | Hoa tests with Premium plus an Echo/TV/speaker |
| Player sheet feel | "Feel to be checked on the phone" (parity row) | Hoa's feedback |
| On-device ML (lyric sync, instrumentals) | Core ML models on release `models-v1`, downloaded on demand | Check the download and sync on the phone |
| Localisation | English only (owner decision 12) | `tools/localization/…py --with-translations` restores 11 locales when Hoa says so |
| Branch clean-up | ~60 merged or experiment branches | Ask Hoa |

## 5. Relation to the Android repo

- The Android app is **`RedSn0w1877/PixlAudio`**, and it's **read-only** for this project. Its
  newest code is branch `android-int-oct3`, which carries the same BiniLyrics and Spotify
  Connect features as iOS `main`. That repo also has two unrelated git histories. See its
  `handoff/2026-10-04-START-HERE.md`.
- Port logic faithfully: read the Kotlin, keep constants, and port its tests to Swift Testing
  (`docs/test-parity.md`). Fixtures that must match Android exactly are generated from the real
  Kotlin in `tools/android-reference/`. Regenerate them; never hand-edit.
- Hoa's local folders (Windows): iOS is `C:\Users\Hoa\Downloads\Code Projects\PixlAudio-iOS`.
  Android is `C:\Users\Hoa\Downloads\Code Projects\PixelPlayer-master\beta2-release`. An older
  copy sits in `Downloads\PixelPlayer-master\PixelPlayer-master`; don't use it.

## 6. Doc map: open only what you need

| Need | Read |
| --- | --- |
| Rules (binding) | `AGENTS.md` |
| UI: Material → glass mapping, colour, type, spacing, shell, screen map, **seams (who owns which folder)**, screenshot ids, per-stage notes | `docs/design.md` (§ headings are a good index) |
| Performance and transitions: what was slow and the rule now | `docs/performance.md` |
| Feature status | `docs/parity.md` |
| Every Apple API used, with doc URL and min OS | `docs/api-notes.md` (add new ones there) |
| Ported Android tests | `docs/test-parity.md` |
| Install steps | `docs/INSTALL.md` |
| Architecture and original research | `docs/research/` (`architecture.md`, `android-feature-map.md`, `spec-lyricsView.md`, `research-apple-docs.md`, `research-build-without-mac.md`) |
| Reference screenshots from Android | `docs/design-refs/` |
| CI scripts (forbidden patterns, sim pick, IPA) | `ci/` |
| Remote client config (InnerTube etc.) | `remote/config.json` |

## 7. Code map

| Area | Where |
| --- | --- |
| App shell, tabs, router, bottom-bar clearance, tab-bar minimizer | `App/Shell/` |
| Observable stores (library, playback, lyrics, settings, theme, accounts, play counts) | `App/Stores/` |
| Audio engine (`DualDeckEngine`, processing tap, session, Now Playing) | `App/Playback/` |
| Glass design system (`GlassPillButton`, `GlassCard`, `GlassNavBar`, `MiniPlayerBar`, …), `Compat27.swift` | `App/DesignSystem/` |
| Screens | `App/Features/<Feature>/` |
| YouTube / Spotify / AI / ML / backup / updates services | `App/Services/` |
| Library import (folders, Documents, MPMediaLibrary) | `App/Library/` |
| SwiftData models (change only with a new `VersionedSchema`) | `App/Persistence/` |
| Demo data and UI-test launch router (`-uiTest -screen <id>`) | `App/Demo/` |
| Pure logic, zero deps, Windows-testable | `Packages/PixlCore/Sources/<Module>/` |

## 8. Traps

- `PixlAudio.xcodeproj` and `App/Info.plist` are **generated** by XcodeGen from `project.yml` on CI
  and are gitignored. Edit `project.yml`, never the project.
- CI fails the build on forbidden patterns: Material names, `.ultraThinMaterial` and friends,
  remote Swift packages, "Apple"/"Apple Music" in UI strings, iOS 27 APIs outside
  `Compat27.swift`. Run `ci/check-forbidden.sh` mentally before pushing.
- Screenshot flakes that **aren't** regressions are listed in `docs/performance.md` (swipe-scroll
  offsets, About/Equalizer appear fade, lyrics cascade frames, the full player cover at 0.95 scale,
  the playlist More menu settle). Don't chase them.
- Under approachable concurrency, `nonisolated async` runs on the caller's actor, and `Task {}`
  from a view stays on the main actor. Off-main work must be `@concurrent` or `Task.detached`.
- Never write fast-changing values (playback position, drag progress) into the SwiftUI
  environment or into observable state that `body` reads.
- No app extensions, iCloud, App Groups or push. Free-Apple-ID signing can't do them.
- Hoa's desktop folder may hold many build or agent leftover folders (they asked about "1500
  folders"). The project root is the folder with `.git` and `project.yml`. `.build/`, `build/`,
  `DerivedData/`, `shots/` and worktree copies are disposable.

## 9. Finish every session with

1. A green CI run on your branch, with the screenshots looked at if you touched UI.
2. Updated `docs/parity.md` / `docs/api-notes.md` / `docs/test-parity.md` where relevant.
3. A dated note in `docs/handoff/` saying what changed, what was verified and how, what's
   waiting on Hoa's phone, and the exact next step. Or update this page if the state above
   changed.
