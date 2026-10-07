# Owner decisions for the 2026-10-07 batch (PixlAudio iOS)

The owner (Hoa) answered the questions below. For every other `ownerDecisions` entry in a plan,
use the plan's **suggested / recommended** option. Owner requests override Android parity:
record each divergence in `docs/parity.md`.

## Lyrics page (plans/lyrics-page.json)
- Synced / Static segments → **A. Translate · Sing**.
  - Translate: on-device translation toggle. Long-press menu holds Translate via AI and Show romanization.
  - Sing: vocals off/on through the instrumental. It replaces the floating instrumental toggle.
- Synced vs plain is chosen automatically. Add a "Show as plain text" switch in the More sheet.
- Keep screen on: **always on** whenever the lyrics page is open (paused too).
  - Remove the toggle from the UI and preferences.
  - Old backups carrying `keep_screen_on_lyrics` restore cleanly and list it under skipped settings.
- "0 liquid glass": fix BOTH the lyrics screen chrome (option a: match the full player's chrome
  tints; play/pause and active segment as strong as the full player's) AND the More sheet
  (partial-height floating glass sheet; rows stay soft fills, and the alignment picker plus the
  shuffle/repeat/heart row become liquid).
- Lyric lines keep fading before the bars (no scroll-under for now).
- Translate on device targets the phone's language only.

## Sync editor bug (plans/sync-editor.json + plans/sync-editor-rootcause.md)
- Symptom on the owner's iPhone: **tap sync → loading screen shows → editor disappears → nothing.**
- Implement the root-cause fix in sync-editor-rootcause.md, which supersedes the plan's option A
  where they differ:
  - close reasons; a disappearing view never navigates;
  - remove the static open flags;
  - present the editor from INSIDE the lyrics cover (nested fullScreenCover). The More-sheet
    entry opens only after the sheet's onDismiss;
  - the same for Edit song;
  - errors instead of silent closes (load watchdog via openWaitMs, Connect-active message).
- While Spotify Connect plays: show "Syncing only works on this iPhone. Switch playback back to
  this iPhone first." with a Close button.
- Tap-screen toasts let taps pass through (Undo excepted).
- Add `UITests/LyricsSyncEntryTests` that opens the editor FROM the lyrics screen (chip, and More
  sheet) and asserts it is still open 3 s later.

## Streaming speed (plans/streaming-speed.json)
Implement in this order:
1. R12 measure: diagnostics timing lines.
2. R2 small first chunk.
3. R3 prefetcher v2: next 1 on cellular, next 2 on Wi-Fi, 512 KB each, none in Low Data Mode,
   only while playing.
4. R4 don't block on remote config.
5. R5a Android-style retry.
6. R7 skip into the prepared next song.
7. R11 faster Spotify matching: pre-match the next 1–2 queue entries.

Then:
- R8 overlapping clients: implement behind a remote-config flag that defaults OFF.
- R9 only if R12 shows it matters. Leave it out unless trivially safe.
- R6 only if the plan's verified approach is low-risk.
- R5b: no. TV/IOS client order: leave as is.
- iOS-first divergence is fine. List each change in parity.md as "Android later".

## Local AI (plans/local-ai.json)
- The owner has an iPhone 16 Pro (Apple Intelligence capable).
- **Phase 1 (option A):** Apple Foundation Models on-device is the DEFAULT for every AI feature.
  - Cloud providers stay as an optional "Cloud assistants" section, off by default, with NO
    automatic fallback to the cloud.
  - Gemini users without a key are switched to on-device once.
  - Hide advanced knobs when on-device is selected (keep Temperature).
  - Playlist Lab: option A (model picks attributes; app fills from library; model orders ~40).
  - Port Android's AI home greeting.
  - Taizo: general music answers + a library lookup tool + conversation memory.
  - Lyrics: one "Translate" action using the system translator.
    - The lyrics group owns the lyrics UI; the AI group must not edit LyricsChrome / LyricsView /
      LyricsMoreSheet.
    - It keeps AILyricsTranslator working on-device for the long-press "Translate via AI".
- **Phase 2 (owner explicitly asked):** ALSO build the DOWNLOADABLE local model (option C:
  Core ML small LLM, Apache-2.0, e.g. Qwen), converted on CI like the wav2vec2/MDX models,
  downloaded on demand via ModelManager.
  - It is **OFF by default**: a Settings toggle "Use downloaded AI model" (with size, download
    progress and delete).
  - When on, AI features use the downloaded model instead of Apple's.
  - Inference only through Apple frameworks (Core ML, MLState KV cache); our own Swift tokenizer
    and sampler. No third-party code in the app.

## Player (plans/player-controls.json)
- Favourite heart: fix A (observed lookup + small child view). Also fix the same staleness
  elsewhere, and wire the lock-screen / Control Center Like command.
- Previous/next: settle back exactly like play/pause (220 ms).
- Top bar: remove "Now Playing" and the cloud icon. Option A: the right-hand output pill grows
  to show the device name.
  - Phone speaker: icon only.
  - Wired, Bluetooth and car outputs show their names, as do AirPlay and Spotify Connect.

## Spotify Connect volume buttons (plans/connect-volume.json)
- Option A: observe outputVolume, suppress the system HUD, re-centre via the hidden MPVolumeView
  slider, with automatic fallback to option B.
- Foreground only. 5 % per press.
- PixlAudio's own glass volume pop-up at top centre, hidden while the devices sheet is open.
- Always on, no toggle.
- Exclude Connect devices of type Smartphone/Tablet.
- While Connect plays, the Equalizer's volume card shows the device volume.

## More Liquid Glass (plans/glass-expansion.json)
- Options A + B.
  - Queue, song options, AI Daily Mix and Taizo chat sheets become see-through glass at about
    92 % height (partial detent; never override presentationBackground).
  - Queue toolbar: (a) separate glass circles, no backing capsule.
  - Queue ⋯ menu: (a) the ⋯ circle liquid-morphs into the menu pills.
- Primary buttons on floating bars become their own glass pill (Save as playlist, Edit song,
  tab-order Done, Quick Fill Next).
- Listening Stats header: frosted glass bar like Settings.
- Do NOT touch the lyrics page (lyrics group) or the full-player top bar (player group).

## Accent colour (plans/accent-color.json)
- Option A, seed-chroma, **vivid**.
- The player keeps album-art colours. Rename the unused "System Dynamic" Player Theme option to
  "Accent Color".
- Default stays today's soft PixlAudio violet.
- Presets: Blue, Indigo, Purple, Pink, Red, Orange, Yellow, Green, Mint, Graphite (grey), Custom.

## Logo (plans/logo.json)
- Universal: both apps. The concept choice is pending (previews being rendered). Not part of
  this build wave.

## Cloud Studio (plans/cloud-studio-design.md, owner answers 2026-10-07)
- Storage: **Cloudflare R2** with presigned URLs. The worker holds no credentials. The design's lifecycle rules and retention apply.
- Languages: **no Whisper in v1.** Songs outside the aligner's 11 languages fall back to line timing. Keep the design hook so Whisper can be added later.
- Streamed (Spotify/YouTube) songs: **download permanently first** (like Android), then upload the downloaded file.
- Every other section 9 decision uses its recommended default:
  - the anvuew BS-RoFormer ft1 model;
  - transcribe songs with no lyrics, labelled "AI-written lyrics";
  - outputs: instrumental plus word-timed lyrics;
  - $10 prepaid, max 1 worker, app cap $3/month, keepalive alarm.
- Results come back immediately while the app is open (poll /status, then fetch from R2). The R2 mailbox covers the app being backgrounded, the phone locking, and large files.
- The owner may already have created a plain repository secret `RUNPOD_API_KEY` (asked earlier). The deploy job runs in `environment: runpod`, and repository secrets are visible to environment jobs, so either works.
- Android uses the same endpoint and schema later.
