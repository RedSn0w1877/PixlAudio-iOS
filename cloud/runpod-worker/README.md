# Cloud Studio worker (RunPod Serverless)

The server half of PixlAudio's "Cloud processing": for each song it separates the vocals with **BS-RoFormer**
(anvuew ft1), returns the **instrumental**, and writes **word-timed lyrics** with Qwen3-ForcedAligner, or
transcribes songs that have no lyrics with Qwen3-ASR (the app labels those "AI-written lyrics"). 4 stems
(htdemucs_ft) are available but off in the app for now. It runs on Hoa's own RunPod account, scales to zero and
bills per second. The full design, with every decision and its reasons, is
[`docs/handoff/2026-10-07-plans/cloud-studio-design.md`](../../docs/handoff/2026-10-07-plans/cloud-studio-design.md).

## How one song travels

1. The phone uploads the song to Hoa's Cloudflare R2 bucket `pixl-cloud-studio` (`in/<jobKey>.<ext>`) with a
   presigned URL, then sends RunPod a tiny `/run` job holding presigned URLs for everything the worker may touch.
   **The worker holds no storage keys.**
2. A GPU worker starts (FlashBoot makes a recently used one resume in about a second), runs the guard (a finished
   manifest is returned at once; a job RunPod re-delivered twice is refused), downloads and checks the input,
   separates, aligns or transcribes, encodes AAC 256k (or FLAC), uploads each output and then `manifest.json`
   **last**. It deletes the input only after a usable result.
3. The phone reads `/status` while it's open (results stay there 30 minutes) or finds `manifest.json` in R2 any
   time in the next 30 days, downloads, verifies sizes, sha256 and sample counts, and imports.

The job and result formats are [`schema/v1/`](schema/v1/) (JSON Schema plus golden examples the app's tests
decode). Errors always come back as a code (`BAD_URL`, `INPUT_MISSING`, `POISONED`, ...) in both places.

## What it costs (estimates until the first `bench`)

| | 16 GB GPU | 24 GB GPU |
|---|---|---|
| One warm song (instrumental + aligned lyrics) | ~$0.003 | ~$0.004 |
| 100 songs sent as one batch | ~$0.33 | ~$0.39 |
| A song on its own (cold start) | ~$0.008 | ~$0.010 |
| Doing nothing | $0 | $0 |

The real ceiling is the **prepaid balance**: auto-pay stays off. The keepalive emails when a week costs more
than `CLOUD_WEEKLY_ALARM_USD` ($2). A job that hangs is cut at 15 minutes (~$0.17); the guard stops a job that
keeps crashing after 2 deliveries (~$0.35 at worst).

## Owner checklist (once, about 15 minutes)

Keys go straight from the provider's page into the GitHub or app field, never into chat, an issue or a commit.

Already done:
- [x] GitHub environment **`runpod`**, deployment branches limited to `main`.
- [x] Secret **`RUNPOD_API_KEY`** (a RunPod key with permission **All**, named e.g. `pixl-deploy`).
- [x] Variable **`CLOUD_WEEKLY_ALARM_USD`** = `2`.

Still to do, in this order:
1. **GitHub variable `R2_ACCOUNT_ID`** (Settings → Secrets and variables → Actions → Variables, or the `runpod`
   environment's variables): the 32-character Cloudflare account id. It is not secret; the deploy uses it to
   allow only *your* R2 account's URLs (`<id>.r2.cloudflarestorage.com`).
2. **RunPod billing** (runpod.io → Billing): make sure **auto-pay is off**, add $10 if the balance is low, turn on
   the low-balance email at $3. Delete or disable the old Android Demucs endpoint and its old full-access key.
   The balance is the most anyone could ever spend.
3. **Cloudflare R2**: bucket **`pixl-cloud-studio`** (create it if it doesn't exist; automatic location). Under the
   bucket's Settings → Object lifecycle rules add three rules: prefix `in/` delete after **7 days**, prefix `out/`
   delete after **30 days**, and one rule with **no prefix** that deletes after **30 days**. Keep the default rule
   that aborts unfinished multipart uploads. Then R2 → Manage API tokens → Create: **Object Read & Write**, only
   for the bucket `pixl-cloud-studio`. Keep the Access Key ID and Secret for the app (step 7).
4. **Merge the worker to `main`.** The first `cloud-worker-build` on main pushes
   `ghcr.io/redsn0w1877/pixl-cloud-worker:sha-<12>`. Its automatic deploy then says "No endpoint yet" and stops:
   that's expected.
5. **Make the package public** (once): your GitHub profile → Packages → `pixl-cloud-worker` → Package settings →
   Change visibility → Public. RunPod pulls it without a password, and public packages cost nothing.
6. **First deploy**: Actions → `cloud-worker-deploy` → Run workflow (branch `main`), tick **bench**. It creates the
   endpoint `pixl-cloud-studio`, waits for it, runs the selftest (~1¢) and the bench (a few ¢). Read the job
   summary: GPU, cold start, seconds per stage, peak VRAM and the peak number of running workers (must be 1).
   Every later main build deploys itself.
7. **RunPod console** → Serverless → `pixl-cloud-studio`: copy the **Endpoint ID**. Settings → API Keys → Create
   `pixl-iphone`, permission **Restricted**: `pixl-cloud-studio` → Read/Write, everything else None.
8. **iPhone** (once the app side ships): Settings → Developer → Experimental → Cloud processing: turn it on,
   paste the Endpoint ID, the restricted key, the R2 endpoint `https://<account-id>.r2.cloudflarestorage.com`,
   the bucket name, the access key id and the secret, then **Test connection**.
9. **Two-minute key check** (design 3.5 F): make a second throwaway Restricted key like `pixl-iphone`, then try
   `PATCH https://api.runpod.io/v2/serverless/<id>` with `{"workers":{"max":2}}` (must be refused with 401/403),
   `GET https://api.runpod.io/v2/billing/serverless` (must be refused) and `GET
   https://api.runpod.ai/v2/<id>/health` (must work). Note the results in the handoff note and delete the key. If
   the PATCH works, a leaked phone key could raise the GPU count, and the app must say so.

To switch everything off at any time: RunPod → API Keys → disable `pixl-iphone`, and/or set the endpoint's max
workers to 0. Delete the R2 token in Cloudflare. Nothing needs a rebuild.

## Runbook

**Deploys.** Automatic after each green `cloud-worker-build` on main (it only updates an existing endpoint). By
hand: Actions → `cloud-worker-deploy` → Run workflow; `image_tag` redeploys an older `sha-<12>` (rollback),
`extra_pools` adds e.g. `ADA_24` when the cheap GPUs are scarce. Logs are public, so they show only pass/fail,
the GPU and timings; the endpoint id is masked and money is never printed.

**Emails from `cloud-worker-keepalive`** (daily at 06:17 UTC). Each failure says which of these it was:
- *unhealthy workers*: workers are crashing at start. RunPod lowers max workers on such endpoints, and the
  keepalive deliberately does not undo it. Open the endpoint's Logs in the RunPod console (look for
  `models_loaded` or a Python traceback), fix, push to main; the next green deploy re-arms the keepalive;
- *the last deploy failed*: same idea; fix the deploy first;
- *spend over the alarm*: check RunPod → Billing. If it isn't you, disable `pixl-iphone`;
- */health failed*: RunPod is unreachable or the key was revoked.
GitHub stops scheduled workflows in public repositories after 60 days without activity; re-enable it in the
Actions tab if that happens (the app also notices a paused endpoint).

**Logs.** RunPod console → Serverless → `pixl-cloud-studio` → Logs (or Workers → a worker → Logs). One JSON line
per event: `boot`, `models_loaded`, `job_start`, `job_done`, `job_error` (with a code), `job_duplicate`.
URLs appear as host/path only; lyrics, titles and job bodies are never logged.

**When a job fails**: the manifest's `error.code` says which step. `BAD_URL`
with HTTP 403 means expired or wrong signatures (the phone re-signs); `INPUT_MISSING` means the upload is gone
(the phone uploads again); `POISONED` means the song crashed the worker twice (look at that worker's log);
`GPU_OOM` recycles the worker by itself.

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
- **Adding word timing for more languages** (Whisper later): implement `WordTimingBackend` in
  `src/pixl_worker/lyrics/` and register it after the Qwen aligner in `handler.load_models`; `backend_for()`
  then routes the languages Qwen lacks to it. Nothing else changes.

## Server-side caps (endpoint env, set by `deploy/endpoint.json`; the app cannot raise them)

| Env | Value | Meaning |
|---|---|---|
| `PIXL_MAX_INPUT_MB` | 160 | biggest upload (a 15-minute song decoded to FLAC on the phone is ~90-130 MB) |
| `PIXL_MAX_AUDIO_S` | 900 | longest song, checked on the probe and on the decoded samples |
| `PIXL_BEST_MAX_AUDIO_S` | 480 | "Best" quality (overlap 4) only up to 8 minutes |
| `PIXL_EXECUTION_TIMEOUT_S` | 900 | the job's own deadline is this minus 30 s, so a manifest is always written |
| `PIXL_ALLOWED_HOST_SUFFIXES` | `<R2_ACCOUNT_ID>.r2.cloudflarestorage.com` | the only storage host; HTTPS, public IP, signed, no redirects |
| `PIXL_MAX_LYRICS_LINES` / `_CHARS` | 500 / 20000 | lyrics payload |
| `PIXL_MAX_BODY_KB` | 256 | job input size |

## Files

```
Dockerfile           test | deps | small | final | smoke (CI only)
requirements.in      top-level deps → requirements.lock (hashed, generated by ci/lock.py); constraints.txt
weights.lock         every model file: sha256, size, licence, pinned URL
fetch_small.py       fetches and verifies the small model files (stdlib)
models/demucs/       the htdemucs_ft bag file (from demucs, MIT)
src/pixl_worker/     handler, schema, storage, audio, separate, lyrics/, pipeline, selftest, smoke, log
schema/v1/           the job contract with the app (+ examples/)
tests/               pytest, CPU only
ci/                  check_weights, check_fixtures, pip_check, lock
deploy/              endpoint.json, runpod_deploy.py, keepalive.py, runpod_api.py (stdlib, REST v2)
LICENSES/ NOTICE     licence texts and where every component comes from
```
