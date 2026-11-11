# Cloud audio: Spatial audio profiles (spec, 2026-11-10; Enhanced audio cut 2026-11-11)

The contract for the next beta's audio work, shared by the GPU worker (`cloud/runpod-worker`, this repo), the
iOS app (this repo) and the Android app (`RedSn0w1877/PixlAudio`, a copy of this file lives in its `handoff/`).
Owner decisions are marked **(owner)**. If code and this file disagree, fix one of them in the same change.

> **Cut on 2026-11-11 (owner): Enhanced audio.** There is no cloud restoration of songs, no `enhance` task, no
> `enhanced.*` object in the library, no `restore` field anywhere, no `enhanced.enabled` setting and no restoration
> model in the worker. This file describes Spatial audio only. Code or contract types that still carry any of
> those names (some were written before the cut) are to be removed, not left dormant.

## 1. What the user gets

- **Spatial audio** for headphones, with six **profiles**: `studio` (default), `wide`, `intimate`, `hall`
  ("Concert Hall"), `surround`, `night`. Picking a profile switches on a light **on-device** version at once.
  The **cloud** renders the real thing from separated stems; when it is ready the player fades to it mid-song,
  and every later play starts on it.
- **Shared library** (owner): a finished render is stored once in R2, keyed by the YouTube video, and any device
  fetches it. Nothing is processed twice while it is there.
- **Silent background processing** (owner): favourites and most-played songs are prepared ahead, like Sing's
  "Prepare songs ahead".

Words that must never appear in UI, docs, changelogs or notes for this feature: *lossless*, *hi-res*, *Dolby*,
*Atmos*, *360 Reality*, and (as before) the cloud AI's model name and the lyrics source's old name. The feature
name is **Spatial audio**. It is for headphones; speakers, cars and Connect devices get the normal stereo
sound.

Out of scope this round: head tracking, multichannel files, stems on the phone, a server in front of R2.

## 2. Ids and versions

| Name | Value |
|---|---|
| `videoId` | the matched YouTube video id, `^[A-Za-z0-9_-]{11}$`. The library key. Never the Spotify id. |
| profile id | `studio`, `wide`, `intimate`, `hall`, `surround`, `night` |
| library version `LIB_V` | `1`. In every key (`lib/v1/...`). Bump it when the renderer or the separator changes audibly; old renders are then ignored and expire on their own. |
| render engine id | `pixl-spatial-1` |
| worker version | `1.1.0` |

## 3. The library in R2 (bucket `pixl-cloud-studio`, the same bucket and keys as Cloud Studio)

```
lib/v1/<videoId>/sp-<profile>.flac     the binaural render, FLAC 16-bit, the input's sample rate and frame count
lib/v1/<videoId>/sp-<profile>.json     its manifest, written LAST (its presence means the render is complete)
```

- Phones sign the URLs (SigV4, the built-in bucket key), exactly as for `in/` and `out/`. The worker still holds
  no storage keys. The worker checks each URL's path against the canonical key above.
- The bucket's catch-all lifecycle rule deletes objects 30 days after they are written. That is the library's
  time-to-live: a render stays shared for 30 days; phones keep their own copy as long as they like.
- **Free-tier guard (owner: storage must stay free):** R2's free tier is 10 GB. `cloud-library-janitor`
  (GitHub Actions, daily, uses `CLOUD_DEFAULTS_KEY` to sign S3 calls like `cloud-e2e`) lists `lib/` and deletes
  the oldest renders until `lib/` is under 8 GB: the manifest first, then the audio, so a half-deleted render is
  never advertised.
- No object is ever updated in place and there is no shared index: one manifest per render. Two jobs rendering the
  same thing at once just write the same result twice.

### 3.1 Render manifest (`sp-<profile>.json`)

```json
{
  "schema": "pixl.library.render", "v": 1, "libV": 1,
  "videoId": "J7p4bzqLvCw", "kind": "spatial", "profile": "studio",
  "audio": {"key": "lib/v1/J7p4bzqLvCw/sp-studio.flac", "bytes": 27100200, "sha256": "<64 hex>",
            "codec": "flac", "bits": 16, "sampleRate": 48000, "samples": 9696000, "durationMs": 202000},
  "loudness": {"integratedLufs": -13.8, "sourceLufs": -9.8, "headroomDb": 4.0, "truePeakDb": -1.0,
               "limiterMaxDb": 0.6},
  "source": {"itag": 251, "codec": "opus", "sampleRate": 48000, "decodedSamples": 9696000,
             "sha256": "<64 hex of the uploaded file>"},
  "render": {"engine": "pixl-spatial-1", "stems": "open-cascade-6", "stemMode": "stems6"},
  "worker": {"version": "1.1.0", "gitSha": "abcdef012345"},
  "createdAt": "2026-11-10T19:02:11Z"
}
```

- `kind` is always `spatial` (the field stays so other kinds can be added later without a new schema).
- `render.stems` names whatever produced the stems (the separator is a replaceable part, see section 5).
- `stemMode` is `stems6`, `stems4` (fallback separator) or `mix` (no usable stems: the stem-free render).
- The audio keeps the source's timeline: same sample rate, same frame count, no added delay.
- **Level.** A binaural render of a loud modern master peaks 3-5 dB higher than the master at the same loudness,
  so every spatial render sits `headroomDb` (4.0) under the source's integrated loudness instead of being squashed
  back (`integratedLufs` = `sourceLufs` - 4.0, within 0.3). The on-device stage has the same 4 dB built into its
  `gain`, so the two match and the switch is level-neutral. The apps give the 4 dB back whenever they have the room
  (6.3).
- A phone accepts a manifest only when `schema`, `v`, `libV`, `videoId`, `kind` and `profile` are what it asked for
  and, after download, bytes and sha256 match.

## 4. Job schema additions (still `v: 1`; old jobs are unchanged)

New task: `spatial`. It needs the new top-level `library` object:

```json
"tasks": ["spatial"],
"library": {
  "v": 1,
  "videoId": "J7p4bzqLvCw",
  "source": {"itag": 251, "codec": "opus"},
  "renders": [
    {"profile": "studio", "audioPut": "<PUT lib/v1/<videoId>/sp-studio.flac>",
     "manifestPut": "<PUT .../sp-studio.json>", "manifestGet": "<GET .../sp-studio.json>"}
  ]
}
```

Rules (worker `schema.py`, mirrored in `job.input.schema.json`, the examples and both apps' builders):

- `library` is required when `tasks` has `spatial`, and ignored otherwise.
- `library.v` must equal the worker's `LIB_V`, else `UNSUPPORTED_VERSION` ("library.v").
- `videoId` must match the pattern. `source` is optional (`itag` integer, `codec` string ≤ 16) and only recorded.
- `spatial` needs `renders`: 1 to 6 entries, profiles unique and known; every URL passes `check_presigned_url`
  with the canonical key as the expected suffix. `manifestGet` is optional (the "already there" check).
- `output.put.manifest` (the job's own manifest in `out/<jobKey>/`) stays required. `output.codec` does not apply to
  library files. `spatial` may be combined with the old tasks in one job; they are independent.
- `separation.quality` applies to the six-stem separator too (`best` = more overlap, same 8-minute limit).

Pipeline order for a job with library tasks:
`guard → caps → download → probe → decode → [existing stages for old tasks] → library checks (manifestGet: a valid
manifest for this libV/videoId/profile means "exists", skip it) →
stems6 → render each missing profile → encode → upload audio → upload its manifest → job manifest last → delete input`.
When every requested library output already exists the job ends `ok` at once (no separation), with the outputs
marked `exists`.

Job manifest additions (`job.result.schema.json`, all optional so old readers are fine):

- `outputs` gains the slots `sp-<profile>` (same shape as a stem output; `key` is the `lib/` key).
- `library`: `{"videoId": "...", "libV": 1, "renders": {"studio": "ok"}, "stemMode": "stems6"}`.
  Per-render states: `ok` (made now), `exists` (was already in the library), `failed` (then the job is `partial`).
- `timings` gains `stems6Ms`, `renderMs` (0 when unused). `models` gains `stems6`.
- Progress strings: `stems6:NN`, `render:NN`.

A failure in one render leaves the others intact (`status: partial`). A library-only job where everything fails is
an error with the first failure's code, and the input stays for a retry.

## 5. Worker modules

| Module | What |
|---|---|
| `pixl_worker/spatial/` | The renderer. Pure NumPy (no torch, no SciPy), so the CPU tests run it. Entry points below. |
| `pixl_worker/separate.py` `Stems6` | Six stems from open models only, as a cascade: vocals from the existing BS-RoFormer (anvuew), then `htdemucs_ft` on the rest for drums, bass and other (both already in the image), then `htdemucs_6s` (MIT, 55 MB, lazy) run on that "other" stem to lift guitar and piano out of it. Running it on "other" keeps the six consistent: guitar + piano + what is left add up to "other" exactly. Without the `htdemucs_6s` file the result is the four stems (`stemMode: stems4`). Stem id `open-cascade-6`. |
| `pixl_worker/library.py` | Library keys, manifests, the "exists" check, encode to FLAC 16-bit with TPDF dither. |

Renderer interface (owned by the lead, do not change the signature without updating this file):

```python
from pixl_worker.spatial import PROFILE_IDS, ENGINE_ID, render_profiles

results = render_profiles(
    mix,            # (frames, 2) float32, the song at `sample_rate`
    stems,          # {"vocals": (frames, 2) float32, "drums": ..., ...} any subset of the six names, or {} for the
                    # stem-free render. Whatever the stems don't sum to is added to "other" inside.
    sample_rate,    # 44100 or 48000 (other rates: resample around the renderer, see library.py)
    profiles,       # iterable of profile ids
    progress=None,  # callable(done, total)
)
# -> {profile: SpatialResult(audio=(frames, 2) float32 in [-1, 1], integrated_lufs, source_lufs, true_peak_db,
#                            limiter_max_db, stem_mode)}
```

`spatial.preview.build_tables()` produces the on-device coefficient file of section 7 from the same HRIR data.
HRIR data: SADIE II subject D1 (Neumann KU100), Apache-2.0, converted once by `tools/build_hrir.py` to the small
`spatial/data/hrir_ku100.npz` that is committed.

Endpoint: `timeout` and `PIXL_EXECUTION_TIMEOUT_S` go to 1800 s (library jobs do more work); GPU pools unchanged.

**The separator is a replaceable part.** The renderer only needs a dict of stems (any subset of vocals, drums,
bass, guitar, piano, other; each `(frames, 2)` float32 at the song's sample rate and length). `Stems6` is the one
place that produces it. The cascade above is what this repository ships. BS-RoFormer SW, the six-stem model with
the best published scores, is NOT shipped by the lead: its only source is a community conversion of the stem
splitter inside Apple's Logic Pro, and the worker image is public. Swapping the separator is the owner's call and
is done by hand in `Stems6` (see `docs/handoff/2026-11-11-spatial-roadmap.md`, "Where your own separator plugs
in"); bump `LIB_V` when the separator changes, so old renders are not reused.

## 6. App behaviour (both platforms; keep the two apps' behaviour identical)

### 6.1 Settings and state

| Setting | Default | Meaning |
|---|---|---|
| `spatial.profile` | `off` | `off` or a profile id. Picking a profile turns Spatial audio on. |
| `spatial.route` | `headphones` | `headphones` (wired, Bluetooth A2DP/LE, USB headset; a Bluetooth speaker counts) or `always` (Developer mode only). |
| `spatial.cloud` | on when built-in cloud keys exist | Ask the cloud for the real render. Off = on-device only. |
| `spatial.prepareAhead` | on | Prepare favourites and most-played ahead (Wi-Fi only, battery not low). |
| `cloudAudio.storageMB` | 3072 | Local budget for downloaded renders; least-recently-played are removed first. |
| `cloudAudio.monthlyCapUSD` | 30 (owner: "raise it"; Developer mode can set up to 200 or No limit) | Separate from Sing's cap; Sing's $3 cap is unchanged. |
| `cloudAudio.dailyAhead` | 25 | Songs a day the background queue may send. |

Stored forms (identical on both platforms): `cloudAudio.monthlyCapUSD` "No limit" is `-1`; `cloudAudio.storageMB`
is kept within 256 … 65536; `cloudAudio.dailyAhead` within 1 … 100; a stored `spatial.route = always` is honoured
whether or not Developer mode is on (only the row is hidden).

**Two switches.** Cloud Studio's own "Process songs in the cloud" switch is the master: off means no cloud
activity of any kind, library lookups and downloads included. `spatial.cloud` is Spatial's own switch under it.
A library job, lookup or download needs both on.

**Money.** Library jobs have their own monthly sum and their own cap (`cloudAudio.monthlyCapUSD`). They are not
counted against Sing's cap and Sing's jobs are not counted against theirs; Sing's $3 rule with built-in keys does
not clamp them.

Per song and profile the app tracks: `none` → `preview` (on-device) → `queued` → `processing` → `downloading` →
`ready` (a verified local render) or `failed` (retry later with backoff: 10 min, 1 h, 1 day). `downloading` is a
state of its own on both platforms (it has its own status line). A render that is wanted but cannot start yet is
`queued` with a reason: `waitingForNetwork` (no network the person allows) or `capReached` (the month's limit).

### 6.2 Getting a render

1. Local store hit (`<videoId>`, profile, `LIB_V`): use it.
2. Else, if `spatial.cloud`: GET `lib/v1/<videoId>/sp-<profile>.json` (signed). 200 and valid → download the FLAC,
   verify bytes and sha256, store. This costs nothing on the GPU and is allowed on any network the user allows
   for cloud work.
3. Else send a job: prepare and upload the song exactly as Cloud Studio does today on that platform (the same
   preparer and the same decode-to-FLAC rule; do not add a resample that isn't there today), `tasks: ["spatial"]`,
   one render entry for the profile.
   `library.source` names the STREAM the audio came from (`itag`, `codec`), not the uploaded FLAC. The request's
   `executionTimeout` policy is 1 800 000 ms for a job with library tasks (it overrides the endpoint's). Reuse
   the Cloud Studio engine, queue, priority lane, background rules, RunPod client and Active jobs UI; where the
   transfer layer only accepts today's slot names, teach it `sp-<profile>`. A Sing job still has
   priority over library jobs.
   A render's sample rate is the uploaded file's (44.1 kHz from an iPhone, the stream's own rate from Android), so
   a phone may fetch a render at a different rate than its own stream: line them up by media time, never by frame
   count across files.
4. On `ok`/`partial`: read the job manifest's `library`, then download each `ok`/`exists` output from its `lib/`
   key and verify it. Never delete `lib/` objects (other devices use them). Delete `in/` and `out/<jobKey>/` as
   today.

Local store: Android `filesDir/cloud_audio/<videoId>/…`, iOS `Application Support/CloudAudio/<videoId>/…`, holding
the FLAC and its manifest. The file's presence plus a valid manifest is the index (no database change).

### 6.3 Playing

- "Spatial active" = a profile is selected AND the route rule passes AND Sing's instrumental mode is not on.
- At the start of a song, when Spatial is active and a local render exists for the profile: play the local file,
  with the on-device spatial stage **bypassed for that item** (never spatialize twice). Otherwise play the normal
  stream through the on-device stage and start 6.2.
- When a render arrives for the song that is playing, with at least 20 s left and no seek or track change in
  flight: switch to it with the existing instrumental swap mechanism (pre-roll muted, align, short **linear**
  crossfade of about 250 ms, at a quiet moment when the app can tell), and bypass the on-device stage for it.
  Otherwise the next play uses it.
- Changing profile mid-song: switch the on-device preset at once (ramp ~80 ms). If a cloud render of the old
  profile was playing, swap to the new profile's local render when there is one, else back to the stream with the
  on-device stage; then run 6.2 for the new profile.
- Turning Spatial off, or the route rule failing (headphones unplugged): the on-device stage bypasses at once; a
  cloud render that is playing is swapped back to the stream (or, if that is hard on a platform, finishes the song
  and the next song is normal: say which in the handoff note).
- ReplayGain, gapless/crossfade between songs, lyrics timing, the queue and Now Playing must not notice any of
  this: the queue entry stays the same song.
- The existing Sing swap fades over 300-700 ms and has no "time left" rule; for these switches the fade is about
  250 ms and the 20 s rule above is new. Sing's own behaviour must not change.
- **Level.** Both spatial paths play 4 dB under the source (3.1). While a spatial rendition is audible (on-device
  stage active, or a spatial render playing) the app multiplies its own playback gain for that item (the
  ReplayGain / volume-normalisation gain it already applies) by +4 dB, **capped at unity**: `min(1.0, gain *
  1.585)`. So with loudness normalisation pulling a loud song down by 4 dB or more, Spatial is exactly as loud as
  stereo; without it, Spatial is up to 4 dB quieter and nothing ever clips. Ramp the change with the same 80 ms /
  crossfade ramps. Use the manifest's `headroomDb` for renders and the table's `headroomDb` for the on-device
  stage (both 4.0 today). Streamed songs have no normalisation gain today, so in practice Spatial plays 4 dB under
  stereo: that is expected (a loud master cannot be spread around the head and stay as loud without crushing its
  peaks), and the sheet says so in one line (6.5).
- While the on-device stage is active, Android audio offload is off (processors don't run under offload) and the
  old "virtualizer/width" effects stay bypassed on both platforms. Turning a profile on mid-song on a phone that
  was using offload costs one short gap, once; that is accepted (offload stays on for everyone who has no profile
  selected). Android's Hi-Fi float output leaves custom processors out of the pipeline, so **Spatial wins**: while
  a profile is selected and Spatial is active, float output is off.
- A song at a sample rate the on-device stage does not take (not 44.1 or 48 kHz) plays without the on-device stage;
  the cloud render still works (the worker resamples around the renderer). No status line of its own.

### 6.4 Background queue (prepare ahead)

Candidates: the same ranking Sing's prepare-ahead uses (favourites, play count, recency, skip rate), for the
selected profile only. For each: 6.2 steps 1–2 first (downloads are cheap), then step 3 within `dailyAhead` and the
monthly cap. Wi-Fi/unmetered only, battery not low, never while Data Saver/Low Data Mode is on. A song whose audio
is not on the phone may be fetched for this (Wi-Fi only). Silent: no notification, only the Active jobs row.

### 6.5 UI

- A **Spatial audio** entry in the full player (a chip/button near the other player actions) opening a sheet:
  the profile list (name + one line), Off, and a status line for the current song. Every state has one:
  | State | Line |
  |---|---|
  | on-device stage playing, cloud render wanted (queued, uploading, processing) | On your phone for now. The cloud version takes about a minute. |
  | wanted, but no network the person allows for cloud work | On your phone for now. The cloud version waits for Wi-Fi. |
  | wanted, but the month's cloud limit is reached | On your phone only. This month's cloud limit is reached. |
  | render downloading | Getting the cloud version. |
  | cloud render playing | Playing the cloud version. |
  | a profile is on, cloud renders are off | On your phone only. Turn on cloud renders for the full version. |
  | the render failed | The cloud version didn't work this time. Still playing on your phone. |
  | route rule fails | Headphones only. Plug in to hear it. |
  | Sing's instrumental mode is on | Paused while Sing is on. |
  Under the list, one quiet line: "Spatial plays a little quieter so the peaks stay clean."
- Settings: a **Sound** group with Spatial audio (profile, cloud toggle, prepare ahead), and
  "Songs ready: N · X GB on this phone" with "Remove downloaded renders". Developer mode shows route mode, caps,
  storage budget and per-song diagnostics (source codec, stem mode, loudness).
- Android: Material 3 Expressive, no glass. iOS: Liquid Glass, system components. Performance rules as always:
  nothing on the main thread, no per-frame allocation, animated values read in layout/draw only.
- Profile one-liners: Studio "Clean and close, like good speakers in a quiet room." · Wide "Instruments pushed
  out to the sides." · Intimate "The voice right in front of you." · Concert Hall "A big room, a few rows back."
  · Surround "Sound beside and behind you." · Night "Softer and gentler for late listening."

## 7. On-device spatial stage (identical maths on Android and iOS)

Stereo in, stereo out, at the source rate (44.1 or 48 kHz; any other rate: bypass). All coefficients come from
`spatial_preview_v1.json` (generated by the worker's `spatial.preview`, committed to both apps as an asset;
never hand-edit it). Per profile and rate:

```json
{"xoverHz": 120.0, "roomHpHz": 250.0, "lowDelay": 55, "taps": 192,
 "direct": [...192 floats...], "cross": [...192 floats...],
 "sparseL": [[delaySamples, gainFromLeft, gainFromRight], ...about 40...],
 "sparseR": [[delaySamples, gainFromLeft, gainFromRight], ...about 40...],
 "gain": 0.573}
```

Processing per channel pair (the head is symmetric, so there are only "same side" and "cross" paths):

```
lo = LR4_lowpass(x, xoverHz)                     # two identical 2nd-order Butterworth low-pass biquads in series
hi = x - lo                                      # per channel
rm = HP2(hi, roomHpHz)                           # ONE 2nd-order high-pass biquad per channel: the room's input
yL = fir(hiL, direct) + fir(hiR, cross) + Σ over sparseL: gainFromLeft*rmL[n-d] + gainFromRight*rmR[n-d]
yR = fir(hiR, direct) + fir(hiL, cross) + Σ over sparseR: gainFromLeft*rmL[n-d] + gainFromRight*rmR[n-d]
outL = gain * (yL + loL[n - lowDelay])           # same for R; fir(x, h)[n] = Σ_k h[k] * x[n-k]
outL = softLimit(outL)                           # see Headroom below; same for R
```

- Biquad coefficients are computed on the device from `xoverHz`, `roomHpHz` and the rate: RBJ low-pass and RBJ
  high-pass, both Q = 1/√2, a0 normalised to 1 (`spatial/preview.py`: `lowpass_coefficients`,
  `highpass_coefficients`). Direct form I, as in `process`.
- **Changed 2026-11-11 (tables v1.1):** the `roomHpHz` high-pass on the sparse room's input is new (without it the
  room carried the bass and a hall boomed before every kick), the rear pair no longer adds level, and the room is
  wetter. The file's `v` stays 1: a v1 table without `roomHpHz` is the old shape and must be treated as
  `roomHpHz` = 0 (no high-pass); the shipped file always has it.
- The file's top level is `{"schema": "pixl.spatial.preview", "v": 1, "engine": "pixl-spatial-1", "headroomDb":
  4.0, "profiles": {"studio": {"44100": {...}, "48000": {...}}, ...}}`. The largest sparse delay is about 8600
  samples (Concert Hall at 48 kHz). The two ears' sparse lists differ on purpose (that is what makes the room
  surround a centred voice).
- State: FIR history, one delay ring ≥ the largest sparse delay + 1 (power of two), biquad states. No allocation
  while processing. Changing preset or bypass ramps a wet/dry mix over ~80 ms (dry = the untouched input delayed by
  `lowDelay`), then swaps coefficients; never a click.
- Headroom: `gain` already holds the loudness match and the 4 dB of headroom, so peaks stay under full scale on
  all but the hottest masters (measured: up to about +1 dB over on loud masters, for a few samples a minute).
  So while the stage is active, every output sample goes through the same soft limiter on both platforms, iOS's
  `SoftLimiter` (`Packages/PixlCore/Sources/PixlAudioCore/ReplayGain.swift`): with t = 0.8912509 (−1 dBFS),
  |x| ≤ t passes untouched, otherwise y = sign(x) · (t + (1 − t) · tanh((|x| − t) / (1 − t))). It does nothing
  below −1 dBFS, so it is not an always-on saturation. Android implements the same function. The golden file is
  the stage BEFORE the limiter (the reference `process` has none).
- The worker also writes `spatial_preview_golden_v1.json`: `{"frames": 1024, "tolerance": 1e-4, "input": {"left":
  [...], "right": [...]}, "output": {"<profile>": {"<rate>": {"left": [...], "right": [...]}}}}`: the output of
  the reference implementation (`spatial/preview.py` `process`, from a zero state) for that input. Both apps' unit
  tests must reproduce every profile and rate within the tolerance.
- Both files are generated: `cloud/runpod-worker/schema/v1/spatial/` holds the originals (`python -m
  pixl_worker.spatial.preview --out schema/v1/spatial`); the apps carry byte-identical copies.

## 8. Tests each side owes

- Worker: schema (good and broken `library` blocks, both through `schema.py` and jsonschema), pipeline with fake
  models (exists/skip, partial, error, manifest contents, keys), library key/URL checks, renderer invariants
  (length, loudness match ±0.3 LU, true peak ≤ −1 dBTP, left/right symmetry, silence in → silence out, stem-free
  path), the janitor's ordering. Examples for every new shape, copied to the apps' fixtures.
- Apps: builder output equals the examples, manifest decoding and rejection of mismatches, store index and
  eviction, state machine, the on-device stage against the golden file, route rule, bypass-for-render rule.

## 9. Open items (to settle with measurements, then update here)

- Speed and memory of the stem cascade and the renderer on the 16/24 GB pools (first `bench` after the worker
  deploys).
- Whether iOS can play the Opus stream repackaged in MP4 (separate work item; unrelated to this contract).
- Volume normalisation for streams (so Spatial and stereo are equally loud) is a possible follow-up; it is not
  part of this round.
