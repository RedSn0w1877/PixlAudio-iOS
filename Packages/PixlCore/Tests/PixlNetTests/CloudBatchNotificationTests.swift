import Foundation
import Testing
@testable import PixlNet

@Suite struct CloudBatchNotificationTests {
    private func record(_ n: Int, _ state: CloudJobState, batch: String = "b1", instrumental: Bool = false,
                        lyrics: Bool = false) -> CloudJobRecord {
        var r = CloudJobRecord(jobKey: "job\(n)", songId: "s\(n)", title: "Song \(n)", artist: "A", batchId: batch,
                               tasks: [.instrumental, .lyrics], lyricsMode: .align, quality: .standard, createdAtMs: 0)
        r.state = state
        r.importedInstrumental = instrumental
        r.importedLyrics = lyrics
        return r
    }

    @Test func incompleteBatchesAreThoseWithAnOutstandingJob() {
        let jobs = [record(1, .imported, batch: "a"), record(2, .running, batch: "a"), record(3, .imported, batch: "b"),
                    record(4, .failed, batch: "c")]
        #expect(CloudBatchNotifier.incompleteBatchIds(jobs) == ["a"])
    }

    @Test func aBatchThatFinishedSinceTheLastCheckIsAnnouncedOnce() {
        let jobs = [record(1, .imported, instrumental: true, lyrics: true), record(2, .imported, instrumental: true, lyrics: true)]
        let first = CloudBatchNotifier.completions(previouslyIncomplete: ["b1"], jobs: jobs, alreadyNotified: [])
        #expect(first.count == 1)
        #expect(first[0].imported == 2 && first[0].total == 2 && first[0].needsAttention == 0)
        #expect(first[0].singleTitle == nil)
        let again = CloudBatchNotifier.completions(previouslyIncomplete: ["b1"], jobs: jobs, alreadyNotified: ["b1"])
        #expect(again.isEmpty)
    }

    @Test func aBatchThatWasAlreadyFinishedBeforeIsNeverAnnounced() {
        let jobs = [record(1, .imported, instrumental: true)]
        #expect(CloudBatchNotifier.completions(previouslyIncomplete: [], jobs: jobs, alreadyNotified: []).isEmpty)
    }

    @Test func aBatchStillRunningIsNotAnnounced() {
        let jobs = [record(1, .imported, instrumental: true), record(2, .downloading)]
        #expect(CloudBatchNotifier.completions(previouslyIncomplete: ["b1"], jobs: jobs, alreadyNotified: []).isEmpty)
    }

    @Test func aBatchTheUserCancelledIsNotNews() {
        let jobs = [record(1, .cancelled), record(2, .cancelled)]
        #expect(CloudBatchNotifier.completions(previouslyIncomplete: ["b1"], jobs: jobs, alreadyNotified: []).isEmpty)
    }

    @Test func failuresCountAsNewsAndCancelledSongsDoNotCount() {
        let jobs = [record(1, .imported, instrumental: true), record(2, .failed), record(3, .cancelled)]
        let outcome = CloudBatchNotifier.completions(previouslyIncomplete: ["b1"], jobs: jobs, alreadyNotified: [])[0]
        #expect(outcome.total == 2 && outcome.imported == 1 && outcome.needsAttention == 1)
    }

    @Test func severalBatchesComeOutOldestFirst() {
        let jobs = [record(1, .imported, batch: "x", instrumental: true), record(2, .imported, batch: "y", lyrics: true)]
        let outcomes = CloudBatchNotifier.completions(previouslyIncomplete: ["y", "x"], jobs: jobs, alreadyNotified: [])
        #expect(outcomes.map(\.batchId) == ["x", "y"])
    }

    @Test func titlesNameWhatCameBack() {
        func outcome(imported: Int, attention: Int = 0, instrumentals: Int, lyrics: Int, single: String? = nil) -> CloudBatchOutcome {
            CloudBatchOutcome(batchId: "b", total: imported + attention, imported: imported, needsAttention: attention,
                              instrumentals: instrumentals, lyrics: lyrics, singleTitle: single)
        }
        #expect(CloudNotificationCopy.title(outcome(imported: 3, instrumentals: 3, lyrics: 0)) == "Your instrumentals are ready")
        #expect(CloudNotificationCopy.title(outcome(imported: 1, instrumentals: 1, lyrics: 0)) == "Your instrumental is ready")
        #expect(CloudNotificationCopy.title(outcome(imported: 2, instrumentals: 2, lyrics: 1)) == "Your instrumentals and lyrics are ready")
        #expect(CloudNotificationCopy.title(outcome(imported: 2, instrumentals: 0, lyrics: 2)) == "Your word-timed lyrics are ready")
        #expect(CloudNotificationCopy.title(outcome(imported: 0, attention: 2, instrumentals: 0, lyrics: 0)) == "Cloud processing needs you")
    }

    @Test func bodiesSayHowManyAndWhereToTap() {
        func body(imported: Int, attention: Int = 0, single: String? = nil) -> String {
            CloudNotificationCopy.body(CloudBatchOutcome(batchId: "b", total: imported + attention, imported: imported,
                                                         needsAttention: attention, instrumentals: imported, lyrics: 0,
                                                         singleTitle: single))
        }
        #expect(body(imported: 1, single: "Neon Harbor") == "Neon Harbor is ready to use. Tap to open the queue.")
        #expect(body(imported: 12) == "12 songs processed. Tap to open the queue.")
        #expect(body(imported: 2, attention: 1) == "2 of 3 ready, 1 needs you. Tap to see which.")
        #expect(body(imported: 0, attention: 1) == "1 song couldn't be processed. Tap to see why.")
        #expect(body(imported: 0, attention: 4) == "4 songs couldn't be processed. Tap to see why.")
    }
}
