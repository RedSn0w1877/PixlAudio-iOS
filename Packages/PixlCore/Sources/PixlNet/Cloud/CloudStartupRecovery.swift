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
    /// person cancelled stays cancelled until they retry it themselves in the Cloud queue.
    public static func retryable(_ jobs: [CloudJobRecord]) -> [CloudJobRecord] {
        jobs.filter { $0.state == .failed || $0.state == .expired }
    }
}
