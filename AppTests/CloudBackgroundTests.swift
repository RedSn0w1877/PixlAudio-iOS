import Foundation
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// Cloud Studio while PixlAudio is closed: the notification when a batch finishes, and the limits of a background wake
/// (nothing new starts in its last seconds or after iOS took the time back). The scheduling decisions themselves are
/// PixlNet's (`CloudBackgroundPlannerTests`); here the orchestrator is driven with the harness's fakes.
@MainActor
final class CloudBackgroundTests: XCTestCase {
    /// A job from Send to imported through the harness's fakes.
    private func finishOneJob(_ h: CloudHarness) async throws -> String {
        let key = try await h.submittedJob()
        let result = h.finish(key)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "COMPLETED", result: result))
        h.clock.advance(16_000)
        await h.studio.pump()
        await h.studio.handle(.downloaded(jobKey: key, slot: "instrumental", stagedFile: try h.stagedInstrumental()))
        XCTAssertEqual(h.studio.job(key)?.state, .imported)
        return key
    }

    // MARK: Notification

    func testAFinishedBatchIsAnnouncedOnceAndPermissionIsAskedWhenSending() async throws {
        let notifier = FakeCloudNotifier()
        let h = CloudHarness(notifier: notifier)
        _ = try await finishOneJob(h)
        await h.waitUntil { !notifier.outcomes.isEmpty }
        XCTAssertEqual(notifier.outcomes.count, 1)
        XCTAssertEqual(notifier.outcomes.first?.imported, 1)
        XCTAssertEqual(notifier.outcomes.first?.instrumentals, 1)
        XCTAssertEqual(notifier.outcomes.first?.lyrics, 1)
        XCTAssertEqual(notifier.permissionRequests, 1, "asked when the person sent the batch, once")
        // Later passes don't announce it again.
        await h.studio.pump()
        await h.studio.backgroundRefresh()
        XCTAssertEqual(notifier.outcomes.count, 1)
    }

    func testNothingIsAnnouncedOrAskedWhileTheSwitchIsOff() async throws {
        let notifier = FakeCloudNotifier()
        let h = CloudHarness(notifier: notifier)
        h.settings.notifyWhenDone = false
        _ = try await finishOneJob(h)
        await h.studio.backgroundRefresh()
        XCTAssertTrue(notifier.outcomes.isEmpty)
        XCTAssertEqual(notifier.permissionRequests, 0)
    }

    func testABatchThatWasFinishedBeforeLaunchIsNotAnnounced() async throws {
        // A job list from an earlier launch holds one finished batch and nothing outstanding.
        let store = CloudJobStore(file: nil)
        var done = CloudJobRecord(jobKey: CloudHarness.key(1), songId: "s", title: "Old", artist: "A", batchId: "old",
                                  tasks: [.instrumental], lyricsMode: nil, quality: .standard,
                                  createdAtMs: 1_790_000_000_000)
        done.state = .imported
        done.importedInstrumental = true
        await store.save([done])
        let notifier = FakeCloudNotifier()
        let h = CloudHarness(store: store, notifier: notifier)
        await h.studio.backgroundRefresh()
        XCTAssertTrue(notifier.outcomes.isEmpty)
    }

    func testForgettingAnAnnouncedBatchLetsItBeAnnouncedAgain() async throws {
        let notifier = FakeCloudNotifier()
        let h = CloudHarness(notifier: notifier)
        let key = try await finishOneJob(h)
        await h.waitUntil { notifier.outcomes.count == 1 }
        // Retry forgets the batch, which is what lets its next finish through.
        XCTAssertEqual(h.settings.notifiedBatchIds.count, 1)
        h.settings.forgetNotified(try XCTUnwrap(h.studio.job(key)?.batchId))
        XCTAssertTrue(h.settings.notifiedBatchIds.isEmpty)
    }

    // MARK: The limits of a background wake

    func testAWakeInItsLastSecondsStartsNoDownloadButALaterOneDoes() async throws {
        let h = CloudHarness()
        h.studio.processingPollInterval = .milliseconds(5)
        let key = try await h.submittedJob()
        let result = h.finish(key)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "COMPLETED", result: result))
        h.clock.advance(16_000)

        // 110 s into a 120 s window with a 15 s margin: RunPod is asked, but nothing new is started.
        await h.studio.backgroundProcessing(window: BackgroundWorkWindow(startedAtMs: h.clock.ms - 110_000,
                                                                          budgetMs: 120_000, safetyMarginMs: 15_000))
        XCTAssertEqual(h.studio.job(key)?.state, .resultsReady)
        XCTAssertTrue(h.transfers.downloads.isEmpty, "no transfer starts in the last seconds")
        XCTAssertTrue(h.host.savedLyrics.isEmpty)

        // A fresh wake brings the results in; it keeps polling until it is cancelled (here: once the download runs).
        let pass = Task { await h.studio.backgroundProcessing(window: .processing(startedAtMs: h.clock.ms)) }
        await h.waitUntil { h.studio.job(key)?.state == .downloading }
        pass.cancel()
        await pass.value
        XCTAssertEqual(h.studio.job(key)?.state, .downloading)
        XCTAssertEqual(h.transfers.downloads.map(\.slot), ["instrumental"])
        XCTAssertEqual(h.host.savedLyrics.count, 1, "the lyrics were imported in the same wake")
    }

    func testAfterIOSTakesTheTimeBackNothingStartsUntilTheAppOpens() async throws {
        let h = CloudHarness()
        let song = h.addSong("f:root/a.m4a")
        h.host.facts[song.id] = CloudHarness.lineSyncedFacts
        let preview = await h.studio.preview(songs: [song], title: "Test")
        await h.studio.backgroundWillExpire()
        await h.studio.send(preview)
        await h.studio.pump()
        await h.studio.settle()
        let key = try XCTUnwrap(h.studio.jobs.first?.jobKey)
        XCTAssertEqual(h.studio.job(key)?.state, .queued, "expired: the song is not prepared")
        XCTAssertTrue(h.preparer.prepared.isEmpty)

        // The person opens the app: work is unrestricted again.
        h.studio.resume()
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.studio.job(key)?.state, .uploading)
        XCTAssertEqual(h.preparer.prepared, [key])
    }

    func testAnExpiredWakeLeavesTheJobListSaved() async throws {
        let store = CloudJobStore(file: nil)
        let h = CloudHarness(store: store)
        let key = try await h.submittedJob()
        await h.studio.backgroundWillExpire()
        let saved = await store.load(nowMs: h.clock.ms)
        XCTAssertEqual(saved.first { $0.jobKey == key }?.state, .submitted)
    }
}
