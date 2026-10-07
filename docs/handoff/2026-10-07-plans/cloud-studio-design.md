# PixlAudio Cloud Studio: RunPod Serverless worker (vocals/instrumental + AI word-timed lyrics)

Design v1, 2026-10-07. Based on read-only research; nothing has been built, deployed or measured yet.
Tags: **[V]** means checked against a doc or code (URL or file:line given). **[I]** means inference or estimate, to be measured on the first deploy.
**(revised)** v1.1, same day: critical review pass. Every change is marked "(revised)"; the reasons and the re-checked facts are in the **Review notes** at the end.

---

## 0. Summary

- **What it is.** A worker on RunPod Serverless, billed to the owner's account. It scales to zero and bills per second. For each song it:
  - separates vocals with **BS-RoFormer** (anvuew ft1; Multisong vocals SDR 11.54, instrumental 17.85);
  - optionally adds **4 stems** with htdemucs_ft;
  - produces **word-timed lyrics**: Qwen3-ForcedAligner aligns known lyrics to the isolated vocals, and Qwen3-ASR-1.7B transcribes when the song has no lyrics.
- **"Process later" works through object storage, not through RunPod job output.**
  - RunPod caps /run at 10 MB and keeps results for only 30 minutes [V].
  - So the phone uploads the song to **Cloudflare R2** with a presigned PUT. It then sends a tiny /run job containing presigned URLs. The worker writes its results to R2, writing `manifest.json` last.
  - The phone collects results whenever it next runs: from /status if that is within 30 minutes, otherwise from R2. R2 lifecycle rules delete leftovers.
  - **(revised)** The worker's presigned URLs are signed **when the job is submitted**, not when the song is uploaded, and the lifecycle backstops are `in/` 7 d, `out/` 30 d plus a catch-all rule (section 2.5). The v1 values could delete an input before its queued job ran.
  - **(revised)** The worker is idempotent and retry-safe: it skips a job whose manifest already exists and refuses a job RunPod has already re-delivered twice (section 2.3, "Guard").
  - Fallback: a RunPod network volume with its S3 API.
- **Where it lives:** `pixlaudio-ios/cloud/runpod-worker/`.
- **Build and deploy:**
  - GitHub Actions builds the image and pushes it to `ghcr.io/redsn0w1877/pixl-cloud-worker:sha-…`.
  - A deploy workflow creates or updates the endpoint through **RunPod REST v2** (`api.runpod.io/v2`). REST v1 retires on 2026-11-15 [V].
  - A keepalive cron undoes RunPod's 7-day idle scale-down and raises an alarm on unexpected spend. **(revised)** It runs daily, and it does not restore an endpoint that RunPod scaled down for crashing workers.
  - **(revised)** Weights go in as `ADD --checksum --link` layers with an inline build cache, so the free runner's disk holds each weight file about twice instead of four times, and a code-only change re-uploads only the code layer (section 3.2).
- **Keys:**
  - The full RunPod key lives only in a GitHub *environment* secret.
  - The phone holds a **Restricted** RunPod key (Read/Write on this one endpoint) and an R2 token scoped to one bucket. Both are in the Keychain.
  - The worker holds no credentials at all.
  - **(revised)** The real ceiling on a leaked phone key is the **prepaid balance**, not `workers.max`. Whether an endpoint-scoped key can also change the endpoint's settings is undocumented, so W1 tests it (R15).
- **Cost (estimates):** about **$0.004 per warm song** and **$0.33–0.39 per 100 songs** sent as one batch. The worst case is about $0.017 per song. Idle cost is **$0/month** with R2. **(revised)** On failure paths (a hung or crashing job, delivered at most twice) one song can bill up to about $0.35; section 6 lists each path with its bound.
- **(revised) What runs while the app is closed:** only the GPU work already queued at RunPod, and transfers the phone had already handed to iOS. Submitting jobs and importing results need the app to run, either in the foreground or in short background wakes; a force-quit stops everything until the next launch (section 7.4).

---

## 1. Architecture

```
 iPhone 16 Pro — PixlAudio iOS                                   Cloudflare R2  (bucket: pixl-cloud-studio)
 ┌─────────────────────────────────────────┐   (2) presigned PUT   ┌──────────────────────────────────────┐
 │ CloudStudio (orchestrator, @MainActor)  │ ────────────────────▶ │ in/<jobKey>.m4a        lifecycle 7 d │
 │ CloudJobStore  (SwiftData "PixlCloud")  │                       │ out/<jobKey>/instrumental.m4a        │
 │ CloudTransfers (background URLSession)  │ ◀──────────────────── │ out/<jobKey>/lyrics.json             │
 │ S3 SigV4 presigner (CryptoKit HMAC)     │   (7) presigned GET   │ out/<jobKey>/manifest.json  ← last   │
 │ Keychain: RunPod RESTRICTED key,        │       + DELETE        │                        lifecycle 30 d│
 │           R2 bucket-scoped token        │                       └───────▲──────────────────────┬───────┘
 └──────┬──────────────────────▲───────────┘                               │ (4) GET input        │ (5) PUT results
        │ (3) POST /run         │ (6) GET /status (≤30 min after done)      │     (presigned)      │     (presigned)
        │  tiny JSON: URLs,     │     or HEAD out/<jobKey>/manifest.json    │                      │
        │  lyrics lines, flags  │     in R2 any time later                  │                      │
        ▼                       │                                           │                      ▼
 ┌─────────────────────────────────────────┐  queue (ttl ≤ 3 d)  ┌──────────────────────────────────────────┐
 │ RunPod Serverless endpoint (QUEUE)      │ ──────────────────▶ │ GPU worker, 0..1, FlashBoot              │
 │ https://api.runpod.ai/v2/<id>/run       │                     │ ffmpeg → BS-RoFormer (fp16)              │
 │ workers min 0 / max 1, idle 10 s        │ ◀── progress ────── │ → [htdemucs_ft] → Qwen3 aligner / ASR    │
 │ timeout 900 s, pools AMPERE_16/_24      │                     │ → AAC 256k → PUT → manifest              │
 └───────────────────▲─────────────────────┘                     └──────────────────────────────────────────┘
                     │ REST v2 (FULL key, GitHub environment secret "runpod", main branch only)
 ┌───────────────────┴───────────────────────────────────────────────────────────────────────────────────┐
 │ GitHub Actions — RedSn0w1877/pixlaudio-ios (public repo)                                              │
 │  cloud-worker-build  → test target → image → ghcr.io/redsn0w1877/pixl-cloud-worker:sha-<12> (public)  │
 │  cloud-worker-deploy → POST/PATCH /v2/serverless → wait for release → /runsync selftest               │
 │  cloud-worker-keepalive (cron, daily; revised) → restore workers.max unless unhealthy, spend alarm    │
 └───────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

(revised) Diagram values: lifecycle `in/` 7 d and `out/` 30 d (were 3 d and 14 d), keepalive daily (was every 2 days). Section 2.5 explains why.

**Flow for one song:**

1. **Prepare.** The phone prepares the audio in the background:
   - an already-compressed source is used as it is **(revised) only when it is AAC-LC in an M4A/MP4 container with a single audio track**;
   - an `ipod-library` item goes through passthrough export (protected items are already skipped by `MediaLibraryImporter`);
   - **(revised)** everything else (HE-AAC itag 139, the muxed video itag 18, MP3, Opus, WAV, ALAC, FLAC) is decoded with `AVAssetReader`, the same decoder the player uses, and uploaded as **FLAC**. The worker then sees exactly the samples the phone plays, so encoder-delay differences between Apple's decoders and ffmpeg cannot shift the instrumental (R13). It costs about 25–35 MB per 4-minute song instead of 4–8 MB, over Wi-Fi only by default.
   The phone records the SHA-256, the duration and its own decoded sample count.
2. **Upload. (revised)** The phone presigns **only the upload PUT** (valid 24 h) and uploads `in/<jobKey>.<ext>` with a background `uploadTask(fromFile:)`. If the upload has not finished when that URL expires, the app re-signs it and starts the upload again on its next launch.
3. **Submit. (revised)** Once the batch's uploads are done, the phone presigns the worker's URLs **at that moment** (input GET and DELETE, output PUTs, and the guard URLs in section 2.3), valid for `ttl + executionTimeout + 1 h` ≈ 76 h. It then sends all the `/run` jobs in one burst, each with `policy.ttl = 3 d`. Submitting in a burst keeps the worker warm between songs. An input older than 3 days is uploaded again instead of being submitted. Then upload age (≤ 3 d) plus queue ttl (3 d) stays under the 7-day `in/` lifecycle, so the lifecycle can never delete an input before its job runs.
4. **Fetch.** A worker starts. FlashBoot resumes in about 200 ms if a frozen worker exists [V]; otherwise it is a cold start. The worker streams in the input and checks the caps.
5. **Process and upload.** **(revised)** The worker first runs the guard: if a manifest already exists it returns that manifest without working, and if RunPod has re-delivered this job twice it fails the job. Otherwise it separates, aligns or transcribes, encodes and uploads each output, then uploads `manifest.json` last. It returns the same manifest as the job output.
6. **Track.**
   - In the foreground, /status gives progress (`stage:pct`).
   - **(revised)** A `/status` 404 means "expired or never existed", not failure. The phone then checks R2.
   - Later (in the foreground or from BGAppRefresh), the phone lists `out/` or HEADs the manifests in R2. This still works after /status has expired.
7. **Import.** A background download fetches the outputs. The phone verifies size, SHA-256 and sample count, imports into `Stems/` and the lyrics store, then deletes `out/<jobKey>/` and `in/<jobKey>.*`.

---

## 2. Worker

### 2.1 Location

**Recommendation:** put it in `RedSn0w1877/pixlaudio-ios` under `cloud/runpod-worker/`. Reasons:

- It is the owner's main repo, and GitHub Actions there is already the build machine.
- The job schema fixtures can be shared, in the same repo, between the Python tests and the Swift tests (PixlNetTests).
- The repo is **public** [V: `gh api` → `visibility: public`], so Actions minutes and a public GHCR package cost $0.

No reason against was strong enough. The one wrinkle is CI cost: `ci.yml` runs on every push with only `docs/**` and `**/*.md` ignored [V: .github/workflows/ci.yml:3-9]. So the first worker PR **must add `cloud/**` and `.github/workflows/cloud-worker-*.yml` to `paths-ignore`**, or every worker change would hold the scarce macOS runners.

```
cloud/runpod-worker/
  README.md                      how it works, owner steps, cost, runbook
  Dockerfile                     multi-stage: test | small | deps | final  (revised: large weights are ADD layers, no weights stage)
  requirements.lock              uv pip compile --generate-hashes (torch excluded: comes from base)
  constraints.txt                torch==2.11.0, torchaudio==<base's> (stops pip from replacing torch)
  weights.lock                   one row per file: source, revision/URL, path, size, sha256, licence
  fetch_small.py                 (revised) stdlib only; fetches the KB-sized config/tokenizer files by pinned
                                 revision and verifies each sha256; the large files are Dockerfile ADD lines
  ci/check_weights.py            (revised) fails if a Dockerfile ADD line and its weights.lock row disagree
  LICENSES/ NOTICE               GPL-3.0 (anvuew ckpt), MIT (msst, demucs), Apache-2.0 (Qwen), sources;
                                 (revised) plus ffmpeg's GPL text and the Ubuntu source-package versions
  src/pixl_worker/
    handler.py                   runpod.serverless.start; loads models at import
    schema.py                    v1 validation (stdlib only; no torch import)
    storage.py                   presigned + volume drivers, host allowlist, streaming caps, retries
    audio.py                     ffprobe/ffmpeg wrappers with timeouts and format allowlist
    separate.py                  msst Separator (BS-RoFormer), htdemucs_ft
    lyrics/{align,transcribe,windows,postprocess}.py
    log.py                       JSON lines, redaction
    selftest.py                  op=selftest / op=bench
  schema/v1/{job.input,job.result,lyrics}.schema.json
  schema/v1/examples/*.json      golden fixtures, copied into Packages/PixlCore/Tests/PixlNetTests/Fixtures/cloud/
  tests/                         pytest, CPU-only, no weights (schema, URLs, caps, postprocess, redaction, deadline)
  deploy/endpoint.json           desired endpoint state (section 3.3)
  deploy/runpod_deploy.py        stdlib-only REST v2 upsert + release wait + selftest
  deploy/keepalive.py            restores workers.max unless workers are unhealthy; spend alarm (revised)
.github/workflows/cloud-worker-build.yml | cloud-worker-deploy.yml | cloud-worker-keepalive.yml
```

The old Android worker (`PixlAudio@0a8b63e:tools/runpod-serverless`, Demucs, base64, 30 s regions) is superseded. Don't build on it. Keep only its lessons: weights baked in, models loaded at import, `pytorch/pytorch` base image.

### 2.2 Dockerfile (sketch)

```dockerfile
# syntax=docker/dockerfile:1.10
# Pin every FROM by digest on the first green build (renovate-style bump PRs later).
ARG BASE=pytorch/pytorch:2.11.0-cuda12.8-cudnn9-runtime   # 4.26 GB amd64 [V Docker Hub]; msst needs torch<2.12 [V PyPI]

########## test: CPU-only unit tests, no torch, no weights (runs on PRs too)
FROM python:3.12-slim AS test
COPY requirements-test.lock /t/
RUN pip install --no-cache-dir --require-hashes -r /t/requirements-test.lock   # pytest, jsonschema
COPY src/ /t/src/
COPY schema/ /t/schema/
COPY tests/ /t/tests/
WORKDIR /t
CMD ["python", "-m", "pytest", "-q", "tests"]

########## deps: base + ffmpeg + pinned python deps
FROM ${BASE} AS deps
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_CONSTRAINT=/opt/constraints.txt
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && dpkg-query -W -f='${Package} ${Version}\n' > /opt/apt-versions.txt      # (revised) for NOTICE / GPL source pointer
COPY constraints.txt requirements.lock /opt/
RUN pip install --require-hashes -r /opt/requirements.lock \
 && pip check \
 && python -c "import torch, runpod, msst, demucs, qwen_asr, nagisa, soynlp, soundfile"

########## small (revised): the KB-sized configs, tokenizers and yaml, by pinned revision, sha256-verified
FROM python:3.12-slim AS small
COPY weights.lock fetch_small.py /w/
RUN python /w/fetch_small.py --lock /w/weights.lock --out /models

########## final (revised): every large weight file is its own `ADD --link --checksum` layer.
# --checksum: BuildKit verifies the sha256 and uses it as the cache key, so an unchanged file is never downloaded
#             again on a warm build, and no separate weights stage holds a second copy on the runner's disk.
# --link:     the layer does not depend on the layers below it, so a deps change does not rebuild or re-push
#             it, its digest stays stable, and RunPod hosts that already have it don't pull it again.
# URLs use the HF *commit* revision (never `main`); each file stays under GHCR's 10 GB per-layer cap [V].
FROM deps AS final
ADD --link --checksum=sha256:<from weights.lock> \
    https://huggingface.co/anvuew/BS-RoFormer/resolve/24988f47270cb3529b62c4f3bbb8234f4586de9b/bs_roformer_ft1_anvuew_sdr_12.55.ckpt /models/sep/   # 204.5 MB
ADD --link --checksum=sha256:<…> https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/<4 × htdemucs_ft .th> /models/demucs/   # 4 lines, 4 × 84 MB
ADD --link --checksum=sha256:<…> \
    https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B/resolve/c7cbfc2048c462b0d63a45797104fc9db3ad62b7/model.safetensors /models/aligner/   # 1.84 GB
ADD --link --checksum=sha256:<…> \
    https://huggingface.co/Qwen/Qwen3-ASR-1.7B/resolve/7278e1e70fe206f11671096ffdd38061171dd6e5/model-00001-of-00002.safetensors /models/asr/   # 4.22 GB (largest layer)
ADD --link --checksum=sha256:<…> \
    https://huggingface.co/Qwen/Qwen3-ASR-1.7B/resolve/7278e1e70fe206f11671096ffdd38061171dd6e5/model-00002-of-00002.safetensors /models/asr/   # 0.48 GB
COPY --link --from=small /models/ /models/          # no RUN in this stage, so no step ever needs the weights unpacked
COPY --link LICENSES/ /opt/pixl/LICENSES/
COPY --link NOTICE /opt/pixl/
COPY --link src/ /opt/pixl/src/
ARG GIT_SHA=unknown
ENV PYTHONPATH=/opt/pixl/src PYTHONUNBUFFERED=1 PIXL_WORKER_GIT_SHA=${GIT_SHA} \
    HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 TOKENIZERS_PARALLELISM=false
LABEL org.opencontainers.image.source=https://github.com/RedSn0w1877/pixlaudio-ios \
      org.opencontainers.image.description="PixlAudio Cloud Studio RunPod worker"
CMD ["python", "-u", "-m", "pixl_worker.handler"]
```

(revised) The HF commit SHAs above are the current heads [V: `huggingface.co/api/models/<repo>`, 2026-10-07]. Re-read them when writing `weights.lock`, and take each sha256 from the API's `lfs.sha256` field (`?blobs=true`). The final stage deliberately has no `RUN`. A `RUN` there would need every layer below it unpacked on the runner, which would force BuildKit to download the 7 GB of weights again whenever the step re-runs.

**Pinned Python dependencies** (top level; `requirements.lock` holds the full hashed closure):

| Package | Version | Licence | Why this pin |
|---|---|---|---|
| runpod | **1.12.0** | MIT | Must be ≥1.10.1: 1.7.11–1.10.0 corrupt job tracking on endpoints with a volume [V](https://docs.runpod.io/serverless/troubleshooting). |
| msst | 0.1.0 | MIT (repo) | `msst.Separator` loads weights once. The package is one month old (released 2026-09-09) and **(revised)** its PyPI metadata has no licence field [V PyPI]; the MIT licence comes from the ZFTurbo repo, so copy that LICENSE into `LICENSES/`. Fallback: vendor ZFTurbo/Music-Source-Separation-Training at a commit. |
| demucs | 4.1.0 | MIT | htdemucs_ft. |
| qwen-asr | 0.0.6 | Apache-2.0 | It pins transformers==4.57.6, accelerate==1.12.0, nagisa==0.2.11 and soynlp==0.0.493, and pulls gradio, flask, sox and qwen-omni-utils [V PyPI]. **Install it `--no-deps`** and list its real runtime deps (transformers, accelerate, nagisa 0.2.11, soynlp, librosa). The `import` smoke step proves the list. |
| soundfile, numpy, requests | pinned to the base image's ABI | BSD/MIT/Apache | |

**Baked weights** (`weights.lock`):

| Slot | Source (pin by HF commit revision or URL + sha256) | Size | Licence |
|---|---|---|---|
| sep | `anvuew/BS-RoFormer`: `bs_roformer_ft1_anvuew_sdr_12.55.ckpt` + `config.yaml` (dim 256, depth 12, chunk 960000) | 204.5 MB | GPL-3.0 (card tag) [V]; the card says only "dataset by bascurtiz", so the training data's licence is unknown (revised) |
| demucs | htdemucs_ft: 4 × `.th` from dl.fbaipublicfiles.com + yaml | 336 MB | MIT |
| aligner | `Qwen/Qwen3-ForcedAligner-0.6B` | 1.84 GB | Apache-2.0 [V] |
| asr | `Qwen/Qwen3-ASR-1.7B` (loaded lazily), 2 shards | 4.70 GB | Apache-2.0 [V] |
| *(alt, decision D2)* | `KimberleyJSN/melbandroformer` `MelBandRoformer.ckpt` | 913 MB | MIT [V] |

- **Never bake BS-RoFormer SW** (6 stems). Its licence and provenance are unknown, and it is probably derived from Logic Pro.
- **No CC-BY-NC weights** (MMS, the default ctc-forced-aligner model, becruily deux).
- Image size: about **12–12.5 GB compressed** and 18–20 GB on disk [I]. Endpoint container disk is **30 GB**.
- Without ASR the image is about 7.6 GB. That is the fallback if pulls are slow (risk R7).
- **(revised)** Pulls are not billed [V](https://docs.runpod.io/serverless/workers/overview), so image size costs latency, not money. What costs money is the model **load** at process start, which is billed. So only the separator (0.2 GB) and the aligner (1.84 GB) load at import; ASR and htdemucs_ft load lazily.
- **(revised)** Weights compress poorly, so `docker/build-push-action` should push with `compression-level=1` for gzip (the default level spends minutes on a single core for almost no gain) [I]. Don't switch to zstd until RunPod is known to pull zstd layers.

### 2.3 Handler contract and versioning

**Versioning rules:**

- `v` is an integer major version.
- New optional fields do **not** bump `v`. Both sides ignore unknown fields.
- A breaking change becomes `v: 2`. The worker accepts `[1, 2]` for at least one release, and `selftest` reports `supported: [1]`, so the app can send the highest version both sides know.
- An unknown `v` or `op` fails fast with `UNSUPPORTED_VERSION` / `BAD_OP`, costing about one cold start.
- `schema/v1/*.schema.json` plus `examples/` are the single source of truth. A CI step (`ci/check-cloud-fixtures.sh`) fails if the Swift fixture copies drift.

**Input** (the /run body; for `storage: "presigned"`, the primary mode):

```json
{
  "input": {
    "schema": "pixl.cloudstudio.job", "v": 1, "op": "process",
    "jobKey": "6f1c2a9e-3b7d-4c11-9a0e-2d5f8b7c4e10",
    "client": {"app": "pixlaudio-ios", "build": "1.0 (412)"},
    "storage": "presigned",
    "audio": {
      "get":    "https://<acct>.r2.cloudflarestorage.com/pixl-cloud-studio/in/6f1c….m4a?X-Amz-Algorithm=…",
      "delete": "https://…/in/6f1c….m4a?X-Amz-…",
      "ext": "m4a", "bytes": 7712345, "sha256": "9b1c…", "durationMs": 241000
    },
    "tasks": ["instrumental", "lyrics"],
    "separation": {"quality": "standard"},
    "lyrics": {
      "mode": "auto", "language": "ko", "synced": true,
      "lines": [{"startMs": 12340, "endMs": 15800, "text": "…"}]
    },
    "output": {
      "codec": "aac", "kbps": 256,
      "put": {
        "instrumental": "https://…/out/6f1c…/instrumental.m4a?X-Amz-…",
        "lyrics":       "https://…/out/6f1c…/lyrics.json?X-Amz-…",
        "manifest":     "https://…/out/6f1c…/manifest.json?X-Amz-…"
      }
    },
    "guard": {
      "manifestGet": "https://…/out/6f1c…/manifest.json?X-Amz-…",
      "attemptGet":  "https://…/out/6f1c…/attempt.json?X-Amz-…",
      "attemptPut":  "https://…/out/6f1c…/attempt.json?X-Amz-…"
    }
  },
  "policy": {"ttl": 259200000, "executionTimeout": 900000}
}
```

**Guard (revised).** Queue-based endpoints retry automatically [V](https://docs.runpod.io/serverless/endpoints/endpoint-configurations), and the docs don't say how many times or when. A song that crashes the worker process (a host OOM-kill, a native crash in ffmpeg or torch) could therefore be billed up to `executionTimeout` again and again. A `/run` whose HTTP response is lost, and which the phone therefore sends a second time, would also be billed twice. Before it downloads anything, the handler:

1. GETs `guard.manifestGet`. If a manifest exists with `status: ok` and the same input `sha256`, it returns that manifest at once (`warnings: ["duplicate"]`). This costs a few hundred milliseconds of GPU time.
2. GETs `guard.attemptGet`, which holds `{"runpodJobId", "attempts"}`. If the object names **this** RunPod job id with `attempts ≥ 2`, the job is a platform re-delivery of a job that already died twice. The handler PUTs an error manifest (`POISONED`) and fails the job without processing.
3. PUTs the attempt object with `attempts + 1`, then starts the pipeline.

The phone's own resubmission gets a new RunPod job id, so it starts again from 1. The guard is optional in the schema (an old app may omit it); without it the worker just processes the job.

Field rules:

- **`tasks`**: a subset of `instrumental | vocals | stems4 | lyrics`. Every requested task needs a matching `output.put` key; `stems4` needs `drums`, `bass` and `other`.
- **`separation.quality`**:
  - `standard` is overlap 2;
  - `best` is overlap 4, about 2× the GPU time, and only for songs of 8 min or less.
- **`lyrics.mode`**:
  - `align` needs `lines`;
  - `transcribe` ignores `lines`;
  - `auto` aligns when there are lines and transcribes otherwise.
  - `synced: false` means plain lyrics with no line times; windows then come from VAD.
- **`lyrics.language`** is an optional ISO 639-1 hint from `NLLanguageRecognizer`. The worker also detects the script per line.
- **`output.codec`**: `aac` (kbps 128–256) or `flac`.
- **Volume fallback** (`storage: "volume"`): `audio.key = "in/<jobKey>.<ext>"` and no URLs. Outputs go to `/runpod-volume/out/<jobKey>/`. Keys must match `^in/[0-9a-f-]{36}\.(m4a|mp3|flac|wav|ogg|opus|webm)$`.
- **`op: "selftest"`** takes no audio. It returns the versions, GPU, VRAM, CUDA, model ids and `supported: [1]`.
- **`op: "bench"`** runs a synthetic 240 s stereo signal through every stage. It logs the seconds for each stage and the peak VRAM, and uploads nothing. Use it on the first deploy (risk R2).

**Output.** The job output is identical to `manifest.json`:

```json
{
  "schema": "pixl.cloudstudio.result", "v": 1, "jobKey": "6f1c…",
  "status": "ok",
  "error": null,
  "warnings": ["lyrics: 2 lines fell back to line timing"],
  "worker": {"version": "1.0.0", "gitSha": "abc1234def56", "gpu": "NVIDIA L4", "vramGB": 24, "cuda": "12.8"},
  "models": {"separator": "anvuew-bs-roformer-ft1", "stems4": null,
             "aligner": "qwen3-forced-aligner-0.6b", "asr": null},
  "input":  {"codec": "aac", "sampleRate": 44100, "channels": 2, "decodedSamples": 10628100, "durationMs": 241000},
  "outputs": {
    "instrumental": {"key": "out/6f1c…/instrumental.m4a", "bytes": 7801234, "sha256": "…",
                     "codec": "aac", "kbps": 256, "samples": 10628100}
  },
  "lyrics": {"key": "out/6f1c…/lyrics.json", "mode": "aligned", "language": "ko",
             "lines": 48, "wordTimedLines": 46, "words": 312},
  "timings": {"coldStartMs": 18400, "downloadMs": 900, "decodeMs": 700, "separateMs": 12100,
              "stemsMs": 0, "lyricsMs": 2600, "encodeMs": 1900, "uploadMs": 1200, "totalMs": 19400}
}
```

- **`status`**:
  - `ok`;
  - `partial`, when the instrumental is delivered but lyrics failed, with the reason in `warnings`;
  - `error`, with `error = {"code", "message"}`.
- **Codes:** `BAD_SCHEMA, UNSUPPORTED_VERSION, BAD_OP, BAD_URL, INPUT_TOO_LARGE, INPUT_MISMATCH, TOO_LONG, UNSUPPORTED_FORMAT, DECODE_FAILED, GPU_OOM, DEADLINE, UPLOAD_FAILED, INTERNAL`, plus **(revised)** `POISONED` (the guard refused a third delivery) and `INPUT_MISSING` (the input GET returned 404, so the app re-uploads instead of retrying blindly).
- **On `error`**, the handler still PUTs the manifest, so the phone learns of the failure after /status has expired. It then returns `{"error": "<CODE>: <message>"}`, so RunPod marks the job FAILED.
- **On CUDA OOM or a poisoned state**, it also returns `refresh_worker: true` so RunPod recycles the worker. **(revised)** This is now [V](https://docs.runpod.io/serverless/workers/handler-functions): the handler returns a dict containing `refresh_worker`, which RunPod strips from the output. The next job then pays a cold start, so use it only on those two paths.
- **`coldStartMs`** is reported only on the first job of a process (0 afterwards), so the app can attribute cost.
- **Progress:** `runpod.serverless.progress_update(job, "separate:40")`, in the form `stage:pct` [V](https://docs.runpod.io/serverless/workers/handler-functions).

**`lyrics.json`** (`pixl.cloudstudio.lyrics` v1):

```json
{"schema": "pixl.cloudstudio.lyrics", "v": 1, "mode": "aligned", "language": "ko",
 "lines": [{"i": 0, "startMs": 12410, "endMs": 15620, "text": "<original line, unchanged>", "timing": "word",
            "words": [{"startMs": 12410, "endMs": 12890, "text": "원문", "conf": 0.94, "c0": 0, "c1": 2}]}]}
```

- `c0` and `c1` are UTF-16 offsets into the original line. The aligner strips punctuation, so the app rebuilds the words exactly from the original text.
- `timing` is `word` or `line` (the fallback).
- `mode: "transcribed"` marks machine-written text.

### 2.4 Pipeline, timeouts and safety caps

| # | Stage | What it does | Limit |
|---|---|---|---|
| 0 | validate | Checks schema, `v`, `op`, the jobKey regex, URLs (below), the lyrics caps and a body of 256 KB or less. | — |
| 0b | guard (revised) | The duplicate and poison checks above: 2 small GETs and 1 small PUT. | 10 s |
| 1 | fetch | Streaming GET with no redirects. Aborts above the byte cap. Checks `bytes` and `sha256` (`INPUT_MISMATCH`). | connect 10 s, total 120 s, 3 tries with backoff |
| 2 | probe | `ffprobe` on the **local file**. Exactly one audio stream; format and codec allowlist; duration within the cap. **(revised)** Ignore `attached_pic` streams (cover art in M4A and MP3 shows up as a video stream), reject any other video stream, and decode with `-map 0:a:0`. | 15 s |
| 3 | decode | `ffmpeg -protocol_whitelist file -f <probed fmt>` → f32 44.1 kHz stereo. Records `decodedSamples`; edit lists are honoured, so AAC priming is removed. | 60 s |
| 4 | separate | BS-RoFormer fp16 autocast, chunk 960000, overlap 2 (or 4 for `best`), batch 2. Instrumental = mix − vocals. | stage budget 300 s |
| 5 | stems4 (optional) | Lazy-loads htdemucs_ft and runs it on the instrumental (shifts 1, overlap 0.25) to get drums, bass and other. | 180 s |
| 6 | lyrics | Vocals → 16 kHz mono. **(revised) Offset check first:** cross-correlate the LRC line starts with a vocal-activity envelope, over ±30 s. If the best global shift is more than 1 s, apply it and report `lyricsOffsetMs`. A YouTube video with a spoken intro, or a radio edit, otherwise puts every ±1.5 s window in the wrong place. If no shift reaches a minimum correlation, align with `synced: false` windows instead. **Align:** windows are the LRC line times ±1.5 s, batched through Qwen3-ForcedAligner. **(revised)** Each aligner call is at most 5 min of audio [V model card], and the aligner covers only zh, en, yue, fr, de, it, ja, ko, pt, ru and es [V card]; any other language gets line timing straight away. **Transcribe:** lazy-loads Qwen3-ASR-1.7B on VAD chunks of 180 s or less, then aligns. **Post-process:** monotonic times, minimum word length 50 ms, line fallback when words collapse, offsets mapped back to the original text. | 240 s |
| 7 | encode + upload | `ffmpeg` AAC 256k `+faststart` (or FLAC). PUTs each output with its Content-Type, then **`manifest.json` last**. | encode 60 s; 120 s per PUT, 3 tries |
| 8 | cleanup | Presigned DELETE of the input (best effort; **(revised)** only after an `ok` or `partial` manifest, so a failed job can be retried without uploading again), `rm -rf /tmp/<jobKey>`, `torch.cuda.empty_cache()`. | 10 s |

- **Global deadline:** `policy.executionTimeout − 30 s` (default 870 s). It is checked between stages and inside the chunk loops, and ends in `DEADLINE` with the manifest still written.
- **Model loading:**
  - The separator and the aligner load at import, so their load is billed once per process.
  - ASR and htdemucs_ft load lazily on first use.
  - Weights are never downloaded at runtime (`HF_HUB_OFFLINE=1`).
- **Concurrency:** one job per worker (the SDK default). Stages run one after another, so peak VRAM stays well under 16 GB [I].

**Safety caps** (environment variables with defaults, enforced server-side whatever the app sends):

| Env | Default | Purpose |
|---|---|---|
| `PIXL_MAX_INPUT_MB` | 60 | Byte cap on the streamed download (a 15-min song at 256k AAC is about 29 MB). |
| `PIXL_MAX_AUDIO_S` | 900 | Duration cap, checked by ffprobe and again on the decoded sample count. |
| `PIXL_BEST_MAX_AUDIO_S` | 480 | Overlap 4 only on songs of 8 min or less. |
| `PIXL_MAX_LYRICS_LINES` / `_CHARS` | 500 / 20000 | Size of the lyrics payload. |
| `PIXL_MAX_BODY_KB` | 256 | Size of the job input; RunPod's own cap is 10 MB [V]. |
| `PIXL_ALLOWED_HOST_SUFFIXES` | **(revised)** `<account-id>.r2.cloudflarestorage.com`, set by the deploy (the account id is not secret) | Allowlist for URLs: HTTPS only, the host must match, the resolved IP must be public, no redirects, and the query must carry `X-Amz-Signature`. The plain `.r2.cloudflarestorage.com` suffix would accept any Cloudflare account's bucket. |
| `PIXL_ALLOWED_FORMATS` | `mov,mp4,m4a…`, `mp3`, `flac`, `wav`, `ogg`, `matroska,webm`, `aac` | ffprobe demuxers. hls, concat and anything else that reads other files is rejected. |
| `PIXL_ALLOWED_CODECS` | aac, mp3, flac, alac, opus, vorbis, pcm_* | Decoder allowlist. |

**Endpoint-level limits:** `timeout` 900 s, `workers.max` 1, `idleTimeout` 10 s. Per request the phone sets **`ttl` to 3 days** and **`executionTimeout` to 900 s**. The ttl is a hard kill that covers queue time [V](https://docs.runpod.io/serverless/endpoints/send-requests).

- **(revised) Worst-case billed time per job** is therefore 900 s, about $0.17 on a 24 GB card, and the guard caps one job at 2 deliveries, so about $0.35.
- **(revised) Worst-case billed time per crashing process** is the init timeout. RunPod marks a worker unhealthy when its *cold start* (model load, which is billed) passes 7 min. Image download is separate and unbilled [V](https://docs.runpod.io/serverless/development/optimization). v1 raised this to 800 s with `RUNPOD_INIT_TIMEOUT` to cover slow image pulls, but pulls don't count towards it, and the higher value only lets a hung model load bill longer. **Drop it** and keep the default. Loading 2 GB at import should take well under a minute [I]; `op: bench` measures it.

### 2.5 Storing results for "process later", and retention

| Where | What | How long | Who cleans up |
|---|---|---|---|
| RunPod queue | the job (input JSON with presigned URLs) | until it runs, at most `ttl` = 3 d [V] | RunPod |
| RunPod /status | job output (= manifest) | **30 min** after completion; fixed [V](https://docs.runpod.io/serverless/endpoints/operation-reference) | RunPod |
| R2 `in/` | the uploaded song | until the worker's DELETE or the phone's DELETE; **(revised) lifecycle 7 d** as a backstop (was 3 d) | worker → phone → lifecycle |
| R2 `out/<jobKey>/` | stems, lyrics.json, manifest.json, attempt.json | until the phone imports and DELETEs them; **(revised) lifecycle 30 d** as a backstop (was 14 d) | phone → lifecycle |
| R2, any other prefix | nothing the app writes, except `probe/` | **(revised)** a bucket-wide catch-all rule deletes after 30 d, so a leaked token can't turn the bucket into permanent free storage on the owner's account | lifecycle |
| Phone `CloudJobRecord` | job history and cost | 30 d after import, then pruned | app |

- **(revised) Why the lifecycle values changed.** R2 lifecycle ages an object from its upload and deletes it "typically within 24 hours" after expiry [V](https://developers.cloudflare.com/r2/buckets/object-lifecycles/). In v1 the `/run` could go out hours or days after the upload: the app may be suspended between the two, and submission waits for the whole batch. A 3-day queue ttl on top of that could then outlive a 3-day `in/` rule, and the job would fail on a 404 after its cold start. `out/` goes to 30 d because a sideloaded app can stay unopenable for days, for example when its signing has expired (section 7.4). 100 uncollected songs are about 1 GB, well inside the 10 GB-month free tier.
- **Presigned URL expiry:** `ttl + executionTimeout + 1 h` (about 76 h), **(revised) counted from submission**, because the phone now signs the worker's URLs when it sends `/run` (section 1, step 3). That is well inside R2's 7-day maximum [V](https://developers.cloudflare.com/r2/api/s3/presigned-urls/). An expired worker URL is therefore always a job that never ran. In v1 the URLs were signed at upload time, so a late submission could hand the worker URLs that had already expired.
- **(revised) `/status` 404** means the job's 30-minute retention, or its ttl, has passed [V](https://docs.runpod.io/serverless/endpoints/send-requests). It is not an error: the phone checks `/health` (200 means the endpoint is fine) and then R2.
- **Finding results after /status expires:**
  - The phone runs one `ListObjectsV2 prefix=out/ delimiter=/`, or a `HEAD out/<jobKey>/manifest.json` for each pending job, signed with its own token.
  - A job with no manifest and a ttl that has passed is "lost". The phone resubmits it once with the same `jobKey`; the outputs are simply overwritten.
- **Volume fallback:** with `max=1`, only one worker writes, so the multi-writer corruption warning [V] does not apply. At startup the worker sweeps `in/` entries older than 7 days and `out/` entries older than 30 days (revised, to match the R2 lifecycle).

### 2.6 Logging

- **Format:** one JSON object per line on stdout, which RunPod captures. Fields: `ts, level, event, jobKey, runpodJobId, stage, ms, gpu, vramPeakMB, worker`, where `worker` is the version plus git sha.
- **Events:** `boot`, `models_loaded`, `job_start`, `stage_done`, `job_done`, `job_error`.
- **Redaction:**
  - URLs are logged as `host/path` only. A regex strips any `X-Amz-*` query from exception text and tracebacks.
  - Never log lyrics text, titles, artist names or job input bodies.
- **Where to read the logs:**
  - the RunPod console (endpoint → Logs);
  - `GET /v2/serverless/{id}/workers/{workerId}/logs`, an SSE stream [V: openapi-v2], which the deploy script streams during the selftest.
  - The timings also come back in every manifest, so the app keeps per-job seconds, GPU and cost.
- **The repo is public, so Actions logs are public.** Workflows print only pass/fail lines. The endpoint ID is masked (`::add-mask::`), and spend amounts are never printed.

---

## 3. Build and deploy

### 3.1 `cloud-worker-build.yml`

```yaml
on:
  push:   {branches: [main], paths: ['cloud/runpod-worker/**', '.github/workflows/cloud-worker-build.yml']}
  pull_request: {paths: ['cloud/runpod-worker/**']}       # unit tests only; never pushes an image
  workflow_dispatch: {}
permissions: {contents: read, packages: write}
concurrency: {group: cloud-worker-build-${{ github.ref }}, cancel-in-progress: true}
jobs:
  test:      # ~2 min: docker build --target test && docker run (pytest, CPU-only)
  image:
    needs: test
    if: github.event_name != 'pull_request'
    runs-on: ubuntu-24.04
    timeout-minutes: 90
    steps:
      - free disk (3.2)  →  checkout  →  setup-buildx  →  login ghcr.io with GITHUB_TOKEN
      - build-push (context cloud/runpod-worker, target final, platform linux/amd64, push: true, no --load,
          provenance: false, tags: ghcr.io/redsn0w1877/pixl-cloud-worker:sha-<12>,
          build-args: GIT_SHA,
          (revised) tags: …:sha-<12> and …:main,
          cache-from: type=registry,ref=…:main   cache-to: type=inline,
          outputs: type=image,compression=gzip,compression-level=1,push=true)
      - df -h before and after the build, kept in the job summary (revised: measures section 3.2's estimate)
      - prune old package versions (keep the 5 newest sha tags, `main`, and whatever tag the endpoint runs now)
```

- Third-party actions (`docker/*`, `actions/delete-package-versions`) are **pinned to commit SHAs**.
- `provenance: false` keeps a plain image manifest, in case RunPod mishandles attestation indexes [I].
- Deploys use only `sha-<12>` tags, never `latest`. RunPod caches by tag [V](https://docs.runpod.io/serverless/endpoints/rolling-releases). **(revised)** `main` is only a build-cache source, never deployed.
- **(revised) Inline cache, not `mode=max`.** A `mode=max` registry cache exports every intermediate layer, including v1's whole `weights` stage as one ~7 GB layer. That layer would be pushed a second time, would be a second on-disk copy during export, and would come close to GHCR's 10 GB layer cap once D7 or D2 add weights. The inline cache stores only metadata in the image config. Together with `--link` layers whose cache key is a checksum, a warm build resolves the weights layers from the registry without downloading them [I: BuildKit lazy remote refs; the first two builds' `df -h` and push logs confirm it].

### 3.2 Disk-space strategy (GitHub-hosted runner)

- GitHub documents a 14 GB SSD for ubuntu runners [V](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). In practice the root volume has more free space, especially after cleanup, but no number is documented, so the workflow measures it and fails early [I].
- **(revised) What the disk must hold.** v1 kept each weight file four times: in the `weights` stage snapshot, in the final-stage COPY snapshot, as the image's compressed blob, and as the `mode=max` cache blob of the weights stage. That is about 28 GB for 7.1 GB of weights. Add the base image (4.3 GB of blobs plus about 8–9 GB unpacked) and deps (about 2 GB), and the peak was around 42 GB, above the 40 GB "fail early" line [I].
  With `ADD --link --checksum` and an inline cache, each file is held twice (its snapshot and its compressed blob), about 14 GB. A cold full build then peaks around 30 GB [I]. A warm build that changes only `src/` needs almost nothing, because cached `--link` layers are not unpacked [I].
- **Step 1.** `df -h`, then delete preinstalled toolchains: `/usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL /usr/local/share/boost`, then `docker system prune -af`. This typically frees about 25–30 GB [I]. If `/mnt` exists, point the Docker `data-root` at `/mnt/docker`. **(revised)** Fail early if less than 35 GB is free.
- **Step 2.** Push straight from BuildKit (`push: true`, no `--load`), so the image is never stored twice.
- **Step 3. (revised)** Weights layers are keyed by their sha256 (`--checksum`) and don't depend on their parent (`--link`). They are rebuilt and re-uploaded only when `weights.lock` changes, never because `requirements.lock` or the base digest changed. Their digests stay stable, so RunPod hosts that already pulled them don't pull them again after a deploy.
- **Step 4.** Each weight file is its own layer, all under GHCR's **10 GB per layer / 10-minute upload** limits [V](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry). **(revised)** The largest is the 4.22 GB ASR shard; at a typical runner-to-GHCR rate of 50 MB/s or more it uploads in under 2 minutes [I].
- **Fallback.** If the free runner still runs out of disk, use RunPod's GitHub integration: 80 GB images, a 30-minute `docker build` inside a 160-minute window, triggered by a GitHub *release* [V](https://docs.runpod.io/serverless/workers/github-integration). **(revised)** It also keeps the image private in RunPod's registry, which removes the public-distribution licence duties (section 5, Licences), but it means connecting RunPod's GitHub app to the owner's account. The other option is the slimmer no-ASR image, with ASR as a RunPod cached model (R7).

### 3.3 `cloud-worker-deploy.yml` and `deploy/runpod_deploy.py`

**Trigger:**

- `workflow_run` of cloud-worker-build (completed, success, branch main);
- `workflow_dispatch` with inputs `image_tag`, `selftest` (default true), `bench` (default false) and `extra_pools` (default none).

**Job settings:** `environment: runpod`, which holds the secret `RUNPOD_API_KEY`; its deployment branches are restricted to `main`. `permissions: contents: read`. Concurrency `cloud-worker-deploy`, never cancelled.

`deploy/endpoint.json` (desired state; REST v2 field names [V: openapi-v2.json `CreateEndpointRequest`]):

```json
{
  "name": "pixl-cloud-studio",
  "type": "QUEUE",
  "disk": 30,
  "gpu": {
    "pools": ["AMPERE_16", "AMPERE_24"],
    "excludedTypes": ["NVIDIA RTX 2000 Ada Generation"],
    "count": 1,
    "minCudaVersion": "12.8"
  },
  "workers": {"min": 0, "max": 1, "idleTimeout": 10},
  "scaling": {"type": "QUEUE_DELAY", "queueDelay": 4},
  "flashboot": "FLASHBOOT",
  "timeout": 900000,
  "env": {
    "PIXL_MAX_AUDIO_S": "900", "PIXL_MAX_INPUT_MB": "60", "PIXL_BEST_MAX_AUDIO_S": "480",
    "PIXL_ALLOWED_HOST_SUFFIXES": "<account-id>.r2.cloudflarestorage.com",
    "PIXL_LOG_LEVEL": "INFO"
  }
}
```

(revised) `RUNPOD_INIT_TIMEOUT` is removed (section 2.4), and the host allowlist is pinned to the owner's R2 account. The account id comes from a GitHub environment *variable*, not a secret.

- **GPU list in price order:** AMPERE_16 (A4000/A4500/RTX 4000 Ada; $0.58/h, $0.000161/s), then AMPERE_24 (L4/A5000/3090; $0.69/h, $0.000192/s) [V](https://docs.runpod.io/serverless/endpoints/endpoint-configurations).
  - The slow RTX 2000 Ada is excluded; per-second prices are flat within a pool. Check the exact type id against `GET /v2/catalog/gpus`.
  - ADA_24 (4090, $1.10/h) is added only through `extra_pools` if cheap GPUs are scarce.
  - In v2, workers go to "whichever listed pool has capacity" [V], so the order is **not** a preference. That is acceptable, because per-song cost is roughly equal across these pools [I]. **(revised)** The two doc pages disagree here: the endpoint-configuration page says the list is a priority order, and that with fewer than 5 workers "all workers use the highest-priority GPU type available" [V](https://docs.runpod.io/serverless/endpoints/endpoint-configurations). Keep AMPERE_16 first either way, and let `op: bench` (which records the GPU) show what actually happens.
- **`flashboot` must be set explicitly.** The API default is OFF [V].
- **No `dataCenterIds` and no `networkVolumes`**, so the scheduler can place workers anywhere. The volume fallback adds both.

**What the script does** (stdlib `urllib` only, idempotent):

1. **Check the image can be pulled anonymously.** Fetch an anonymous token from `ghcr.io/token`, then HEAD the manifest. On 401/403, fail with the message "make the package public (owner step B3)". RunPod rejects image references that don't resolve [V].
2. `GET /v2/serverless` and find the endpoint by `name`.
3. **Create or update:**
   - If it is missing: `POST /v2/serverless` with `endpoint.json + image`.
   - Otherwise: `PATCH /v2/serverless/{id}` with the image and the fields that changed. **Always send `gpu.pools` and `gpu.excludedTypes` together**, because a PATCH with only `pools` clears the exclusions [V].
   - **(revised)** A PATCH that carries `env` **replaces the whole env** [V: openapi-v2 `UpdateEndpointRequest`], so the script always sends the complete `env` from `endpoint.json`, never a diff. Changes to `image` or `env` create a new release that rolls out as workers cycle; `workers.max` alone does not [V: update-endpoint reference].
4. **Wait for the rollout.** Poll `GET /v2/serverless/{id}/releases` until the new image is rolling out or active (up to 15 min; it rolls out as workers cycle [V]).
5. **Selftest:** `POST https://api.runpod.ai/v2/{id}/runsync?wait=300000` with `{"input":{"v":1,"op":"selftest"}}`. Pass if `worker.gitSha` matches; retry 3× while old workers drain. Costs about 1 cold start, roughly $0.01. If `bench` is set, also run `op:bench` and stream the worker logs.
   - **(revised) Concurrency check (W1, with `bench`).** Queue 3 `op: bench` jobs at once. Every 5 s, poll `GET /v2/serverless/{id}/workers` and record the peak `summary.running`. The workers page says the system "may also spin up extra workers during traffic spikes … (default: 2)" [V](https://docs.runpod.io/serverless/workers/overview), and it does not say whether those count against `workers.max`. If the peak is above 1, every "max 1" cost bound in this design is off by up to 3×. Record the result in the handoff note.
6. **Print safely:** `::add-mask::` the endpoint ID before printing anything. Print only `created|updated`, the release state, the selftest GPU and the cold-start seconds.

### 3.4 `cloud-worker-keepalive.yml`

- **Schedule (revised):** `cron: '17 6 * * *'` (daily, was every 2 days) plus `workflow_dispatch`, in `environment: runpod`. Runs are free on a public repo, and daily runs shrink a paused endpoint's gap from up to 2 days to 1, well inside the 3-day job ttl.
- **What it does:**
  1. `GET /v2/serverless/{id}`. If `workers.max < 1`, `PATCH {"workers":{"max":1}}`. This undoes RunPod's idle scale-down: after 3 idle days max workers drops to 2, and after 7 to 0 [V](https://docs.runpod.io/serverless/endpoints/endpoint-configurations#idle-endpoint-scale-down).
     - **(revised)** RunPod *also* sets max workers down when an endpoint "consistently produces unhealthy (crashing) workers", and warns that it may do so again if the problem isn't fixed [V](https://docs.runpod.io/serverless/troubleshooting). A blind restore would re-arm a crash loop, and every crash bills its model-load time. So the keepalive first reads `GET /v2/serverless/{id}/workers`. If `summary.unhealthy > 0`, or the last deploy's selftest failed, it does **not** restore. It **fails the run** instead, which emails the owner.
  2. `GET https://api.runpod.ai/v2/{id}/health`. **(revised)** This probably does *not* reset the idle timer: the docs speak of "requests", meaning jobs. Treat it only as a reachability check, and rely on step 1 to undo the scale-down. Sending a real job every day would cost a cold start each time (about $0.15–0.30 a month) for no gain.
  3. `GET /v2/billing/serverless?serverlessId={id}&bucketSize=day&lastN=7`. If the 7-day sum is above `vars.CLOUD_WEEKLY_ALARM_USD` (default 2), **fail the run**. GitHub emails the owner about failed scheduled runs. The amount is never printed.
- **Caveat:** GitHub disables scheduled workflows in public repos after 60 days with no repo activity [I: GitHub docs]. The app also detects a paused endpoint (section 7.4; v1 said 7.6, revised).

### 3.5 What the owner does: the complete list, done once (about 15 minutes)

Every key goes **straight from the provider's page into the GitHub secret field or the app's settings field**, ideally in Safari on the iPhone. Keys never go into chat, an issue, a commit or a note.

**A. RunPod console** (runpod.io)
1. **Billing:** add **$10** of credit. It is non-refundable [V]. Leave **auto-pay off**, and turn on the **low-balance email alert at $3**.
   - **(revised)** The owner already has a RunPod account from the Android worker. **Check that auto-pay is off on it**, delete or disable the old Demucs endpoint and its old full-access key, and note the existing balance: the prepaid ceiling is whatever balance the account holds, not just the new $10.
   - **(revised)** RunPod bills every 5 minutes [V](https://docs.runpod.io/accounts-billing/billing), so the balance can briefly go slightly below $0 before everything stops. Prepaid cards need deposits of at least $100 [V], so use a normal card for a $10 top-up.
2. **Settings → API Keys → Create**, named `pixl-deploy`, with permission **All**. Copy it and go straight to step B2.

**B. GitHub** (repo RedSn0w1877/pixlaudio-ios)
1. **Settings → Environments → New environment** named `runpod`. Under **Deployment branches**, choose *Selected branches* and add `main`.
2. In that environment, **Add secret**: `RUNPOD_API_KEY` = the key from A2.
3. After the first **cloud-worker-build** run is green, make the package public: **your profile → Packages → pixl-cloud-worker → Package settings → Change visibility → Public**. This is needed once, because new packages start private [V].
4. **Actions → cloud-worker-deploy → Run workflow**. Only the first time; later deploys are automatic.

**C. RunPod console again**
5. **Serverless → pixl-cloud-studio:** copy the **Endpoint ID** into the app (step E).
6. **Settings → API Keys → Create**, named `pixl-iphone`, permission **Restricted**:
   - `pixl-cloud-studio` → **Read/Write**;
   - everything else → **None** [V](https://docs.runpod.io/get-started/credentials).
   Paste it into the app.

**D. Cloudflare dashboard** (only for the recommended R2 storage)
7. **R2 → Create bucket** `pixl-cloud-studio` (automatic location). Cloudflare may ask for a payment method even on the free tier [I].
8. **Bucket → Settings → Object lifecycle rules (revised):** prefix `in/` deletes after **7 days**; prefix `out/` deletes after **30 days**; plus **one rule with no prefix** that deletes after **30 days**. A rule with no prefix applies to the whole bucket [V](https://developers.cloudflare.com/r2/buckets/object-lifecycles/). Keep the default rule that aborts incomplete multipart uploads after 7 days.
9. **R2 → Manage API tokens → Create**, with **Object Read & Write**, limited to **the bucket `pixl-cloud-studio`** only [V](https://developers.cloudflare.com/r2/api/tokens/). Paste the Access Key ID, the Secret, and the endpoint `https://<account-id>.r2.cloudflarestorage.com` into the app.

**E. iPhone app:** **Settings → Developer → Experimental → Cloud processing**:
- turn the switch on;
- paste the Endpoint ID, the RunPod key, the R2 endpoint, the bucket name, the access key and the secret;
- tap **Test connection**.

Revoking access: RunPod key toggle (disable or revoke), and delete the Cloudflare token. Neither needs a rebuild.

**(revised) F. One-time W1 checks with a throwaway Restricted key** (closes R15; about 2 minutes, no GPU cost):
- `PATCH https://api.runpod.io/v2/serverless/{id}` with `{"workers":{"max":2}}` must return 401 or 403. If it succeeds, the phone key can raise the GPU ceiling. Section 5's worst case is then "the whole balance, at up to $80/h", and the app must say so in Settings.
- `GET /v2/billing/serverless` must fail, and `POST /v2/serverless` must fail.
- `POST …/purge-queue`, `POST …/retry/{id}`, `/run` and `/status` on the endpoint should succeed. Record the results in the handoff note, then delete the key.

---

## 4. Storage choice

| | **Cloudflare R2 (recommended)** | RunPod network volume + S3 API (fallback) | /status only (rejected) |
|---|---|---|---|
| Survives "process later" | yes | yes | **no**: 30 min [V] |
| Presigned URLs | GET/PUT/DELETE, up to 7 d [V] | **not supported** [V](https://docs.runpod.io/storage/s3-api) | — |
| Credential on the phone | token **scoped to one bucket** [V] | S3 key with **access to every volume on the account** (revised: the Credentials page offers no scope option when creating one [V](https://docs.runpod.io/get-started/credentials)) | — |
| Credentials in the worker | **none** (presigned) | none (mounted at /runpod-volume) | none |
| Automatic expiry | lifecycle rules per prefix [V] | none; the worker sweeps | — |
| GPU placement | any datacenter | **pinned to the volume's datacenter**, which can limit GPUs [V] | any |
| Idle cost | **$0** under 10 GB-month free; egress free [V](https://developers.cloudflare.com/r2/pricing/) | **$0.70/mo** minimum (10 GB × $0.07) [V] | $0 |
| Extra account | Cloudflare | none | none |

**Recommendation: R2.**

- It is the only option where the worker holds no secret and the phone's storage key can't touch anything else.
- Nothing is pinned to a datacenter, it costs $0, and it cleans up after itself.

**Fallback: a RunPod network volume**, for an owner who wants no second provider.

- Choose an S3-API datacenter with good 16/24 GB supply, for example US-KS-2 or EU-RO-1. Check `GET /v2/catalog/gpus?include=AVAILABILITY` first.
- The deploy adds `networkVolumes` and `dataCenterIds`, and the jobs use `storage: "volume"`.
- The phone signs SigV4 *header* requests: there is no presign. Header signatures expire in hours, so background transfers must start within the 1 h skew window [V], or be re-signed on relaunch.
  - **(revised)** This fallback is worse than it looks on iOS. Any transfer the app creates while it is in the background is *discretionary* [V](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/isdiscretionary), so iOS may start it hours later, for example once the phone is on Wi-Fi and charging. By then its signature is past the 1-hour window and the request fails with 403. Every such transfer must therefore be created in the foreground, or retried after a re-sign. R2's presigned URLs (valid 24–76 h) don't have this problem.
  - **(revised)** If the account balance reaches $0, RunPod may eventually terminate network volumes, and their data can't be recovered [V](https://docs.runpod.io/accounts-billing/billing). With the prepaid-only policy that is a real failure mode: queued songs and finished results would be lost.
- The app's S3 code is shared between the two; only the signer mode differs.

**Rejected:** carrying the credentials in the worker (a RunPod secret) and having the phone ask for presigned PUTs. That needs a second always-reachable service (a CPU endpoint or an edge function), which means another cold start and more to maintain, for little gain on a single-user app.

---

## 5. Security

**Where each key lives:**

| Secret | Lives in | Scope | If it leaks |
|---|---|---|---|
| RunPod **All** key `pixl-deploy` | GitHub *environment* secret `runpod`, usable only by jobs on `main`; never on the phone | manages endpoints and billing | Revoke it in RunPod. Exposure is limited by: secrets are not passed to fork PRs; deploys only run from `main`; actions are pinned. |
| RunPod **Restricted** key `pixl-iphone` | iOS Keychain, account `cloud_studio_runpod_token`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | Read/Write on **one endpoint** [V] | Someone can queue jobs. **(revised)** Cost is capped by the **prepaid balance**. `max=1` × $0.69/h (about $16/day) caps it *only if* step F shows the key can't change `workers.max`, and the W1 concurrency check shows no extra workers. Otherwise the limit is the account's $80/h spend limit [V], which RunPod raises automatically over time [V], so a $10 balance could be gone within minutes. Disable the key with the toggle. |
| R2 token | iOS Keychain, account `cloud_studio_r2_secret`; the key id and endpoint in UserDefaults `cloud_studio_r2_*` | object read, write and delete on **one bucket** | Someone can read, write or delete the owner's queued songs and results. The lifecycle limits how long anything stays. **(revised)** They could also store their own data in the bucket. The catch-all lifecycle rule deletes it within about 31 days, and storage above the free tier costs $0.015/GB-month [V](https://developers.cloudflare.com/r2/pricing/). That is a nuisance, not a blow-up. |
| Presigned URLs | the job input stored by RunPod | one object, one method, about 76 h or less | read one song, or write one result slot |

- **Naming:** Keychain and UserDefaults names avoid the `_api_key / _model / _base_url / _system_prompt` suffixes. Otherwise `SettingsBackup.isKeychainKey` and `PreferencesModule` would export them [V: SettingsBackup.swift:183, PreferencesModule.swift:169-175].
- **Backups:** these keys are **never** included in backups.
- **`ThisDeviceOnly`** keeps them out of device-to-device migration. It still works for background tasks after the first unlock.
- **(revised) Sideloading.** Keychain items belong to the signing team's access group. If the owner re-signs the app under a different team (another sideloading tool or Apple ID), the app can no longer read them, and Settings must show "Cloud keys missing — paste them again" rather than failing silently. Re-signing under the same team keeps them.
- **(revised) What sits on disk.** A background-session request, including its `Authorization` header, is persisted by the system transfer daemon until it runs [I]. So `/run` POSTs are sent from the app process (section 7.4) and never as background tasks. Background tasks carry only presigned R2 URLs, which hold no reusable secret.

**What the app may do:**

- `/run`, `/runsync` (selftest only), `/status`, `/cancel` and `/health` on its one endpoint;
- object GET, PUT, HEAD, DELETE and List in its one bucket;
- read RunPod spend? **No.** The Restricted key probably can't, so the app shows estimates.

**What the app must not do:**

- create or modify endpoints, or change max workers;
- hold the All key;
- send anything before the **consent switch** is on, or send to non-HTTPS URLs;
- use the cloud **automatically or as a fallback**. The rule matches the local-AI decision: AutomaticStudioRunner stays local, and the cloud runs only batches the person confirmed;
- log keys, URLs with signatures, or lyrics.

**Input validation on the worker:** described in section 2.4. In short:

- schema and version allowlist;
- jobKey regex;
- URL host suffix allowlist, HTTPS, public IP, no redirects, signature present;
- streamed byte cap and SHA check;
- ffprobe on a local file with format and codec allowlists, so ffmpeg can't be led to read other files (no hls or concat);
- duration cap on both the probed and the decoded duration;
- lyrics size caps; enum checks;
- `subprocess` with argument lists only (never `shell=True`), each with a timeout;
- the global deadline.

**Abuse and cost caps, from outermost to innermost:**

1. **The prepaid balance ($10) is the hard ceiling.** Auto-pay is off; there is a low-balance alert at $3. **(revised)** The ceiling is the *whole* account balance, including anything left over from the Android experiments (step A1).
2. **RunPod limits:** `workers.max = 1`; endpoint timeout 900 s; per-job `executionTimeout` 900 s and `ttl` 3 d; RunPod's own $80/h account spend limit [V]. **(revised)** `workers.max = 1` is a hard concurrency cap only once the W1 concurrency check (section 3.3) shows no "extra workers".
3. **Keepalive alarm:** fails the run if a week's spend is above $2.
4. **Worker caps:** 15 min of audio, 60 MB of input, overlap 4 only up to 8 min. **(revised)** The guard allows at most 2 deliveries of one RunPod job and makes duplicate submissions nearly free (section 2.3).
5. **App guards:**
   - a per-batch confirm sheet with the estimated cost;
   - a monthly cap (default $3), after which submissions stop;
   - at most 200 songs per batch;
   - one `/run` per 100 ms or slower;
   - `/status` polled for running jobs only, at most every 15 s in the foreground.
6. **The worst case with a stolen phone key** is about 1 GPU × 24 h × $0.69 = **$16.6/day** until the balance runs out or the key is disabled. **(revised)** That holds only if step F passes. If the key can raise `workers.max`, the worst case is the whole balance within minutes. Either way the owner loses at most the prepaid balance, never more, because auto-pay is off.

**Privacy:** songs go only to the owner's own bucket and endpoint, and are deleted after import, or **(revised)** within 7 to 30 days by lifecycle at the latest. Nothing is shared.

**(revised) Licences.** A public GHCR image is *distribution*, so every licence's redistribution terms apply. Server-side use alone would not trigger them.

| Component | Licence | Duty when the image is public |
|---|---|---|
| anvuew BS-RoFormer ft1 checkpoint | GPL-3.0 (HF card tag) [V](https://huggingface.co/anvuew/BS-RoFormer) | Ship the GPL text, and point to the exact HF repo and commit as the source. The checkpoint is loaded as data by MIT code, so it doesn't relicense the worker [I; not legal advice]. The card names a dataset author, but not the training data or its licence. Fine for the owner's personal use; re-check before any paid use for others. |
| Kim Mel-Band RoFormer (D2 alternative) | MIT [V](https://huggingface.co/KimberleyJSN/melbandroformer) | Licence text. |
| Qwen3-ForcedAligner-0.6B, Qwen3-ASR-1.7B | Apache-2.0 [V](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) | Licence text, plus any NOTICE file from the repos. |
| htdemucs_ft weights, demucs | MIT [V PyPI] | Licence text. |
| msst code | MIT (repo); the PyPI metadata is empty [V] | Copy the repo's LICENSE. |
| ffmpeg from Ubuntu `apt` | GPL build (Ubuntu enables GPL components) [I] | GPL text, plus the package names and versions (`/opt/apt-versions.txt`) as the source pointer, in NOTICE. |
| CUDA and cuDNN in the PyTorch base image | NVIDIA's redistributable-runtime terms [I] | Nothing extra beyond keeping the base image's own licence files. |

If the owner would rather not publish anything, the alternatives are: a private GHCR package plus a RunPod "Container Registry Auth" credential (a classic PAT with `read:packages`, one more long-lived secret) [V](https://docs.runpod.io/get-started/credentials), or RunPod's GitHub integration (section 3.2, Fallback).

---

## 6. Cost and cold start

Assumptions [I]: a 4-minute song; FLOP-based speed estimates (to be measured with `op: bench`); RunPod Flex prices [V](https://www.runpod.io/pricing): 16 GB **$0.000161/s**, 24 GB **$0.000192/s**. Billing runs from worker start (model load) through execution and the 10 s idle timeout. Image pull is **not** billed [V](https://docs.runpod.io/serverless/pricing).

**Per song:**

| Case | Billed GPU s | 16 GB | 24 GB |
|---|---|---|---|
| Warm: instrumental + aligned lyrics (standard) | ~20 | $0.0032 | $0.0038 |
| + 4 stems | ~25 | $0.0040 | $0.0048 |
| Transcription instead of alignment | ~30 | $0.0048 | $0.0058 |
| `best` quality (overlap 4) | ~32 | $0.0052 | $0.0061 |
| Cold-start overhead per wake (load 15–25 s + idle 10 s) | 25–35 | $0.004–0.006 | $0.005–0.007 |
| One song on its own (cold + standard) | 45–55 | $0.007–0.009 | $0.009–0.011 |
| Worst case: cold, 4 stems, ASR, overlap 4, slow card | ~90 | ~$0.015 | ~$0.017 |

**Per 100 songs:**

| Case | Billed s | 16 GB | 24 GB |
|---|---|---|---|
| One burst, standard (one cold start) | ~2,035 | **$0.33** | **$0.39** |
| One burst, every option (4 stems + ASR + best) | ~4,750 | $0.76 | $0.91 |
| 100 songs sent one at a time (each cold) | ~5,000 | $0.81 | $0.96 |
| Worst case, every song | ~9,000 | $1.45 | $1.73 |

**Idle cost per month:**

| Item | Cost |
|---|---|
| RunPod endpoint (min 0) | $0 |
| R2 | $0 below 10 GB-month (about 660 uncollected songs/week at 15 MB) and ~1M writes |
| GHCR (public package) | $0 |
| GitHub Actions on the public repo | $0 |
| **Total** | **≈ $0/month** |

The volume fallback adds $0.70/month. Each deploy selftest is about $0.01.

**(revised) Failure-path costs.** These are the ways the bill can grow without anyone noticing:

| Failure | Billed per occurrence | Bound |
|---|---|---|
| Job hangs (deadlock, stuck CUDA call) | up to 900 s, about $0.17 | `executionTimeout`; the handler's own deadline normally ends it at 870 s |
| Worker crashes mid-job and RunPod re-delivers the job | up to 900 s per delivery | the guard: 2 deliveries, about $0.35 per song |
| Lost `/run` response, so the phone sends the job again | about 1 s (the guard returns the existing manifest) | the guard; if the first job is still running, the second waits in the queue and then returns the manifest |
| Model load crashes at import (bad weights, driver mismatch) | load time per attempt, about $0.003–0.005 | RunPod marks the worker unhealthy and eventually scales the endpoint down [V]; the keepalive won't restore it |
| Model load hangs | up to 7 min, about $0.08 | default init timeout (v1's 800 s override removed) |
| More than 1 worker during a burst | ×(1 + extra workers) for a few minutes | W1 concurrency check; prepaid balance |
| Keepalive or deploy selftests | about $0.01 each | only on deploys; the keepalive sends no jobs |

**Cold start:**

| Situation | Wall time | Billed |
|---|---|---|
| FlashBoot resume (recently idle worker) | ~0.2–2 s [V blog](https://www.runpod.io/blog/serverless-gpu-cold-starts-flashboot) | ~0 extra |
| Image cached on the host, new process (imports + 2.4 GB of weights) | 20–40 s [I] | 15–25 s |
| New host: pull a ~12 GB image | +2–6 min [I] | not billed [V] |
| First ASR use in a process | +10–15 s [I] | billed |
| No free GPU in the pools | minutes or more, job stays IN_QUEUE | not billed |

What this means for sporadic phone use: the first result arrives about **1–6 minutes** after the batch is submitted, then about **20–30 s per song**.

---

## 7. iOS app integration plan

**Prerequisites:**

- **Start after the 2026-10-07 build wave merges.** During the wave, the cloud work must not touch `LyricsChrome`, `LyricsView`, `LyricsMoreSheet`, `AISettingsSection`, `ModelCatalog` or `ModelManager`, and it must not add a cloud badge to the player.
- **Use the name "Cloud processing"** so it is not confused with "Cloud assistants".
- **Phase 0, the worker, can run now in parallel.** It touches no app code.

### 7.1 Files

**PixlCore**: pure Swift, zero dependencies, builds on Windows, no CryptoKit (inject it). Package.swift is unchanged.

- `PixlNet/Cloud/CloudJobSchema.swift`: `nonisolated` Codable/Sendable types for `CloudJobInputV1`, `CloudJobResultV1` and `CloudLyricsV1`, plus `CloudSchema.version = 1`.
- `PixlNet/Cloud/RunPodJobsClient.swift`:
  - an actor over the `HTTPClient` seam, with injected `nowMs` and `sleep`;
  - `run`, `status`, `cancel`, `health`, and `runsync` for selftest only;
  - a Retry-After gate in the SpotifyConnectClient style;
  - error mapping: 401/403 → `.unauthorized`, 404 → `.endpointNotFound` (or job expired), 429 → gate, 5xx → backoff.
- `PixlNet/Cloud/S3Signer.swift`:
  - SigV4 **query presign** for R2 (region `auto`, service `s3`, `UNSIGNED-PAYLOAD`, host-only signed headers);
  - **header signing** for the volume fallback;
  - injected `SHA256Function` and a new `HMACSHA256Function`;
  - a ListObjectsV2 XML parser (`#if canImport(FoundationXML)`).
- `PixlLibrary/CloudQueuePolicy.swift`: selection rules, caps (15 min, 200 per batch), the job state machine, the backoff ladder (1 → 5 → 15 → 60 min), presign expiry, the cost estimator (GPU name → pool price table), and the monthly-cap decision.
- `PixlAudioCore/CloudLyrics.swift`:
  - converts `pixl.cloudstudio.lyrics` v1 into a `LyricsDoc`, rebuilding words from the `c0/c1` offsets;
  - uses source `"cloud"`, with transcriptions flagged;
  - reuses `TaisLyricsAlignment.validateForSave`.

**App services** (`App/Services/Cloud/`):

- `CloudStudio.swift`: `@MainActor @Observable`. It is the orchestrator and holds the per-song state. Methods: `enqueue(songs:tasks:)`, `resume()`, `cancel(_:)`, `retry(_:)`.
  - Construct it in `AppEnvironment.init` next to `tais` (AppEnvironment.swift:191), because a background relaunch never runs `start()`.
- `CloudJobStore.swift`: `@ModelActor`, over a **separate container named "PixlCloud"** with `CloudSchemaV1: VersionedSchema` plus its own migration plan. The main store has never been migrated, so it is left alone (SchemaV1.swift:473-477).
  - `CloudJobRecord` fields:
    - identity: `jobKey`, `songId`, `videoId`, title and artist;
    - request: tasks, lyricsMode, language;
    - state: state, runpodJobId, inputKey and ext, sha256, bytes, durationMs, presignExpiry;
    - retries: attempts, nextAttemptAt, lastError;
    - telemetry: timings, gpu, coldStartMs, costMicroUSD;
    - results: outputs (key, bytes, sha), importedInstrumental and importedLyrics;
    - timestamps: createdAt, submittedAt, completedAt.
- `CloudTransfers.swift`: a background `URLSession` with id `io.github.redsn0w1877.pixlaudio.cloud`, used for both uploads (`uploadTask(with:fromFile:)` to a presigned PUT) and downloads.
  - **(revised)** Only presigned R2 transfers go through it. RunPod calls (`/run`, `/status`, `/health`) always use an ordinary session from the app process, because a background task persists its `Authorization` header (section 5).
  - **(revised)** Create uploads and downloads in the foreground whenever possible. iOS treats every transfer created while the app is in the background as discretionary and may hold it until Wi-Fi and power [V](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/isdiscretionary).
  - `taskDescription = "<jobKey>|<slot>"`.
  - `allowsConstrainedNetworkAccess = false`, so Low Data Mode is respected.
  - `allowsExpensiveNetworkAccess` follows the "Use cellular" setting.
- `CloudAudioPreparer.swift` (`@concurrent`):
  - **(revised)** an AAC-LC M4A/MP4 source with exactly one audio track is used as it is;
  - an `ipod-library` item goes through `AVAssetExportSession` passthrough (protected items never reach here: `MediaLibraryImporter` skips them [V: MediaLibraryImporter.swift:26]);
  - **(revised)** everything else, including HE-AAC (itag 139), the muxed video itag 18, MP3, Opus and lossless sources, is decoded with `AVAssetReader` and written as FLAC with `AVAudioFile` / `ExtAudioFile` (Apple frameworks only). This replaces v1's "lossless → AAC 256k". It keeps the player's decoder as the single source of truth for sample timing, and it never stacks one lossy encode on another;
  - it records the CryptoKit SHA-256, the duration and the decoded sample count;
  - files go in `Application Support/CloudStudio/uploads`, excluded from backup.
- `CloudResultImporter.swift`: section 7.5.
- `CloudCredentials.swift`: the Keychain accounts above, read off the main actor.
- `CloudPlatform.swift`: CryptoKit `HMAC<SHA256>` and `SHA256` injected into PixlNet.
- `CloudBackground.swift`: BGAppRefresh, URL-session relaunch, and continued processing (section 7.4).

**UI** (`App/Features/CloudStudio/`):

- `CloudProcessingSettingsView`, `CloudQueueView` and `CloudConfirmSheet`. The sheet uses the 92 % glass detent and never overrides `presentationBackground`.
- Routes `.cloudProcessing` and `.cloudQueue` in `App/Core/Routes.swift` and `RouteDestinations.swift`.
- `DemoScreen`s `cloud.settings`, `cloud.queue` and `cloud.confirm` in `UITestLaunchRouter`.

**Small hooks in existing files:**

- `StemSeparation.swift:274-317`: add the suffix `_cloud_inst.m4a` to the candidates (order: roformer wav, cloud m4a, MDX wav) and to `songId(fileName:)`. Never store AAC under a `.wav` name.
- `TaisStudio`: add `noteInstrumentalImported()` and `noteLyricsImported(song:)`, which bump the revisions and mirror `reloadLyricsIfShowing`.
- `TaisLyricsAlignment.lyricsDoc(source:)`: add the `source` parameter.
- `TaisStudioProgressCard`: add a **Cloud** row.
- `PlaylistDetailView` ⋯ menus: add "Process all in the cloud".
- `AutomaticStudioRunner.isComplete/candidates`: skip songs that have a pending cloud job.
- `HomeStore.jobs`: add one summary, for example "Cloud: 12 waiting, 1 processing".
- `PixlAudioApp`: add `.backgroundTask(.appRefresh(".refresh"))` and `.backgroundTask(.urlSession(".cloud"))`, plus url-session handlers for the existing `downloads` and `models` sessions, which today have none.
- `project.yml:86-90`: add the identifiers `…cloud-prepare` (BGContinuedProcessing). `…refresh` is already declared and unused.
- **Required fix:** for `sp:` songs, `TaisServices.audioSource` (:39) and `DownloadManager.download` (:78) must first resolve `SpotifyPlayableURLResolver.videoId(for:)` and then download `youTubeSong(videoId:)`. Results stay keyed by the `sp:` id, and the videoId is re-checked on import.

### 7.2 Settings (Experimental first; a row under "Ready when you play" after the AI wave)

- **Consent switch:** "Send songs to my RunPod account". Off by default; nothing leaves the phone until it is on.
- **RunPod:** Endpoint ID and Restricted key (secure field).
- **Storage:** an R2 / Other-S3 / RunPod volume picker, then endpoint, bucket, access key id and secret.
- **Outputs:**
  - Instrumental: on.
  - Word-timed lyrics: on.
  - "Write lyrics when none are found (AI transcription)": on, labelled in the UI.
  - Quality: Standard/Best.
  - Stems: off, hidden until a stem mixer exists.
- **Network:** "Use cellular data": off.
- **Cost:** GPU tier price (editable, $0.000192/s default) and monthly cap ($3).
- **Test connection:**
  1. `GET api.runpod.ai/v2/{id}/health`: 200 → OK, showing queue and worker counts; 401/403 → key; 404 → wrong endpoint ID [V research].
  2. PUT, GET and DELETE of a 1-byte object at `probe/<uuid>` through presigned URLs.
  3. An optional "Run selftest (~1¢)" via `/runsync`, which shows the worker version and GPU.
- Built from `SettingsScaffold`, `SettingsTextField(secure:)`, `SettingsFillButton` and `GlassCard`.

### 7.3 The queue

**Where jobs come from:**

- the song sheet's Cloud row;
- playlist and album menus;
- the queue screen's "Add…", with: Current song / Songs without word-timed lyrics / Songs without an instrumental.

**Selection** runs off the main actor:

- Skip songs that already have an instrumental or catalog word-synced lyrics.
- Skip user-synced lyrics unless "Replace" is chosen.
- Skip songs with no local or fetchable audio, and songs over 15 min.
- One job per song covers all its missing tasks.

**Confirm sheet:** songs, minutes, upload MB, estimated cost, and the remaining monthly cap.

**States:** queued → preparing → uploading → uploaded → submitted ("Waiting for a GPU") → running (`stage %`) → resultsReady → downloading → imported. Side branches: failed, cancelled, expired. Failed jobs show the worker's error code with Retry.

**Batch submission is gated:** `/run` is sent once *all* the batch's uploads are done, or 2 minutes after the first one finishes. The worker then drains the queue warm.

**(revised) Streamed songs (YouTube, and Spotify matched to YouTube).** These fail in more ways than local files:

| Failure | What goes wrong | Handling |
|---|---|---|
| Bulk download refused | Fetching 100 streams back to back from one IP invites 403s and bot checks [I]. | Download at most 2 at a time, with jitter. At most 50 streamed songs per batch. Each failure is reported per song ("Couldn't fetch audio"), and the rest of the batch goes on. |
| Low-quality or odd format | itag 139 is 48 kbps HE-AAC; itag 18 is muxed video. The app plays AAC itags 141/140/139, then 18 [V: InnerTubeService.swift:13]. | Prefer 141 or 140. If only 139 or 18 is available, mark the song "low quality source" on the confirm sheet. Always decode to FLAC (section 7.1). |
| Wrong version for the lyrics | The matched video has an intro, outro or skit, or is a radio edit, so LRC times from the catalog don't match the audio. | Send `synced: true` only when the lyrics source's duration is within ±2 s of the audio's. Otherwise send `synced: false`. The worker's offset check (section 2.4, stage 6) is the second line of defence. |
| Playback uses a different file later | The instrumental is aligned to the uploaded bytes. If a later playback resolves another itag or file size, the Sing crossfade drifts. | Record `itag` and `contentLength` in `CloudJobRecord`. Enable the cloud instrumental only when the playing item matches them, or when the song is downloaded from the same itag. `StreamCache` already tracks both [V: StreamCache.swift:13-55]. |
| `sp:` mapping changes | The Spotify→YouTube match is redone and picks another videoId. | Re-check the videoId on import (section 7.1) and again before Sing uses the result. On a mismatch, hide the result and offer "Process again". |
| Region-locked, age-gated or members-only, or longer than 15 min | Can't fetch, or too long. | Skip at selection, with the reason shown. |
| Temp file deleted after upload | The import check can't decode the source again. | Use the sample count recorded at preparation (section 7.5). |

### 7.4 Background behaviour (no push, no extensions: product rule 5)

**(revised) What actually runs, by app state.** The GPU work needs nothing from the phone once `/run` has been accepted. Everything on the phone side does:

| App state | Uploads already started | `/run` submission | Watching for results | Downloads and import |
|---|---|---|---|---|
| Foreground | run | immediate | `/status` every ≥ 15 s for running jobs; R2 List on resume | immediate |
| Suspended (in the background, not force-quit) | continue in `nsurlsessiond` | only during a background wake (below) | BGAppRefresh, opportunistic: maybe a few times a day, maybe never; none in Low Power Mode or with Background App Refresh off | tiny files (manifest, lyrics.json) are fetched and imported during the wake; the instrumental is queued as a background download, which is **discretionary** because it was created in the background [V](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/isdiscretionary) |
| Terminated by the system | continue; iOS relaunches the app in the background when they finish [V](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)) | as for "suspended" | as for "suspended" | as for "suspended" |
| **Force-quit by the person** | **cancelled**, and the app is **not** relaunched for them [V same page] | none until the next launch | none (no BGAppRefresh either) | none until the next launch |
| Sideload signing expired / app won't open | none | none | none | none; results wait in R2 for 30 days (`out/` lifecycle) |

- **Upload and download:** a background URLSession. Transfers survive suspension, but a **force-quit cancels them** [V Apple]. The UI says so.
  - On relaunch, the `.urlSession` handler recreates the session and handles the events.
  - It then submits `/run` for batches whose uploads are complete, and imports finished downloads.
  - **(revised)** That wake lasts only seconds; the system calls the completion handler when it decides. Submitting runs inside `UIApplication.beginBackgroundTask` (about 30 s): presign → POST each job at least 100 ms apart → save each job id **before** the next POST. Whatever doesn't go out stays in "uploaded" and is sent at the next wake or launch. The guard (section 2.3) makes a duplicate POST after a lost response harmless.
- **Polling:**
  - `resume()` on becoming active: one R2 List of `out/`, `/status` only for running jobs, then downloads.
  - BGAppRefresh with `earliestBeginDate` about 15 min, scheduled only while jobs are in flight, within a ~25 s budget: List, then enqueue downloads, then reschedule. **(revised)** Order inside that budget: List → import the lyrics (KB-sized, fetched with a normal session) → queue the instrumental downloads → reschedule. Lyrics then show up even if the discretionary instrumental downloads wait for Wi-Fi and power.
- **Preparation:** a person-initiated "Send N songs" runs AAC encoding under `BGContinuedProcessingTaskRequest`, using the TaisBackgroundRun pattern and a new id. Small batches just run in the foreground. **(revised)** The request must be submitted from the foreground as the result of the person's tap [V](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest), and it needs no GPU entitlement, because AAC and FLAC encoding run on the CPU. "AAC encoding" here now means "decode to FLAC, or pass through" (section 7.1).
- **Paused-endpoint detection:** if jobs stay `IN_QUEUE` for more than 30 min while `/health` shows 0 idle and 0 running workers, show "RunPod paused this endpoint — run the keepalive workflow" (risk R5). **(revised)** That pattern also appears when no GPU is free in the pools, so the message names both causes.
- **Optional:** a local notification "Cloud results ready (12)" (UserNotifications, local only).
- **(revised) What the UI promises:** "Songs are processed on your RunPod account even when PixlAudio is closed. Results come back the next time PixlAudio runs, and are kept for 30 days. Swiping PixlAudio away stops uploads that haven't finished."

### 7.5 Importing results

1. Download to staging and verify `bytes`, `sha256` and `samples`. The sample count must equal the app's own decode of the source within ±1 frame (AAC priming check). **(revised)** For streamed songs the source file is gone, so compare with the sample count recorded at preparation. On a mismatch, don't import the AAC: submit the job once more with `output.codec: flac`. FLAC has no encoder delay, so it settles the question at about 4× the download size.
2. Instrumental: move it atomically to `Stems/<safeName>_cloud_inst.m4a`, then call `studio.noteInstrumentalImported()`. InstrumentalController, the Sing segment and OnDeviceModelsPanel pick it up unchanged.
3. Lyrics:
   - Right before writing, re-check `isUserSyncedStored`, and re-check whether catalog word-synced lyrics have arrived since submission.
   - Run `validateForSave`.
   - `LyricsService.save(song:rawContent:source:"cloud")`, then `noteLyricsImported`.
4. DELETE `out/<jobKey>/*` and `in/<jobKey>.*`. Record the cost and timings.

### 7.6 Tests

- **PixlCore** (Swift Testing; runs on the Linux `core` job):
  - schema round-trip against `cloud/runpod-worker/schema/v1/examples` (copied fixtures, with a CI drift check);
  - SigV4 against AWS's published presign and header test vectors, using the existing `TestSHA256` plus a test HMAC [V: PixlNetTests/TestSupport.swift:96];
  - `RunPodJobsClient` against a scripted `FixtureHTTPClient` (200/401/403/404/429/5xx, Retry-After);
  - `CloudQueuePolicy`: selection, caps, the state machine, backoff and cost;
  - `CloudLyrics`: offsets, CJK, line fallback, validation.
- **App** (XCTest):
  - importer naming and the atomic move (fixture m4a);
  - `CloudJobStore` CRUD in memory;
  - preparer bitrate and passthrough decisions;
  - the Keychain naming guard, asserting that the keys are not exported by SettingsBackup.
- **UI tests:** `cloud.settings`, `cloud.queue` and `cloud.confirm` screenshots in light and dark.
- **Worker** (pytest, CPU-only): schema, URL allowlist, caps, redaction, deadline, lyrics post-processing.
- **End to end:** after deploy, the selftest and bench steps; then the owner sends 3 songs from the phone (en / ko / ja) and checks the instrumental, the word timing and the cost line.

### 7.7 Order of work

| Step | When | Content |
|---|---|---|
| **W1** | now (parallel to the wave) | Worker, test target, schema and fixtures, the three workflows, the `ci.yml` `paths-ignore` line. Owner steps A–D. Deploy, then selftest and **bench**. Record the real timings in a handoff note. **(revised)** Also: owner step F (the Restricted key's rights), the concurrency check (peak running workers), the build's `df -h` peak, and one deliberate poison job (`op: bench` with a crash flag, test builds only) to see how many times RunPod re-delivers it. |
| **W2** | after W1 | A lyrics-quality probe: about 10 owner songs with trusted word timing (NetEase YRC), comparing the aligner against the on-device result. Decide whether the aligner is good enough on singing. **(revised)** First, count the library's lyric languages (decision D7). Include at least 2 streamed songs whose YouTube match has an intro, to exercise the offset check. |
| **P1** | after the wave merges | PixlCore: schema, S3Signer, RunPodJobsClient, CloudQueuePolicy, CloudLyrics, and their tests. |
| **P2** | after P1 | Prerequisites in existing files: StemFiles suffix, TaisStudio hooks, `lyricsDoc(source:)`, the `sp:` audio-source fix, url-session handlers for the existing sessions. |
| **P3** | after P2 | App/Services/Cloud plus the Settings screen (Experimental) and Test connection; single-song "Process in cloud" from the song sheet; demo screens. |
| **P4** | after P3 | Queue screen, playlist batches, confirm sheet, background (refresh, continued processing), HomeJob, AutomaticStudio skip, monthly cap. |
| **P5** | coordinated with the lyrics and AI groups | Cloud progress inside Sing and a "Better in the cloud" option; a row under "Ready when you play". Docs: `parity.md` (iOS-first, "Android later"), `api-notes.md` (BackgroundTask.urlSession, uploadTask(with:fromFile:), allowsExpensive/ConstrainedNetworkAccess, AVAssetWriter AAC settings, CryptoKit HMAC, a second ModelContainer, ThisDeviceOnly accessibility, UNUserNotificationCenter), `test-parity.md`, a dated handoff note. |

---

## 8. Optional Android follow-up

Same endpoint, same schema v1, same bucket. Work on `origin/android-int-oct3`.

- **Client:** extend `data/premium/CloudStudioClient.kt` with a `RUNPOD` backend. Keep its `consentToUpload` (fails closed) and its HTTPS-only rule. Android parses an unknown `tais_roformer_backend_type` as `GRADIO_SPACE`, so a new value degrades safely.
- **Background:** WorkManager. Upload and submit with `NetworkType.UNMETERED` by default; collection runs as a periodic worker (15 min) while jobs are pending.
- **Keys:** the Android Keystore or EncryptedSharedPreferences, kept out of `.pxpl` backups.
- **Retire the old pieces:** `tools/runpod-serverless` (Demucs, base64) and the f9f1a82 pod server, with a note pointing to `pixlaudio-ios/cloud/runpod-worker`.
- **Licence check if this ever powers the paid Plus tier for other people:**
  - The current stack is GPL-3.0 weights used server-side, plus MIT and Apache-2.0. Serving output is not distribution [I; not legal advice]. **(revised)** But the public image *is* distribution (section 5, Licences), and the anvuew training data's licence is unknown, so a paid tier needs its own review.
  - Never add CC-BY-NC models (MMS, becruily deux).
  - Per-user keys and quotas would then need a real backend. That is out of scope.

---

## 9. Owner decisions (recommended defaults in bold)

1. **Storage:** **Cloudflare R2** (free, bucket-scoped key, no datacenter pinning), or a RunPod network volume (no second account, but $0.70/month, an account-wide key, and one datacenter).
2. **Vocals model:** **anvuew BS-RoFormer ft1, GPL-3.0, vocals SDR 11.54**, or Kim Mel-Band RoFormer, MIT, about 11.05. The image is public, so GPL weights are redistributed with their licence and NOTICE. **(revised)** Note the size difference: anvuew is 0.2 GB with dim 256, Kim is 0.9 GB. The licence duties are in section 5.
3. **Songs with no lyrics:** **transcribe and save automatically, labelled "AI-written lyrics"**, or hold them for review, or don't transcribe at all. The last option makes the image about 4.7 GB smaller.
4. **Outputs:** **instrumental (AAC 256k .m4a) + word-timed lyrics**; vocals and 4 stems off until a stem mixer exists. No 6-stem model.
5. **Money:** **$10 prepaid, auto-pay off, alert at $3, max 1 worker, app cap $3/month, keepalive alarm at $2/week.**
6. **Spotify and YouTube songs:** **fetch to a temporary file just for the upload**, or download them permanently like Android does. **(revised)** With the temporary file, the Sing instrumental is valid only while playback resolves the same itag and file size (section 7.3). Downloading permanently removes that drift and costs storage on the phone.
7. **Languages beyond Qwen's 11** (e.g. Vietnamese, Thai, Indonesian): **none in v1, fall back to line timing**. Or add stable-ts + faster-whisper large-v3-turbo, about 1.6 GB more, for word timing in any Whisper language.
   - **(revised) Decide this from data, not by default.** The aligner covers only zh, en, yue, fr, de, it, ja, ko, pt, ru and es. Qwen3-ASR *transcribes* 30 languages including vi, th and id, but its word timestamps come from that same aligner [V model card]. So in those languages, "AI lyrics" can at best produce untimed text.
   - If a meaningful share of the owner's library is in one of those languages, the lyrics half of this feature mostly doesn't work. Before W2, run `NLLanguageRecognizer` over the library's stored lyrics on the phone and count the languages. If unsupported languages are above about 10 %, put the Whisper path into v1 (MIT code and weights; within GHCR's per-layer cap as its own layer).

---

## 10. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | The dependency stack is untested together: msst 0.1.0 is a month old; qwen-asr pins transformers 4.57.6 and nagisa/dynet; torch 2.11. | W1's `deps` stage with `pip check` and an import smoke test is the first gate. Fallbacks: vendor MSST at a commit; a faster-whisper ASR path. |
| R2 | Every speed and cost figure is a FLOP estimate. | `op: bench` on the first deploy. Re-tune the pools, overlap and idle timeout from real numbers. |
| R3 | Qwen3-ForcedAligner is documented for **speech**; its accuracy on separated singing is unverified. | W2 quality probe; line-level fallback; the on-device wav2vec2 path stays. |
| R4 | REST v1 retires 2026-11-15, and v2 has only been GA since 2026-08-18; schemas may drift. | v2 only. The deploy script validates responses and fails loudly; the desired state lives in `endpoint.json`. |
| R5 | Idle scale-down sets max workers to 0 after 7 days, stranding queued jobs. Scheduled workflows in public repos stop after 60 days of inactivity. **(revised)** RunPod also scales down endpoints that keep producing unhealthy workers. | **(revised)** Keepalive daily (was every 2 days); it doesn't restore while workers are unhealthy, and fails the run instead (email). The app detects a paused endpoint and points to "Run workflow". |
| R6 | Cheap GPUs are scarce, so jobs wait in the queue. | The queue wait isn't billed; ttl is 3 days; `extra_pools` can add ADA_24 or AMPERE_48. Not pinned to a datacenter. |
| R7 | The 12 GB image means slow first pulls (latency, not cost). **(revised)** The 7-minute limit applies to the billed model load, not to the pull [V](https://docs.runpod.io/serverless/development/optimization). | **(revised)** Keep the default init timeout (v1's `RUNPOD_INIT_TIMEOUT=800` removed); `--link` weights layers with stable digests, so a new deploy pulls only the code layer; option to drop ASR or move it to a RunPod cached model (unbilled download, one model per endpoint, console step) [V](https://docs.runpod.io/serverless/endpoints/model-caching). |
| R8 | Runner disk, plus GHCR's 10 GB layer cap and 10-minute upload limit [V]. | **(revised)** `ADD --link --checksum` per weight file (no weights stage), inline cache instead of `mode=max`, `df -h` logged; peak about 30 GB instead of about 42 GB [I]; fallback to RunPod's GitHub integration. |
| R9 | Public repo: Actions logs and package are public. | Environment secret limited to `main`; pinned actions; masked IDs; no spend in logs; no secrets in the image. |
| R10 | The phone holds billing-capable and storage tokens. | Restricted single-endpoint key; bucket-scoped token; ThisDeviceOnly; never backed up; instant revocation; the prepaid ceiling. **(revised)** Plus: RunPod calls never go through background sessions; a catch-all R2 lifecycle rule; the worker's host allowlist pinned to the owner's R2 account. |
| R11 | Presigned URLs sit in job inputs that RunPod retains. | Short expiry (about 76 h or less); per-object, per-method scope; only the owner's own data. |
| R12 | Licences: GPL-3.0 checkpoint in a public image; the unknown-provenance SW model. **(revised)** Also the GPL ffmpeg binary, and the anvuew training data's unknown licence. | LICENSES and NOTICE in the image, **(revised)** including ffmpeg's GPL text and apt versions (section 5, Licences); SW and CC-BY-NC models excluded; decision D2 offers MIT. |
| R13 | AAC priming or timeline offset breaks the 700 ms crossfade and word timing. | `decodedSamples` in the manifest is checked on import (±1 frame); ffmpeg honours edit lists; `+faststart`. **(revised)** Anything that isn't AAC-LC M4A is decoded on the phone and uploaded as FLAC; on a mismatch, the job is redone with FLAC output. |
| R14 | iOS background limits: force-quit; BGAppRefresh is opportunistic. **(revised)** Transfers created in the background are discretionary (Wi-Fi and power). | Results wait safely in R2 for **(revised)** up to 30 days and are collected on the next open; lyrics are imported inside the refresh window; the UI explains (section 7.4). |
| R15 | The Restricted key's exact rights (purge-queue, retry, runsync) are undocumented. **(revised)** So is whether it can change the endpoint's settings, which decides the leaked-key worst case. | Test with a throwaway key during W1 (owner step F); the app needs only run, status, cancel, health and runsync. |
| R16 | R2 needs a Cloudflare account and possibly a payment method. | Decision D1 fallback: the RunPod volume (code path kept). |
| R17 | The RunPod SDK volume bug (1.7.11–1.10.0). | Pin runpod 1.12.0. |
| R18 (revised) | Platform retries of a job that kills the worker process, or a duplicate `/run` after a lost response, bill again and again. The retry count isn't documented. | The guard (section 2.3): at most 2 deliveries; a finished manifest short-circuits. |
| R19 (revised) | "Extra workers" during spikes [V](https://docs.runpod.io/serverless/workers/overview) may exceed `workers.max = 1`. | W1 concurrency check; the prepaid ceiling; on a positive result, revise the cost bounds. |
| R20 (revised) | Streamed songs: wrong version for the lyrics, itag or file drift, bulk-download blocks. | Section 7.3's streamed-songs table; the worker's offset check. |
| R21 (revised) | The aligner's 11 languages leave vi, th and id (among others) without word timing. | D7, decided from a count of the library's languages before W2. |
| R22 (revised) | Presigned URLs signed at upload time, or a short `in/` lifecycle, outlived by a delayed submission plus a 3-day ttl. | Worker URLs are signed at submit time; `in/` 7 d; inputs older than 3 d are uploaded again. |

---

### Sources

**RunPod:**
- https://docs.runpod.io/api-reference-v2/migrate-from-v1
- https://docs.runpod.io/release-notes
- https://docs.runpod.io/serverless/endpoints/operation-reference
- https://docs.runpod.io/serverless/endpoints/send-requests
- https://docs.runpod.io/serverless/workers/handler-functions
- https://docs.runpod.io/serverless/endpoints/endpoint-configurations
- https://docs.runpod.io/serverless/pricing
- https://docs.runpod.io/serverless/workers/overview
- https://docs.runpod.io/serverless/endpoints/rolling-releases
- https://docs.runpod.io/serverless/workers/github-integration
- https://docs.runpod.io/serverless/endpoints/model-caching
- https://docs.runpod.io/storage/network-volumes
- https://docs.runpod.io/storage/s3-api
- https://docs.runpod.io/get-started/credentials
- https://docs.runpod.io/accounts-billing/billing
- https://docs.runpod.io/serverless/troubleshooting
- https://www.runpod.io/pricing
- https://www.runpod.io/blog/serverless-gpu-cold-starts-flashboot
- OpenAPI v2 spec (local copy): `scratchpad/docs/openapi-v2.json`
- (revised) https://api.runpod.io/v2/openapi.json (live; byte-identical to the local copy on 2026-10-07)
- (revised) https://docs.runpod.io/serverless/development/optimization (7-minute cold-start limit, `RUNPOD_INIT_TIMEOUT`)
- (revised) https://docs.runpod.io/serverless/endpoints/job-states
- (revised) https://docs.runpod.io/serverless/batch-jobs (beta; not used in v1)
- (revised) https://docs.runpod.io/api-reference-v2/serverless/update-a-serverless-endpoint

**Cloudflare R2:**
- https://developers.cloudflare.com/r2/pricing/
- https://developers.cloudflare.com/r2/api/s3/presigned-urls/
- https://developers.cloudflare.com/r2/buckets/object-lifecycles/
- https://developers.cloudflare.com/r2/api/tokens/

**Apple (revised):**
- https://developer.apple.com/documentation/foundation/urlsessionconfiguration/isdiscretionary
- https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)
- https://developer.apple.com/documentation/foundation/urlsessionconfiguration/sessionsendslaunchevents
- https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest

**Models:**
- https://huggingface.co/anvuew/BS-RoFormer
- https://huggingface.co/KimberleyJSN/melbandroformer
- https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B
- https://huggingface.co/Qwen/Qwen3-ASR-1.7B
- https://github.com/facebookresearch/demucs
- https://github.com/ZFTurbo/Music-Source-Separation-Training
- https://mvsep.com/quality_checker/multisong_leaderboard?sort=vocals
- (revised) https://huggingface.co/api/models/{repo}?blobs=true for the commit SHAs, file sizes and licence tags of the four model repos; https://huggingface.co/anvuew/BS-RoFormer/blob/main/config.yaml
- (revised) https://pypi.org/pypi/{qwen-asr,msst,runpod,demucs}/json
- (revised) https://hub.docker.com/v2/repositories/pytorch/pytorch/tags/2.11.0-cuda12.8-cudnn9-runtime (4.26 GB amd64)

**GitHub:**
- https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners

**Code:**
- `pixlaudio-ios@86a5cce`: paths cited inline.
- `PixlAudio@0a8b63e:tools/runpod-serverless/*` and `@f9f1a82:tools/runpod/stem_server.py` (prior art).

---

## Review notes

Review of v1, 2026-10-07, read-only. Every change in the body is marked "(revised)". The live docs.runpod.io pages were fetched again as `.md` and compared byte for byte with the copies v1 was built from (`scratchpad/docs/`): all 19 pages and the v2 OpenAPI spec were identical. Copies of everything re-checked are in `scratchpad/review-live/`.

### Load-bearing claims, re-checked

| Claim in v1 | Result | Source |
|---|---|---|
| `/run` payload 10 MB, `/runsync` 20 MB | **Confirmed** | https://docs.runpod.io/serverless/endpoints/operation-reference |
| `/run` results kept 30 min, `/runsync` 1 min, then deleted | **Confirmed** | https://docs.runpod.io/serverless/endpoints/send-requests, …/endpoint-configurations |
| `ttl` covers queue time and is a hard kill; max 7 d; `executionTimeout` max 7 d | **Confirmed** | send-requests ("Execution policies") |
| Network-volume S3 API has no presigned URLs | **Confirmed** (`GeneratePresignedURL` ❌); the 1 h clock-skew window is confirmed too | https://docs.runpod.io/storage/s3-api |
| Restricted key can be scoped per endpoint | **Confirmed**, but whether endpoint-level Read/Write includes *management* (PATCH `workers.max`) is **not documented**, so the leaked-key worst case was wrong (R15, owner step F) | https://docs.runpod.io/get-started/credentials |
| REST v2 at `api.runpod.io/v2`; v1 retires 2026-11-15; v2 GA | **Confirmed** | https://docs.runpod.io/api-reference-v2/migrate-from-v1, /release-notes |
| v2 create fields (`type`, `gpu.pools`, `excludedTypes`, `minCudaVersion`, `workers.{min,max,idleTimeout}`, `scaling`, `flashboot` default `OFF`, `timeout`, `disk`, `env`) | **Confirmed** against the live spec. New: a PATCH with `env` replaces the whole env, and `image`/`env` changes start a release while `workers.max` alone does not | https://api.runpod.io/v2/openapi.json |
| Prices: 16 GB $0.58/h ($0.00016/s), 24 GB $0.69/h ($0.00019/s), 4090 $1.10/h | **Confirmed**. The 16 GB pool includes the RTX 2000; the 24 GB pool includes a "Pro 6000 MIG 24GB" slice | https://www.runpod.io/pricing, endpoint-configurations |
| Image pull and cached-model download are unbilled; model load is billed | **Confirmed** | https://docs.runpod.io/serverless/pricing, /serverless/workers/overview |
| Idle scale-down: 3 d → max 2, 7 d → max 0 | **Confirmed**, plus a second trigger v1 missed: repeated unhealthy workers | endpoint-configurations, /serverless/troubleshooting |
| `refresh_worker` | **Confirmed** (was [I]) | https://docs.runpod.io/serverless/workers/handler-functions |
| 7-minute init limit needs `RUNPOD_INIT_TIMEOUT=800` for big images | **Wrong premise.** The limit is on the billed cold start (model load), not the image download. Override removed | https://docs.runpod.io/serverless/development/optimization |
| GitHub integration: 80 GB image, 30-min build | **Confirmed**, inside a 160-min total window | https://docs.runpod.io/serverless/workers/github-integration |
| GHCR 10 GB per layer, 10-min upload timeout, new packages private, anonymous pulls of public images | **Confirmed** | GitHub Packages docs (Container registry) |
| GitHub runner 14 GB SSD | **Confirmed** as documented; real free space is undocumented | GitHub-hosted runners reference |
| R2: presign 1 s–7 d; GET/HEAD/PUT/DELETE; free 10 GB-month, 1M A, 10M B; free egress; lifecycle per prefix or whole bucket, deletes within about 24 h of expiry | **Confirmed** | developers.cloudflare.com/r2/… (presigned-urls, pricing, object-lifecycles) |
| Model licences: anvuew GPL-3.0, Kim MIT, Qwen3 aligner and ASR Apache-2.0 | **Confirmed** (HF API licence tags); file sizes and commit SHAs recorded in section 2.2 | huggingface.co/api/models/… |
| Qwen3-ForcedAligner: 11 languages, ≤ 5 min per call, "Speech" only | **Confirmed**. Qwen3-ASR lists "Singing Voice, Songs with BGM" and 30 languages, including vi, th and id | Qwen3-ASR / ForcedAligner model cards |
| Base image `pytorch/pytorch:2.11.0-cuda12.8-cudnn9-runtime` is 4.26 GB | **Confirmed** (amd64) | Docker Hub tags API |

### What was wrong, and the fix

1. **Retention mismatch (payload and retention).** Worker URLs were presigned at upload time and `in/` expired after 3 d, while the 3-day queue ttl only starts at submission, which can be hours or days later. **Fix:** sign the worker's URLs at submit time; `in/` 7 d; re-upload inputs older than 3 d; `out/` 30 d; a catch-all rule. `/status` 404 is now handled as "go to R2".
2. **Cost blow-ups v1 didn't bound:** (a) platform re-delivery of a job that kills the process, and duplicate `/run`s after lost responses. **Fix:** the guard (attempt marker plus manifest short-circuit). (b) The 800 s init-timeout override, which only made a hung model load bill longer. **Fix:** removed. (c) The keepalive blindly restoring an endpoint that RunPod had scaled down for crash-looping. **Fix:** check `summary.unhealthy` first. (d) "Extra workers" during spikes. **Fix:** a W1 measurement. (e) An old account balance or auto-pay left over from the Android experiments. **Fix:** owner step A1. A failure-path cost table was added to section 6.
3. **The leaked phone key's worst case was overstated as a bound.** `$16.6/day` assumed the key can't change `workers.max`, and that is undocumented. **Fix:** the bound is now "the prepaid balance", with a throwaway-key test (owner step F) that decides which number the Settings screen shows. `/run` is never sent through a background session, so the Authorization header isn't persisted by the transfer daemon. The worker's host allowlist is pinned to the owner's R2 account.
4. **iOS background realities were too optimistic.** Transfers created in the background are discretionary (Apple docs), so downloads queued from BGAppRefresh can wait for Wi-Fi and power. A force-quit stops everything, including relaunch. **Fix:** a state-by-state table of what actually runs; `/run` submission inside `beginBackgroundTask` during the URL-session wake, saving each job id before the next POST; KB-sized lyrics imported inside the refresh window; honest UI copy. The RunPod-volume fallback is now flagged as fragile on iOS (header signatures expire after 1 h and background transfers start late) and as at risk at a $0 balance.
5. **GitHub Actions disk.** v1's separate weights stage plus a `mode=max` registry cache kept each weight file about 4 times (about 42 GB peak, above its own 40 GB fail-early line). **Fix:** `ADD --link --checksum` per file (pinned HF commits), inline cache, gzip level 1, `df -h` logged; about 30 GB peak, and near zero for code-only builds [I until measured].
6. **Licences.** The weights were right, but the public image also ships a GPL ffmpeg binary. msst's PyPI metadata has no licence. anvuew's training data is unspecified. **Fix:** a licence table with each duty in section 5, NOTICE carries the apt versions, and the private-image alternatives are listed.
7. **Streamed-song failure modes were missing.** Bulk-download blocks, low-quality or muxed itags, YouTube versions whose timing doesn't match catalog LRC, and itag drift between upload and later playback. **Fix:** a table in section 7.3, a worker-side global offset check, `synced: false` when the durations disagree, and itag and content length recorded per job.
8. **Sample-exactness (R13).** Passing HE-AAC, MP3 or Opus through to ffmpeg risks an encoder-delay mismatch with Apple's decoder, which is exactly what the Sing crossfade depends on. **Fix:** decode on the phone and upload FLAC for anything that isn't AAC-LC M4A, and redo the job with FLAC output on an import mismatch.
9. **Lyrics language coverage.** The aligner has no vi, th or id. **Fix:** D7 is decided from a count of the library's languages, done before W2.
10. **Small corrections:** the attached-picture stream in M4A or MP3 no longer fails "exactly one audio stream"; the input DELETE happens only after success; the doc-page conflict about GPU priority is noted; a broken cross-reference (7.6 → 7.4) is fixed; deps and versions are verified on PyPI.

### Kept as is (checked, no change needed)

- R2 over a RunPod volume; GHCR plus REST v2 deploys over the GitHub integration (which stays the fallback).
- `max 1 / min 0 / idle 10 s`, explicit `flashboot`, `pools` and `excludedTypes` sent together, and `sha-<12>` tags only.
- BS-RoFormer ft1 as the default separator. Its config (dim 256, depth 12) makes the ~12 s separation estimate on a 24 GB card plausible, but `op: bench` still decides.
- Batch Jobs (beta, "multi-hour latency", dedicated batch workers) is not adopted. Its pricing and result retention are undocumented, and R2 already solves "process later".

### Still open after this review (measure in W1)

- The Restricted key's management rights (owner step F) and the extra-worker behaviour (concurrency check). Each changes a cost bound.
- How many times RunPod re-delivers a job whose process dies (the poison test).
- Real runner disk peak and push time with `--link` plus the inline cache.
- Whether `/health` resets the idle scale-down timer (assumed not).
- Whether RunPod pulls GHCR images with gzip level 1 layers fine. It should, because the compression level doesn't change the format; to be confirmed on the first deploy.
