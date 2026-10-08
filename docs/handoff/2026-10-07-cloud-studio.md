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
  once through `/runsync` and reports its version and GPU (and refuses a worker that doesn't speak job v1 or misses a
  model).
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
`Packages/PixlCore/Tests/PixlNetTests/Fixtures/cloud/worker/`) showed, and this branch fixed on the phone side:

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
   15-minute FLAC is ~90–110 MB). **The worker's `PIXL_MAX_INPUT_MB` must be 160 too** — its branch had only the schema
   when this was written.

`bash ci/check-cloud-fixtures.sh origin/s19-cloud-worker` compares the copies with the worker branch; once the worker
is on `main`, `bash ci/check-cloud-fixtures.sh` compares with the checkout (it is not wired into `ci.yml` yet).

## How it was verified

- Windows, Swift 6.4: **all 1,246 PixlCore tests pass** (PixlNet 349, incl. the new schema, lyrics, budget and
  estimate suites). The earlier saved state had tests that never compiled (mutating calls inside `#expect`, a
  non-Sendable presign type) and two expressions the type checker gave up on; fixed.
- CI run `RUN_ID` on `HEAD_SHA`: STATUS_LINE
- Screenshots looked at: SHOTS_LINE

## Phone checklist (Hoa)

- [ ] Settings › Developer Options › Experimental shows the **Cloud processing** panel; it opens the screen.
- [ ] Paste the six values (Safari → the field; keys never in chat). The account ID under the R2 field matches.
- [ ] **Test connection**: both RunPod and Storage green. Break one value on purpose and check the sentence is right.
- [ ] **Run selftest (~1¢)**: shows the worker version and GPU (the first one can take a few minutes: cold start).
- [ ] Cloud queue › Add › **Current song** with a local song: the confirm sheet's numbers look sane → Send.
- [ ] The row goes Preparing → Uploading % → Waiting for a GPU → Separating vocals % → Done; Sing uses the new
      instrumental and the lyrics are word-timed. The cost line is about a cent.
- [ ] A **streamed** song and a **Spotify** song: they download first, then go up as FLAC.
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
- `ci/check-cloud-fixtures.sh` should run in `ci.yml` once the worker is merged.
- Next: merge the worker (W1: deploy, selftest, bench, owner step F), then run the phone checklist; record the real
  timings and per-song cost in a handoff note; then Android (design §8).
