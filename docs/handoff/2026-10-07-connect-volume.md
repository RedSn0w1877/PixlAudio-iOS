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
- **CI** (no Mac, no device):
  - run `37691708574` (`c9b5e5a`, the feature): PixlCore tests, build and AppTests (incl. the audio-session hold
    tests) pass; screenshot classes `SpotifyConnectScreenshotTests`, `PlayerScreenshotTests` and
    `SettingsScreenshotTests` pass except `PlayerScreenshotTests/testFavoriteTogglesImmediately` and
    `testSongInfoFavoriteTogglesImmediately`, which fail on main too (branch `s21-main-health` owns them; this branch
    doesn't touch the player).
  - run `37705767037` (`f4a7e0e`): all green — core, build, unit tests, `SpotifyConnectScreenshotTests` +
    `SettingsScreenshotTests` (57 UI tests, light + dark).
  - run `37708207135` (`95482df`, the pop-up's final size): `SpotifyConnectScreenshotTests` pass (15). Its
    first attempt failed one unit test this branch doesn't touch (`DualDeckEngineTests.testCrossfadeOverlapsBothDecks
    WithTheirGainCurves`: 10 audio buffers checked where it wants more than 10, a timing flake on the shared runner;
    it passed on the two runs before); the re-run (attempt 2) is all green.
- **Locally on Windows:** `swift test --filter SpotifyConnect` on PixlCore (34 tests in 7 suites pass); parse check and
  forbidden-pattern check pass.
- **Screenshots looked at** (light + dark): the pop-up over the full player and over the lyrics screen, the devices
  hero after the demo press (slider at 50 %, no pop-up over the sheet), and the Equalizer's Connect volume card. The
  first pop-up let the output pill's and the lyrics title's text show through its glass and truncated "Kitchen Echo
  Show"; it now uses the toasts' tint strength and is 264 pt wide, so it sits between the full player's collapse and
  queue buttons with the whole name.
- **Not verified anywhere:** the button handling itself. The Simulator can't change the volume, so UI tests show the
  pop-up from a demo press only. Nothing here was tested on a phone.
- **Open design choice:** the pop-up uses the app's colours (like Connect's toasts), not the album-art colours, even
  over the full player. Say so if it should follow the player's colours there.

## Review (adversarial pass after the implementer)
Checked the diff against the plan, DECISIONS and AGENTS.md, and looked at the latest screenshots (pop-up over the full
player light/dark and over the lyrics screen, the hero after the demo press, the Equalizer card). Fixed:
- **A speaker that refuses volume commands** (`VOLUME_CONTROL_DISALLOW` while it reports `supports_volume`) got volume
  control back with the next poll (every second): the buttons restarted and re-centred the phone volume, the slider
  came back, and every press showed the "can't change the volume" toast again. The refusal now sticks for the session
  (`SpotifyConnectReducer.refuseVolume`; polls and the device list can't undo it; unit-tested).
- No "Spotify is busy" toast when a poll's 429 lands right after the last volume request (nothing was waiting).
- A cancellation error that isn't the lane's own can no longer leave the volume lane stuck (every later change would
  have waited forever).
- A call or Siri during a reset no longer switches the buttons to Relative mode for the session.

Left as is (by design or edge cases, listed so they're known): the pop-up's glass lets a faint ghost of the output
pill's name show through in light mode (legible); a reset that lands later than 500 ms switches to Relative and its
late echo then counts as one press the other way (one lost press, once); in Relative mode a phone volume already at
full or silent gets no toast until a press reaches the end; after "Waiting: another app is playing audio" the buttons
start the next time PixlAudio becomes active (the hint notification doesn't reach an app without an active session).

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
