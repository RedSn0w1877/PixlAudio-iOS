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
    }

    /// 2026-10-07 18:00 UTC, the same clock as `CloudDemo`.
    static let now: Int64 = 1_791_396_000_000

    static func fixture(for screen: DemoScreen?) -> Fixture {
        switch screen {
        case .jobsNone: .none
        case .jobsMixed: .mixed
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
                      destination: .cloudQueue, updatedAtMs: now - 3 * 3_600_000),
            ActiveJob(id: "tais.failed.lyricsSync.demo", kind: .lyricsSync,
                      subtitle: "Glass Hours · The lyric sync model isn't downloaded yet", state: .failed,
                      updatedAtMs: now - 5 * 3_600_000),
        ]
    }
}
