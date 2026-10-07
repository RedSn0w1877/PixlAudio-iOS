# Building, verifying and installing iOS apps without a Mac (verified 2026-09-30)

## GitHub Actions macOS runners (https://github.com/actions/runner-images)
- `macos-latest` = `macos-26`: arm64 M1, 3 vCPU, 7 GB RAM, 14 GB SSD; Xcode 26.6 default (26.0.1–26.5 also); iOS SDKs 26.0–26.5; simulators iOS 26.2/26.4/26.5 (iPhone 17 family).
- **`xcode-27`** (public preview since 2026-07-16; on macOS 27 since 2026-09-10): arm64; Xcode 27.0 GA (27A266a) default, 27.1, 27.2 beta; iOS 27.x SDKs; iOS 27.0 simulators (iPhone 17, 17e, 18 Pro, 18 Pro Max, iPads). GitHub now publishes one image per major Xcode. Readme: https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md
- Preinstalled: fastlane, xcbeautify, xcodes. **XcodeGen/Tuist NOT installed** — `brew install xcodegen` or download a pinned release binary.
- Public repos: standard runners free, unlimited minutes; 5 concurrent macOS jobs (Free plan); 6 h max per job. Simulators work (not VMs).
- Select Xcode: `sudo xcode-select -s /Applications/Xcode_27.0.app` or `maxim-lobanov/setup-xcode@v1`.
- Rough timings [uncertain]: small SwiftUI build 2–5 min; simulator boot + UI tests +3–8 min.
- Artifact storage: keep `retention-days` short.

## Project generation: XcodeGen (`project.yml`), .xcodeproj not committed
- Tuist uses Swift manifests (can't validate on Windows) and had a `.icon` bug. Pure SwiftPM can't make an iOS app bundle with entitlements/icons/UI tests — use SwiftPM only for the logic package.
- Icon Composer `.icon`: XcodeGen 2.45.1+ has built-in `.icon` folder support (#1600; the older workaround for XcodeGen#1556 is no longer needed), and CI pins 2.46.0. The asset catalog stays the default because a `.icon` can't be authored or previewed without a Mac: `Assets.xcassets/AppIcon.appiconset` holds 1024×1024 PNGs for the Any, Dark and Tinted appearances, rendered by `ci/make-icon.py`.
- XcodeGen 2.44+ supports `type: syncedFolder` sources.

Minimal example:
```yaml
name: PixlAudio
options:
  bundleIdPrefix: io.github.redsn0w1877
  deploymentTarget: { iOS: "26.1" }
packages:
  PixlCore: { path: Packages/PixlCore }
settings:
  base: { SWIFT_VERSION: "6.0", DEVELOPMENT_TEAM: "" }
targets:
  PixlAudio:
    type: application
    platform: iOS
    sources: [App]
    dependencies: [{ package: PixlCore, products: [...] }]
    info:
      path: App/Info.plist
      properties:
        CFBundleDisplayName: PixlAudio
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
        UIBackgroundModes: [audio]
        UILaunchScreen: {}
        ITSAppUsesNonExemptEncryption: false
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.github.redsn0w1877.pixlaudio
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        CURRENT_PROJECT_VERSION: 1
        GENERATE_INFOPLIST_FILE: NO
  PixlAudioTests: { type: bundle.unit-test, platform: iOS, sources: [AppTests], dependencies: [{ target: PixlAudio }] }
  PixlAudioUITests: { type: bundle.ui-testing, platform: iOS, sources: [UITests], dependencies: [{ target: PixlAudio }] }
schemes:
  PixlAudio:
    build: { targets: { PixlAudio: all } }
    test: { targets: [PixlAudioTests, PixlAudioUITests] }
```

## Install route chosen: free Apple ID + unsigned IPA + Sideloadly on Windows
```bash
xcodebuild archive -project PixlAudio.xcodeproj -scheme PixlAudio -configuration Release \
  -destination generic/platform=iOS -archivePath build/App.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
mkdir -p build/Payload && cp -R build/App.xcarchive/Products/Applications/PixlAudio.app build/Payload/
(cd build && zip -qry PixlAudio-unsigned.ipa Payload)
```
- Sideloadly (v0.60, iOS 26+, auto-refresh daemon, https://sideloadly.io/) or AltServer. Both need iTunes + iCloud from Apple's website (not Microsoft Store).
- Limits: apps expire after 7 days; 3 active apps per device; ~10 App IDs / 7 days [community-reported]; Developer Mode (Settings → Privacy & Security → Developer Mode, reboot); trust profile under Settings → General → VPN & Device Management.
- Background audio survives (Info.plist key). Personal teams cannot use Push or iCloud. Sideloaders re-sign with basic entitlements and may rewrite bundle/group IDs → App Groups / keychain sharing unreliable. → **no app extensions**.
- (Paid route for later, if Hoa ever upgrades: TestFlight via App Store Connect API key + p12 created with openssl on Windows; internal testing needs no review.)

## Verifying UI without a Mac
- XCUITest with launch arguments, e.g. `app.launchArguments = ["-uiTest", "-screen", "nowPlaying"]`; the app reads `ProcessInfo.processInfo.arguments` to load demo data and route to the screen.
- `let a = XCTAttachment(screenshot: app.screenshot()); a.name = "nowPlaying"; a.lifetime = .keepAlways; add(a)`
- Export: `xcrun xcresulttool export attachments --path build/T.xcresult --output-path build/shots` (writes manifest.json); `xcrun xcresulttool get test-results summary --path build/T.xcresult --compact`; `… get test-results tests …`.
- simctl: `xcrun simctl status_bar $UDID override --time 9:41 --batteryState charged --batteryLevel 100`; `xcrun simctl ui $UDID appearance dark`; `xcrun simctl io $UDID screenshot x.png`; `xcrun simctl io $UDID recordVideo --codec h264 x.mp4 & … kill -INT`.
- Windows side: `gh run list -w ci`, `gh run watch --exit-status`, `gh run view <id> --log-failed`, `gh run download <id> -n <artifact> -D out/`, then open PNGs.
- [uncertain] Glass blur/refraction may render with lower fidelity in CI simulators → judge layout/hierarchy on CI, fidelity on the phone.

## Pipeline sketch
```yaml
name: ci
on: { push: {}, workflow_dispatch: {} }
concurrency: { group: ci-${{ github.ref }}, cancel-in-progress: true }
jobs:
  core:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - run: swift test --package-path Packages/PixlCore --parallel
  app:
    runs-on: xcode-27
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
      - run: sudo xcode-select -s /Applications/Xcode_27.0.app
      - run: brew install xcodegen && xcodegen generate
      - run: |
          set -o pipefail
          xcodebuild test -project PixlAudio.xcodeproj -scheme PixlAudio \
            -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=latest" \
            -resultBundlePath build/T.xcresult CODE_SIGNING_ALLOWED=NO | xcbeautify
      - if: always()
        run: xcrun xcresulttool export attachments --path build/T.xcresult --output-path build/shots
      - if: always()
        uses: actions/upload-artifact@v4
        with: { name: shots, path: build/shots, retention-days: 14 }
  ipa:
    runs-on: xcode-27
    steps: [checkout, xcodegen, ci/make-ipa.sh, upload-artifact ipa]
```

## Swift on Windows
- `winget install --id Swift.Toolchain -e` (Swift 6.4.0 current) + VS 2022 Build Tools (C++ tools) + Windows 11 SDK. https://www.swift.org/install/windows/
- Works: compiler, stdlib, SwiftPM (`swift build`, `swift test`), Dispatch, cross-platform Foundation (networking needs `import FoundationNetworking`), XCTest and Swift Testing. Observation likely.
- Doesn't: SwiftUI, UIKit, AVFoundation, MediaPlayer, Combine, OSLog, SwiftData, CryptoKit (Apple-only), anything iOS SDK; no simulator.
- Pattern: pure logic in `Packages/PixlCore`; Apple-only code behind protocols / `#if canImport(...)`; run `swift build && swift test` locally; CI on macOS is authoritative.
