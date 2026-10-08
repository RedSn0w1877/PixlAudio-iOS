# Cloud Studio, app side (2026-10-07, branch `s20-cloud-studio`)

Design: [`2026-10-07-plans/cloud-studio-design.md`](2026-10-07-plans/cloud-studio-design.md) §7 plus the client side of
§1–2.5; owner decisions in [`DECISIONS.md`](2026-10-07-plans/DECISIONS.md) › Cloud Studio. The worker (Python, RunPod,
GitHub workflows) is a separate item on `s19-cloud-worker`. **Nothing here has run on a phone or against a real RunPod
endpoint or R2 bucket yet** — CI builds it, runs the unit tests with fakes and takes screenshots from demo data.

## What the person gets

- **Settings › Developer Options › Experimental › Cloud processing.** Off until "Send songs to my RunPod account" is
  switched on. Fields in the order of the setup steps (design §3.5 E): Endpoint ID, RunPod key (Restricted), R2 endpoint
  *or* the bare 32-character Cloudflare account ID (the account found is shown under the field), bucket (default
  `pixl-cloud-studio`), access key ID, secret. The three keys go to the Keychain on this iPhone only
  (`AfterFirstUnlockThisDeviceOnly`), never into backups. If the app is re-signed by another team and the keys can't be
  read any more, the screen says "Cloud keys missing — paste them again".
- **Test connection** checks RunPod (`/health`: 401/403 = the key, 404 = the Endpoint ID) and storage (a 1-byte
  `probe/<id>` PUT, HEAD and DELETE) separately, each with a sentence to act on. **Run selftest (~1¢)** wakes a worker
  once through `/runsync` and reports its version, GPU and song limits ("Worker 1.0.0 on NVIDIA L4 · songs up to
  160 MB and 15 min"); it refuses a worker that doesn't speak job v1, misses a model, or allows no storage host. The
  limits it reports are kept (until the Endpoint ID changes), and a song the endpoint would refuse stops before its
  upload with a sentence naming the endpoint setting.
- **Outputs:** Instrumental, Word-timed lyrics, "Write lyrics when none are found (AI transcription)" (saved as
  AI-written lyrics), Standard/Best. **Network:** Use cellular data (off). **Cost:** GPU price per second ($0.000192)
  and a monthly cap ($3.00) with "This month: … used or on its way".
- **Cloud queue** (from Cloud processing): Add › Current song / Songs without word-timed lyrics / Songs without an
  instrumental (up to 200 songs). Also a playlist's ⋯ › "Process all in the cloud" and the Remaster Song card's Cloud
  row, both only once Cloud processing is on. Every batch goes through a **confirm sheet**: songs, minutes, upload MB,
  estimated cost and what is left of the month; over the cap the Send button is off.
- Rows show where each song is (Preparing, Uploading 42 %, Waiting for a GPU, Separating vocals 40 %, Downloading,
  Done · instrumental + word-timed lyrics, the cost and GPU), what went wrong (the worker's code, Retry), and Cancel.
  Home's Active jobs sheet shows "Cloud: 3 waiting, 1 processing".

## How it works (code)

- **PixlNet (`Packages/PixlCore/Sources/PixlNet/Cloud/`)** — schema v1 (`CloudJobSchema`), SigV4 presigning
  (`S3Signer`), RunPod jobs (`RunPodJobsClient`), the bucket's small requests (`CloudObjectClient`), every rule
  (`CloudQueuePolicy`: states, selection, gate, cost, cap, import checks, retention), the `/run` body (`CloudJobBuilder`),
  the settings fields (`CloudConfig`), Test connection (`CloudConnectionTest`), lyrics both ways (`CloudLyrics`).
- **App (`App/Services/Cloud/`)** — `CloudStudio` (the orchestrator, `@MainActor @Observable`, built in
  `AppEnvironment.init`), `CloudStudioDependencies` (the seams + live host), `CloudStudioFactory`, `CloudSettings`,
  `CloudCredentials`, `CloudJobStore` (one JSON file, `Application Support/CloudStudio/jobs.json`, not a second
  SwiftData store: no migrations, the main store untouched), `CloudAudioPreparer`, `CloudTransfers` (background
  session `io.github.redsn0w1877.pixlaudio.cloud`), `CloudBackground`, `CloudPlatform` (CryptoKit, sessions, month).
- **UI (`App/Features/CloudStudio/`)** — `CloudProcessingSettingsView`, `CloudQueueView`, `CloudConfirmSheet`; routes
  `.cloudProcessing`, `.cloudQueue`, sheet `.cloudConfirm`; demo `App/Demo/CloudDemo.swift`.
- **A song's path:** prepare (AAC-LC `.m4a` as is, music-library AAC by passthrough export, everything else decoded by
  the player's decoder to 44.1 kHz stereo 16-bit FLAC; streamed songs are downloaded permanently first, Spotify ones
  through their YouTube match) → the SHA-256, duration and frame count recorded → presigned PUT (24 h) in the
  background session → once the batch's uploads are done (or 2 min after the first) `/run` with every worker URL
  signed at that moment (≈ 76 h) and the job id saved before the next POST → `/status` every ≥ 15 s while the app is
  open and RunPod holds jobs, plus one `ListObjectsV2 out/` per pass (results after `/status` expired) → lyrics.json
  fetched and checked (size, SHA-256), converted with the words rebuilt from the original text, saved only when it
  beats what is stored and never over the person's own sync → the instrumental downloaded in the background, checked
  (size, SHA-256, and the sample count against the phone's own decode within ±1 AAC frame) and moved atomically to
  `Stems/<song>_cloud_inst.m4a` → the job's objects deleted from the bucket.
- **When something goes wrong:** INPUT_MISSING / INPUT_MISMATCH upload again; GPU_OOM, DEADLINE, UPLOAD_FAILED,
  INTERNAL, BAD_URL, DOWNLOAD_FAILED send again; the rest stop (Retry starts over). Retries climb 1 → 5 → 15 → 60 min,
  4 automatic tries. A job RunPod lost (no status, no manifest, past its ttl) goes out once more with the same key,
  then expires. An AAC result that doesn't line up is redone once as FLAC. A streamed song whose YouTube match changed
  since it was sent isn't imported.
- **Background:** uploads and downloads continue while the app is suspended; the transfer-session wake
  (`.backgroundTask(.urlSession(…))`) and BGAppRefresh (`…pixlaudio.refresh`, asked for ~15 min out while jobs are in
  flight) each run one pass. A person-started batch keeps preparing under continued processing
  (`…pixlaudio.cloud-prepare`, new in `project.yml`). A force-quit stops transfers until the next launch, as the
  screens say.
- **Money guards:** the confirm sheet's estimate must fit what is left of the month, and every `/run` checks the cap
  again with jobs still at RunPod counted at their estimate; per-job cost comes from each manifest's timings and GPU.

## Schema differences found against the worker's golden examples

The phone's types were written from the design before the worker existed. Decoding
`origin/s19-cloud-worker:cloud/runpod-worker/schema/v1/examples/*` (now copied byte for byte into
`Packages/PixlCore/Tests/PixlNetTests/Fixtures/cloud/`) showed, and this branch fixed on the phone side:

1. The manifest's `lyrics` entry carries `bytes`, `sha256` and **`offsetMs`** (the phone had `lyricsOffsetMs`).
2. `lyrics.json` has a top-level `offsetMs`.
3. Output files carry `sampleRate`.
4. `DOWNLOAD_FAILED` is a code; any unknown code must read as `INTERNAL`.
5. The selftest output is its own schema (`pixl.cloudstudio.selftest`: `supported`, `ops`, `models` as `true`/`false`/
   `"lazy"`, `versions`, `wordTimingLanguages`).
6. `output.put` is absent in the volume fallback; `op: bench` carries `bench`; `attempt.json` has its own schema.
7. The worker's language pattern is lower-case `^[a-z]{2,3}(…)` and a line's text is capped at 2,000 characters; synced
   lines must be sorted.
8. Upload cap: **160 MB** (`CloudLimits.maxInputBytes`, coordinator note; the design's 60 MB was sized for AAC, a
   15-minute FLAC is ~90–110 MB). The finished worker's `PIXL_MAX_INPUT_MB` default is 160 too (checked on its branch).
9. From the worker's final review (2026-10-07 22:05, `9dbdf06`): the manifest's `input` names the verified input's
   `sha256`, and the selftest reports the endpoint's `caps` (`maxInputMB`, `maxAudioS`, `bestMaxAudioS`, lyrics caps,
   `hostsConfigured`). The phone decodes both: a manifest in the bucket that names another input is an earlier
   attempt's and isn't imported (`CloudImportCheck.manifestDescribesUpload`), and the caps are used as above
   (`CloudLimits.workerRefusal`). A lyrics-only job whose lyrics fail is now an error with the lyrics' code (or
   `INTERNAL`) and keeps its upload: the phone already sends those again without re-uploading.

**Fixture layout (fixed this round):** the worker's own drift check (`cloud/runpod-worker/ci/check_fixtures.py`)
compares every `*.json` directly in `Packages/PixlCore/Tests/PixlNetTests/Fixtures/cloud/` with its examples, so that
folder now holds exactly the 14 worker examples (synced to `9dbdf06`), and the phone's own fixtures (RunPod responses,
a bucket listing, lyrics edge cases) moved to `Fixtures/cloud-phone/`. Before, the copies sat in `cloud/worker/` (which
the worker's script doesn't read) next to phone-only files it would have flagged. `bash ci/check-cloud-fixtures.sh
origin/s19-cloud-worker` compares with the worker branch (OK, 14 match); once the worker is on `main`,
`bash ci/check-cloud-fixtures.sh` compares with the checkout (not wired into `ci.yml` yet). The worker's own script,
run against these copies, reports no drift.

## The CI failure this round (runs 37711835786 and 37715125605)

Both failed on one unit test, `CloudAudioPreparerTests.testWAVIsDecodedToFLACAtTheWorkersRate`, line 90: a 3-second
tone (132,300 frames) was written as FLAC but read back by `AVAssetReader` as **133,632 = 29 × 4,608** frames. The
earlier fix (bc8051d, "count by the buffer's sample count") was aimed at the writer, but both runs failed at the
read-back, so the writer had been right all along: Apple's FLAC encoder works in whole 4,608-frame packets and pads a
short last packet, and decoders disagree on whether to trim that padding. In the app this would have made every
decoded (non-AAC) song fail the import's sample check (1,332 frames > the 1,024 tolerance), redo as FLAC once, and fail
again. Fix: the preparer ends the file on a whole packet of silence (under 0.1 s, from the file format's
`mFramesPerPacket`; if the format doesn't say, the read-back count sets the silence and the file is written once more)
and records the phone's own read-back as `frames`, so the phone, the worker's ffmpeg and the import check all see the
same length.

## How it was verified

- Windows, Swift 6.4: **PixlNet's 352 tests pass** after this round (the earlier full PixlCore run: 1,246); new ones
  cover the worker caps, the selftest's limits and empty allowlist, and the manifest's input check. The worker's
  `check_fixtures.py` logic run against the new `Fixtures/cloud/`: no drift.
- CI run 37731451069 on `5a525d6`: **green** — core 1,249 PixlCore tests (PixlNet 352), app 287 unit tests (incl. the FLAC read-back test that failed before, plus 3 new orchestrator/settings tests), 50 screenshot tests (SettingsScreenshotTests + CloudStudioScreenshotTests), 0 failures. The non-blocking YouTube live smoke failed (external; not this branch).
- Screenshots looked at: Cloud processing light/dark incl. the tested state (RunPod, Storage and the new Worker line "Worker 1.0.0 on NVIDIA L4 · songs up to 160 MB and 15 min"), the queue, the confirm sheet (Send fits on one line), Experimental's Cloud processing row: all render correctly.

## Phone checklist (Hoa)

- [ ] Settings › Developer Options › Experimental shows the **Cloud processing** panel; it opens the screen.
- [ ] Paste the six values (Safari → the field; keys never in chat). The account ID under the R2 field matches.
- [ ] **Test connection**: both RunPod and Storage green. Break one value on purpose and check the sentence is right.
- [ ] **Run selftest (~1¢)**: shows the worker version, GPU and "songs up to 160 MB and 15 min" (the first one can
      take a few minutes: cold start).
- [ ] Cloud queue › Add › **Current song** with a local song: the confirm sheet's numbers look sane → Send.
- [ ] The row goes Preparing → Uploading % → Waiting for a GPU → Separating vocals % → Done; Sing uses the new
      instrumental and the lyrics are word-timed. The cost line is about a cent.
- [ ] A **streamed** song and a **Spotify** song: they download first, then go up as FLAC, and their instrumentals
      import (this is the path the FLAC packet fix covers; a "didn't line up" error here means it needs another look).
- [ ] Send 3 songs, **lock the phone** for 30+ minutes, reopen: results come in (the R2 listing).
- [ ] Swipe the app away during an upload: the row says it stopped; reopening starts it again.
- [ ] A playlist's ⋯ › **Process all in the cloud** (≈10 songs): one cold start, then ~20–30 s per song.
- [ ] Lower the monthly cap to $0.01: Send is off on the confirm sheet.
- [ ] In R2, `in/` and `out/` are empty after the imports (lifecycle rules are only the backstop).
- [ ] Re-sign the app with another tool/team if that ever happens: the screen asks for the keys again.

## Not done / next

- Not built: the optional "Cloud results ready" local notification; Sing's "Better in the cloud" option and a row under
  "Ready when you play" (design P5, coordinated with the lyrics and AI groups); stems (hidden until a stem mixer
  exists); the storage picker's Other-S3 / RunPod-volume modes (R2 only; the signer has header signing for the
  volume fallback, unused); url-session handlers for the existing `downloads` / `models` sessions; jitter between
  streamed downloads (they are 2 at a time).
- `ci/check-cloud-fixtures.sh` should run in `ci.yml` once the worker is merged (left out of the shared `ci.yml` for
  now). Merge order doesn't matter: the worker's `check_fixtures.py` passes with a notice until `Fixtures/cloud/` exists
  and passes on these copies once both are on `main`.
- Measured only on the iOS 27 simulator: the FLAC read-back. That the worker's ffmpeg decodes the padded upload to the
  same count is reasoned (no short last packet left to trim), not measured; the first real job with a decoded
  (non-AAC) song settles it: the manifest's `input.decodedSamples` must equal the job's recorded `frames`.
- Next: merge the worker (W1: deploy, selftest, bench, owner step F), then run the phone checklist; record the real
  timings and per-song cost in a handoff note; then Android (design §8).
