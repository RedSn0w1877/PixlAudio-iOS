# Many jobs at once, and jobs that fail and cannot be cleared (2026-10-09, branch `fix-many-jobs-ios`)

Two owner reports, one branch.

1. "when multiple active jobs are working at once it lags up the app and the phone, then crashes".
2. "if the things fail in any way or error or download problem, like no source to download from, it just errors and
   there's no way to clear everything out."

Found by reading the code (no device, no crash log yet). Line numbers are `origin/main` at `3dec9fb`.

## Part 1 — lag, then a crash

### Root causes

1. **Memory: the heavy jobs overlapped.** Nothing ordered them. `TaisStudio` runs one lyric/instrumental job at a
   time, but the model install ran beside it: `ModelManager.finished` (ModelManager.swift:186) extracts and then calls
   `MLModel.compileModel` (:316) on the ~900 MB local AI package, the largest memory spike in the app, while a lyric
   sync (Core ML wav2vec2 ≈ 190 MB, `Wav2Vec2Aligner.swift:89` predicts on the CPU) or a separation (a 44.1 kHz stereo
   decode plus its spectrogram) held hundreds of MB. Add the LLM (~1 GB when loaded), Cloud song preparation (two
   decodes at once, `CloudStudio.swift:764`) and artwork, and iOS ends the app for memory. That is the crash.
2. **Memory: `AudioPCMReader` held the song twice.** It appended every buffer to one interleaved array and then
   built the per-channel arrays from it (AudioPCMReader.swift:45, :62, :70): ~2x the audio at peak, about 170 MB extra
   for a 6-minute stereo song, on top of the separator's own copies.
3. **Release only at the end.** The Core ML models were dropped when the lane drained (`TaisStudio.swift:245`) and
   never on a memory warning; both kinds could be loaded at once when lyric and instrumental jobs alternate.
4. **CPU: the heavy work ran at the creator's priority.** The lane's task (`TaisStudio.swift:249`), the Cloud
   preparations (`CloudStudio.swift:768`) and the install were plain `Task {}` from the main actor, so minutes of
   CPU-only Core ML and FLAC encoding competed with the UI on equal terms: the lag.
5. **Active jobs re-read everything on every tick.** `ActiveJobs.track()` (ActiveJobs.swift:75-80) re-armed its
   observation immediately after every change of every source (a download percent, a cloud upload percent, a lyric
   window, a scan batch) and re-walked all of them; the sheet did the same from its `body`
   (`ActiveJobsSheet.swift:19`: `snapshot()` built, sorted and compared every row on each change, and every row
   re-rendered because its closure made it never equal). With several jobs reporting, that is a few hundred
   passes a second on the main actor. (Home itself was already narrow: it reads `badgeCount` / `isWorking` only.)
6. **Live Activity IPC per progress tick** (`TaisBackgroundRun.swift:64`): `updateTitle` on every report.

Checked and fine (no change): `BackgroundGrace` balances every begin (normal return, throw, expiry, idempotent
`end`); `CloudBackground.ProcessingRun` reports completion once (`BackgroundCompletionGate`) and cancels its work on
expiry; Cloud `pump()` is serialised (`isPumping` / `pumpRequested`), so two passes never run at once, and the
foreground poll is one loop at 15 s that stops in the background; `LocalModelRuntime` already unloads on a memory
warning, in the background and after 180 s; library scans report every 25 files; downloads, model downloads and cloud
transfers publish whole percents only; the `model()` watcher in `TaisStudio` is cancelled by `defer`. No job loads a
whole audio file into memory (every `Data(contentsOf:)` in `App/` reads small state files, and the BS-RoFormer upload
maps its file).

### What changed

- `HeavyJobGovernor` (App/Services): one lease at a time, FIFO, cancellable waiters, idempotent release.
  Taken by lyric alignment and stem separation for their compute part (after the model is in hand, never while
  waiting for the install, which needs the lease: that would deadlock), and by `ModelManager` around extract+compile.
  Pure rules in PixlModel (`HeavyLane`, `UpdateCoalescer`, `JobThrottling.swift`).
- Waiting is visible: `TaisStudio.JobState.waiting` and `ModelManager.waitingToInstall` make Active jobs show the row
  as queued, "Waiting for other work to finish".
- Priority `.utility` for the lane, the install and Cloud preparations; Cloud preparation drops to one song at a time
  while the lane is busy.
- Models: released when the other kind starts and on a memory warning with no job running.
- `AudioPCMReader`: splits channels buffer by buffer (no interleaved copy).
- `ActiveJobs`: re-reads at most 4 times a second (first change after a quiet moment is immediate); one live
  observation at a time (`generation`); sheet rows are stored (`active` / `recent`), refreshed only while the sheet is
  up (`setSheetVisible`), written only when different; `ActiveJobRow` is `Equatable` on its job.
- `TaisBackgroundRun.update`: at most twice a second.

## Part 2 — failures that wedge, and no way to clear them

### Root causes (what could be stuck, and why)

1. **A failed scan left the jobs button lit for ever.** `LibraryStore.refresh` (LibraryStore.swift:120-126) stored
   `lastImportProgress` on every report and never cleared it when the importer threw or was cancelled: a scan that
   died at "40 %" kept a "Library sync 40 %" row and the button's badge until the next successful scan. Nothing could
   cancel a scan either (callers `try?` it from their own tasks).
2. **A model download with no connection never failed.** The models use a *background* `URLSession`
   (ModelManager.swift:96). A background session waits for connectivity without a deadline (up to 7 days), so with the
   phone offline, or a source that never answers, the row sat at "Downloading…" and every lyric sync waiting for the
   model sat behind it. Songs have the same session (DownloadManager.swift:51). A 404 did fail (HTTP status check),
   but with a bare "answered HTTP 404".
3. **"Cancel" did not cancel the install, and an error had no exit.** `ModelManager.cancel` (:162) stopped the
   download only: a running install carried on and then wrote `.installed` over the person's "cancel". The install
   showed a spinner with no button (DownloadedModelRows.swift:86), and a failed model offered only "Retry"
   (:79), so after "no source" the only way out was to retry into the same error.
4. **Song downloads could not be cancelled before their transfer started.** `DownloadManager.download` ran its stream
   lookup in an untracked `Task {}` (DownloadManager.swift:90), so removing or cancelling a download could be undone by
   the lookup finishing a moment later.
5. **The Spotify audio matcher retried for ever.** On network trouble `SpotifyService.startMatching` waited 60 s,
   120 s, … up to an hour and tried again without end (SpotifyService.swift:348-350); the row stayed "running".
6. **Cloud Studio: stale "preparing" and no clear-out.** A job stored as `.preparing` by a process that died was
   requeued only by the first full pass (`reconcileTransfers`, CloudStudio.swift:746), which does not run while the
   feature is off or the keys are missing, so the row said "Preparing the audio" for ever. `clearFinished`
   (CloudStudio.swift:481) removed only *imported* jobs: failed, cancelled and expired ones could only be removed one by
   one from a context menu, and nothing cancelled a whole queue.
7. **Active jobs could only look.** Failed rows could not be dismissed, retried or cleared (the sheet's own comment:
   "Android's sheet has no actions either"); `TaisStudio.cancelAll` cancelled the task but left the running row saying
   "running" until the task noticed; finished studio jobs were never forgotten.

Already right (and now tested): Cloud jobs retry on the 1 / 5 / 15 / 60 minute ladder and fail after 4 automatic
attempts (`CloudJobRecord.recordFailure`); studio jobs end as `.failed(reason)` and the lane, the heavy lease and the
continued-processing run are released by `defer`s; `TaisServices.audioSource` makes 3 attempts of 90 s; the automatic
studio keeps a persistent per-song retry ledger.

### What changed

**Rules (PixlModel, pure, tested on Windows and CI):** `JobFailureText` (one short plain line per failure: HTTP 404 =
"There is nothing to download at the source any more", offline = "No internet connection."), `RetryBudget` (a ladder of
waits, then give up), `StallWatchdog` (a transfer that shows no new byte for N ticks has stopped), and
`ActiveJobBoard.clearable / cancellable / retryable / removing` plus `ActiveJob.canRetry` / `isFinished`.
PixlNet: `CloudStartupRecovery` (a `.preparing` job from a dead process goes back to the queue on load) and
`CloudJobClearing`.

**Services:**
- `StallMonitor` (one 15 s timer for all armed transfers, none while idle) fails a model or song download that
  stops moving for about 1½-2 minutes, cancels the transfer and says why. A suspended app does not tick, so a download
  that carries on in the system's background session is not failed for the time the app was away.
- `ModelManager`: the install is a tracked, cancellable task (a cancel really stops it and releases every waiting job);
  `reset` ("Delete download": forgets the error, removes the leftover archive; never touches an installed model),
  `failures`, `clearFailures`, `cancelAll`; stale staging archives older than an hour are removed at launch; failure
  texts go through `JobFailureText`.
- `DownloadManager`: the lookup is a tracked task; `cancel(videoId:)`, `cancelAll`, `dismissFailure`, `clearFailures`,
  `retry`; same stall watchdog and texts. A lyric/instrumental job waiting for a song whose download was cancelled ends
  at once instead of starting it again.
- `LibraryStore.refresh`: runs the scan as a tracked task, always clears the progress when it ends (done, failed or
  cancelled), keeps `scanFailure`, `cancelScans()`.
- `SpotifyService`: `syncFailure` / `matchFailure`, `cancelSync` / `cancelMatching`, a generation guard so a replaced or
  cancelled pass never clears its successor's flag; the matcher gives up after 5 failures in a row (1+2+4+8 minutes)
  with "Finding audio gave up…".
- `TaisStudio`: `cancelAll` marks the running row cancelled at once, `cancelAll(kind:)`, `clearFinished`, `dismiss`,
  `activeCount`; network errors are worded plainly.
- `CloudStudio`: `cancelAll`, `cancelBatch`, `clearAllFinished`, `clearBatch`, `clearAttention`, `retryBatch`;
  stale `.preparing` jobs are requeued on load.

**Screens (Liquid Glass, fills on glass rows, no glass on glass):**
- Active jobs sheet: **Cancel all** (glass pill with a confirmation; stops every source for real), **Clear finished**
  (glass pill; removes every done and failed row, not only the five listed; "and N more finished" says how many hide),
  per finished row a **Dismiss** (✕) and, where the source can do it, **Retry**; a running row's context menu has
  **Cancel**. VoiceOver gets the same as custom actions. The button's badge counts running and waiting jobs only; with
  nothing running it is not shown (failed leftovers cannot keep it lit).
- Cloud queue: **Cancel all** under "On its way" (confirmation), **Clear failed** under "Needs you" (next to the
  existing "Clear done").
- Settings > AI features (and Experimental > On-device models): a failed model download shows the reason with **Try
  again** and **Delete download**; while installing there is now a **Cancel**.

### Where a failure still shows, now that the button hides

The button hides when nothing is running. A failure is shown in the sheet while anything else runs, and always where
its job lives: the song's studio card (lyric sync / instrumental), Cloud queue "Needs you", the model row in
Settings. Backup restore and export keep their own progress screens (unchanged).

## Tests

- PixlModel: `JobFailuresTests` (words, retry budget, stall watchdog), `ActiveJobClearingTests` (badge, clear, cancel,
  retry, dismiss), plus the earlier `JobThrottlingTests`.
- PixlNet: `CloudStartupRecoveryTests` (stale-running recovery, clear / cancel / retry sets, bounded automatic retry).
- AppTests `JobFailureHandlingTests`: a job with no source fails with a reason and frees the lane, the next one runs;
  an offline failure reads "No internet connection."; clear finished / dismiss / cancel all / cancel a kind on the
  studio; model and song download failure, reset, cancel all and the stall watchdog; a failed scan leaves no progress
  and says why; cancelling a scan stops it; the sheet's clear / cancel / dismiss / retry on the demo rows and every
  row id mapping back to its source. `HeavyJobGovernorTests` as before.
- UI: `ActiveJobsScreenshotTests` — `jobs.failed` (light / dark), Clear finished, Cancel all with its confirmation,
  Dismiss and Retry on one row, and the failed model download with Try again / Delete download.

## Check on the phone

Start 3 or 4 things at once and do not wait: (1) lyric sync for a whole playlist, (2) Settings > Library > Full
Rescan, (3) Cloud Studio instrumentals for 3-4 songs, (4) download the local AI model (Settings > AI features, turn on
"Use downloaded AI model"). Open Home > Active jobs.

1. The sheet stays smooth and scrolls; rows update about four times a second; the lyric sync runs one song at a time;
   the model install shows "Waiting for other work to finish…" while a lyric song computes; the phone is warm but the
   UI keeps up; no crash.
2. While the model downloads, turn on **airplane mode**. Within about two minutes the model row fails with a reason
   ("The download stopped: no data is arriving. Check your connection and try again.") instead of sitting at a
   percentage; the lyric sync waiting for it fails too. The failed row has **Retry** and **✕**.
3. **Clear finished** empties "Recently finished" (the failed rows, and anything else finished). **Cancel all** (it
   asks first) stops the scan, the lyric sync, the cloud jobs and any download; the sheet then says "Nothing running
   right now." and the button on Home disappears.
4. Settings > AI features: with a failed model download, **Try again** restarts it, **Delete download** puts the row
   back to "Not downloaded". While "Checking and installing…" there is a **Cancel**.
5. Cloud queue: **Clear failed** under "Needs you", **Cancel all** under "On its way".
6. Kill the app while a Cloud job says "Preparing the audio", reopen: it is "Waiting" again, not stuck.

**If it still crashes, please send the crash log:** Settings > Privacy & Security > Analytics & Improvements >
Analytics Data, the newest `PixlAudio` entry (a `.ips`; "jetsam" / "EXC_RESOURCE" in it means memory). Also say which
jobs were running.

## Could not verify without a device

Real peak memory and how long the install now waits behind a long lyric batch (it gets the lane between songs, FIFO).
Whether the iPhone model's jetsam limit is hit by the install alone (the local AI package compile). Whether the
`.utility` priority is enough on an older chip. The stall watchdog's two-minute figure against a very slow connection
(a download that really moves a byte every minute is not failed; one that moves nothing for ~2 minutes is). How the
system's background session reports a download it dropped while the app was dead (the launch re-attach arms the same
watchdog).
