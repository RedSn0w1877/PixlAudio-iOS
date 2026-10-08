# 2026-10-07 — Volume buttons drive the Spotify Connect speaker (item 8)

Branch `s17-connect-volume` (from main `27dcc76`). Plan: `2026-10-07-plans/connect-volume.json`; owner decisions:
DECISIONS › Spotify Connect volume buttons.

## What changed (what Hoa sees)
- While PixlAudio is open and a Spotify Connect speaker plays, **each press of the phone's volume buttons moves the
  speaker 5 %** (Android's `VOLUME_STEP`). Only for devices that take volume commands (`supports_volume`) and never
  for Smartphone/Tablet devices (so this iPhone's own Spotify app is never interrupted). Always on, no setting.
- **PixlAudio's own volume pop-up** replaces the system one: a glass capsule at the top centre with the speaker's
  name, a level bar and the percentage; it goes away 1.5 s after the last press. It shows over the tabs, the full
  player, the lyrics screen and sheets such as the queue, and stays away while the devices sheet is open (its slider
  moves instead).
- **Equalizer › Volume** shows and drives the speaker's volume while Connect plays (the phone's slider otherwise).
- **Sliders no longer jump back**: a poll that predates the last change can't snap the volume back for 3 s.
  The slider never moves under your finger.
- **Fewer requests, no 429 spam**: volume has its own lane (first change at once, then at most one request every
  300 ms with the latest value). When Spotify asks to wait, it waits quietly and shows at most one "Spotify is busy"
  toast per wait of 3 s or more.
- **Diagnostics** (Settings › Developer › Diagnostics) has a "Volume Buttons (Spotify Connect)" section: mode,
  presses counted, the last change.

## How it works, and the honest limits
iOS has no API for volume button presses. PixlAudio uses the technique the developer forums describe
(docs/api-notes.md › Spotify Connect volume buttons has the sources):
- the audio session is held active during Connect, and `outputVolume` changes are key-value observed; each one-step
  change is one press (`SpotifyConnectVolumeKeys`, unit-tested);
- a 1×1 pt, 1 %-opaque `MPVolumeView` in a corner of the window keeps the system pop-up away (**undocumented**);
- **re-centre:** after each press the phone's volume is set back through that view's internal slider, so presses
  keep coming at any level (**undocumented**; Apple DTS said in 2020 it "generally doesn't work now");
- if the volume doesn't come back within 500 ms, it falls back on its own to **relative** steps: presses still
  work, but the phone's own volume moves with them, and at full or silent a toast says to use the slider in Devices.

Foreground only: Control Center, the lock screen and the background never count; the phone's own volume is put back
when you leave the app. It never starts while another app plays audio. Known gaps: a down press landing exactly
while a reset is still settling is lost; one press can be lost after returning to the app; changing the phone volume
in Control Center while a speaker plays is not a press. Speakers that round their volume (Echo, TVs) may show a
single 5 % step as unchanged after a few seconds.

## How it was verified
- **CI** (no Mac, no device): run `37691708574` — see the final status in the batch report. PixlCore tests,
  build, AppTests (incl. the audio-session hold tests) and the screenshot classes `SpotifyConnectScreenshotTests`,
  `PlayerScreenshotTests`, `SettingsScreenshotTests`.
- **Locally on Windows:** `swift test --filter SpotifyConnect` on PixlCore (34 tests, 7 suites pass); parse check and
  forbidden-pattern check pass.
- **Screenshots looked at:** the pop-up over the full player (light/dark) and over the lyrics screen, the devices
  hero after the demo press, and the Equalizer's Connect volume card (light/dark).
- **Not verified anywhere:** the button handling itself. The Simulator can't change the volume, so UI tests show the
  pop-up from a demo press only. Nothing here was tested on a phone.

## Hoa's iPhone checklist
- [ ] Play on the Echo (or any Connect speaker), stay in PixlAudio, press volume up/down: the speaker moves 5 % per
      press and PixlAudio's glass pop-up shows (not the iPhone's own volume pop-up).
- [ ] Diagnostics › Volume Buttons reads **Re-centre** (not Relative). If it says Relative, note the line under it.
- [ ] Hold a button: the speaker keeps stepping smoothly, no "Spotify is busy" spam.
- [ ] Leave the app and come back: your phone's own volume is what it was before.
- [ ] Pull down Control Center and drag the volume: the speaker doesn't change.
- [ ] If it runs in Relative mode: at full / silent phone volume a toast points to the slider in Devices.
- [ ] The pop-up shows over the full player, the lyrics screen and the queue; it doesn't show over the devices sheet.
- [ ] Equalizer › Volume shows the Echo's volume while it plays, and its slider changes it.
- [ ] Play something in another app first, then open PixlAudio while the Echo plays: the other app keeps playing.
- [ ] Stop playing on the Echo: music continues on the phone at a normal volume with the normal iPhone pop-up.
- [ ] If the iPhone's own pop-up still shows: tell the next session (the hidden view's position/alpha is the knob).

## Next step
Merge after Hoa's phone check (or merge now and treat the checklist as a follow-up). If re-centring doesn't work
on iOS 27, relative mode is the floor; nothing else in the app depends on it.
