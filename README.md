# PixlAudio for iOS

A native iPhone music player — the iOS port of the PixlAudio Android app. Swift 6 and SwiftUI,
**Liquid Glass only**, built exclusively from Apple's system frameworks (no third-party code in the app).
Plays your own music (folders, Files, the DRM-free part of your music library), streams matched
tracks, and has the karaoke lyrics view from the Android app.

Status: under construction (stage 0 — bootstrap). See [`docs/parity.md`](docs/parity.md).

## Install (Windows, free Apple ID, Sideloadly)

1. Download the latest `PixlAudio-unsigned.ipa` from **Releases** (or the `PixlAudio-unsigned-ipa`
   artifact of the latest green `ci` run on `main`).
2. Install **iTunes** and **iCloud** from Apple's website (not the Microsoft Store versions), then
   [Sideloadly](https://sideloadly.io/).
3. Connect the iPhone by USB, drag the `.ipa` into Sideloadly, enter your Apple ID, press **Start**.
4. On the iPhone: Settings › Privacy & Security › **Developer Mode** on (reboot), then
   Settings › General › VPN & Device Management › trust your Apple ID.
5. Free-account apps expire after 7 days — re-sign with Sideloadly (or enable its auto-refresh).

Requires iOS 26.1 or later (tuned for iOS 27).

## Building

There is no Mac in this project's workflow: GitHub Actions builds, tests, screenshots and packages
everything (`.github/workflows/ci.yml`). The Xcode project is generated from `project.yml` with
XcodeGen and never committed. Pure logic lives in `Packages/PixlCore` (zero dependencies), which also
builds and tests on Windows with Swift for Windows:

```
swift test --package-path Packages/PixlCore
```

Contributors: read [`AGENTS.md`](AGENTS.md) first.
