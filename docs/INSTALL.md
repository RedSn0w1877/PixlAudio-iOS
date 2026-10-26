# Installing PixlAudio on an iPhone

PixlAudio isn't on the App Store. Every release on GitHub comes with one file, `PixlAudio-unsigned.ipa`, which
gets signed with your own Apple ID (or your installer's certificate) when you install it. It needs **iOS 26.1 or
later**.

Get it from the releases page (betas are the ones marked **Pre-release**):
<https://github.com/RedSn0w1877/PixlAudio-iOS/releases>

## Option A: an IPA installer app on the iPhone

This is how Hoa installs it.

1. On the iPhone, open the release page in Safari and download `PixlAudio-unsigned.ipa`. It lands in
   Files › Downloads.
2. Open the file with your IPA installer app (tap it in Files and use Share › the installer, or import it from
   inside the installer) and install it. The installer signs it for you.
3. If iOS asks, turn on **Developer Mode** (Settings › Privacy & Security › Developer Mode, restart, then
   Turn On), and trust the developer (Settings › General › VPN & Device Management › the Apple ID or
   certificate › Trust).

## Option B: Sideloadly on Windows

1. Install **iTunes** and **iCloud** from Apple's website (apple.com), not the Microsoft Store versions.
   Sideloadly needs them to talk to the iPhone.
2. Install [Sideloadly](https://sideloadly.io/) and download the `.ipa` from the release page.
3. Plug the iPhone in by USB, unlock it and tap **Trust** on "Trust This Computer?".
4. In Sideloadly, drag the `.ipa` in, pick your iPhone, enter your Apple ID and press **Start**. Type the
   two-factor code if Apple asks for one. A spare Apple ID works fine.
5. On the iPhone, turn on **Developer Mode** (Settings › Privacy & Security › Developer Mode, restart, Turn On),
   then trust your Apple ID under Settings › General › VPN & Device Management.

### Free Apple ID limits

- An app signed with a free Apple ID **stops opening after 7 days**. Install it again before then (the same
  `.ipa` or a newer one, same way) and the clock restarts. Sideloadly can also refresh it automatically while
  the PC is on.
- **Keep the bundle ID `io.github.redsn0w1877.pixlaudio`** (don't let the installer change it). Installing over the
  existing app with the same bundle ID keeps your library, playlists and settings. A different bundle ID gives you
  a second, empty copy, and deleting the app deletes its data, so make a backup first
  (Settings › Backup & Restore).
- A free Apple ID can have 3 sideloaded apps on a phone at once and register 10 app IDs a week.

### Updating

When a new release is out, PixlAudio shows a banner with what's new. Install the new `.ipa` over the old app the
same way; with the same bundle ID nothing is lost.

## First run

A short setup walks you through connecting Spotify, restoring a backup, theme and library layout. Everything it asks
can be changed later in Settings (the gear on Home, Library or Search).

### Your music comes from Spotify

PixlAudio's library is your Spotify account: your liked songs and playlists. Connecting Spotify is required; until you
do, Home and Library show a **Connect Spotify** button. Songs stored on the phone aren't used.

- Spotify gives the app song details only, not audio. Each song plays through a matching track on YouTube Music,
  found automatically. Streamed audio tops out around 256 kbps.
- **Beta: Spotify only lets invited testers sign in.** Before you sign in, send the email address of your Spotify
  account to the person who invited you, so they can add it.
- Connect on the setup's Spotify page or in Settings › Accounts.
- **Coming from Android:** a PixlAudio backup (`.pxpl`) from the Android app restores your settings and listening
  history here too, on the setup's backup page or in Settings › Backup & Restore.

### Spotify setup (for whoever builds the IPA)

- The IPA is built with the Spotify client ID from the repo secret **`SPOTIFY_CLIENT_ID`** (GitHub › the repo ›
  Settings › Secrets and variables › Actions). If it was empty when the IPA was built, the Spotify screen says
  "No client ID in this build — set one" and you can paste one there.
- In the [Spotify developer dashboard](https://developer.spotify.com/dashboard), the app's redirect URIs must
  include **`pixlaudio://spotify-callback`** exactly (the Android app's `pixelplay://spotify-callback` can stay).
- Spotify apps in development mode only let listed users in: add each tester's name and Spotify email under
  User Management in the dashboard.

### YouTube sign-in (optional)

Streamed songs play without an account. If YouTube starts refusing songs ("confirm you're not a bot"), sign in
with a Google account: **Connect YouTube** on the Spotify screen, or Settings › Developer Options › YouTube
account. You type a short code on Google's own page, so the app never sees your password. **Test playback** (same
places) walks one song through every step and shows which one failed.

## What's different from the Android app

- **AirPlay instead of Cast.** The player's output button opens AirPlay & Bluetooth devices through the iOS picker
  (iOS doesn't let apps list or connect devices themselves).
- **No widgets and no Quick Settings tile.** Apps installed with a free Apple ID can't carry extensions. The
  Lock Screen, Control Center and Dynamic Island controls cover the same ground.
- **No CarPlay** (it needs an entitlement Apple doesn't give sideloaded apps), so no Android Auto equivalent.
  Bluetooth and USB audio in the car work like any player.
- **No watch app.** An Apple Watch shows the usual Now Playing controls.
- **Swiping PixlAudio away stops the music**; iOS ends the app, so there is no "Keep playing after closing".
- Surround downmix, hi-res caps and audio offload are handled by iOS, so those settings aren't there.
- Updates are announced in the app, but you install them yourself.
- Liquid Glass instead of Material, SF Pro instead of Android's fonts, and English only for now.
