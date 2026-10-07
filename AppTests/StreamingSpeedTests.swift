import Foundation
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// Streaming speed (2026-10-07): the start-timings store behind Settings › Developer › Test playback › Stream start
/// timings (R12). The pure policies (chunk sizes, prefetch depth, retries, the hedging flag) are tested in PixlNet's
/// `StreamingPolicyTests`; the skip into a prepared item (R7) in `DualDeckEngineTests`.
@MainActor
final class StreamingSpeedTests: XCTestCase {
    // MARK: Start timings (R12)

    func testAStreamedStartRecordsEveryStep() throws {
        let timings = PlaybackStartTimings()
        let key = YouTubeSongIdentity.timingKey(videoId: "dQw4w9WgXcQ")
        let id = timings.begin(title: "Neon Harbor")
        timings.urlResolved(id, url: try XCTUnwrap(YouTubeSongIdentity.streamURL(videoId: "dQw4w9WgXcQ")))
        timings.loaderRequest(key: key, contentInfo: true, toEnd: false)
        timings.resolved(key: key, PlaybackStartTimings.Resolve(ms: 310, configMs: 0, strategy: "VISIONOS",
                                                                 detail: "itag 140", hasN: false))
        timings.networkFetched(key: key, bytes: 131_072)
        timings.loaderRequest(key: key, contentInfo: false, toEnd: true)
        timings.answered(key: key)
        timings.networkFetched(key: key, bytes: 524_288)
        timings.loaderCancelled(key: key)
        timings.tracksLoaded(id)
        timings.itemBuilt(id)
        timings.playing(id)
        // Another song's events don't land on this start.
        timings.networkFetched(key: YouTubeSongIdentity.timingKey(videoId: "Zz9_-Zz9_-Z"), bytes: 1)

        let record = try XCTUnwrap(timings.records.first)
        XCTAssertEqual(record.key, "pixlstream://dQw4w9WgXcQ")
        XCTAssertFalse(record.isFile)
        XCTAssertEqual(record.resolve?.strategy, "VISIONOS")
        XCTAssertEqual(record.requests, 2)
        XCTAssertEqual(record.infoRequests, 1)
        XCTAssertEqual(record.toEndRequests, 1)
        XCTAssertEqual(record.cancelled, 1)
        XCTAssertEqual(record.fetches, 2)
        XCTAssertEqual(record.fetchedBytes, 655_360)
        XCTAssertEqual(record.firstFetchBytes, 131_072)
        XCTAssertNotNil(record.firstAnswerMs)
        let steps = [record.urlMs, record.tracksMs, record.builtMs, record.playingMs].compactMap { $0 }
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps, steps.sorted(), "steps are measured in order")

        let lines = record.lines()
        XCTAssertTrue(lines[0].hasPrefix("• Neon Harbor — "))
        XCTAssertTrue(lines[0].hasSuffix(" ms to play"))
        XCTAssertTrue(lines.contains { $0.contains("resolve: 310 ms via VISIONOS (itag 140) · n: no") })
        XCTAssertTrue(lines.contains { $0.contains("2 fetches") })
        XCTAssertTrue(lines.contains { $0.contains("2 requests (1 info, 1 to end), 1 cancelled") })
        XCTAssertEqual(timings.lastStartSummary(), lines.joined(separator: "\n"))
    }

    func testPrefetchedResolutionLocalFilesAndEndings() throws {
        let timings = PlaybackStartTimings()
        let key = YouTubeSongIdentity.timingKey(videoId: "dQw4w9WgXcQ")
        timings.resolved(key: key, PlaybackStartTimings.Resolve(ms: 280, configMs: 0, strategy: "IOS", detail: nil,
                                                                 hasN: true))
        let streamed = timings.begin(title: "Prefetched")
        timings.urlResolved(streamed, url: try XCTUnwrap(URL(string: key)))
        timings.playing(streamed)
        let first = try XCTUnwrap(timings.records.first)
        XCTAssertNil(first.resolve)
        XCTAssertEqual(first.earlierResolve?.strategy, "IOS")
        XCTAssertTrue(first.lines().contains { $0.contains("done before the tap (prefetch)") && $0.contains("n: yes") })
        XCTAssertTrue(first.lines().contains { $0.contains("network: none before playback") })

        let local = timings.begin(title: "Local")
        timings.urlResolved(local, url: URL(fileURLWithPath: "/tmp/a.m4a"))
        timings.readyPaused(local)
        let paused = try XCTUnwrap(timings.records.first)
        XCTAssertTrue(paused.isFile)
        XCTAssertTrue(paused.lines()[0].contains("(paused)"))
        XCTAssertEqual(paused.lines().count, 2, "local files show no streaming lines")

        let failed = timings.begin(title: "Broken")
        timings.failed(failed, "No YouTube client could provide this song's audio.")
        XCTAssertTrue(try XCTUnwrap(timings.records.first).lines()[0].contains("failed after"))
        let left = timings.begin(title: "Skipped")
        timings.abandoned(left)
        timings.playing(left)   // too late: the start was already left
        XCTAssertTrue(try XCTUnwrap(timings.records.first).lines()[0].contains("left after"))

        for i in 0..<PlaybackStartTimings.capacity { _ = timings.begin(title: "\(i)") }
        XCTAssertEqual(timings.records.count, PlaybackStartTimings.capacity)
        XCTAssertEqual(timings.records.first?.title, "\(PlaybackStartTimings.capacity - 1)")
    }

    // MARK: Remote client table (R4)

    func testTheSavedTableGatesTheRefreshAcrossRelaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("remote-config.json")
        try Data(#"{"schema": 1, "innertube": {"note": "saved"}}"#.utf8).write(to: file)

        // Saved minutes ago: a relaunch uses it and makes no request.
        let http = CountingHTTPClient()
        let fresh = RemoteClientConfigStore(http: http, directory: directory)
        await fresh.refreshIfNeeded()
        await fresh.refreshInBackground()
        XCTAssertEqual(http.count, 0)
        let source = await fresh.source
        XCTAssertEqual(source, "cached remote (saved)")

        // Saved seven hours ago: one refresh, started without waiting for it.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7 * 3600)],
                                              ofItemAtPath: file.path)
        let stale = RemoteClientConfigStore(http: http, directory: directory)
        await stale.refreshInBackground()
        let refreshed = await waitUntil(timeout: 5) { http.count == 1 }
        XCTAssertTrue(refreshed)
        await stale.refreshIfNeeded()   // the attempt just made gates the next one
        XCTAssertEqual(http.count, 1)
    }

    func testResolveTimingDescribesTheWinner() {
        let stream = ResolvedStream(url: "https://r1.googlevideo.com/videoplayback?itag=140&n=abc", userAgent: "UA",
                                    strategyName: "VISIONOS")
        let timing = InnerTubeService.timing(stream: stream, strategy: "VISIONOS",
                                             attempts: ["VISIONOS: itag 140, 129 kbps, n descifrado (sin validar)"],
                                             ms: 300, configMs: 2)
        XCTAssertEqual(timing.detail, "itag 140, 129 kbps, n descifrado (sin validar)")
        XCTAssertEqual(timing.hasN, true)
        let failed = InnerTubeService.timing(stream: nil, strategy: nil, attempts: ["VISIONOS: x", "IOS: y"], ms: 9,
                                             configMs: 0)
        XCTAssertNil(failed.hasN)
        XCTAssertEqual(failed.detail, "VISIONOS: x; IOS: y")
    }
}
