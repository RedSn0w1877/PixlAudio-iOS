# iOS Spatial audio: the cloud side (CLOUD, 2026-11-11)

Branch `audio-cloud` (from `audio-hq` 6529ea4). Contract: `docs/handoff/2026-11-10-plans/cloud-audio-spec.md`;
manual: `docs/handoff/2026-11-10-plans/ios-integration-map.md`. Only files CLOUD owns (map 11) were edited; the
frozen contract is untouched.

## What is there

**PixlNet** (`Packages/PixlCore/Sources/PixlNet/Cloud/`, tested on Windows):

- `CloudJobSchema.swift`: `CloudTask.spatial` (no `output.put` slots of its own), `input.library`
  (`CloudLibraryJobRequest`), result `library` (`CloudLibraryResult`), `models.stems6`, `timings.stems6Ms/renderMs`;
  `output.codec` is optional (a library-only job sends `output.put.manifest` and no codec, as the worker's example).
- `CloudLibraryJob.swift` (new): the library block and result types, `CloudLibraryJobInfo` (what a record remembers:
  video, profiles, ahead, stream itag/codec, lookup hit, cap hold, per-render states, manifests while downloading,
  imported/rejected), `CloudLibraryJobBuilder.block` (every URL presigned for the canonical `lib/` key),
  `CloudLibrarySourceFormat` (itag/content type to `aac`/`opus`), `CloudLibraryImportCheck` (own render by frame
  count, shared render by media time, job output vs render manifest).
- `CloudLibraryState.swift` (new): `CloudLibraryStatus` (record + facts to `RenditionStatus`), `CloudLibraryRetryBook`
  (10 min / 1 h / 1 day, each failed job counted once, stored as JSON), `CloudAudioStorePolicy` (acceptance of a
  stored pair, least-recently-played eviction, usage), `CloudLibraryBudget` (own cap, nil = no limit; daily count for
  the background queue only), `CloudLibraryAhead` (the queue's room).
- `CloudJobBuilder`: library block, execution timeout 1 800 000 ms and URL lifetimes `ttl + 1800 s + 1 h` for jobs
  with `spatial`. `CloudJobRecord`: origin `library`, `library`, `libraryReservedMicroUSD` (all optional),
  `isLibraryJob`, `isPreparedAhead`. `CloudQueuePolicy`: `(.preparing, .resultsReady)` (lookup hit),
  library estimate (60 s + 25 s per render for 4 minutes: not measured, spec 9), `CloudBudget` sums leave library
  jobs out (Sing's cap only), library records pruned after 1 day (done) / 3 days (failed). Priority lane: library
  jobs never priority, tier 3 (playing) / 4 (ahead), held back like auto jobs while a Sing job gets ready.
  Notifications: none for library batches. Background planner: library-only work may wait for the charger.
  Progress words for `stems6` / `render`. `CloudAutoLedger.reserve(_:countsForToday:)`.
- `PixlModel/ActiveJob.swift`: `Kind.spatial` ("Spatial audio", `headphones`). `CloudActiveJobMapper` gives library
  batches that kind (row id stays `cloud.<batch>`, so Cancel / Retry / Dismiss work unchanged).

**App**:

- `App/Services/Cloud/CloudStudio.swift`: library jobs through the same queue, transfers, RunPod client, priority lane
  and background passes. `enqueueLibraryRender` (one job per video+profile; the playing song takes over a background
  queue job), `cancelLibraryJobs`, `libraryMayUseNetwork`, the library ledger (reserve on RunPod accept, settle on
  result, refund if never started), `prepareLibrary` (spec 6.2 step 1 local store, step 2 signed GET of
  `lib/v1/<id>/sp-<p>.json` — a valid one means fetch only, no upload, no GPU — then the cap and day checks, then the
  stream-cache audio, decoded to FLAC like every streamed song, upload), submit-time library cap, `collectLibrary`
  (render manifest from its `lib/` key, `check(for:)`, agreement with the job manifest's output, background download
  under slot `sp-<profile>`), `importRender` (bytes + SHA-256, timeline, hand to the store), cleanup of `in/` and
  `out/<jobKey>/` only. Sing's lookups (`job(forSong:)`, `hasPendingJob`, `pendingSongIds`, Sing availability) ignore
  library jobs, so a Sing tap on a song with a pending render gets its own job.
- `CloudTransfers.isSafeSlot` accepts `-` (not first). `CloudSettings`: `cloud_studio_library_ledger`.
  `CloudStudioDependencies`: `CloudLibraryAudioSource`, `CloudStudioHost.libraryAudioSource(for:videoId:)` (default:
  the old source), `CloudRenderInstalling`. `CloudStudioFactory`: the live library source. `CloudDeviceConditions`:
  `addNetworkObserver`. `SingPrepareRunner`: library jobs don't count as "songs the person asked for".
- `App/Services/CloudAudio/` (new): `CloudAudioSource` (a download already there, else the stream cache's complete
  file, filled first if needed: never a permanent download), `CloudAudioStore` (actor; `Application
  Support/CloudAudio/<videoId>/sp-<profile>.flac` + `.json`, excluded from backups, audio first and manifest last, a
  pair is the index, last played = the manifest's modification date), `SpatialCloudLibrary` (the `SpatialLibrary`
  and `CloudRenderInstalling`; follows Cloud Studio's records by observation and sends `statusChanged`,
  `renditionReady`, `renditionRemoved`, `usageChanged`), `CloudAudioPrepareAhead` (spec 6.4),
  `SpatialLibraryFactory` (no-op library in UI tests).

## Behaviour, in the spec's terms

- Cloud renders on = Cloud Studio's switch AND `spatial.cloud`. Either off: `request` is `ready` for a stored render,
  `none` otherwise. Switching `spatial.cloud` off cancels every pending library job (also one running at RunPod).
  The master off: Cloud Studio does nothing at all (as today); library jobs wait and carry on when it is back.
- Status: stored `ready`; job queued/preparing/uploading `queued`, or `waitingForNetwork` when the job may not use
  the network there is (playing: Cloud Studio's rule, Wi-Fi or mobile data with "Use cellular data"; ahead:
  `CloudAutoConditions`), or `capReached` while the library cap holds it; uploaded `queued`/`capReached`;
  submitted/running `processing`; resultsReady/downloading `downloading`; a render not made or refused `failed`;
  failed/expired `failed`; then `failed` while the backoff runs, else `none`. Cloud Studio's own transient retry
  ladder (1/5/15 min) shows as `queued`; the library's 10 min / 1 h / 1 day backoff starts when the job ends failed.
- Money: own ledger and cap (`cloudAudio.monthlyCapUSD`, default $30, nil = no limit, never Sing's $3 clamp); the cap
  is checked before anything is prepared (no upload over the cap) and at submission. Lookups and downloads cost
  nothing and are never held by the cap. `dailyAhead` counts background-queue jobs that reach RunPod (a lookup that
  ends in a download doesn't count). `usage()` reports the ledger (spent incl. reservations, sent today).
- Store: `cloudAudio.storageMB`, least recently played first, after every new render and when the budget shrinks.
- While a job for the playing song is under way the library pumps Cloud Studio every 5 s, also in the background
  (Cloud Studio's own poll loop stops there), so a render can land while its song still plays.
- Background queue: Sing's ranker, the selected profile only, songs with a stored YouTube match only, at most 3 of
  its jobs at once, Wi-Fi on a ready phone, looks only while the app is open (like Sing's runner); its jobs go on in
  Cloud Studio's background passes (no new task identifiers).

## Tests and CI

- PixlCore (Windows): full suite green (8 targets). New `CloudLibraryTests` (21 tests): the built body equals the
  worker's `job.input.spatial.json` and `run.request.spatial.json` field for field (URLs included, via the example's
  own signatures), every spatial example round-trips (`CloudSchemaTests` lists), result parsing (ok, exists, partial),
  manifest acceptance and rejection, store policy, money, status machine, retry ladder, priority, Active jobs row,
  notifications, retention.
- App: `AppTests/CloudAudioLibraryTests.swift` (16 tests: job end to end, lookup hit, refused cut-off render, damaged
  download, already stored, one job per rendition, own cap, Sing's cap ignored, Sing not blocked, network rules,
  library + real store events, backoff, master switch, cancel on `spatial.cloud` off, store index/eviction).
- `ci/parse-check.ps1`, `check-forbidden.sh`, `check-cloud-fixtures.sh`, `check-spatial-fixtures.sh`: OK.
- CI: see the report's run ids (`gh run list --repo RedSn0w1877/PixlAudio-iOS --branch audio-cloud`).

## Divergences and readings (lead, please confirm or overrule)

1. **Step 2 runs inside a Cloud Studio record.** A shared-library hit is a library job that never uploads (it goes
   preparing → resultsReady → downloading → imported). It shows briefly in the Cloud queue and Active jobs, and its
   download survives a relaunch through the background session. Map 7.3 allowed either way.
2. **No permanent download** (map 12 "Still open" 2): library jobs take the stream cache's copy (filled if needed);
   a song the person downloaded is used as it is. Owner's call if Sing's behaviour is wanted instead.
3. **A cut-off render in the shared library poisons its key for up to 30 days.** A shared render is refused when it is
   more than max(10 s, 10 %) shorter than the song (an upload that stopped early, e.g. a PoToken-truncated Android
   stream). Phones never delete `lib/`, and the worker's `manifestGet` says "exists", so nobody can replace it until it
   expires or the janitor drops it. Suggest: the worker refuses to render (or to write a manifest for) audio whose
   decoded length is far below `audio.durationMs`, or a `replace` flag. Spec change, the lead's.
4. **Status `resultsReady` reads as `downloading`** (the render exists and its fetch is next).
5. **Cancelling on `spatial.cloud` off includes jobs running at RunPod** (spec: "Off = on-device only"); turning
   prepare-ahead off or picking another profile cancels the background queue's jobs not yet started at RunPod.
6. **Library records are pruned after 1 day (imported) / 3 days (failed)**, not Sing's 30: one record per song and
   profile played; failures live in the library's retry book.
7. **New enum cases** `CloudJobOrigin.library`, `ActiveJob.Kind.spatial`, `CloudTask.spatial`: an older build reading a
   job list with a library record would fail to decode it (downgrade only).
8. **Estimates** (60 s + 25 s per render for a 4-minute song) are guesses until the worker's first bench (spec 9).

## Asks

- **UI**: `App/Features/CloudStudio/CloudQueueView.swift` shows library records like any job; consider labelling them
  "Spatial audio" (`record.isLibraryJob`) and treating `record.isPreparedAhead` like the auto rows (line 266 checks
  `effectiveOrigin == .auto`). Active jobs rows already carry `ActiveJob.Kind.spatial`.
- **ENGINE**: nothing new. `localRendition` waits for the store's first scan at launch (off the main actor, a few
  ms); call `markPlayed` when a render starts; `renditionRemoved` may name a file that is playing.
- **Lead**: changelog line ("Spatial audio: the cloud version is made once and shared, your phone keeps the ones you
  play"); item 3 above; Android's CLOUD should take the same readings (1, 4, 5, 6).
