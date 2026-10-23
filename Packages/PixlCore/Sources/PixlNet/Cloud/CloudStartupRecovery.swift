// What a launch does with the Cloud jobs it finds on disk, and which jobs "Clear finished" / "Cancel all" touch. Pure:
// the app hands over the records and applies the result; the rules are tested here.

import Foundation

public enum CloudStartupRecovery {
    /// A job stored as "preparing" was being decoded by a process that no longer exists: nothing is working on it and
    /// nothing will, so it goes back to the queue (its audio is prepared again). Without this the job shows as
    /// "Preparing the audio" for ever whenever the first pass cannot run (the feature is off, the keys are missing).
    /// Returns how many jobs were put back. Every other step survives a launch: transfers belong to the system's
    /// background session, RunPod keeps its jobs, and `CloudStudio.reconcileTransfers` checks the rest.
    @discardableResult
    public static func recover(_ jobs: inout [CloudJobRecord], nowMs: Int64) -> Int {
        var changed = 0
        for index in jobs.indices where jobs[index].state == .preparing {
            if jobs[index].apply(.requeue, nowMs: nowMs) { changed += 1 }
        }
        return changed
    }

    /// Sing's preview pieces still on their way from an earlier launch: what they were for (a minute of a song playing
    /// then, and the wish to sing it) did not survive the process, and their files are cleared at launch, so they are
    /// stopped instead of being separated for nothing.
    public static func staleClips(_ jobs: [CloudJobRecord]) -> [String] {
        jobs.filter { $0.isClip && $0.state.isPending }.map(\.jobKey)
    }

    /// The cloud no longer times or writes lyrics (2026-10-23). Jobs stored before that which RunPod doesn't have yet
    /// (queued, preparing, uploading or uploaded) go without the lyrics task: an instrumental job just drops it; the
    /// keys of lyrics-only jobs are returned, to be cancelled (nothing is left for the cloud to make). Jobs RunPod
    /// already has finish as they are, and whatever lyrics they bring may be imported. Returns how many records changed.
    @discardableResult
    public static func retireCloudLyrics(_ jobs: inout [CloudJobRecord], nowMs: Int64) -> (changed: Int, lyricsOnly: [String]) {
        var changed = 0
        var lyricsOnly: [String] = []
        for index in jobs.indices where jobs[index].state.isBeforeSubmit && jobs[index].tasks.contains(.lyrics) {
            if jobs[index].dropLyricsTask(nowMs: nowMs) {
                changed += 1
            } else {
                lyricsOnly.append(jobs[index].jobKey)
            }
        }
        return (changed, lyricsOnly)
    }
}

public enum CloudJobClearing {
    /// What "Clear finished" removes: every job nothing more happens to without the person (done, failed, cancelled,
    /// expired). Pending jobs are never cleared: they are cancelled first.
    public static func clearable(_ jobs: [CloudJobRecord]) -> [CloudJobRecord] {
        jobs.filter { $0.state.isFinished }
    }

    /// What "Cancel all" stops: every job that is not finished.
    public static func cancellable(_ jobs: [CloudJobRecord]) -> [CloudJobRecord] {
        jobs.filter { $0.state.isPending }
    }

    /// The jobs a failed batch row's "Retry" starts again: the ones that "need you" (failed or expired). A job the
    /// person cancelled stays cancelled until they retry it themselves in the Cloud queue. A Sing's preview piece is never
    /// retried: the minute it was for has gone by.
    public static func retryable(_ jobs: [CloudJobRecord]) -> [CloudJobRecord] {
        jobs.filter { ($0.state == .failed || $0.state == .expired) && !$0.isClip }
    }
}
