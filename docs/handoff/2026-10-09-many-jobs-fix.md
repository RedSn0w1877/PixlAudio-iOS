# Many jobs at once: lag, then a crash (2026-10-09, branch `fix-many-jobs-ios`)

Owner report: "when multiple active jobs are working at once it lags up the app and the phone, then crashes".
Found by reading the code (no device, no crash log yet). Line numbers are `origin/main` at `3dec9fb`.

## Root causes

1. **Memory: the heavy jobs overlapped.** Nothing ordered them. `TaisStudio` runs one lyric/instrumental job at a
   time, but the model install ran beside it: `ModelManager.finished` (ModelManager.swift:198) extracts and then calls
   `MLModel.compileModel` (:316) on the ~900 MB local AI package, the largest memory spike in the app, while a lyric
   sync (Core ML wav2vec2 ≈ 190 MB, `Wav2Vec2Aligner.swift:89` predicts on the CPU) or a separation (a 44.1 kHz stereo
   decode plus its spectrogram) held hundreds of MB. Add the LLM (~1 GB when loaded), Cloud song preparation (two
   decodes at once, `CloudStudio.swift:764`) and artwork, and iOS ends the app for memory. That is the crash.
2. **Memory: `AudioPCMReader` held the song twice.** It appended every buffer to one interleaved array and then
   built the per-channel arrays from it (AudioPCMReader.swift:45, :72): ~2x the audio at peak, about 170 MB extra for
   a 6-minute stereo song, on top of the separator's own copies.
3. **Release only at the end.** The Core ML models were dropped when the lane drained (`TaisStudio.swift:245`) and
   never on a memory warning; both kinds could be loaded at once when lyric and instrumental jobs alternate.
4. **CPU: the heavy work ran at the creator's priority.** The lane's task (`TaisStudio.swift:249`), the Cloud
   preparations (`CloudStudio.swift:768`) and the install were plain `Task {}` from the main actor, so minutes of
   CPU-only Core ML and FLAC encoding competed with the UI on equal terms: the lag.
5. **Active jobs re-read everything on every tick.** `ActiveJobs.track()` (ActiveJobs.swift:77) re-armed its
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
transfers publish whole percents only; the `model()` watcher in `TaisStudio` is cancelled by `defer`.

## What changed

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
  up (`setSheetVisible`), written only when different; `ActiveJobRow` is `Equatable` on its job. Look unchanged.
- `TaisBackgroundRun.update`: at most twice a second.
- Tests: `JobThrottlingTests` (PixlModel, 9), `HeavyJobGovernorTests` (AppTests, 5). Rules in `docs/performance.md`
  (Many jobs at once) and `docs/api-notes.md`.

## Reproduce on the phone

Start, in this order and without waiting: (1) lyric sync for a whole playlist, (2) Settings > rescan library,
(3) Cloud Studio instrumentals for 3-4 songs, (4) download the local AI model. Open Home > Active jobs.
Expect: the sheet stays smooth and scrolls; rows update about four times a second; the lyric sync runs one song at a
time; the model install shows "Waiting for other work to finish…" while a lyric song computes and proceeds between
songs; the phone is warm but the UI keeps up; no crash. Memory Gauge in Xcode is not needed: if it still dies, the log
tells which job.

## Could not verify without a device

Real peak memory and how long the install now waits behind a long lyric batch (it gets the lane between songs, FIFO).
Whether the iPhone model's jetsam limit is hit by the install alone (the local AI package compile). Whether the
`.utility` priority is enough on an older chip.

## Request for the owner

If it still crashes, please send the crash log: Settings > Privacy & Security > Analytics & Improvements > Analytics
Data, the newest `PixlAudio` entry (a `.ips`; "jetsam" / "EXC_RESOURCE" in it means memory). Also say which jobs were
running.
