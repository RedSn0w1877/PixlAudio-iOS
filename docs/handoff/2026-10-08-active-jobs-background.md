# Active jobs on Home + background processing (2026-10-08, branch `s25-active-jobs`)

Owner's request: "can you also implement an active jobs button on home just like on android and make it looks
niceish? and implement background processing too".

## What was built

### Home "Active jobs" button and sheet (a port of Android's)
- **Where:** Home's top row, left of the changelog and settings circles — where Android's `HomeGradientTopBar` puts its
  `BadgedBox` jobs button. Like Android, it only shows while something is queued or running.
- **Look:** a Liquid Glass capsule tinted with the accent's container colour, a sync symbol and the count. The symbol
  turns while a job is actually working (not while jobs only wait), and stays still with Reduce Motion. It appears and
  goes with a short spring; the number rolls when it changes. Light haptic on tap. VoiceOver reads "Active jobs, 3
  active jobs".
- **Sheet:** Android's `JobsBottomSheet` layout (title, then one row per job: ring or spinner, label, detail line,
  bar when the percentage is known) with each row as a glass card. Below the running ones, **Recently finished** keeps
  the last day's done and failed rows (at most 5), so after the app comes back you can see what happened while it was
  closed. A Cloud row opens the Cloud queue (where Retry and Cancel live; Android's sheet has no buttons either).
- **What it lists (only work that reports real progress):** library scan, Spotify import, Spotify "Finding audio",
  offline song downloads, AI/ML model downloads and installs, lyric sync / instrumentals / BS-RoFormer (one row per kind:
  the song being worked on and how many wait), and Cloud Studio (one row per batch: "5 of 12 ready · 3 uploading · …"
  with a bar).
- **How:** `App/Services/ActiveJobs.swift` is one `@Observable` aggregator fed by the services that already track the
  work; Home reads only its count, which is written only when it changes (no re-render on progress ticks). The sheet
  reads the full rows only while it is open. Ordering, counting and wording are pure PixlCore code with tests
  (`ActiveJob`/`ActiveJobBoard` in PixlModel, `CloudActiveJobMapper` in PixlNet).

### Background processing
iOS has no WorkManager. What the app now does with the tools iOS gives a sideloaded app (no push, no extensions):

| Work | While the app is in the background / closed |
|---|---|
| Cloud uploads and result downloads | Keep going in iOS's transfer daemon (background URLSession). iOS wakes the app when they finish; the app then submits uploaded songs to RunPod and imports what came back. (Already there; unchanged.) |
| Cloud: checking RunPod and importing results | **New:** a BGProcessing task (`…cloud-processing`, needs network, not power) on top of the existing BGAppRefresh. iOS runs it when the phone is idle (often while charging or overnight). It polls RunPod every 30 s for up to 2 minutes and imports lyrics and queues instrumental downloads as results arrive. Both requests are made only while jobs are outstanding, and withdrawn when nothing is left (`CloudBackgroundPlanner`). |
| Cloud: in the last seconds of any wake | **New:** nothing new starts (no upload, submission or download in the last 8 s of a short wake or 15 s of a long one), and the job list is always saved before the wake ends. When iOS takes the time back early, the pass stops cleanly and the next request is already placed. |
| Cloud: preparing a batch you just sent | Continued processing with the system's progress UI (already there). |
| "Your instrumentals are ready" | **New:** one local notification per finished batch, only when the app is not on screen. Tapping it opens the Cloud queue. Switch: Settings › Developer › Experimental › Cloud processing › Notifications › "Notify me when it's done" (on by default). iOS asks for permission the first time you send songs, never at launch. A batch you cancelled yourself, or one that was already finished before, never notifies. |
| Lyric sync, instrumentals you started | Continued processing (already there). Now also holds the ordinary ~30 s of background time from the tap until iOS hands over the continued-processing task. |
| Library scan, Spotify import and matching, model install | **New:** the honest minimum (`BackgroundGrace`): about 30 seconds to finish after you switch apps. If that is not enough, iOS suspends the app and the work carries on when you open it again. Spotify then also asks for its own background refresh, which resumes the import in slices. None of these is resumable mid-file, so they don't get a processing task. |

**What iOS cannot do here (and the app does not pretend to):**
- **Force-quit stops everything** — transfers, wakes, notifications — until you open the app again. This is iOS's rule.
- iOS decides **when** background wakes happen; none in Low Power Mode or with Background App Refresh off for
  PixlAudio. A batch may only be imported the next time you open the app; the results wait safely in the cloud.
- Downloads started during a background wake are "discretionary": iOS may wait for Wi-Fi and power.
- Automatic studio work ("Ready when you play") still runs only while the app is open, by design.
- The GPU work itself never needs the phone: RunPod keeps working whatever the phone does.

## Your iPhone checklist

- [ ] With nothing running, Home's top row has only Beta, changelog and settings.
- [ ] Start a lyric sync (or a library rescan): the jobs capsule appears with a count; its symbol turns. Tap it: the
      sheet lists the job with a ring and a bar. The capsule goes away when it is done.
- [ ] Send 2–3 songs for instrumentals (Cloud queue › Add). The first time, iOS asks about notifications: allow.
      Home's capsule shows the batch; the sheet says "0 of 3 ready · 3 uploading …". Tap the Cloud row: the queue opens.
- [ ] Lock the phone for 10+ minutes (charging helps). A notification "Your instrumentals are ready" arrives. Tap it:
      PixlAudio opens on the Cloud queue with the songs done.
- [ ] Open Home after that: the sheet's "Recently finished" shows the batch as done.
- [ ] Turn "Notify me when it's done" off, send one song, lock the phone: no notification; the results are still there
      when you open the app.
- [ ] Start a library rescan and switch apps right away for a minute: it either finished, or carries on when you return.
- [ ] VoiceOver on Home: the capsule reads "Active jobs, N active jobs"; each sheet row reads its label, song and
      percentage.
- [ ] Reduce Motion on: the capsule's symbol does not turn.
- [ ] Optional: Settings › General › Background App Refresh off for PixlAudio: nothing breaks; results come in when
      you open the app.

## Where things are
- `App/Services/ActiveJobs.swift`, `App/Features/Home/ActiveJobsButton.swift`, `App/Features/Home/ActiveJobsSheet.swift`,
  `App/Demo/ActiveJobsDemo.swift` (UI-test fixtures: `-screen home.jobs`, `jobs`, `jobs.mixed`, `jobs.none`).
- `App/Services/Cloud/CloudBackground.swift` (BGAppRefresh + BGProcessing requests and handler),
  `CloudNotifier.swift` (local notification + tap routing), `CloudStudio.swift` (wake windows, notifications, saving),
  `App/Services/BackgroundGrace.swift`.
- Pure logic + tests: `Packages/PixlCore/Sources/PixlModel/ActiveJob.swift`,
  `Packages/PixlCore/Sources/PixlNet/Cloud/{CloudActiveJobs,CloudBackgroundPlanner,CloudBatchNotifications}.swift`.
- Tests: PixlCore `ActiveJobBoardTests`, `CloudActiveJobsTests`, `CloudBackgroundPlannerTests`,
  `CloudBatchNotificationTests`; AppTests `CloudBackgroundTests`, `ActiveJobsTests`; UITests `ActiveJobsScreenshotTests`.
- The background task handlers themselves can't run in CI: they are thin, and the phone checks above cover them.
- `project.yml`: `io.github.redsn0w1877.pixlaudio.cloud-processing` added to `BGTaskSchedulerPermittedIdentifiers`
  (`UIBackgroundModes` already had `fetch` and `processing`).
