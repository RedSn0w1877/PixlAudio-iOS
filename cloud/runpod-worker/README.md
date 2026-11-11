# Cloud Studio worker (RunPod Serverless)

The server half of PixlAudio's "Cloud processing": for each song it separates the vocals with **BS-RoFormer**
(anvuew ft1) and returns the **instrumental**. It can also write **word-timed lyrics** with Qwen3-ForcedAligner, or
transcribe songs that have no lyrics with Qwen3-ASR (labelled "AI-written lyrics"), but since 2026-10-23 neither
app asks for that (the apps' online lyrics sources cover lyrics): the aligner now loads only when a job
asks for lyrics, so cold starts don't pay for it. 4 stems (htdemucs_ft) are available but off in the app for now.
It runs on Hoa's own RunPod account, up to **3 workers at once** (`deploy/endpoint.json`, since 2026-10-23: three
songs process side by side), scales to zero and bills per second, so a batch costs the same per song, only sooner. The full design, with every decision and its reasons, is
[`docs/handoff/2026-10-07-plans/cloud-studio-design.md`](../../docs/handoff/2026-10-07-plans/cloud-studio-design.md).

Since worker 1.1.0 it also makes **Spatial audio** renders (a song for headphones, from six separated stems, in six
profiles). They go into a **shared library** in the same bucket, keyed by the YouTube video, where every phone
fetches them: see "Spatial audio (the shared library)" below. The contract for that work is
[`docs/handoff/2026-11-10-plans/cloud-audio-spec.md`](../../docs/handoff/2026-11-10-plans/cloud-audio-spec.md).

## How one song travels

1. The phone uploads the song to Hoa's Cloudflare R2 bucket `pixl-cloud-studio` (`in/<jobKey>.<ext>`) with a
   presigned URL, then sends RunPod a tiny `/run` job holding presigned URLs for everything the worker may touch.
   **The worker holds no storage keys.**
2. A GPU worker starts (FlashBoot makes a recently used one resume in about a second), runs the guard (a finished
   manifest is returned at once; a job RunPod re-delivered twice is refused), downloads and checks the input,
   separates, aligns or transcribes, encodes AAC 256k (or FLAC), uploads each output and then `manifest.json`
   **last**. It deletes the input only after a usable result. After the last songs of a batch (the phone marks the
   final one per worker, up to 3, `policy.last_in_batch`) each worker asks RunPod to stop it, so nothing stays up
   idle and billed.
3. The phone reads `/status` while it's open (results stay there 30 minutes) or finds `manifest.json` in R2 any
   time in the next 30 days, downloads, verifies sizes, sha256 and sample counts, and imports.

The job and result formats are [`schema/v1/`](schema/v1/) (JSON Schema plus golden examples the app's tests
decode). Errors always come back as a code (`BAD_URL`, `INPUT_MISSING`, `POISONED`, ...) in both places.

## Spatial audio (the shared library)

One more task, `spatial`, in the same job format (still `v: 1`; a 1.0.0 worker refuses it by name). It can ride
along with `instrumental` and the other tasks in one job, or come alone. Its results are not the job's own: a
finished render is stored once and every device uses it.

```
lib/v1/<videoId>/sp-<profile>.flac    a spatial render: FLAC 16-bit, the song's own sample rate and frame count
lib/v1/<videoId>/sp-<profile>.json    its manifest, written LAST: while it is missing the render does not exist
```

`<videoId>` is the matched YouTube video, `<profile>` one of `studio`, `wide`, `intimate`, `hall`, `surround`,
`night`, and `v1` the library version (`LIB_V` in `src/pixl_worker/library.py`, the only place it lives).

What a job with this task does, after the download and decode every job starts with:

1. **The job's own outputs first**, if it asked for any (instrumental, lyrics, ...): made, uploaded and freed as
   before. The vocals are kept for step 3, so a job that wants an instrumental and a render separates them once.
2. **What is already there?** One GET per requested render (`manifestGet`). A manifest for this library version,
   video and profile means the render exists: it is skipped and reported as `exists`. When everything asked for
   exists, the job ends `ok` there, without touching the GPU. Any doubt (no `manifestGet`, a bucket that does
   not answer, a manifest for something else) means "make it".
3. **Six stems** (`separate.Stems6`, open models only): vocals from BS-RoFormer, then htdemucs_ft on the rest for
   drums, bass and other, then htdemucs_6s on that "other" for guitar and piano. Without the htdemucs_6s files
   the render is made from four stems and says so (`stemMode: stems4`). `Stems6` is the only place stems come
   from: a different separator is a class with the same contract (its docstring), built in
   `handler.load_models()` instead (the spatial roadmap, "Where your own separator plugs in").
4. **Render** every missing profile (`pixl_worker.spatial.render_profiles`, NumPy on the CPU), then for each one:
   encode FLAC 16-bit (TPDF dither), upload the audio, upload its manifest.
5. The job's own `manifest.json` last, as always, now with a `library` block: per render `ok` (made now), `exists`
   or `failed`. Then the input is deleted.

Progress strings `stems6:NN` and `render:NN`, timings `stems6Ms` and `renderMs`, and `models.stems6` are new in
the job's manifest (spec section 4).

A failure in one render leaves the others: the job is `partial`. A job that delivers nothing at all is an error
with the first failure's code, and its input stays for a retry. Every spatial render sits 4 dB under the song's
loudness on purpose (`loudness.headroomDb` in its manifest; the apps give it back when their volume gain has the
room).

**The library is shared and is never cleaned up by a phone.** Two things keep it small:
- the bucket's own lifecycle rule (owner checklist, step 2: the rule with no prefix) deletes every object
  **30 days** after it was written. That is how long a render stays shared; phones keep their own copy as long as
  they like, and a song that is asked for again is simply rendered again;
- **`cloud-library-janitor`** (GitHub Actions, daily at 04:43 UTC; `deploy/library_janitor.py`) keeps `lib/` inside
  R2's free 10 GB: when it holds more than **8 GB** it deletes the oldest renders until it is under, each manifest
  before its audio. Under 8 GB it deletes nothing. See the runbook.

A new library version (`LIB_V` 2, when the renderer or the separation changes audibly) moves every key to
`lib/v2/`; the old renders are then ignored and go away on their own.

Jobs with these tasks may run for 30 minutes (the endpoint's `timeout`); the apps must send them with
`policy.executionTimeout` 1 800 000 (`schema/v1/examples/run.request.spatial.json`), because the worker cannot see
a request's policy and plans for the endpoint's limit. Every other job keeps its 15 minutes.

## What it costs (estimates until the first `bench`)

| | 16 GB GPU | 24 GB GPU |
|---|---|---|
| One warm song (instrumental) | ~$0.003 | ~$0.004 |
| 100 songs sent as one batch | ~$0.33 | ~$0.39 |
| A song on its own (cold start) | ~$0.008 | ~$0.010 |
| Doing nothing | $0 * | $0 * |

(The 2026-10-22 bench on an RTX A4500 measured more: about 38 s for a warm 4-minute song with aligned lyrics,
about 33 s for the instrumental alone, and a 15 s cold start, which the apps' estimates use. With up to 3 workers
a batch pays up to three cold starts instead of one, a few tenths of a cent.)

\* Only while no worker stays up idle. RunPod bills an idle worker like a busy one (about $0.58–0.69 an hour on
these pools), and on 2026-10-08 one sat idle and ready for 7+ minutes after the first deploy's selftest although
`idleTimeout` is 10 s. So the worker now stops itself after the jobs nothing follows, and `cloud-worker-reaper`
releases any that stay anyway within 30 minutes (~$0.35 a worker at worst, up to 3); see "Idle workers" in the
runbook.

A spatial render has not been timed on a GPU worker yet: it adds the htdemucs_ft and htdemucs_6s passes on the GPU
and the renderer on the CPU to the vocal separation above. Run the deploy with **bench** ticked once this worker is
deployed: its summary now has `stems6` and `render` (one profile) and the memory the process needed for them.
Storing the renders costs nothing while the bucket stays inside R2's free 10 GB, which the janitor sees to.

The real ceiling is the **prepaid balance**: auto-pay stays off. The keepalive emails when a week costs more
than `CLOUD_WEEKLY_ALARM_USD` ($2). A job that hangs is cut at 15 minutes (~$0.17), one with the spatial task at 30
(~$0.35); the guard stops a job that keeps crashing after 2 deliveries (~$0.35 at worst, twice that for a library
job).

## Owner checklist (once, about 15 minutes)

Keys go straight from the provider's page into the GitHub or app field, never into chat, an issue or a commit.

Already done:
- [x] GitHub environment **`runpod`**, deployment branches limited to `main`.
- [x] Secret **`RUNPOD_API_KEY`** (a RunPod key with permission **All**, named e.g. `pixl-deploy`).
- [x] Variable **`CLOUD_WEEKLY_ALARM_USD`** = `2`.
- [x] Variable **`R2_ACCOUNT_ID`** (the 32-character Cloudflare account id; not secret). Both variables live in the
  `runpod` environment, which is where the deploy and keepalive jobs run. The deploy uses the id to allow only
  *your* R2 account's URLs (`<id>.r2.cloudflarestorage.com`).

Still to do, in this order:
1. **RunPod billing** (runpod.io → Billing): make sure **auto-pay is off**, add $10 if the balance is low, turn on
   the low-balance email at $3. Delete or disable the old Android Demucs endpoint and its old full-access key.
   The balance is the most anyone could ever spend.
2. **Cloudflare R2**: bucket **`pixl-cloud-studio`** (create it if it doesn't exist; automatic location). Under the
   bucket's Settings → Object lifecycle rules add three rules: prefix `in/` delete after **7 days**, prefix `out/`
   delete after **30 days**, and one rule with **no prefix** that deletes after **30 days**. Keep the default rule
   that aborts unfinished multipart uploads. Then R2 → Manage API tokens → Create: **Object Read & Write**, only
   for the bucket `pixl-cloud-studio`. Keep the Access Key ID and Secret for the app (step 7).
3. **Merge the worker to `main`.** The first `cloud-worker-build` on main pushes
   `ghcr.io/redsn0w1877/pixl-cloud-worker:sha-<12>`. Its automatic deploy then says "No endpoint yet" and stops:
   that's expected.
4. **Make the package public** (once): your GitHub profile → Packages → `pixl-cloud-worker` → Package settings →
   Change visibility → Public. RunPod pulls it without a password, and public packages cost nothing.
5. **First deploy**: Actions → `cloud-worker-deploy` → Run workflow (branch `main`), leave `image_tag` empty (it
   deploys the newest green `cloud-worker-build` on main, even when app commits landed on main since), tick
   **bench**. It creates the endpoint `pixl-cloud-studio`, waits for it, runs the selftest (~1¢) and the bench
   (a few ¢). Read the job summary: GPU, cold start, seconds per stage, peak VRAM and the peak number of running
   workers (never above workers.max, 3 since 2026-10-23; the check queues one job more than that). If no GPU is free for 25 minutes the run fails and cancels its queued jobs, so nothing
   bills later; run it again. Every later main build deploys itself. (The endpoint was created on 2026-10-08.
   Each selftest and bench job now stops its worker afterwards, so the bench's concurrency jobs each start a
   worker of their own: a cent or two more than before. The deploy then checks that no worker stays idle.)
6. **RunPod console** → Serverless → `pixl-cloud-studio`: copy the **Endpoint ID**. Settings → API Keys → Create
   `pixl-iphone`, permission **Restricted**: `pixl-cloud-studio` → Read/Write, everything else None.
7. **iPhone** (once the app side ships): Settings → Developer → Experimental → Cloud processing: turn it on,
   paste the Endpoint ID, the restricted key, the R2 endpoint `https://<account-id>.r2.cloudflarestorage.com`,
   the bucket name, the access key id and the secret, then **Test connection**.
8. **Two-minute key check** (design 3.5 F): make a second throwaway Restricted key like `pixl-iphone`, then try
   `PATCH https://api.runpod.io/v2/serverless/<id>` with `{"workers":{"max":2}}` (must be refused with 401/403),
   `GET https://api.runpod.io/v2/billing/serverless` (must be refused) and `GET
   https://api.runpod.ai/v2/<id>/health` (must work). Note the results in the handoff note and delete the key. If
   the PATCH works, a leaked phone key could raise the GPU count, and the app must say so.

To switch everything off at any time: RunPod → API Keys → disable `pixl-iphone`, and/or set the endpoint's max
workers to 0. Delete the R2 token in Cloudflare. Nothing needs a rebuild.

## Runbook

**Deploys.** Automatic after each green `cloud-worker-build` on main (it only updates an existing endpoint). By
hand: Actions → `cloud-worker-deploy` → Run workflow; an empty `image_tag` deploys the newest green main build,
a `sha-<12>` redeploys that build (rollback),
`extra_pools` adds e.g. `ADA_24` when the cheap GPUs are scarce. Logs are public, so they show only pass/fail,
the GPU and timings; the endpoint id is masked and money is never printed.

**Emails from `cloud-worker-keepalive`** (daily at 06:17 UTC). Each failure says which of these it was:
- *unhealthy workers*: workers are crashing at start. RunPod lowers max workers on such endpoints, and the
  keepalive deliberately does not undo it. Open the endpoint's Logs in the RunPod console (look for
  `models_loaded` or a Python traceback), fix, push to main; the next green deploy re-arms the keepalive;
- *the last deploy didn't pass* (failed, timed out or was cancelled): same idea; fix it and run a deploy that
  passes (deploy runs skipped after a failed main build don't count either way);
- *spend over the alarm*: check RunPod → Billing. If it isn't you, disable `pixl-iphone`;
- */health failed*: RunPod is unreachable or the key was revoked.
GitHub stops scheduled workflows in public repositories after 60 days without activity; re-enable it in the
Actions tab if that happens (the app also notices a paused endpoint).

**Idle workers** (they bill like busy ones). Three layers, from the first to the last resort:
1. *The worker stops itself* after the jobs nothing follows: every `selftest` and `bench`, and the process jobs the
   phone marks `policy.last_in_batch: true` (the last song of each submit burst for each worker that may run it, up
   to 3, and none while more of the phone's songs are still on their way; a single song is a burst of one).
   It returns runpod's per-job `refresh_worker`, so RunPod stops it once the result is in; the next job starts a
   fresh worker (a cold start, FlashBoot makes it short). Songs in the middle of a batch keep the worker warm. Its
   log says `worker_refresh` with the reason.
2. *`cloud-worker-reaper`* (every 30 minutes, at :07 and :37, and by hand: Actions → cloud-worker-reaper → Run
   workflow) reads `/health` twice a minute apart. When both show an idle or ready worker and nothing queued, in
   progress or running, it sets max workers to 0 until the worker is gone (2 minutes at most; a job that arrives
   meanwhile only waits for the restore) and then back to what it was, never above `deploy/endpoint.json` (min
   and idle timeout stay as they were). It leaves an endpoint at max 0 alone (that is the off switch), and one with
   min workers above 0 (a worker you keep warm on purpose). When RunPod answers so slowly that the two reads take
   well over their minute, it changes nothing and the next run looks again. Most runs only read `/health` and print
   the counts. A cancelled or timed-out run still puts max workers back (the step `exec`s python, so the cancel
   reaches it).
3. *The deploy* does the same release after its selftest/bench, whether they passed or not.

By hand, if a worker ever stays up (RunPod console → Serverless → `pixl-cloud-studio` → Workers shows one *idle*
for minutes with nothing queued): Edit → Max workers 0 → Save, wait until the worker is gone, then Max workers
back to 3. Or run `cloud-worker-reaper` by hand.

**Emails from `cloud-worker-reaper`** (it fails only when something needs a look): *max workers 0 didn't release
the idle worker* (stop it in the console under Workers, and tell RunPod support: it bills), or *couldn't set max
workers back* / *couldn't set max workers to 0* (a RunPod API error: put Max workers back to 3 in the console, or
run `cloud-worker-keepalive`, which restores it). A `/health` that can't be read is only a warning there: the
keepalive's daily run reports an unreachable RunPod or a revoked key.

**The shared library (`lib/` in the bucket).** Nothing to do day to day: renders expire 30 days after they were
written (the bucket's lifecycle rule with no prefix; check it exists under the bucket's Settings → Object
lifecycle rules, because without it `lib/` only ever grows), and **`cloud-library-janitor`** runs every day.
- Its summary says how many objects and GB `lib/` holds and what it deleted. Most days: "under the limit, nothing
  to delete".
- By hand: Actions → `cloud-library-janitor` → Run workflow; tick **dry run** to only see what it would delete.
  From a checkout: `CLOUD_DEFAULTS_KEY=... python3 deploy/library_janitor.py --dry-run` (needs `cryptography`).
- It fails (GitHub emails) only when something needs a look: the listing was refused (the R2 token lost its
  rights, or was replaced: bake the keys again), or renders could not be deleted. A failed delete never leaves a
  manifest without its audio; the other way round (audio whose manifest is gone) is harmless and expires.
- To empty the library on purpose (a bad render went out): raise `LIB_V` in `src/pixl_worker/library.py`
  (everything moves to `lib/v2/` and the old renders are ignored by workers and phones), or delete the `lib/`
  prefix in the Cloudflare dashboard. Phones keep the copies they already downloaded either way.
- GitHub stops scheduled workflows in public repositories after 60 days without activity; re-enable it in the
  Actions tab if that happens. The lifecycle rule still deletes on time; only the 8 GB guard would be asleep.

**Bench after a deploy.** Actions → `cloud-worker-deploy` → Run workflow, tick **bench**. One synthetic 4-minute
song goes through every stage, the spatial path included: the summary shows `stems6` (htdemucs_ft and htdemucs_6s
on the GPU, with their first loads) and `render` (one profile on the CPU) in seconds, peak VRAM, and the
process's peak memory around those two stages next to what the container may use. Multiply the render's memory by
the song's length over 4 minutes for a longer song: it grows in step with it.

**Logs.** RunPod console → Serverless → `pixl-cloud-studio` → Logs (or Workers → a worker → Logs). One JSON line
per event: `boot`, `models_loaded`, `job_start`, `job_done`, `job_error` (with a code), `job_duplicate`,
`worker_refresh` (the worker asked RunPod to stop it after this job), and for library jobs `library_checked` (how
many outputs were already there) and `library_failed` (which output, during what, with a code). URLs appear as
host/path only; lyrics, titles and job bodies are never logged.

**When a job fails**: the manifest's `error.code` says which step. `BAD_URL`
with HTTP 403 means expired or wrong signatures (the phone re-signs); `INPUT_MISSING` means the upload is gone
(the phone uploads again); `POISONED` means the song crashed the worker twice (look at that worker's log);
`GPU_OOM` recycles the worker by itself; `UNSUPPORTED_FORMAT` saying "ask for flac output" is a 176.4/192 kHz song
sent with AAC output (AAC tops out at 96 kHz; the phone resends it with `output.codec: flac`). A job whose only
task is `lyrics` fails with the lyrics' own code when they fail (there is nothing else to deliver); with stems
requested it is `partial` instead.
A job with the spatial task says per render what happened (`library.renders`, and a warning such as
`library: sp-wide failed (UPLOAD_FAILED)`): `partial` when some of it arrived, an error with the first
failure's code when none did. `UNSUPPORTED_VERSION` with "library.v" means the app and the worker disagree about
the library version (deploy the worker first, then ship the app). `BAD_URL` on a `library` URL means it does not
point at that video's own object. A long song that ends in `DEADLINE` during `stems6` or `render` was most
likely sent with the old 15-minute `executionTimeout`.

**Sending a job twice** (a lost `/run` response) costs about a second: a finished `ok` manifest for the same
input comes straight back with the warning `duplicate`. A resend that finds the input already gone also hands
back an `ok` or `partial` result instead of overwriting it with `INPUT_MISSING`. To *retry* a partial job for
its lyrics, upload the song again: while the input is there, a partial result is processed again, not reused.

**Measuring re-delivery (W1, optional).** Set the endpoint env `PIXL_ALLOW_CRASH_TEST=1` in the RunPod console
(test only), send `{"input":{"v":1,"op":"bench","bench":{"crash":true}}}` to `/run`, watch how many times a
worker starts it, then remove the env var again (the next deploy also resets env to `deploy/endpoint.json`).

## Developing

```bash
# CPU-only tests (no torch, no weights): Python 3.12 with pytest, jsonschema, numpy (ffmpeg + openssl optional)
python -m pytest -q tests
python ci/check_weights.py      # the Dockerfile's ADD lines agree with weights.lock
python ci/lock.py               # regenerate requirements.lock / requirements-test.lock (needs uv)
```

- **Python dependencies**: edit `requirements.in` (or `constraints.txt` when the base image changes), run
  `python ci/lock.py`, commit both. The image installs the lock with `--no-deps --require-hashes`; `ci/pip_check.py`
  fails the build on any new conflict.
- **Model files**: add a row to `weights.lock` (kind `large` also needs its `ADD --link --chmod=644
  --checksum=sha256:...` line in the Dockerfile's `final` stage; `small` files are fetched by `fetch_small.py`).
  Pin Hugging Face files by commit, never `main`; take sha256 from `https://huggingface.co/api/models/<repo>?blobs=true`.
- **A branch build**: put `[image]` in the commit message to build the whole image and run the CPU smoke test
  (real weights on CPU) without pushing anything. On main the image is pushed.
- **The contract files have copies in the apps.** `schema/v1/examples/` and `schema/v1/spatial/` are the
  originals; `python ci/check_fixtures.py` fails when a copy in this repository differs by a byte. The two files in
  `schema/v1/spatial/` are generated: after changing a profile or the head model run
  `PYTHONPATH=src python -m pixl_worker.spatial.preview --out schema/v1/spatial`, commit them, and copy them into
  both apps (a test compares the committed files with what the generator writes).
- **Changing how a render sounds** (the renderer, a profile, the separation): raise `LIB_V` in
  `src/pixl_worker/library.py` and the `const` in `schema/v1/job.input.schema.json`, and the apps' own constant.
  Renders made before are then ignored and expire.
- **A different six-stem separator**: a class with `Stems6`'s contract (`model_id`, `available()`,
  `stems(...)`; the docstring of `separate.Stems6` says exactly what it must return), in its own file, built in
  `handler.load_models()` instead of `Stems6`; its weights in `weights.lock` and the Dockerfile (`final` and
  `smoke`), the smoke stage pointed at it, and `LIB_V` raised (see the line above). The pipeline checks what it
  returns (names and shapes) and fails the renders with a clear message otherwise.
- **Adding word timing for more languages** (Whisper later): implement `WordTimingBackend` in
  `src/pixl_worker/lyrics/` and register it after the Qwen aligner in `handler.load_models` (load it lazily, like
  `_LazyAligner`, so cold starts don't pay for it); `backend_for()` then routes the languages Qwen lacks to it.

## Server-side caps (endpoint env, set by `deploy/endpoint.json`; the app cannot raise them)

| Env | Value | Meaning |
|---|---|---|
| `PIXL_MAX_INPUT_MB` | 160 | biggest upload (a 15-minute song decoded to FLAC on the phone is ~90-130 MB) |
| `PIXL_MAX_AUDIO_S` | 900 | longest song, checked on the probe and on the decoded samples |
| `PIXL_BEST_MAX_AUDIO_S` | 480 | "Best" quality (overlap 4) only up to 8 minutes |
| `PIXL_EXECUTION_TIMEOUT_S` | 1800 | the endpoint's `timeout`. A job with the `spatial` task ends itself 30 s before it, so a manifest is always written; every other job still ends itself at 870 s, because the apps send those with `executionTimeout` 900 000 and RunPod would cut them there |
| `PIXL_ALLOWED_HOST_SUFFIXES` | `<R2_ACCOUNT_ID>.r2.cloudflarestorage.com` | the only storage host; HTTPS, public IP, signed, no redirects |
| `PIXL_MAX_LYRICS_LINES` / `_CHARS` | 500 / 20000 | lyrics payload |
| `PIXL_MAX_BODY_KB` | 256 | job input size |

## Files

```
Dockerfile           test | deps | small | final | smoke (CI only)
requirements.in      top-level deps → requirements.lock (hashed, generated by ci/lock.py); constraints.txt
weights.lock         every model file: sha256, size, licence, pinned URL
fetch_small.py       fetches and verifies the small model files (stdlib)
models/demucs/       the htdemucs_ft and htdemucs_6s bag files (from demucs, MIT)
src/pixl_worker/     handler, schema, storage, audio, separate, lyrics/, pipeline, selftest, smoke, log;
                     library (the shared library: keys, manifests, FLAC, the one call into the renderer),
                     spatial/ (the renderer and the on-device tables' generator; NumPy only)
schema/v1/           the job contract with the app (+ examples/), the render manifest, spatial/ (the tables)
tests/               pytest, CPU only
ci/                  check_weights, check_fixtures, pip_check, lock
deploy/              endpoint.json, runpod_deploy.py, keepalive.py, reaper.py, runpod_api.py (stdlib, REST v2),
                     e2e.py, library_janitor.py (need `cryptography`)
tools/               build_hrir.py (made spatial/data/hrir_ku100.npz from the SADIE II database; run by hand)
LICENSES/ NOTICE     licence texts and where every component comes from
```
