# Spatial audio: the whole roadmap (2026-11-11)

Everything about how PixlAudio turns a song into its spatial version: what each step does, what is built, what
is left, and where a different stem splitter plugs in. Written for Hoa and for any agent picking this up.

- The **contract** between the worker and the two apps is `docs/handoff/2026-11-10-plans/cloud-audio-spec.md`
  (a copy is in the Android repo under `handoff/2026-11-10-plans/`). This file explains; that file rules.
- **Enhanced audio was cut on 2026-11-11.** There is no restoration model and no "enhance" job. Spatial only.

---

## Part 1. In plain words

### What the listener gets

Pick one of six profiles (Studio, Wide, Intimate, Concert Hall, Surround, Night) with headphones on. The phone
switches on a light version at once. Meanwhile the cloud makes the real one: it splits the song into instruments,
puts each one in its own place in a virtual room around a dummy head, and sends back one stereo file made for
headphones. The player fades to that file mid-song, and uses it from then on. A finished file is kept in shared
storage for 30 days, so the same song is not processed twice.

### The nine steps from a song to the spatial file

1. **Get the audio.** The phone uploads the song it is already playing (decoded to FLAC), exactly as Sing does.
2. **Split it into stems.** A separator model on the GPU splits the song into voice, drums, bass, guitar, piano
   and everything else. *This is the replaceable part.* See Part 3.
3. **Find what is inside each stem.** Each stem is stereo. The renderer works out, moment by moment and pitch by
   pitch, which sounds in it are panned where (hard left, a bit left, centre, ...) and what is just ambience
   (reverb, wide pads). Every sound gets exactly ONE direction.
4. **Place every sound around a dummy head.** Each sound is played through a measurement of a real dummy head
   (a Neumann KU100) from its direction, so the two ears get the level and time differences a real source there
   would give. Voice, kick and bass stay in the middle; guitars, keys and the rest go out to the sides, how far
   depends on the profile.
5. **Add the room.** Each sound gets a handful of early reflections from the side walls (this is what moves
   sound out of your head) and all of them feed a soft reverb tail. Studio is nearly dry; Concert Hall is big.
6. **Spread (Wide, Surround, a little in Hall).** A centred guitar or synth stays in the middle no matter how
   wide the stage is. So in these profiles part of it is sent to the sides through a tiny scrambling filter that
   makes the copy sound like the same instrument coming from somewhere else, instead of cancelling.
7. **Keep the bass untouched.** Everything under 110 Hz is the ORIGINAL song, passed straight through, so the
   low end keeps its weight and punch.
8. **Match it to the original.** Tone is matched to the original in 23 bands (it rarely needs more than 2 dB),
   then loudness: every spatial version sits 4 dB under the original (a loud modern master cannot be spread
   around a head and stay as loud without crushing its peaks; Apple's spatial tracks are quieter for the same
   reason). A limiter only acts if a peak would go over.
9. **Save it.** One 16-bit FLAC per profile, same length and timing as the song, plus a small info file, into
   the shared library.

### What exists today

| Piece | State |
|---|---|
| The renderer (steps 3 to 8) | **Built and measured**, in the iOS repo on branch `audio-hq`. An independent reviewer checked the maths. |
| Listening test page | **Built**: `builds\spatial-listening` on this PC (80-second clips, four songs). Needs your ears. |
| The spec | **Written** (Spatial only since 11-11). |
| The worker (steps 1, 2, 9 and running the renderer in the cloud) | **Being built** on branch `audio-worker`. Not deployed. |
| Both apps: groundwork (settings, shared types, where things plug in) | **Being built** on branch `audio-foundation` in each repo. |
| Both apps: the feature itself (profile picker, on-phone version, switching, background queue) | **Not started.** |
| On the GPU today | Only the OLD worker (Sing). It can already give four stems, which is what the test clips used. |

### What is left, in order

1. Finish and merge the worker change (**needs Hoa's "merge"**: the GPU only deploys from `main`), then run the
   bench to learn real speed and memory.
2. Build the feature into both apps (three parallel pieces per app: engine, cloud, screens), then join them and
   get CI green.
3. Test builds on Hoa's phones. Tune the profiles by ear from Hoa's notes.
4. Later, if wanted: head tracking, volume normalisation so Spatial and stereo are equally loud.

### Honest limits

- Nobody has listened to it critically yet. It was tuned by measurement (tone, loudness, timing, how alike the two
  ears are). Ears decide.
- Spatial plays about 4 dB quieter than stereo (see step 8).
- It is for headphones. On speakers the app plays the normal song.
- Separation is never perfect. The renderer is built to hide bleed (what stems miss is put back, nothing is ever
  shared between two positions), but a bad separation still shows.

---

## Part 2. The pipeline in detail

All code: `cloud/runpod-worker/src/pixl_worker/spatial/` (NumPy only, deterministic, no torch). Entry point:

```python
from pixl_worker.spatial import render_profiles
results = render_profiles(mix, stems, sample_rate, ["studio", "wide"])   # -> {profile: SpatialResult}
```

- `mix`: `(frames, 2)` float32, the song. `sample_rate`: 44100 or 48000.
- `stems`: dict with any of `vocals, drums, bass, guitar, piano, other`, each `(frames, 2)` float32, same length
  and rate as `mix`. `{}` gives the stem-free render (the whole mix treated as one stem).
- `SpatialResult`: `audio (frames, 2) float32`, `integrated_lufs`, `source_lufs`, `true_peak_db`, `limiter_max_db`,
  `stem_mode` (`stems6`, `stems4` or `mix`), `tone_db` (the tone correction that was applied, for diagnostics).

### 2.1 Before anything else (`render.prepare`)

- What the stems do not add up to (`mix - sum(stems)`) is added to `other`, so the six always sum to the song.
- If the stems miss the song by more than -6 dB, they are not trusted: the render falls back to `mix` mode.
- Stems more than 70 dB under the song are dropped. NaN/Inf samples are zeroed.

### 2.2 Taking a stem apart (`upmix.decompose`)

STFT 4096 / hop 1024, sqrt-Hann both ways. Per time-frequency bin, from the channel powers `P_L`, `P_R` and the
real part of their cross-spectrum `C`, each averaged over 9 frames and a third of an octave:

1. `C' = max(C - 0.2*sqrt(P_L*P_R), 0) / 0.8` (two unrelated signals never measure as exactly unrelated).
2. Ambience power `N` = the smaller eigenvalue of the 2x2 covariance: `N = ((P_L+P_R) - sqrt((P_L-P_R)^2 + 4C'^2)) / 2`.
3. The source's amplitudes in the two channels: `a = sqrt(P_L-N)`, `b = sqrt(P_R-N)`; its direction vector
   `u = (a, b)/|(a, b)|`.
4. The source signal: `m = g * (u_L*L + u_R*R)`, with the gate `g = S/(S + N/4)`, `S = a^2+b^2` (closes where
   there is no source). `m` carries the power the sound had in BOTH channels together.
5. Ambience: `A_L = L - u_L*m`, `A_R = R - u_R*m`.
6. A trim puts the bin's power back where the gate is half open.
7. Pan: `(a-b)/(a+b)`, with everything within 0.18 of the middle snapped to centre, then rounded to one of
   **7 directions** (hard left ... centre ... hard right). The whole bin's `m` goes to that one direction.
   Directions holding under -35 dB of the stem are merged towards the centre.

Output per stem: up to seven mono source signals (one per direction) and two ambience signals.

Why one direction per bin: a sound shared between two positions reaches an ear twice, a fraction of a millisecond
apart, and cancels around 4-5 kHz (measured before the fix: a 4 dB hole in the voice; for part-panned sounds up
to 9 dB and the image flipping sides in that band).

### 2.3 The head model (`hrir.py`, `tools/build_hrir.py`)

- Data: SADIE II database, subject D1 = Neumann KU100, University of York, Apache-2.0
  (https://zenodo.org/records/12092466). `tools/build_hrir.py` turns the 48 kHz SOFA file into the committed
  `spatial/data/hrir_ku100.npz`: 625 directions (azimuth every 5 degrees on rings every 15 degrees of elevation),
  256 taps, made exactly left/right symmetric, common leading silence removed, diffuse-field equalised. 44.1 kHz
  is made from it at load time.
- Azimuth 0 = front, positive = LEFT. Nearest measured direction is used (no interpolation).

### 2.4 Placing a source (`room.KernelBuilder`)

For a source at (azimuth, elevation, distance) the builder makes one impulse response per ear:

- **Direct sound**: the head model for that direction, with its tone made neutral: both ears are equalised
  together until their summed power is flat (full strength in front, half strength behind, so "behind" still
  sounds a little duller). Everything BETWEEN the ears (level and time difference) stays as measured. Then it is
  levelled so every direction is as loud as the front.
- **Level rule**: every source is multiplied by `1/sqrt(2)` (`SIDE_LEVEL`), because its signal carries the power of
  both channels and that power is shared between two ears. A centred voice then reaches each ear exactly as on
  plain headphones, and a hard-panned guitar keeps the power its one channel had.
- **Early reflections**: image sources of a shoebox room up to 3 bounces. Each wall has its own reflection
  coefficient `(back, front, right, left, floor, ceiling)`: soft floor, ceiling and front wall (their reflections
  arrive in the same plane as a centred source and only colour it), lively side walls. The listener sits off the
  room's centre line so left and right reflections do not arrive as a mirrored pair. Each reflection goes through
  the head model for ITS direction, is delayed (fractional, in the frequency domain), damped at high frequencies
  per bounce, high-passed at 250 Hz (reflections carry no lows) and turned down if it follows within 6 ms.
  The whole set is scaled so a centred source gets exactly the profile's `er_db`.
- **Spread** (when the profile asks): above 400 Hz, that share of the centred source's power is taken out of the
  middle and sent to +/- `spread_az` through two short decorrelating filters (`decorrelate.py`: 24 ms of sparse
  decaying impulses, picked from fixed candidates for the flattest tone). Lows and the rest stay in the middle.

Positions: the centre direction is at 0 degrees; direction step k of 3 is at `k/3 * width`; ambience at
`+/- ambience` (default: the width). Per stem these come from the profile (`profiles.py`).

### 2.5 The late reverb (`room.late_tail`)

A stereo send of all stems (per-stem send levels) feeds a synthetic tail: noise that decays at the room's RT60
(set at 125 Hz, 1 kHz, 8 kHz), fades in from the mixing time, and is as alike between the two ears as a real
diffuse field is around THIS head (computed from the head model itself). Left and right sends have their own
tails. Scaled so a centred source gets exactly the profile's `rev_db`.

### 2.6 Putting it together (`render.render_one`)

1. All sources are convolved with their kernels in one pass (overlap-add FFT, `dsp.convolve_bank`), the tail in a
   second pass, and the head model's own delay is removed so the output is on the song's timeline.
2. Crossover at 110 Hz, zero-phase and exactly complementary: output = highs of the render + lows of the ORIGINAL.
3. Tone match: third-octave bands 80 Hz to 16 kHz, correction limited to +/- 5 dB (measured need: 1 to 3 dB).
4. Night only: a -4 dB shelf above 7 kHz and a slow leveller (at most 3.5 dB).
5. Loudness: integrated loudness (BS.1770) set to the source's minus 4.0 LU (`HEADROOM_DB`).
6. True-peak limiter at -1 dBTP: exactly idle under the ceiling; around an over, the gain dips over 20 ms either
   side. Measured on test songs: active at most 2.5 % of the time, at most about 2 dB.
7. A 10 ms fade at the very end; output clipped to +/- 1.

### 2.7 The six profiles (`profiles.py`)

Widths in degrees for the stems (voice / drums / bass / guitar / piano / other), then the room.

| Profile | Stage widths | Spread | Room (RT60 mid) | Early / late level |
|---|---|---|---|---|
| Studio | 22 / 32 / 12 / 48 / 42 / 58 | none | 6.8 x 6.0 x 3.0 m (0.28 s) | -11 / -17 dB |
| Wide | 28 / 44 / 14 / 72 / 62 / 88 | guitar 35 %, piano 30 %, other 40 % | 7.8 x 7.2 x 3.2 m (0.36 s) | -10.5 / -16 dB |
| Intimate | 16 / 26 / 10 / 38 / 34 / 44, voice at 0.9 m and +1.5 dB | none | 4.8 x 4.2 x 2.6 m (0.20 s) | -16 / -24 dB |
| Concert Hall | 20 / 18 / 8 / 26 / 24 / 34, everything 9-11 m away | 15-20 % | 38 x 26 x 15 m (1.7 s) | -9.5 / -9.5 dB |
| Surround | 26 / 40 / 14 / 100 / 70 / 128 | guitar 50 %, piano 45 %, other 55 %, to the sides and behind | 7.4 x 6.8 x 3.1 m (0.42 s) | -9.5 / -14.5 dB |
| Night | Studio's widths x 0.9 | none | Studio's, late -21 dB | plus the shelf and the leveller |

These numbers are first settings from measurement. They are the thing to tune from listening.

### 2.8 The on-phone version (`preview.py`, spec section 7)

A phone cannot separate stems in real time, so until the cloud file arrives it runs a fixed filter on the plain
stereo song: a real centre (the mid signal through the frontal head response), the side signal on a virtual
speaker pair (plus a second pair further round for Wide, Hall and Surround), a short sparse "room" of about 40
taps per ear, a 120 Hz crossover that leaves the lows alone, and a gain that already holds the same 4 dB of
headroom. `python -m pixl_worker.spatial.preview --out schema/v1/spatial` writes the coefficient file
(`spatial_preview_v1.json`, shipped in both apps) and a golden test file both apps must reproduce to 1e-4.

### 2.9 Around the renderer (the worker job; spec sections 3 and 4)

- Job: `tasks: ["spatial"]` plus a `library` block naming the YouTube video id and, per profile, signed upload
  URLs for `lib/v1/<videoId>/sp-<profile>.flac` and `.json`.
- Order: download, decode, check which renders already exist (skip those), separate, render each missing profile,
  encode FLAC 16-bit with dither, upload audio then its manifest, then the job's own manifest.
- Storage: the existing R2 bucket and keys. Objects expire after 30 days (the bucket's own rule); a daily GitHub
  Action keeps `lib/` under 8 GB so storage stays in the free tier.

---

## Part 3. Where your own separator plugs in

The renderer does not care where stems come from. The ONE place that makes them is the class `Stems6` in
`cloud/runpod-worker/src/pixl_worker/separate.py` (on branch `audio-worker`). Its contract:

```python
class Stems6:
    model_id = "open-cascade-6"          # goes into every render's manifest as render.stems
    def available(self) -> bool: ...     # are the weights there?
    def stems(self, mix, sample_rate, *, quality="standard", vocals=None, progress=None) -> dict[str, np.ndarray]:
        """mix: (frames, 2) float32 at sample_rate. Returns any of vocals, drums, bass, guitar, piano, other,
        each (frames, 2) float32 at the SAME sample rate and the SAME number of frames as mix."""
```

What ships in this repository is a cascade of open models: voice from the BS-RoFormer already in the image, then
`htdemucs_ft` on the rest for drums, bass and other, then `htdemucs_6s` on that "other" to lift guitar and piano
out. To use a different separator, by hand:

1. **Write a class with the same `stems(...)` contract.** Rules the renderer relies on:
   - same sample rate and exactly the same frame count as the input (resample in and out if the model runs at
     another rate; `pixl_worker.audio.resample` and `fit_length` do this for the existing models);
   - time-aligned with the input to the sample (no model delay left in);
   - stems should add up to the song as closely as they can. The renderer adds the difference to `other`, and
     falls back to the stem-free render if the difference is bigger than -6 dB of the song;
   - names from `vocals, drums, bass, guitar, piano, other` only. Fewer is fine (four stems works).
   - call `progress(done, total)` now and then (it also enforces the job's deadline) and turn a GPU out-of-memory
     error into `WorkerError(GPU_OOM, ..., refresh_worker=True)` like the existing classes do.
2. **Register it** where the worker builds its models: `handler.load_models()` creates the `Stems6` object and
   passes it to the pipeline as `models.stems6`. Construct yours there instead. Load weights lazily (on first use),
   as `Stems4` does, so cold starts stay short.
3. **Ship the weights the way the image expects**: one row per file in `weights.lock` (sha256, size, licence,
   destination under `/models/`, pinned URL) and one `ADD --link --chmod=644 --checksum=sha256:... <url> <dest>`
   line in the Dockerfile's `final` stage and again in `smoke`. `python ci/check_weights.py` must pass. The final
   stage has no `RUN` on purpose.
4. **Give it its own id** (`model_id`) and **bump `LIB_V`** (the `lib/v1/` in every key; spec section 2), in the
   worker and in both apps, so renders made with the old separator are not reused.
5. **Test it**: the CI smoke stage should run it once on CPU on a short clip; then, on the GPU, the bench.
   To hear it without any phone: `stems_job.py` and `render_lab.py` in Part 5 take stems from disk, so any stems
   you produce yourself (six FLAC files per song) can be rendered and compared on this PC today.

The quickest experiment needs none of the worker: put `vocals.flac, drums.flac, bass.flac, guitar.flac,
piano.flac, other.flac` (and `mix.flac`) for a song in a folder and run `render_lab.py` on it.

Note from the lead: the six-stem model with the best published scores (BS-RoFormer SW) is not in this repository
because its only source is a conversion of Apple Logic Pro's stem splitter and the worker image is public. Which
separator goes in this slot is the owner's decision; the slot is the same either way.

---

## Part 4. Where everything is

| What | Where |
|---|---|
| iOS repo (also the worker) | `RedSn0w1877/PixlAudio-iOS`; working copy `C:\Users\Hoa\Downloads\Code Projects\PixlAudio-iOS-audio`, branch `audio-hq` |
| Android repo | `RedSn0w1877/PixlAudio`; working copy `...\Code Projects\PixlAudio-android-audio`, branch `audio-hq` |
| Renderer | `cloud/runpod-worker/src/pixl_worker/spatial/` : `render.py`, `upmix.py`, `room.py`, `decorrelate.py`, `hrir.py`, `profiles.py`, `loudness.py`, `dsp.py`, `preview.py`, `data/hrir_ku100.npz` |
| Head-model builder | `cloud/runpod-worker/tools/build_hrir.py` |
| On-phone tables | `cloud/runpod-worker/schema/v1/spatial/spatial_preview_v1.json` (+ golden file); copies in both apps |
| Spec | `docs/handoff/2026-11-10-plans/cloud-audio-spec.md` |
| Worker integration (in progress) | branch `audio-worker`, worktree `...\PixlAudio-iOS-audio-worker` |
| App groundwork (in progress) | branch `audio-foundation` in each repo; maps: `docs/handoff/2026-11-10-plans/ios-integration-map.md`, `handoff/2026-11-10-plans/android-integration-map.md` |
| Listening test | `C:\Users\hoa\Downloads\PixelPlayer-master\PixelPlayer-master\builds\spatial-listening\` (`Open listening test.bat`) |
| Open pull request | iOS #28 (checklist + iOS 26 support; `audio-hq` is built on it). Needs "merge". |

---

## Part 5. Doing it by hand on this PC

A lab folder holds everything used so far (it is a scratch folder, not in any repo):
`C:\Users\HoaVo\AppData\Local\Temp\claude\b55c2285da7114cf\67cb4895-ce03-4422-a84f-0ba14549d08c\scratchpad\lab`

- `venv\` : Python with numpy, scipy, soundfile (use `venv\Scripts\python.exe`).
- `stems\<song>\` : `mix.flac` and the stems of the four test songs (48 kHz).
- `stems_job.py <worker dir> <out dir> <song files...>` : sends songs through the LIVE worker exactly as a phone
  does (it reads the built-in keys through the local unlock key and never prints them) and brings back four stems.
- `render_lab.py <worker src> <stems root> <out root> <song> [profiles...] [--seconds=N] [--offset=N] [--mix]` :
  renders a song from the stems on disk and prints loudness, peak, limiter, tone.
- `listening_render.py` : rebuilds the listening page's clips after a renderer change.
- `review\` : the independent reviewer's test scripts and their outputs (`*_out.txt`).

To hear a change: edit a profile in `profiles.py`, run `listening_render.py`, reload the listening page.

---

## Part 6. What was measured (so it is not re-done)

- STFT round trip -138 dB; the convolution matches a direct one to -135 dB; fractional delays -67 dB or better.
- Loudness equals pyloudnorm within 0.002 LU; true peak within 0.05 dB of 16x oversampling; every test render at or
  under -1.00 dBTP and at source minus 4.0 LU.
- After the tone match: within 2 dB of the original per third octave; each stem's two-ear power within about 1 dB
  of the stem itself.
- Timing: the render arrives 0.1 to 0.3 ms after the original; kick lag at most 0.33 ms.
- A centred source with ambience 6 to 10 dB under it: at most 2 % of it is left in the ambience.
- A part-panned source goes to one direction with no leftover; hard-panned to the edge; unrelated left/right
  material stays ambience (about 97 % of it).
- Memory: a 6-minute song with six stems peaked at 4.7 GB (before the direction split; to be re-measured).

## Part 7. Decisions, with the reason

- **4 dB under the source**: at equal loudness a render of a loud master peaks 2 to 4 dB higher than the master.
  Limiting that away took the punch out (the limiter was working 5.5 dB on Blinding Lights).
- **No blend of the untouched song above 110 Hz**: it cancelled against the head model's phase (2 to 5 dB hole).
- **Tone-neutral direct sound**: someone else's ear colourations just sound dull or phasey; the differences
  between the ears are what place a sound, and those are kept.
- **Side walls lively, floor and ceiling soft, listener off-centre**: side reflections carry about 75 % of the
  early energy (was 33 %), and a centred sound is coloured about half as much.
- **Open separators in the repository; the slot is replaceable** (Part 3).
- **No extra server**: the phones sign storage URLs with the keys they already have; a daily job keeps storage
  under the free tier.
- **Enhanced audio cut** (owner, 2026-11-11).
