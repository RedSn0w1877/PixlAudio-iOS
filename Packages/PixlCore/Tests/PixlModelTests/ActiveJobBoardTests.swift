import Foundation
import Testing
@testable import PixlModel

@Suite struct ActiveJobBoardTests {
    private func job(_ id: String, _ kind: ActiveJob.Kind, _ state: ActiveJob.State, percent: Int? = nil,
                     at: Int64 = 0) -> ActiveJob {
        ActiveJob(id: id, kind: kind, subtitle: nil, percent: percent, state: state, updatedAtMs: at)
    }

    @Test func titleDefaultsToTheKindsAndroidLabel() {
        #expect(job("a", .libraryScan, .running).title == "Library sync")
        #expect(job("b", .cloud, .running).title == "Cloud processing")
        #expect(job("c", .lyricsSync, .running).title == "Syncing lyrics")
        #expect(ActiveJob(id: "d", kind: .cloud, title: "Mine", state: .queued).title == "Mine")
    }

    @Test func percentsAreClamped() {
        #expect(job("a", .cloud, .running, percent: 140).percent == 100)
        #expect(job("a", .cloud, .running, percent: -5).percent == 0)
        #expect(ActiveJobBoard.percent(completed: 1, total: 4) == 25)
        #expect(ActiveJobBoard.percent(completed: 9, total: 4) == 100)
        #expect(ActiveJobBoard.percent(completed: 1, total: 0) == nil)
        #expect(ActiveJobBoard.percent(fraction: 0.646) == 64)
        #expect(ActiveJobBoard.percent(fraction: nil) == nil)
        #expect(ActiveJobBoard.percent(fraction: .nan) == nil)
    }

    @Test func runningRowsComeBeforeQueuedOnesAndKindsKeepTheirOrder() {
        let jobs = [
            job("scan", .libraryScan, .running), job("wait", .lyricsSync, .queued), job("cloud", .cloud, .running),
            job("lyrics", .lyricsSync, .running), job("done", .cloud, .done), job("wait2", .cloud, .queued),
        ]
        #expect(ActiveJobBoard.active(jobs).map(\.id) == ["cloud", "lyrics", "scan", "wait2", "wait"])
    }

    @Test func equalRowsKeepTheSourcesOrder() {
        let jobs = [job("b", .songDownload, .running), job("a", .songDownload, .running), job("c", .songDownload, .running)]
        #expect(ActiveJobBoard.active(jobs).map(\.id) == ["b", "a", "c"])
    }

    @Test func badgeCountsQueuedAndRunningOnly() {
        let jobs = [job("a", .cloud, .running), job("b", .cloud, .queued), job("c", .cloud, .done), job("d", .cloud, .failed)]
        #expect(ActiveJobBoard.badgeCount(jobs) == 2)
        #expect(ActiveJobBoard.badgeCount([]) == 0)
    }

    @Test func theSymbolAnimatesOnlyWhileSomethingRuns() {
        #expect(ActiveJobBoard.isWorking([job("a", .cloud, .running)]))
        #expect(!ActiveJobBoard.isWorking([job("a", .cloud, .queued), job("b", .cloud, .done)]))
        #expect(!ActiveJobBoard.isWorking([]))
    }

    @Test func recentRowsAreNewestFirstLimitedAndExpire() {
        let now: Int64 = 100 * 3_600_000
        var jobs = (0..<8).map { job("r\($0)", .cloud, $0 % 2 == 0 ? .done : .failed, at: now - Int64($0) * 60_000) }
        jobs.append(job("old", .cloud, .done, at: now - 25 * 3_600_000))
        jobs.append(job("active", .cloud, .running, at: now))
        let recent = ActiveJobBoard.recent(jobs, nowMs: now)
        #expect(recent.map(\.id) == ["r0", "r1", "r2", "r3", "r4"])
        #expect(!recent.contains { $0.id == "old" })
    }

    @Test func accessibilityWords() {
        #expect(ActiveJobBoard.accessibilityValue(count: 0) == "No active jobs")
        #expect(ActiveJobBoard.accessibilityValue(count: 1) == "1 active job")
        #expect(ActiveJobBoard.accessibilityValue(count: 3) == "3 active jobs")
        let running = ActiveJob(id: "a", kind: .lyricsSync, subtitle: "Neon Harbor", percent: 64, state: .running)
        #expect(ActiveJobBoard.accessibilityLabel(running) == "Syncing lyrics, Neon Harbor, 64 percent")
        let queued = ActiveJob(id: "b", kind: .spotifyMatch, subtitle: "Queued", state: .queued)
        #expect(ActiveJobBoard.accessibilityLabel(queued) == "Finding audio, Queued")
        let failed = ActiveJob(id: "c", kind: .cloud, subtitle: "2 of 3 ready", state: .failed)
        #expect(ActiveJobBoard.accessibilityLabel(failed) == "Cloud processing, 2 of 3 ready, needs attention")
    }
}

/// "Clear finished", "Cancel all" and what the button counts, over a mixed list.
@Suite struct ActiveJobClearingTests {
    private func job(_ id: String, _ state: ActiveJob.State, canRetry: Bool = false) -> ActiveJob {
        ActiveJob(id: id, kind: .modelDownload, state: state, canRetry: canRetry)
    }

    private var mixed: [ActiveJob] {
        [job("run", .running), job("wait", .queued), job("done", .done), job("bad", .failed, canRetry: true),
         job("bad2", .failed)]
    }

    @Test func failedAndDoneRowsNeverLightTheButton() {
        let leftovers = [job("done", .done), job("bad", .failed), job("bad2", .failed)]
        #expect(ActiveJobBoard.badgeCount(leftovers) == 0)
        #expect(!ActiveJobBoard.isWorking(leftovers))
        #expect(ActiveJobBoard.badgeCount(mixed) == 2)
    }

    @Test func clearFinishedTakesEveryFinishedAndFailedRowAndNothingActive() {
        let cleared = ActiveJobBoard.clearable(mixed)
        #expect(cleared.map(\.id) == ["done", "bad", "bad2"])
        let left = ActiveJobBoard.removing(Set(cleared.map(\.id)), from: mixed)
        #expect(left.map(\.id) == ["run", "wait"])
        #expect(ActiveJobBoard.clearable(left).isEmpty, "clearing twice finds nothing more")
    }

    @Test func cancelAllTakesRunningAndWaitingRowsOnly() {
        #expect(ActiveJobBoard.cancellable(mixed).map(\.id) == ["run", "wait"])
        #expect(ActiveJobBoard.cancellable([job("done", .done)]).isEmpty)
    }

    @Test func retryIsOfferedOnlyWhereTheSourceCanDoIt() {
        #expect(ActiveJobBoard.retryable(mixed).map(\.id) == ["bad"])
        #expect(!job("done", .done, canRetry: true).isActive)
        #expect(ActiveJobBoard.retryable([job("done", .done, canRetry: true)]).isEmpty, "only failed rows retry")
    }

    @Test func aDismissedRowGoesAndTheRestStay() {
        let left = ActiveJobBoard.removing(["bad"], from: mixed)
        #expect(left.map(\.id) == ["run", "wait", "done", "bad2"])
        #expect(ActiveJobBoard.removing([], from: mixed) == mixed)
    }

    @Test func aFinishedRowIsDismissibleAnActiveOneIsNot() {
        #expect(job("a", .done).isFinished)
        #expect(job("b", .failed).isFinished)
        #expect(!job("c", .running).isFinished)
        #expect(!job("d", .queued).isFinished)
    }
}
