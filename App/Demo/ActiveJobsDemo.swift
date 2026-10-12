import Foundation
import PixlModel

/// Home's "Active jobs" for UI tests (`-screen home.jobs`, `jobs`, `jobs.none`, `jobs.mixed`): fixed rows, so the
/// screenshots are the same on every run. No source is touched.
enum ActiveJobsDemo {
    enum Fixture {
        /// Nothing running: the button is hidden on Home, the sheet says so.
        case none
        /// A cloud batch with a bar, lyric sync mid-song, a library scan, audio matching, and instrumentals waiting.
        case running
        /// The same, plus what finished (a done batch) and what needs attention (a failed one, a failed sync).
        case mixed
        /// A few things still running, and what went wrong: a model with no source, a download with no connection, a
        /// cloud batch, a library sync, the matcher and a lyric sync (the Retry / Dismiss / Clear finished state).
        case failures
        /// After the app closed unexpectedly: two things still waiting, and what was interrupted (Retry, Dismiss).
        case interrupted
    }

    /// 2026-10-07 18:00 UTC, the same clock as `CloudDemo`.
    static let now: Int64 = 1_791_396_000_000

    static func fixture(for screen: DemoScreen?) -> Fixture {
        switch screen {
        case .jobsNone: .none
        case .jobsMixed: .mixed
        case .jobsFailed: .failures
        case .jobsInterrupted: .interrupted
        case .homeJobs, .jobs: .running
        default: .none
        }
    }

    static func make(launch: LaunchConfiguration) -> ActiveJobs {
        ActiveJobs(demo: rows(fixture(for: launch.screen)), nowMs: now)
    }

    static func rows(_ fixture: Fixture) -> [ActiveJob] {
        switch fixture {
        case .none: return []
        case .running: return running
        case .mixed: return running + finished
        case .failures: return Array(running.prefix(3)) + failures
        case .interrupted: return Array(running.suffix(2)) + interrupted
        }
    }

    private static var running: [ActiveJob] {
        [
            ActiveJob(id: "cloud.demo", kind: .cloud,
                      subtitle: "5 of 12 ready · 3 uploading · 2 waiting for a GPU · 2 processing", percent: 58,
                      state: .running, destination: .cloudQueue, updatedAtMs: now),
            ActiveJob(id: "tais.lyricsSync", kind: .lyricsSync, subtitle: "Neon Harbor · Aligning words · 2 waiting",
                      percent: 64, state: .running, updatedAtMs: now),
            ActiveJob(id: "library", kind: .libraryScan, subtitle: "Scanning music folders", percent: 35,
                      state: .running, updatedAtMs: now),
            ActiveJob(id: "spotify.match", kind: .spotifyMatch, subtitle: "1,204 of 3,861 songs", percent: 31,
                      state: .running, updatedAtMs: now),
            ActiveJob(id: "tais.instrumental", kind: .instrumental, subtitle: "3 songs waiting", state: .queued,
                      updatedAtMs: now),
        ]
    }

    private static var finished: [ActiveJob] {
        [
            ActiveJob(id: "cloud.earlier", kind: .cloud, subtitle: "12 songs processed", percent: 100, state: .done,
                      destination: .cloudQueue, updatedAtMs: now - 25 * 60_000),
            ActiveJob(id: "cloud.failed", kind: .cloud, subtitle: "9 of 12 ready · 3 need you", state: .failed,
                      destination: .cloudQueue, updatedAtMs: now - 3 * 3_600_000, canRetry: true),
            ActiveJob(id: "tais.failed.lyricsSync.demo", kind: .lyricsSync,
                      subtitle: "Glass Hours · The lyric sync model isn't downloaded yet", state: .failed,
                      updatedAtMs: now - 5 * 3_600_000, canRetry: true),
        ]
    }

    /// What the previous run had in flight when it ended abnormally: "Interrupted", nothing restarted by itself.
    private static var interrupted: [ActiveJob] {
        [
            ActiveJob(id: "interrupted.lyricsSync.demo1", kind: .lyricsSync, title: "Interrupted",
                      subtitle: "Lyric sync · Neon Harbor · PixlAudio closed while this was running", state: .failed,
                      updatedAtMs: now - 4 * 60_000, canRetry: true),
            ActiveJob(id: "interrupted.modelDownload.wav2vec2", kind: .modelDownload, title: "Interrupted",
                      subtitle: "Model install · Lyric sync model · PixlAudio closed while this was running",
                      state: .failed, updatedAtMs: now - 4 * 60_000, canRetry: true),
            ActiveJob(id: "interrupted.instrumental.demo2", kind: .instrumental, title: "Interrupted",
                      subtitle: "Instrumental · Glass Hours · PixlAudio closed while this was running", state: .failed,
                      updatedAtMs: now - 4 * 60_000, canRetry: true),
        ]
    }

    /// Six finished rows (the sheet lists the newest five and says so), five of them failed.
    private static var failures: [ActiveJob] {
        [
            ActiveJob(id: "model.failed.llm", kind: .modelDownload, title: "Model download failed",
                      subtitle: "Local AI model · There is nothing to download at the source any more (HTTP 404).",
                      state: .failed, updatedAtMs: now - 2 * 60_000, canRetry: true),
            ActiveJob(id: "download.failed.demo1", kind: .songDownload, title: "Download failed",
                      subtitle: "Glass Hours · No internet connection.", state: .failed,
                      updatedAtMs: now - 3 * 60_000, canRetry: true),
            ActiveJob(id: "cloud.failed", kind: .cloud, subtitle: "9 of 12 ready · 3 need you", state: .failed,
                      destination: .cloudQueue, updatedAtMs: now - 9 * 60_000, canRetry: true),
            ActiveJob(id: "spotify.match.failed", kind: .spotifyMatch, title: "Finding audio failed",
                      subtitle: "Finding audio gave up: YouTube Music could not be reached. Try again later.",
                      state: .failed, updatedAtMs: now - 14 * 60_000, canRetry: true),
            ActiveJob(id: "tais.failed.lyricsSync.demo", kind: .lyricsSync,
                      subtitle: "Glass Hours · The lyric sync model isn't downloaded yet", state: .failed,
                      updatedAtMs: now - 20 * 60_000, canRetry: true),
            ActiveJob(id: "cloud.earlier", kind: .cloud, subtitle: "12 songs processed", percent: 100, state: .done,
                      destination: .cloudQueue, updatedAtMs: now - 25 * 60_000),
        ]
    }
}
