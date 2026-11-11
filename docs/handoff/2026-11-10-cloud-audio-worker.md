# Cloud audio, the worker: Spatial audio renders and the shared library (2026-11-11)

Branch `audio-worker`, cut from `audio-hq` (and merged with it again at `f681921`). Contract:
[`2026-11-10-plans/cloud-audio-spec.md`](2026-11-10-plans/cloud-audio-spec.md), sections 2 to 5 and the worker part
of 8, and [`2026-11-11-spatial-roadmap.md`](2026-11-11-spatial-roadmap.md), Part 3. Only `cloud/runpod-worker/`,
`.github/workflows/cloud-library-janitor.yml`, one `paths-ignore` line in `.github/workflows/ci.yml`, the Swift
tests' copies of the worker's examples (`Packages/PixlCore/Tests/PixlNetTests/Fixtures/cloud/`) and this note
changed. No app code and nothing in `src/pixl_worker/spatial/` (the renderer is the lead's).
**Nothing was deployed. No call was made to RunPod, to R2 or to any paid service, no key was read, and no money
was spent.** The worker has not run on a GPU in this form: what ran is the CPU test suite (locally and in CI) and
the image's CPU smoke stage (CI). See "Verified and not".

Enhanced audio was cut on 2026-11-11. Everything the worker had for it (the `enhance` task, `library.restore`,
`library.enhanced`, the `enhanced.*` objects, the cutoff detector, `restore.py` and its seam, `restoreMs`,
`models.restorer`, `cutoffHz`, the `restore` block of the render manifest, the `not_needed` state, their examples
and tests) is removed, not left dormant. `"enhance"` in `tasks` is now refused like any unknown task (`BAD_SCHEMA`).

## What the worker does now

A job with `tasks: ["spatial"]` and a `library` block (spec section 4; example
`schema/v1/examples/job.input.spatial.json`, or `job.input.spatial.combined.json` next to an instrumental):

    guard → caps → download → probe → decode → [the job's own outputs, if any] →
    library checks (manifestGet: a valid manifest for this libV/videoId/profile = exists, skipped) →
    stems6 → render each missing profile → for each: FLAC 16-bit (TPDF dither), upload audio, upload its manifest →
    the job's manifest last → delete the input

- Library keys: `lib/v1/<videoId>/sp-<profile>.flac` and `.json` (manifest written last). `LIB_V = 1` lives only
  in `src/pixl_worker/library.py`.
- Render manifest = spec 3.1 exactly (`schema/v1/library.render.schema.json`, example
  `library.render.spatial.json`): `kind` is always `spatial`, `render` is `{engine, stems, stemMode}`, `source` is
  `{itag, codec, sampleRate, decodedSamples, sha256}`. `render.stems` is always the separator's `model_id`
  (`open-cascade-6`), also when `stemMode` is `mix`.
- Job manifest: `outputs["sp-<profile>"]` (key = the `lib/` key, also for `exists`), `library = {videoId, libV,
  renders: {profile: ok|exists|failed}, stemMode}`, timings `stems6Ms` and `renderMs`, `models.stems6`, progress
  `stems6:NN` and `render:NN`. Examples: `job.result.spatial.json`, `.exists.json`, `.partial.json`.
- One render failing leaves the others (`partial`); a spatial-only job where every render fails is an error with
  the first failure's code, and its input stays for a retry. Everything already there: `ok` at once, no GPU.
- Worker 1.1.0; the endpoint's `timeout` and `PIXL_EXECUTION_TIMEOUT_S` are 1800 s (`deploy/endpoint.json`).
  Jobs without `spatial` still end themselves at 870 s.

## The separator seam (roadmap Part 3)

`class Stems6` in `src/pixl_worker/separate.py` is the one place stems come from. Its docstring is the contract a
replacement has to meet, the same as the roadmap's: `model_id` (goes into every manifest as `render.stems`),
`available() -> bool`, `stems(mix, sample_rate, *, quality="standard", vocals=None, progress=None) ->
dict[str, np.ndarray]` returning any of vocals, drums, bass, guitar, piano, other, each `(frames, 2)` float32 at
the same rate and frame count as `mix`. `handler.load_models()` builds it on one marked line
(`stems6 = Stems6(separator, stems4, GuitarPiano(DEMUCS_DIR))`) and hands it to the pipeline as `models.stems6`;
a replacement in its own file (e.g. `separate_custom.py`) is constructed on that line instead and nothing else in
the handler changes (a test does exactly that with a stand-in). The pipeline uses nothing else of it, and now
checks what it returns: an unknown stem name or a stem whose shape is not the song's fails the renders with
`INTERNAL: the six-stem separator returned ...` instead of something obscure inside the renderer. Optional, not
part of the contract: `separator` (the cascade's BS-RoFormer; when present and it ran, the job reports it as
`models.separator`) and `six` (the cascade's htdemucs_6s, whose load state the selftest lists). What a swap still
needs by hand, as the roadmap says: its weights (`weights.lock`, the Dockerfile's `final` and `smoke` stages),
`smoke.py` pointed at it (it builds the cascade), and `LIB_V` raised in the worker and both apps.

The renderer is reached through one call only: `library.render()` calls
`pixl_worker.spatial.render_profiles(mix, stems, sample_rate, profiles, progress=...)`. For songs at a rate other
than 44.1 or 48 kHz it resamples to 48 kHz around that call and back, sets the render 4 dB under the song again
with a plain gain (at most 3 dB; measured at the song's own rate a 22.05 kHz render came back 4.3 dB under),
turns it down as a whole if that or the resampling put its true peak over the ceiling (the renderer's limiter is
no longer run a second time), and measures the file with `spatial.loudness.integrated_lufs` / `true_peak_db`
(measuring only: the one import from the package besides its public names).

## How to bench after the deploy

The worker only reaches the GPU once this branch is on `main` (`cloud-worker-build` pushes the image only from
`main`, and `cloud-worker-deploy` deploys that image).

1. Merge `audio-worker` (via `audio-hq`) to `main`. `cloud-worker-build` builds and pushes the image;
   `cloud-worker-deploy` updates the endpoint, including `timeout` and the env (1800 s).
2. Actions → `cloud-worker-deploy` → Run workflow, tick **bench** (a few cents). Its summary prints:
   - selftest: `htdemucs_6s=lazy`, `library: v1, 6 profiles`, the host's CPU count and memory limit;
   - `bench (240 s synthetic song): ... stems6 N s, render N s`: `stems6` is htdemucs_ft plus htdemucs_6s with
     their first loads (the vocals are handed over from the `separate` stage, as in a combined job); `render` is
     one profile (`studio`) on the CPU;
   - `bench: process memory peak stems6 ... MB, render ... MB (overall ...; the container may use ... MB)`. The
     render's share grows with the song: for 15 minutes multiply what it adds by 3.75;
   - `bench: render: studio, <stemMode>, ... LUFS (... in), true peak ... dB`. A synthetic song is not music:
     `mix` there only means the renderer did not trust the stems of a test tone;
   - `bench: stems6: ... gave N stems, not six` only when htdemucs_6s is missing from the image.
   To run just the spatial path: `{"v": 1, "op": "bench", "bench": {"seconds": 240, "stages": ["separate",
   "stems6", "render"]}}` (drop `separate` to time the cascade with its own vocal pass).
3. Then one real song from a phone: its job manifest's `timings.stems6Ms` and `renderMs`, and its render manifest in
   the library against `library.render.schema.json`.
4. Put the measured seconds, cents and memory into the worker README's cost section and the spec's open items.

## What the owner has to do

1. Merge (the worker only runs on a GPU from `main`), then deploy and bench as above.
2. Check that the bucket has the catch-all 30-day lifecycle rule (README, owner checklist, step 2): without it
   `lib/` only shrinks through the janitor.
3. `cloud-library-janitor` only starts running once its workflow file is on `main` (scheduled workflows run from
   the default branch).
4. Both apps ship numbers derived from the SADIE II Database (Apache-2.0) in `spatial_preview_v1.json`; each app's
   third-party notices need an entry (text: `cloud/runpod-worker/LICENSES/SADIE-II.txt`). Not done here.
5. Send library jobs with `policy.executionTimeout` 1,800,000 (`run.request.spatial.json`): RunPod never shows the
   worker a request's policy, so a spatial job sent with the old 900,000 that runs past 15 minutes is cut with no
   manifest.

## What the apps need to know

- `manifestGet` is the switch for "skip what is there". The worker sees a render's manifest, not its audio. The
  bucket's 30-day rule removes the two objects separately (the audio a few seconds older), so at the very end of
  a render's life its manifest can outlive its audio. A phone that gets `exists` and then a 404 on the FLAC should
  send the job again without `manifestGet` for that profile. The janitor deletes such a lone manifest first when
  it has to make room.
- `library.stemMode` is `null` when the job rendered nothing (everything was already there).
- A render manifest's `source.itag` and `source.codec` are `null` when the job sent no `library.source`.
- A 1.1.0 worker's selftest has `library.libV`; a 1.0.0 worker has no `library` field and refuses `spatial` with
  `BAD_SCHEMA`.

## Where this goes beside the spec

Choices where the spec is silent or the code needed one; none changes a shape in the spec.

1. **The volume fallback has no library**: `spatial` with `storage: volume` is `BAD_SCHEMA`.
2. **`library.source.itag` is limited to 0 … 2³¹−1** (it lands in a manifest every phone decodes).
3. **"Already there" also needs a usable `audio` block** (its own key, a size, a sha256): a manifest a phone would
   reject must not stop the render from ever being made.
4. **The library checks run after the job's own outputs** (the spec's order line), not before the download: a job
   whose renders all exist still downloads and decodes its input (seconds), then ends `ok` without the GPU.
5. **One renderer call for all missing profiles of a job**, so the preparation runs once. If that call fails or
   runs out of time, every profile in it fails together; encode/upload/manifest failures stay per profile.
6. **`separation.quality: best` raises demucs' overlap from 0.25 to 0.5 in the cascade**; the 4-stem task keeps
   0.25.
7. **Songs at other sample rates** are resampled around `render_profiles` (spec section 5 allows it) and levelled
   by plain gains (above); they used to go through the renderer's limiter a second time, a call into its insides.
   Measured on the test material: exact for normal levels; a clipped -2 LUFS brick lands 1.0 LU under its target
   at 22.05 and 32 kHz, where the renderer itself leaves the same brick 0.65 LU under at 44.1 and 48 kHz.
8. **The pipeline checks the separator's stems** (names, shapes) before the renderer sees them.
9. **Selftest and bench report more than asked**: `library`, `host`, per-stage VRAM, the process's peak memory.
10. **The janitor** deletes in this order when `lib/` is over 8 GB: what no phone can use (audio whose manifest never
    arrived, older than an hour; a manifest whose audio is gone), renders of an older library version, then complete
    renders oldest first, each manifest before its audio. GB is decimal (10⁹ bytes).
11. **Lyrics that fail next to `spatial` no longer end the job** before the renders ran.
12. **The worker README no longer names the lyrics source** (owner rule on names).

## The renderer (reviewed version, `f681921`): what the tests say

- The tests in `tests/test_spatial.py` are this branch's checks of the lead's renderer, run on every push.
- The limiter now holds its ceiling on a clipped -6 LUFS brick at 48 kHz: the test that was an expected failure
  before the review passes and is a normal test again.
- A guitar hard left in Studio now comes out 2.0 dB louder in the left ear (it was over 3 dB before the review); the
  test asks for more than 1 dB to that side. Reported in case the narrowing was not meant.
- The spec's "integratedLufs = sourceLufs - 4.0, within 0.3" holds for normal material; a clipped -2 LUFS brick
  (4.8 to 5.3 dB of limiting) comes out 0.64 to 0.68 LU under at 44.1 and 48 kHz. No real master is that loud;
  the manifest's numbers are measured on the file either way.
- Memory (measured before the review, with `tracemalloc`, synthetic six-stem songs, before any change for memory):
  the peak was 32.5 song-sized stereo float32 arrays inside `prepare()`, i.e. about 11 GB for a 15-minute song at
  48 kHz; the pipeline itself holds 7 of them (the mix and six stems) during the call and frees everything else
  before it. The bench's memory line answers this for the real workers and the reviewed renderer.

## Verified and not

Verified:
- The CPU suite, locally (Python 3.14, NumPy 2.5.4, ffmpeg 8.1) and in CI (Python 3.12 in the test image), and
  the image's CPU smoke stage with the real weights, including the six-stem cascade and one render: see "CI".
- `ci/check_weights.py`, `ci/check_fixtures.py` (it also compares the apps' copies of `schema/v1/spatial/*.json`;
  the apps have none yet) and `ci/check-cloud-fixtures.sh` (the Swift copies are byte-identical).
- The htdemucs_6s file's size and sha256 (checked once by downloading it: 54,996,327 bytes).

Not verified:
- Anything on a GPU; the six-stem cascade with real weights has only run in the image's CPU smoke stage.
- Any call to RunPod or R2: storage, the whole job and the janitor ran against fakes only.
- The bucket's lifecycle rule, and that `cloud-library-janitor` runs (it needs `main`).
- The cost, duration and memory of a spatial job on the real workers (the first bench says).

## CI

Workflow `cloud-worker-build` on `audio-worker`, after the removal of Enhanced audio:
- run 43066554839 (`dff97b0`, `[image]`): green.
  - test job: weights check, fixture check, 539 passed and 8 skipped in the Docker test image (locally on Windows:
    545 passed, 2 skipped; the 6 extra local ones need files outside the worker folder).
  - image job: the image built without pushing, then the CPU smoke stage with the real weights: separator,
    separator at 48 kHz, aligner, htdemucs_ft, the six-stem cascade (six stems, progress 0 to the end, what they
    miss of the mix -7.8 dB), and one render (`studio`, `stemMode` stems6, -19.04 LUFS from a -15.04 LUFS clip,
    true peak -6.4 dBTP, a 190,490-byte FLAC). All six checks ok.
- run 43065833679 (`cd92f24`, `[image]`): failed at the fixture check, because the Swift copies came in the next
  commit (`6f1fa0e`, `[skip ci]`); nothing was built. Superseded by the run above.
- The `[image]` run before the removal (43047397464) had failed on the runner's DNS (apt could not resolve
  archive.ubuntu.com), not on the worker.
