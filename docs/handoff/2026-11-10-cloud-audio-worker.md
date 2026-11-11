# Cloud audio, the worker: Spatial audio renders, the Enhanced audio check, the shared library (2026-11-11)

Branch `audio-worker`, cut from `audio-hq`. Contract: [`2026-11-10-plans/cloud-audio-spec.md`](2026-11-10-plans/cloud-audio-spec.md),
sections 2 to 5 and the worker part of 8. Only `cloud/runpod-worker/`, `.github/workflows/cloud-library-janitor.yml`,
one `paths-ignore` line in `.github/workflows/ci.yml` and this note changed. No app code, no Swift, and nothing in
`src/pixl_worker/spatial/` (the renderer is the lead's). **Nothing was deployed. No call was made to RunPod, to R2
or to any paid service, no key was read, and no money was spent.** The worker has not run on a GPU in this form:
what ran is the CPU test suite (locally and in CI) and the image's CPU smoke stage (CI). See "Verified and not".

## What changed

1. **Schema** (`src/pixl_worker/schema.py`, `schema/v1/`). Tasks `spatial` and `enhance` and the top-level
   `library` object, every rule checked by hand and in `job.input.schema.json`. `library.v` must be `LIB_V`
   (`UNSUPPORTED_VERSION`), every presigned URL must end in the canonical key of its own object
   (`lib/v1/<videoId>/sp-<profile>.flac|.json`, `enhanced.flac|.json`; `BAD_URL` otherwise).
   `job.result.schema.json` gains `library`, the `sp-<profile>` and `enhanced` output slots, three timings and two
   models, all optional. New `library.render.schema.json` for the manifests in the library. New examples (the old
   ones are byte-identical): `job.input.spatial.json`, `job.input.spatial.combined.json`,
   `run.request.spatial.json`, `job.result.spatial.json`, `.exists.json`, `.partial.json`,
   `library.render.spatial.json`, `library.render.enhanced.none.json`, `library.render.enhanced.json`.
2. **`library.py`** (new). The one home of `LIB_V = 1`, the keys, the render manifest, the "already there" test,
   FLAC 16-bit with TPDF dither made in NumPy (`audio.flac_from_s16` packs the finished samples bit for bit;
   `audio.encode` is untouched), and rendering at sample rates the renderer does not work at.
3. **`separate.py`**. `Stems6`, the open cascade of spec section 5, and `GuitarPiano` (htdemucs_6s, lazy). The
   demucs call is now one helper shared with `Stems4`. `htdemucs_6s` is in `weights.lock`, the Dockerfile (final
   and smoke stages) and `models/demucs/htdemucs_6s.yaml`; its sha256 was checked by downloading the file once
   (54,996,327 bytes, `34c22ccb…02ddd`, as expected).
4. **`restore.py`** (new). `detect_cutoff_hz` and the `Restorer` seam, with no model behind it.
5. **`pipeline.py`, `storage.py`, `handler.py`**. The order and semantics of spec section 4; details below.
6. **Version and limits.** `WORKER_VERSION` 1.1.0. `deploy/endpoint.json`: `timeout` 1,800,000 and
   `PIXL_EXECUTION_TIMEOUT_S` 1800.
7. **`selftest.py`, `smoke.py`, `deploy/runpod_deploy.py`.** The selftest reports `htdemucs_6s`, the library
   version and profiles, and the host's CPU count and memory limit. `op: bench` has the stages `stems6` and
   `render`. The image's smoke stage runs the cascade and one render on CPU. The deploy prints all of it.
8. **The janitor.** `deploy/library_janitor.py` and `.github/workflows/cloud-library-janitor.yml`.
9. **`ci/check_fixtures.py`** also compares the apps' copies of `schema/v1/spatial/*.json`.
10. **Docs and licences.** The worker's `README.md`, `NOTICE`, `LICENSES/SADIE-II.txt`.

Tests: `tests/test_spatial.py`, `test_library.py`, `test_restore.py`, `test_separate.py`,
`test_pipeline_library.py`, `test_smoke_bench.py`, `test_library_janitor.py` are new; `test_schema.py`,
`test_pipeline.py`, `test_storage.py`, `test_handler.py`, `test_deploy.py`, `test_deadline.py`, `test_ci_tools.py`
grew. The suite went from 314 to 570 passing (plus one expected failure, see "The renderer").

## What the apps need to know

- **Send library jobs with `policy.executionTimeout` 1,800,000** (`schema/v1/examples/run.request.spatial.json`).
  RunPod never shows the worker a request's policy, so the worker plans for the endpoint's 30 minutes. A library
  job sent with the old 900,000 that runs longer than 15 minutes is cut by RunPod with no manifest written.
  Jobs without library tasks are unaffected: the worker still ends those at 870 s on its own.
- The job example to build against is `job.input.spatial.json` (one profile plus `enhance`). The result examples
  show the three outcomes. `outputs["sp-studio"].key` is the `lib/` key, also when the state is `exists`.
- **`manifestGet` is the switch for "skip what is there".** The worker can only see a render's manifest, not its
  audio (the job carries no GET for the audio). The bucket's 30-day rule removes the two objects separately, and
  the audio is the older one by a few seconds, so for up to a day at the end of a render's life its manifest can
  outlive its audio. A phone that gets `exists` (or a manifest from its own GET) and then a 404 on the FLAC should
  send the job again **without `manifestGet`** for that output: the worker then renders it whatever is there.
  (The janitor never causes this: it deletes the manifest first.)
- `library.enhanced` is `not_needed` whenever there is no restored file, whether the worker wrote the note now or
  found one already there. `exists` for enhanced means a restored file is in the library.
- `library.restore` and `library.stemMode` are `null` when the job did no analysis (everything it asked for was
  already there).
- A render manifest's `source.itag` and `source.codec` are `null` when the job sent no `library.source`.
- The selftest of a 1.1.0 worker has `library.libV`. A 1.0.0 worker has no `library` field and refuses the new
  tasks with `BAD_SCHEMA`.
- Both apps ship numbers derived from the SADIE II Database (Apache-2.0) in `spatial_preview_v1.json`. Each app's
  third-party notices need an entry; the text is in `cloud/runpod-worker/LICENSES/SADIE-II.txt`. Not done here
  (those files are the app agents').

## Where this goes beyond or beside the spec

Each of these is a choice made where the spec was silent or the code needed one. None changes a shape in the spec.

1. **The volume fallback has no library.** A job with `spatial` or `enhance` and `storage: volume` is refused
   (`BAD_SCHEMA`). The shared library only makes sense in R2.
2. **`library.source.itag` is limited to 0 … 2³¹−1.** It is only recorded, but it lands in a manifest every phone
   decodes.
3. **"Already there" also needs a usable `audio` block for a spatial manifest** (its own key, a size, a sha256).
   A manifest a phone would reject must not stop the render from ever being made.
4. **The library checks run after the job's own outputs, as the spec's order line says**, not before the
   download. A job whose outputs all exist still downloads and decodes its input (a few seconds), then ends `ok`
   without touching the GPU, and its manifest has the usual `input` block.
5. **Reasons, in this order:** `full_band` (cutoff above 17 kHz) wins over `off`, which wins over `unavailable`.
   A full-band song is reported as `full_band` even when the job said `library.restore: off`, because that note
   is shared and is a fact about the song.
6. **A failed restoration** (only possible once a model exists; tested with a fake one): no `enhanced.json` is
   written and the enhanced output is `failed`, so a later job tries again. The renders are still made from the
   song as it is, and their manifests say `restore.reason: failed`.
7. **`render.stems` is `null` when `stemMode` is `mix`**: the render used no stems.
8. **Jobs without library tasks keep their 15 minutes** (see "What the apps need to know").
9. **The cutoff detector checks for a cliff**, not only the level. Details under "Measurements".
10. **`separation.quality: best` raises demucs' overlap from 0.25 to 0.5 in the cascade.** The 4-stem task keeps
    0.25. `Stems4.available()` now asks for its own bag (yaml plus all four files) instead of "any .th file".
11. **One renderer call for all missing profiles of a job**, so the preparation runs once. The price: if that call
    fails or runs out of time, every profile in it fails together, also ones that were already finished inside
    it. Per-profile failures after the render (encode, upload, manifest) are separate, as the spec asks.
12. **Songs at other sample rates**: after resampling back from 48 kHz the render is set 4 dB under the song's
    loudness again, passed through the renderer's limiter once more, and measured again, so the manifest's numbers
    describe the file.
13. **Selftest and bench report more than asked**: `library`, `host`, per-stage VRAM, the process's peak memory.
14. **The janitor** deletes in this order when over 8 GB: audio whose manifest never arrived (older than an hour),
    renders of an older library version, then complete renders oldest first; a lone `enhanced.json` note goes
    last. GB is decimal (10⁹ bytes), the smaller reading of the free tier.
15. **Lyrics that fail next to library tasks no longer end the job** before those tasks ran. With no library
    tasks the old behaviour is unchanged.
16. **`ci.yml` ignores the janitor workflow file**, like the other worker workflows, and the commit that added it
    carries `[skip ci]` so that it did not start a macOS build.

## Measurements

All on this Windows PC (Core Ultra 7 155H, 15.6 GB, busy with other sessions), NumPy 2.5.4, no GPU.

**Memory of the render path.** Measured with `tracemalloc` on synthetic six-stem songs of 30, 60 and 90 s at
44.1 and 48 kHz; the result is the same number of song-sized arrays at every length (within 0.1), so it scales
in step with the song. One unit `U` is one stereo float32 array of the song: 8 bytes a frame, 345.6 MB for 15
minutes at 48 kHz.

| Moment | Held by the pipeline | Held inside the renderer | Together |
|---|---|---|---|
| the peak of `prepare()` (the centre split of each stem) | 7 U: the mix and six stems | 25.5 U | **32.5 U** |
| after `prepare()` | 7 U | 10 U: the split stems, the mix's spectrum | 17 U |
| the peak of one profile's render | 7 U | 17.5 U | 24.5 U |

So the peak is **32.5 U, inside the renderer's `prepare()`**: 2.8 GB for a 4-minute song at 44.1 kHz, 6 GB at
about 8 minutes, **11.2 GB for a 15-minute song at 48 kHz** (10.3 GB at 44.1 kHz). The 6 GB goal is not met for
songs over about 8 minutes, and the pipeline cannot change that from outside: it holds only what the renderer's
interface needs (the job's own outputs are uploaded and freed before, the vocals are handed over, results are
freed one by one). A 15-minute run was not done: this PC had about 1.5 GB free. The number is the 30/60/90 s
measurement scaled, which is exact for arrays that grow with the song.
The six-stem stage before it was not measured (it needs torch). Reading demucs' `apply_model`, it holds the
model's whole output on the CPU twice for a moment: an estimate of 5 to 6 GB for 15 minutes.
`op: bench` now reports the process's peak memory around both stages and the container's limit, and the selftest
reports the limit, so the first deploy answers this for the real workers.

**Time of the renderer.** Without tracing, with this PC about 60 % busy: preparation 0.27 s per second of song
(six stems; one centre split of a 60 s stem takes 2.1 s), then 0.145 s per second of song for each profile. A
4-minute song with one profile is about 100 s of one CPU core here. That is CPU time billed at the GPU's price,
and more than the separation itself. The bench will give the real number.

**Cutoff detection** on the four masters in the lab (decoded from Opus, stored as 16-bit FLAC):

| Song as | Detected | Says |
|---|---|---|
| it came (Opus) | 19.99 to 20.12 kHz | `full_band` |
| 128 kb/s AAC, cut at 16 kHz | 16.54 to 16.62 kHz (the encoder's band edge) | band-limited |
| 128 kb/s MP3 | 16.34 to 16.68 kHz | band-limited |
| AAC cut at 11 kHz | 11.05 to 11.83 kHz | band-limited |
| brick wall at 15 kHz, with or without a 19 kHz pilot tone | 15.00 to 15.01 kHz | band-limited |
| made dull with a 2-pole low-pass at 5 kHz | no cutoff | `full_band` |
| resampled to 32 kHz | 15.6 to 16.0 kHz | band-limited |
| that 16 kHz AAC re-encoded as Opus | about 20 kHz or no cutoff for three songs, 16.6 kHz for one | mixed |

Two things came out of the real songs. Their level at 17 kHz is already 8 to 25 dB under their 2-8 kHz average,
and at 19 kHz up to 29 dB, so "30 dB under" alone sits a hair away from calling full-band songs cut. And the
noise floor of a 16-bit upload is only 45 to 50 dB under that average. Hence the cliff test (at least 10 dB
across the edge) and the stop at 42 dB. The last row is Opus itself: it fills its top band (15.6 to 20 kHz) from
the band's energy, so a song cut at 16.6 kHz comes out of Opus with something up to 20 kHz. Such a stream is
reported as it is.

## The renderer: found, reported, not changed

- **Memory** and **time**, above. Where a fix would go:
  - `split_center()` holds two whole-song STFTs and several whole-song power arrays for one stem while all stems
    and all earlier splits are alive. Doing the split in blocks of some tens of seconds (with a few frames of
    overlap for its 5-frame smoothing) takes `prepare()` from 32.5 U to about 17 U without changing a sample.
  - After `prepare()` the stems are not read again, but the caller's dict keeps them alive for the whole call
    (6 U). If `render_profiles` emptied that dict once it has its split parts (and the spec said so), a profile's
    render would peak at 18.5 U instead of 24.5 U. The pipeline could do the same from its progress callback,
    which the renderer calls right after `prepare()`; it does not, because today that would lean on the
    renderer's insides and would not lower the overall peak anyway.
  - The rest of a profile's 7.5 U is whole-song spectra and their temporaries in `render_one`. Under 6 GB for 15
    minutes at 48 kHz means under 17 U in every phase.
  - The six splits are independent and NumPy's FFTs run in parallel on threads: four 30 s splits took 5.9 s one
    after another and 2.4 s on four threads here. (Threads multiply the split's memory, so the blocks come first.)
- **The limiter does not hold its ceiling when it has to work hard.** With more than about 3.5 dB to take off, its
  three passes leave the true peak over −1 dBTP: −0.57 to −0.84 dBTP with 3.5 to 6 dB of reduction, −0.18 dBTP
  with 10 dB (clipped, very hot synthetic mixes at 48 kHz). With up to 0.7 dB of reduction it lands on −1.00, and
  the lab's own log shows −1.00 on a real master with 2 dB. The samples themselves stay inside ±1. Recorded as an
  expected failure in `tests/test_spatial.py` (`test_a_brick_of_a_master_is_held_under_the_ceiling_too`), which
  will start passing, and say so, when it is fixed.
- **Stems that miss more than a quarter of the mix's power are dropped** (`BAD_STEMS_DB`), so a subset such as
  "vocals only" renders as `mix`. That is the code's rule and the tests follow it; the spec's "any subset" reads
  wider. The cascade always returns all of the song, so it does not arise in the pipeline.
- `render_profiles` reports progress after the preparation and after each profile only. That is where the job's
  deadline can stop it; inside a profile it cannot.

## Verified and not

Verified:
- The CPU suite locally (Python 3.14, NumPy 2.5.4, ffmpeg 8.1) and in CI (Python 3.12 in the test image):
  570 passed, 8 skipped, 1 expected failure. CI run ids are at the end of this note.
- `ci/check_weights.py` and `ci/check_fixtures.py` pass.
- The htdemucs_6s file's size and sha256.
- The committed on-device tables are byte-identical to what the generator writes today.

Not verified:
- Anything on a GPU. `Stems6` with the real models has only run in the image's CPU smoke stage.
- Any call to RunPod or R2: the storage methods, the job as a whole and the janitor ran against fakes only. The
  janitor has never listed the real bucket.
- That the bucket has the catch-all 30-day lifecycle rule (owner checklist, step 2). Without it `lib/` only
  shrinks through the janitor.
- The cost and duration of a spatial job, and the workers' memory. The first bench says.
- That `cloud-library-janitor` runs: a scheduled workflow only exists once its file is on `main`.

## How to bench after the deploy

1. Merge to `main`; `cloud-worker-build` pushes the image and `cloud-worker-deploy` updates the endpoint (it now
   patches `timeout` and the env to 1800 s).
2. Actions → `cloud-worker-deploy` → Run workflow, tick **bench**. Read in the summary:
   - `selftest`: `htdemucs_6s=lazy`, `library: v1, 6 profiles; host: N CPUs, memory limit M MB`;
   - `bench (240 s synthetic song)`: `stems6` (htdemucs_ft and htdemucs_6s with their first loads, the vocals
     handed over from `separate`) and `render` (one profile, CPU), in seconds;
   - `bench: process memory peak stems6 … MB, render … MB (overall …; the container may use … MB)`. The render's
     share grows in step with the song: for 15 minutes multiply what it adds by 3.75;
   - `bench: render: studio, <stemMode>, … LUFS (… in), true peak … dB`. A synthetic song is not music: `mix`
     here only means the renderer did not trust the stems of a test tone.
3. Then one real song from a phone, and check its manifest in the library against `library.render.schema.json`.
4. Put the measured seconds and cents into the worker README's cost section and the spec's open items.

## What is left: the restoration model

The second worker change (spec section 5). Everything around the model is in place and tested with a fake:

- Subclass `restore.Restorer`: set `model_id`, implement `available()`, `loaded` and
  `restore(mix, sample_rate, cutoff_hz, progress=)`. Its docstring is the contract: same shape and timeline back,
  float32 within ±1, the source's loudness, `progress` called often (it carries the deadline),
  `WorkerError(GPU_OOM, …, refresh_worker=True)` when the GPU runs out.
- Hand it to `pipeline.Models(restorer=…)` in `handler.load_models` and report it in the selftest's `models`.
- Add its weights to `weights.lock` and the Dockerfile, its licence to `NOTICE` and `LICENSES/`.
- The pipeline then stores `enhanced.flac` with its manifest (audio first), renders from the restored song, and
  no longer reuses the vocals of the unrestored one. `restoreMs`, `models.restorer` and the `restore:NN` progress
  are wired. Add `restore` to the bench's stages.
- Decide whether to raise `LIB_V`: renders of band-limited songs made before the model say
  `restore.reason: unavailable` and stay in the library for up to 30 days, and so do the `enhanced.json` notes
  with that reason. A new library version makes every phone ask again.

## CI

Workflow `cloud-worker-build` on `audio-worker`:
- test job (CPU tests in Docker, Python 3.12): run 43046935145, green, 570 passed, 8 skipped, 1 expected failure.
- image build and CPU smoke stage (`[image]`): run 43047397464, see below.
