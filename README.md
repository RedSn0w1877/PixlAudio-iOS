# PixlAudio for iOS

A native iPhone music player — the iOS port of the PixlAudio Android app. Swift 6 and SwiftUI,
**Liquid Glass only**, built exclusively from Apple's system frameworks (no third-party code in the app).
Plays your own music (folders, Files, the DRM-free part of your music library), streams matched
tracks, and has the karaoke lyrics view from the Android app.

Version 1.0. Feature parity with Android is tracked in [`docs/parity.md`](docs/parity.md).

## Install

Download `PixlAudio-unsigned.ipa` from **Releases** and follow [`docs/INSTALL.md`](docs/INSTALL.md): an IPA
installer app on the iPhone or Sideloadly on Windows (free Apple ID), first-run setup, Spotify and what differs from
Android.

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
