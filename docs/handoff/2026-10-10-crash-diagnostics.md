# Crashes, diagnostics and cancel controls (2026-10-10, branch `fix-crash-diagnostics-ios`)

Owner report (iPhone 13, 3.58 GB, iOS 27.0): "kept crashing, plus I didn't see any log generator inside the app, and
there's still no cancel button or cancel all anywhere." Five iOS reports came with it, **all from builds before the
many-jobs fix (2026-10-10, `docs/handoff/2026-10-09-many-jobs-fix.md`)**, so it is not known whether current `main`
still crashes. This branch makes the app say which build it is, keep its own log, protect itself after a crash, and stop
doing the things the reports show. Nothing here could be run on a device (no Mac, no phone): CI compiles and runs the
tests and the screenshots.

## What each report says, and what answers it

Line numbers are on this branch.

### 1. The crash: `PixlAudio-2026-10-08-212618.ips` (SIGKILL, 0x8BADF00D, scene-update watchdog)

The main thread was in SwiftUI's scroll-view layout, inside the snapshot the system takes when the app goes to the
background, and did not finish in 10 s. The thread list shows who else was busy:

- `io.github.redsn0w1877.pixlaudio.localmodel` was **inside a Metal Performance Shaders Graph encode step**: the
  downloaded AI model's generation, on the GPU, while the app's `ProcessVisibility` was Background.
- `LocalModelRuntime` already unloaded "when the app goes to the background", but the unload was a `queue.async` on the
  same serial queue the generation was running on, so it ran **after** the generation instead of stopping it. A
  generation can run for minutes; a backgrounded app may not submit GPU work, and the system's reaction on a busy main
  thread is the 10 s watchdog (the 39 s of *system* CPU time in the report fits a process fighting the kernel for
  the GPU and for memory).
- A `background-qos` thread was reading file attributes (a library scan) at the same time.

Fixes:

- `LocalModelRuntime.swift:229` `CancelFlag.isSet`: a generation stops at its next model step once the app has been out of
  the foreground for 1.5 s (a short Control Center pull only pauses it), or when everything heavy is told to stop
  (critical memory event, Emergency stop). `:131` no prewarm and `:185` no model load while not in front; `:190` the
  GPU is used only in the foreground. Generation start/end go to the in-flight journal (`JobTelemetry`, kind `localModel`).
- Heavy loops pause in the background: `HeavyWorkGate` / `WorkPacer` (`App/Services/Diagnostics/HeavyWorkGate.swift`),
  checkpoints between chunks in the lyric aligner (`Wav2Vec2Aligner.swift:73,81`), the separator
  (`MdxStemSeparator.swift:44,52`), the song decode (`AudioPCMReader.swift:61`) and the Cloud decode
  (`CloudAudioPreparer.swift:333,421`). Pure rules (and tests): `HeavyWorkPolicy` in PixlModel.
- Inside a window iOS granted (a `BGContinuedProcessingTask`, a background-task assertion, a BGProcessingTask) heavy work
  may carry on: `TaisBackgroundRun`, `BackgroundGrace`, `CloudBackground` tell the gate (`windowOpened/Closed`).

What is **not** proven: that this was the only cause. The report cannot show what the main thread waited on. The fix
removes the one thing that was demonstrably running that must not run there.

### 2. `cpu_resource` 2026-10-08 17:02 (122 s, 74 % CPU, +609 MB) and 5. `cpu_resource` 2026-10-04 (89 %)

Core ML on the **CPU (BNNS)**, driven from our code, while the app was in front. Both aligner and separator were forced
to `.cpuOnly` (`Wav2Vec2Aligner` / `MdxStemSeparator`), for minutes at full speed, at the creator's priority (before
the many-jobs fix put them on `.utility`), plus decoding at the same time.

Fixes:

- `ModelCompute.swift`: `.cpuAndNeuralEngine` in the foreground on a cool phone with no Low Power Mode, `.cpuOnly`
  otherwise and after any Neural Engine failure (load or prediction; it falls back and says so in the log). The CI
  conversion gate (`ci/ml/convert_wav2vec2.py:279`, `convert_mdx.py:186`) only ships a precision that passed on **both**
  CPU_ONLY and ALL, so the Neural Engine is within what was measured.
- Duty cycle: after each window the pacer sleeps so the average CPU share is 50 % (35 % warm, 30 % in Low Power Mode, 20 %
  after a memory warning; paused when serious/critical). `HeavyWorkPolicyTests.theDutyCycleKeepsAverageCpuUnderHalf...`
  simulates 3 minutes and checks the average.
- Memory: `AudioPCMReader.swift:24` caps a decode by the phone's memory (`HeavyWorkPolicy.maxDecodeSeconds`: about
  11 minutes of 44.1 kHz stereo on a 3.5 GB phone, 20 minutes of 16 kHz mono); it already splits channels buffer by buffer.
  The separator still keeps the mix and its result (PixlAudioCore's `MdxSeparation` computes the gain from both, and it is
  parity-tested, so it was not restructured): the cap is what bounds it.
- One heavy lane (many-jobs fix), models released when the other kind starts and on memory warnings.

### 3. `cpu_resource` 2026-10-08 20:42 (142 s, two AAC/MP3 decoders in a tight loop)

That is Cloud Studio's "Preparing the audio": `CloudAudioPreparer.decode` plus the read-back count, two `AVAssetReader`
loops with no pause. Now both call the pacer per buffer (`CloudAudioPreparer.swift:333,421`) and the stored queue does
not start preparing by itself in safe mode (`CloudStudio.startPreparations`; sending songs is the go-ahead).

### 4. `diskwrites_resource` 2026-10-08 16:42 (1.07 GB in 18 s, non-frontmost, background QoS)

`ModelManager.finished` ran the install (extract + `MLModel.compileModel`, a ~900 MB package) as soon as the **background
URLSession** finished the download, which can be while the app is in the background; it only held a 30 s grace. Now the
install **waits for the foreground** (`ModelManager.swift:302`, row says "Installs when PixlAudio is open"), takes the
heavy lane after that, never starts twice (`installTasks[id] == nil` guard), and a download left behind is installed
without downloading ~900 MB again (`download(_:)` checks the staging archive). Model loads (`ModelCompute.load`, aligner,
separator, LLM) also refuse to happen out of the foreground.

## What was added

### A. Safe mode (crash-loop protection)

- `AppHealth.launch()` (`AppHealth.swift:69`): a **clean-exit marker file** is written when the app goes to the background
  with nothing heavy in flight (or later, once the last heavy job ends while backgrounded) and on `willTerminate`;
  deleted when the app becomes active and at launch. No marker at launch after an earlier run = abnormal end. MetricKit
  crash / hang / CPU-exception / disk-write diagnostics count too (`MetricKitCollector`), once per launch.
- Abnormal end: safe mode on, a one-time Home banner ("PixlAudio closed unexpectedly while working. Heavy jobs are
  paused — tap to review", `SafeModeBanner`), and what the **in-flight journal** (`JobTelemetry`, a small JSON file of kind
  + opaque reference per heavy job: lyric sync, separation, model install, library scan, Spotify matching, the local
  model) held becomes **"Interrupted" rows with Retry / Dismiss** in Active jobs (`ActiveJobs.interruptedRows`).
- Nothing heavy starts by itself while it is on: the automatic studio (`AutomaticStudioRunner.scan`), the launch / foreground
  library rescan (`LibraryAutoRefresh`), the Spotify matcher at launch (`SpotifyService.start`), Cloud preparing
  (`CloudStudio.startPreparations`), the install of a download a previous run left behind (`ModelManager.finished`). What
  the person starts by hand still works. **Retry** on an interrupted row, sending songs to the cloud, or turning the switch
  off lifts it for the run.
- Two abnormal ends in a row: sticky, stays on through clean sessions until Settings › Developer › Diagnostics › Safe mode
  is turned off. One abnormal end followed by a clean session: back to normal. A retried run that ends cleanly clears it.
- Rules are pure and tested: `SafeModePolicy` (PixlModel, `SafeModeTests`), wiring in `CrashProtectionTests`.

### B. Good citizen

Scene phase → `HeavyWorkGate` (inactive and background pause heavy work unless a window was granted); `ProcessInfo`
thermal state and Low Power Mode slow or pause it; `DispatchSource` memory pressure and `didReceiveMemoryWarning`
release idle models and the local LLM, stop unattended jobs (`TaisStudio.handleMemoryWarning`, :297), and on a **critical**
event stop every heavy job with a reason and a Retry (`stopForMemory`, :304). Home and the Active jobs sheet were
audited: lazy stacks, no `GeometryReader` loops, 4 Hz coalesced publishes (many-jobs fix), the banner is one small view
reading one rarely-changing property.

### C. Diagnostics (Settings › Developer › Diagnostics, and a card in About)

- Build identity: `BuildStamp` (commit short sha and day, written by `ci/write-build-identity.sh` on CI; the committed stub
  says "local build"), shown first in About, in Diagnostics and in every exported log.
- Live status: memory footprint (`phys_footprint`), physical memory, thermal state, Low Power Mode, heavy jobs running /
  waiting, scene, last memory warning, whether the previous run ended unexpectedly, device model, iOS, safe mode.
- Event log: `DiagnosticsLog`, ~1 MB ring file (`LogRing`), mirrored to `os.Logger`; app lifecycle, memory and thermal
  events, job start / finish / fail / cancel with duration and reason, abnormal-end detection, safe-mode decisions,
  background windows. Opaque ids and job kinds only; `LogRedactor` strips paths, URLs (host only), e-mail addresses and
  token-like strings.
- MetricKit: `MetricKitCollector` stores diagnostic and metric payload JSON (newest 10 / 5).
- **Share logs**: one `.txt` (identity, status, safe mode, event log, MetricKit payloads) through the share sheet.
- **Emergency stop** (confirmation): `ActiveJobs.emergencyStop()` cancels every source for real (library scans, Spotify
  import and matcher, song and model downloads, the install, studio jobs including the automatic ones, Cloud Studio),
  forgets finished / failed / interrupted records, clears the journal, releases the Core ML and local models, and keeps
  automatic work off for ten minutes. The log is kept (evidence).

### D. Cancel everywhere a job shows progress

Added: Home capsule long press (Open, Cancel all with confirmation); Settings › Library rescan row (Cancel); the lyrics
screen's "Rendering instrumental" (Cancel); a song's Offline card while downloading (Cancel download); Spotify dashboard
import and "Finding audio" (Cancel); the setup flow's library scan (Cancel scan). Already had one: Active jobs sheet (Cancel
all, per-row Cancel, Clear finished), Cloud queue, the Settings model rows, the Remaster Song progress card.

## Tests

- PixlModel: `SafeModeTests` (policy, journal, pacing rules, redaction, ring, report).
- AppTests `CrashProtectionTests`: log cap and redaction, journal across a relaunch, launch decisions (clean, killed while
  working, backgrounded with work running, retry, sticky, switch off, cloud go-ahead), report content, the gate and the
  pacer, the generation stop flag, Emergency stop on the demo sheet, low-memory stop and Clear leaving the studio empty.
- UI: `ActiveJobsScreenshotTests` (`jobs.interrupted`, `home.safeMode`, Retry / Dismiss, banner), `ScreenshotTests`
  extension `DiagnosticsScreenshotTests` (Diagnostics and About, Emergency stop confirm and done).

## Phone checklist

1. Settings › About shows "Build N · commit xxxxxxx · date". Make sure that commit is the one you meant to install.
2. Start a lyric sync, the AI model download/install and a Cloud job. Press Home, then lock the phone mid-job. The app must
   not be killed. Reopen: the model row said "Installs when PixlAudio is open" and now installs; the lyric sync waited in the
   background unless iOS gave it time (its Live Activity), then carried on.
3. Force-quit PixlAudio in the middle of a lyric sync or a model install, reopen: the Home banner shows, Active jobs lists the
   job as **Interrupted** with Retry, **nothing restarts by itself** (no automatic studio, no rescan, no Spotify matching).
   Retry starts it. Close it cleanly and reopen: the banner is gone and normal behaviour is back. Force-quit twice in a row
   while working: Diagnostics › Safe mode stays on until you switch it off.
4. Settings › Developer › Diagnostics: the build line is at the top, Live status updates, **Share logs** opens the share sheet
   with a `.txt`, **Emergency stop** (asks first) leaves Active jobs empty and the banner gone.
5. Cancel exists on: the Home capsule (hold it), Active jobs, Settings › Library rescan, a song's Offline card while it
   downloads, the lyrics screen while it renders an instrumental, Spotify dashboard import / matching, the Cloud queue and the
   AI model rows.

## If it still crashes

Settings › Developer › Diagnostics › **Share logs** right after reopening the app, and the newest PixlAudio entry from
Settings › Privacy & Security › Analytics & Improvements › Analytics Data. Say which jobs were running. MetricKit payloads
(crash, hang, CPU, disk) appear in the log up to a day after the event.

## Could not verify without a device

- Whether the main-thread starvation in the watchdog report had only the LLM generation behind it.
- The Neural Engine path for the two Core ML models on a real iPhone 13 (load time, first-use compile writes, and that results
  match; a failure falls back to CPU and is logged as `model` events).
- That MetricKit delivers on a sideloaded, free-account build (it does not in the simulator).
- The duty cycle's effect on total lyric-sync time (it roughly doubles while the app is in front; Low Power Mode and heat
  make it slower on purpose).
- The 1.5 s grace of the generation stop against a real Control Center pull.
