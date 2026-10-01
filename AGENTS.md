# AGENTS.md — rules for anyone (human or AI) working in this repo

PixlAudio for iOS is a native Swift 6 / SwiftUI port of the PixlAudio Android app. These rules are binding.
The full architecture is in [`docs/research/architecture.md`](docs/research/architecture.md); the UI rules in
[`docs/design.md`](docs/design.md). Where this file and the research docs disagree, this file wins.

## Product rules (owner decisions)
1. **Liquid Glass only. No Material anywhere** — no Material concepts, colours, ripples, FABs, shapes or naming.
   Built strictly from Apple's official frameworks and documentation.
2. **No third-party code in the app.** Only Apple frameworks and our own Swift. No remote Swift packages
   (CI enforces: `project.yml` may only reference local packages; `Packages/PixlCore` has zero dependencies).
   Build-time tools that never ship are fine (XcodeGen; Python tooling on CI for one-off model conversion).
3. **Full feature parity with Android** before the owner installs — track it in [`docs/parity.md`](docs/parity.md).
4. **SF Pro (the system font) everywhere**, lyrics included. Never bundle fonts.
5. Distribution is a **free Apple ID + Sideloadly**: CI builds an unsigned `.ipa`. Therefore **no app extensions**
   (widgets, Live Activities, share extensions, watch app), no push, no iCloud, no App Groups, no keychain access
   groups. Background audio via the Info.plist key is fine.
6. Deployment target **iOS 26.1**; the owner's phone runs iOS 27. **iOS 27-only APIs live only in
   `App/DesignSystem/Compat27.swift`** behind `#if compiler(>=6.4)` + `if #available(iOS 27, *)` (CI enforces).
7. The karaoke lyrics view must faithfully recreate the Android one (engine constants, feel, background).
8. **Performance is first-class**: no dropped frames at 120 Hz, instant touch response.
9. **Never "Apple" or "Apple Music" in any UI string** (CI greps string literals in `App/`).

## Liquid Glass rules (HIG)
- Glass only in the navigation/control layer: tab bar, toolbars, the mini-player accessory, Now Playing transport,
  floating controls, sheets. **Never on content** — lists, rows, cards, grids, artwork. CI forbids `glassEffect`
  in `*Row*`/`*Cell*`/`*Card*` files and anything under a `Rows/` folder.
- Prefer system components that are glass automatically (`TabView`, `NavigationStack` toolbars, sheets, menus,
  `.searchable`, `.buttonStyle(.glass/.glassProminent)`). Custom glass → `glassEffect` inside one
  `GlassEffectContainer`, few on screen.
- No glass on glass. Never mix `.regular` and `.clear`; `.clear` only over media with bold foreground and ~35 %
  dimming over bright art. Tint only the primary action (tint the glass, not the glyph). Monochrome bars over
  colourful content.
- Never override sheet/popover backgrounds (`presentationBackground`). SF Symbols with accessibility labels.
  Respect Reduce Transparency / Increase Contrast / Reduce Motion. Light and dark everywhere except Now Playing
  and lyrics (always dark).

## Performance rules
- Playback position is **never** observable state; read the player timebase on demand (scrubber ≤ 4 Hz via
  `TimelineView`; lyrics per display-link tick, only for hot lines).
- Fine-grained `@Observable` stores; no fast-changing values in the environment; keep `body` cheap (no sorting,
  formatting, decoding in `body`; cache formatters); stable `id`s in `List`/`ForEach`; lazy stacks/grids.
- Decode/resize images off the main thread (ImageIO thumbnails at display size, cached). DB, file, network and
  parsing work in actors/background tasks. Nothing heavy at launch.
- Animations interruptible (springs); press feedback immediate; no timers ticking while idle.
- The audio render path (processing-tap callbacks) is real-time safe: no allocation, locks, heavy Swift runtime
  work or logging.

## Engineering rules
- Swift 6 language mode, strict concurrency. The app target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
  approachable concurrency; mark pure value types `nonisolated` (so their `Hashable`/`Codable` conformances are not
  main-actor isolated) and put background work in actors or `nonisolated` functions.
- `Packages/PixlCore`: pure Swift, **zero dependencies**, `Sendable` value types, must build and test on **Windows**
  (Swift for Windows) and macOS. Use Foundation only as far as swift-corelibs-foundation supports it
  (`#if canImport(FoundationNetworking)`, `#if canImport(FoundationXML)`); no CryptoKit/os/Combine in PixlCore
  (inject SHA-256 etc. from the app; PixlBackup has its own pure-Swift inflate). `Package.swift` already declares every module and test target —
  **don't edit it** unless a stage genuinely needs a new module. Keep each module's `<Module>Module` enum (the
  app's Diagnostics screen lists them). Test fixtures go in `Tests/<Module>Tests/Fixtures/` (already bundled).
- **API ledger**: every Apple API used for the first time goes into [`docs/api-notes.md`](docs/api-notes.md) with its
  developer.apple.com URL and minimum OS. If unsure an API exists with that signature, check the docs or prove it
  compiles on CI in a small change first. Never guess signatures.
- Port Android logic faithfully (read the Kotlin, keep behaviour and constants), port its unit tests to Swift
  Testing, and record them in [`docs/test-parity.md`](docs/test-parity.md). The Android repo is **read-only**.
- Tests: Swift Testing for PixlCore; XCTest/XCUITest for the app (`AppTests/`, `UITests/`). Screens used in UI
  tests are reachable with launch arguments `-uiTest -screen <id> -appearance light|dark` (see
  `App/Demo/UITestLaunchRouter.swift`); add new screens there with demo data.
- Commit messages in plain English, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` when
  written with Claude. Never rewrite history, never force-push `main`, never `reset --hard` shared branches.
  `.gitattributes` keeps LF line endings.

## Workflow (no Mac)
- App code cannot compile on Windows. Before pushing, run `pwsh ci/parse-check.ps1` (a `swiftc -parse` syntax
  check; it skips with a warning when Swift for Windows is not installed). PixlCore: `swift test --package-path
  Packages/PixlCore` locally (only one local Swift build at a time — use the lock file `.swiftbuild.lock`). On the
  owner's Windows PC plain `swift` lacks its environment: run `cmd //c "ci\swiftw.cmd test --package-path
  Packages\PixlCore"` (the wrapper sets SDKROOT and the MSVC linker; its paths are that machine's). PixlCore passes
  on Windows, `Bundle.module` fixtures included.
- Logic that must match Android/Compose exactly is checked against fixtures generated from the real Android code
  (`tools/android-reference/`); regenerate them there rather than hand-editing.
- Work on stage branches `sNN-name`; push; `gh run watch --exit-status`; on failure `gh run view <id> --log-failed`
  (the job summary lists `file:line: error` lines). `main` must stay green; merge only after CI passes; tag
  `stage-NN`.
- CI (`.github/workflows/ci.yml`): `core` (macos-26, `swift test`), `app` (xcode-27: forbidden-pattern check,
  XcodeGen, build-for-testing, unit tests on an iOS 27 iPhone simulator), `shots` (UI screenshot tests, light +
  dark → artifact `shots-<sha>`; runs on `main` and when the commit message contains `[shots]`), `ipa` (unsigned
  archive → artifact `PixlAudio-unsigned-ipa`; runs on `main`, tags, and `[ipa]`). Batch changes per push.
- Look at screenshots: `gh run download <id> -n shots-<sha> -D shots/`, then open the PNGs.
- `fallback-xcode26.yml` keeps the project building with Xcode 26.6 on `macos-26` (weekly/manual).
