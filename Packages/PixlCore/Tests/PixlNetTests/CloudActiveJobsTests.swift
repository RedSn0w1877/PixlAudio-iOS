import Foundation
import Testing
import PixlModel
@testable import PixlNet

@Suite struct CloudActiveJobsTests {
    private func record(_ n: Int, _ state: CloudJobState, batch: String = "b1") -> CloudJobRecord {
        var r = CloudJobRecord(jobKey: "job\(n)", songId: "s\(n)", title: "Song \(n)", artist: "Artist", batchId: batch,
                               tasks: [.instrumental, .lyrics], lyricsMode: .align, quality: .standard,
                               createdAtMs: Int64(n) * 1_000)
        r.state = state
        return r
    }

    @Test func aLoneUploadShowsItsRealTransferPercent() {
        let rows = CloudActiveJobMapper.rows([record(1, .uploading)], transfer: ["job1": 0.426])
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.kind == .cloud && row.destination == .cloudQueue)
        #expect(row.state == .running)
        #expect(row.percent == 42)
        #expect(row.subtitle == "Song 1 · Uploading 42%")
    }

    @Test func waitingForAGpuIsQueuedAndIndeterminate() {
        let row = CloudActiveJobMapper.rows([record(1, .submitted)], transfer: [:])[0]
        #expect(row.state == .queued)
        #expect(row.percent == nil)
        #expect(row.subtitle == "Song 1 · Waiting for a GPU")
    }

    @Test func aRunningJobShowsTheWorkersStage() {
        var r = record(1, .running)
        r.progressStage = "separate"
        r.progressPercent = 40
        let row = CloudActiveJobMapper.rows([r], transfer: [:])[0]
        #expect(row.state == .running)
        #expect(row.percent == 40)
        #expect(row.subtitle?.contains("40%") == true)
    }

    @Test func aBatchIsOneRowWithAnAveragedBar() {
        let jobs = [record(1, .imported), record(2, .uploading), record(3, .submitted), record(4, .running), record(5, .queued)]
        let rows = CloudActiveJobMapper.rows(jobs, transfer: ["job2": 0.5])
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.id == "cloud.b1")
        #expect(row.state == .running)
        #expect(row.subtitle == "1 of 5 ready · 1 waiting · 1 uploading · 1 waiting for a GPU · 1 processing")
        // (1 + 0.25 + 0.45 + 0.5 + 0) / 5 = 0.44
        #expect(row.percent == 44)
    }

    @Test func separateBatchesAreSeparateRowsInOrder() {
        let rows = CloudActiveJobMapper.rows([record(1, .running, batch: "x"), record(2, .running, batch: "y"),
                                              record(3, .queued, batch: "x")], transfer: [:])
        #expect(rows.map(\.id) == ["cloud.x", "cloud.y"])
    }

    @Test func aFinishedBatchIsDone() {
        let one = CloudActiveJobMapper.rows([record(1, .imported)], transfer: [:])[0]
        #expect(one.state == .done && one.subtitle == "Song 1 is ready" && one.percent == 100)
        let many = CloudActiveJobMapper.rows([record(1, .imported), record(2, .imported)], transfer: [:])[0]
        #expect(many.state == .done && many.subtitle == "2 songs processed")
    }

    @Test func aBatchWithAFailureNeedsTheUser() {
        let row = CloudActiveJobMapper.rows([record(1, .imported), record(2, .failed), record(3, .expired)], transfer: [:])[0]
        #expect(row.state == .failed)
        #expect(row.subtitle == "1 of 3 ready · 2 need you")
        #expect(row.percent == nil)
    }

    @Test func aCancelledBatchLeavesNoRowButCancelledJobsDontCount() {
        #expect(CloudActiveJobMapper.rows([record(1, .cancelled)], transfer: [:]).isEmpty)
        let row = CloudActiveJobMapper.rows([record(1, .cancelled), record(2, .imported)], transfer: [:])[0]
        #expect(row.subtitle == "Song 2 is ready")
    }

    @Test func aRetryWaitIsQueuedNotRunning() {
        var r = record(1, .queued)
        r.nextAttemptAtMs = 9_999
        r.lastError = "No network"
        let row = CloudActiveJobMapper.rows([r], transfer: [:])[0]
        #expect(row.state == .queued)
        #expect(row.subtitle == "Song 1 · Trying again soon")
    }

    @Test func weightsRiseThroughTheSteps() {
        let order: [CloudJobState] = [.queued, .preparing, .uploading, .uploaded, .submitted, .running, .resultsReady,
                                      .downloading, .imported]
        let weights = order.map { CloudActiveJobMapper.weight(record(1, $0), transfer: 0) }
        #expect(weights == weights.sorted())
        #expect(weights.first == 0 && weights.last == 1)
    }

    @Test func theButtonsSummaryMatchesTheRows() {
        var retry = record(9, .queued, batch: "r")
        retry.nextAttemptAtMs = 9_999
        let sets: [[CloudJobRecord]] = [
            [],
            [record(1, .imported), record(2, .failed)],
            [record(1, .submitted), record(2, .uploaded, batch: "b2")],
            [record(1, .uploading), record(2, .imported), record(3, .cancelled, batch: "c")],
            [retry, record(4, .running, batch: "x"), record(5, .queued, batch: "x")],
        ]
        for jobs in sets {
            let rows = CloudActiveJobMapper.rows(jobs, transfer: [:])
            let summary = CloudActiveJobMapper.activeSummary(jobs)
            #expect(summary.count == ActiveJobBoard.badgeCount(rows))
            #expect(summary.working == ActiveJobBoard.isWorking(rows))
        }
    }
}
