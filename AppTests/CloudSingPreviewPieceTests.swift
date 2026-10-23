import Foundation
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// Sing's preview piece (the clip job, Sing step 4) through Cloud Studio's orchestrator, with the same fakes as
/// `CloudStudioTests`: a Sing tap with a playhead sends a minute of the song first and the whole song right behind it,
/// in one burst; the piece is cut from the song's own decode, checked against its own frames, kept out of `Stems/`, the
/// queue and the notifications, and stopped once nothing will play it.
@MainActor
final class CloudSingPreviewPieceTests: XCTestCase {
    private let clip = CloudClipRange(startMs: 87_000, endMs: 150_000)

    /// A Sing tap at 1:30 into a 4-minute song: the piece's job and the song's job.
    private func singWithClip(_ h: CloudHarness, song: Song) async throws -> (clip: String, full: String) {
        let started = await h.studio.startSing(song: song, playheadMs: 90_000)
        XCTAssertEqual(started, .started(1), "one song, whatever its preview piece")
        let clipKey = try XCTUnwrap(h.studio.pendingClip(forSong: song.id)?.jobKey)
        let fullKey = try XCTUnwrap(h.studio.job(forSong: song.id)?.jobKey)
        return (clipKey, fullKey)
    }

    /// The worker's ok manifest for a piece: an instrumental exactly as long as the piece.
    private func clipResult(_ h: CloudHarness, key: String) -> CloudJobResult {
        CloudJobResult(
            jobKey: key, status: .ok,
            worker: CloudWorkerInfo(version: "1.0.0", gitSha: "abc", gpu: "NVIDIA L4", vramGB: 24, cuda: "12.8"),
            outputs: ["instrumental": CloudOutputFile(key: "out/\(key)/instrumental.flac", bytes: Int64(h.instrumental.count),
                                                      sha256: CloudPlatform.sha256Hex(h.instrumental), codec: "flac", kbps: nil,
                                                      sampleRate: 44_100, samples: FakeCloudPreparer.clipFrames(clip))],
            timings: CloudTimings(coldStartMs: 0, totalMs: 5_000))
    }

    /// Both jobs prepared and uploaded, and sent in one pass.
    private func bothAtRunPod(_ h: CloudHarness, _ keys: (clip: String, full: String)) async {
        await h.studio.pump()
        await h.studio.settle()
        await h.studio.handle(.uploaded(jobKey: keys.clip))
        await h.studio.handle(.uploaded(jobKey: keys.full))
        await h.studio.pump()
    }

    // MARK: Sending

    func testASingTapWithAPlayheadSendsAPreviewPieceAheadOfTheSongInTheSameBatch() async throws {
        let h = CloudHarness()
        let song = h.addSong("f:root/a.m4a")
        let keys = try await singWithClip(h, song: song)
        XCTAssertEqual(h.studio.jobs.count, 2)
        XCTAssertEqual(h.studio.jobs.map(\.jobKey), [keys.clip, keys.full], "the piece first")
        let piece = try XCTUnwrap(h.studio.job(keys.clip))
        let whole = try XCTUnwrap(h.studio.job(keys.full))
        XCTAssertEqual(piece.clipRange, clip, "3 s before the playhead to a minute after it")
        XCTAssertEqual(piece.tasks, [.instrumental], "no lyrics, no transcription")
        XCTAssertNil(piece.lyricsMode)
        XCTAssertEqual(piece.quality, .standard)
        XCTAssertEqual(piece.outputCodec, .flac, "no encoder delay: it lines up with the song to the sample")
        XCTAssertEqual(piece.origin, .sing)
        XCTAssertNotNil(piece.priorityAtMs)
        XCTAssertEqual(piece.batchId, whole.batchId)
        XCTAssertFalse(whole.isClip)
        XCTAssertEqual(whole.origin, .sing)
        // The queue and Home's job line show the song once.
        XCTAssertEqual(h.studio.activeJobs.map(\.jobKey), [keys.full])
        XCTAssertEqual(CloudActiveJobMapper.rows(h.studio.jobs, transfer: [:]).count, 1)
    }

    func testAShortSongOrAPlayheadNearTheEndGoesAsAWholeOnly() async throws {
        let h = CloudHarness()
        let short = h.addSong("f:root/short.m4a", durationMs: 70_000)
        let first = await h.studio.startSing(song: short, playheadMs: 10_000)
        XCTAssertEqual(first, .started(1))
        XCTAssertNil(h.studio.pendingClip(forSong: short.id))
        let song = h.addSong("f:root/a.m4a")
        let second = await h.studio.startSing(song: song, playheadMs: 225_000)
        XCTAssertEqual(second, .started(1))
        XCTAssertNil(h.studio.pendingClip(forSong: song.id), "within 20 s of the end")
        // No playhead (an older caller): no piece either.
        let other = h.addSong("f:root/b.m4a")
        _ = await h.studio.startSing(song: other)
        XCTAssertNil(h.studio.pendingClip(forSong: other.id))
        XCTAssertFalse(h.studio.jobs.contains(where: \.isClip))
    }

    func testThePieceIsCutFromTheSongsOwnDecodeBesideTheWholeJob() async throws {
        let h = CloudHarness()
        let song = h.addSong("f:root/a.m4a")
        let keys = try await singWithClip(h, song: song)
        await h.studio.pump()
        await h.studio.settle()
        XCTAssertEqual(h.preparer.clipsByJob[keys.clip], clip)
        XCTAssertNil(h.preparer.clipsByJob[keys.full], "the whole song is decoded whole")
        XCTAssertEqual(h.preparer.pacedByJob[keys.clip], false, "somebody is waiting for it: full speed")
        for key in [keys.clip, keys.full] { XCTAssertEqual(h.studio.job(key)?.state, .uploading, key) }
        // Its own frames are what its result is checked against.
        XCTAssertEqual(h.studio.job(keys.clip)?.decodedFrames, FakeCloudPreparer.clipFrames(clip))
        XCTAssertEqual(h.studio.job(keys.clip)?.clipDurationMs, 63_000)
    }

    func testThePieceAndTheSongAreOneBurstWithOneLast() async throws {
        let h = CloudHarness()
        let keys = try await singWithClip(h, song: h.addSong("f:root/a.m4a"))
        await bothAtRunPod(h, keys)
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.compactMap(\.input.jobKey), [keys.clip, keys.full], "the piece first")
        XCTAssertEqual(runs.map(\.input.isLastInBatch), [false, true], "only the song asks the worker to stop")
    }

    func testAPieceReadyFirstGoesAtOnceAndKeepsTheWorkerUpForTheSong() async throws {
        let h = CloudHarness()
        let keys = try await singWithClip(h, song: h.addSong("f:root/a.m4a"))
        await h.studio.pump()
        await h.studio.settle()
        await h.studio.handle(.uploaded(jobKey: keys.clip))
        await h.studio.pump()
        var runs = await h.runpod.runs
        XCTAssertEqual(runs.compactMap(\.input.jobKey), [keys.clip], "no waiting for the song's upload")
        XCTAssertEqual(runs.map(\.input.isLastInBatch), [false], "the song is right behind it")

        await h.studio.handle(.uploaded(jobKey: keys.full))
        await h.studio.pump()
        runs = await h.runpod.runs
        XCTAssertEqual(runs.compactMap(\.input.jobKey), [keys.clip, keys.full])
        XCTAssertEqual(runs.map(\.input.isLastInBatch), [false, true], "the song ends the burst")
        let cancelled = await h.runpod.cancelled
        XCTAssertEqual(cancelled, [], "the piece is never stepped aside for its own song")
    }

    func testAPieceWhoseSongIsWaitingOutARetryIsTheLast() async throws {
        let h = CloudHarness()
        let keys = try await singWithClip(h, song: h.addSong("f:root/a.m4a"))
        await h.studio.pump()
        await h.studio.settle()
        // The song's upload failed: it waits a minute before trying again.
        await h.studio.handle(.uploadFailed(jobKey: keys.full, message: "offline", httpStatus: nil))
        await h.studio.handle(.uploaded(jobKey: keys.clip))
        await h.studio.pump()
        let runs = await h.runpod.runs
        XCTAssertEqual(runs.compactMap(\.input.jobKey), [keys.clip])
        XCTAssertEqual(runs.map(\.input.isLastInBatch), [true], "nothing is right behind it: the worker may stop")
    }

    // MARK: Joining

    func testASingTapThatJoinsAJobOnItsWayStillGetsAPiece() async throws {
        let h = CloudHarness()
        let song = h.addSong("f:root/a.m4a")
        let sent = await h.studio.startAuto(songs: [song], limit: 3)
        XCTAssertEqual(sent, 1)
        let autoKey = try XCTUnwrap(h.studio.job(forSong: song.id)?.jobKey)
        let started = await h.studio.startSing(song: song, playheadMs: 90_000)
        XCTAssertEqual(started, .started(1))
        XCTAssertEqual(h.studio.job(forSong: song.id)?.jobKey, autoKey, "joined, not duplicated")
        XCTAssertEqual(h.studio.job(autoKey)?.origin, .sing)
        let piece = try XCTUnwrap(h.studio.pendingClip(forSong: song.id))
        XCTAssertEqual(piece.batchId, h.studio.job(autoKey)?.batchId)
        XCTAssertEqual(piece.clipRange, clip)
        // A second tap doesn't add another.
        _ = await h.studio.startSing(song: song, playheadMs: 100_000)
        XCTAssertEqual(h.studio.jobs.filter(\.isClip).count, 1)
    }

    // MARK: Importing

    func testALandedPieceIsKeptAsideNotAsTheSongsInstrumental() async throws {
        let h = CloudHarness()
        let song = h.addSong("f:root/a.m4a")
        let keys = try await singWithClip(h, song: song)
        await bothAtRunPod(h, keys)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "COMPLETED", result: clipResult(h, key: keys.clip)))
        h.clock.advance(16_000)
        await h.studio.pump()
        XCTAssertEqual(h.studio.job(keys.clip)?.state, .downloading)
        h.inspector.decodedFrames = FakeCloudPreparer.clipFrames(clip)
        await h.studio.handle(.downloaded(jobKey: keys.clip, slot: "instrumental", stagedFile: try h.stagedInstrumental()))

        XCTAssertEqual(h.studio.job(keys.clip)?.state, .imported)
        XCTAssertTrue(h.host.installed.isEmpty, "never in Stems/")
        XCTAssertEqual(h.host.installedClips.map(\.songId), [song.id])
        XCTAssertEqual(h.host.installedClips.map(\.startMs), [87_000])
        let landed = try XCTUnwrap(h.studio.clips[song.id])
        XCTAssertEqual(landed.range, clip)
        XCTAssertEqual(landed.jobKey, keys.clip)
        XCTAssertEqual(h.studio.job(keys.full)?.state, .submitted, "the song goes on")
        XCTAssertTrue(h.studio.finishedJobs.isEmpty, "the piece has no row of its own")
    }

    func testThePieceIsCheckedAgainstItsOwnFramesNotTheSongs() async throws {
        let h = CloudHarness()
        let song = h.addSong("f:root/a.m4a")
        let keys = try await singWithClip(h, song: song)
        await bothAtRunPod(h, keys)
        await h.runpod.setStatus("rp-1", RunPodJob(id: "rp-1", status: "COMPLETED", result: clipResult(h, key: keys.clip)))
        h.clock.advance(16_000)
        await h.studio.pump()
        // This phone decodes the download as long as the whole song: it does not line up with the piece.
        h.inspector.decodedFrames = CloudHarness.sourceFrames
        await h.studio.handle(.downloaded(jobKey: keys.clip, slot: "instrumental", stagedFile: try h.stagedInstrumental()))
        XCTAssertEqual(h.studio.job(keys.clip)?.state, .failed, "no FLAC redo and no retry for a piece")
        XCTAssertNil(h.studio.clips[song.id])
        XCTAssertTrue(h.host.installedClips.isEmpty)
        XCTAssertEqual(h.studio.job(keys.full)?.state, .submitted, "the song goes on without it")
        XCTAssertTrue(h.studio.attentionJobs.isEmpty, "nothing for the person to see")
    }

    func testTheSongsInstrumentalLandingStopsAPieceStillOnItsWay() async throws {
        let h = CloudHarness()
        let song = h.addSong("f:root/a.m4a")
        let keys = try await singWithClip(h, song: song)
        await bothAtRunPod(h, keys)
        // The song comes back first (rp-2); the piece (rp-1) still waits.
        await h.runpod.setStatus("rp-2", RunPodJob(id: "rp-2", status: "COMPLETED", result: h.finish(keys.full)))
        h.clock.advance(16_000)
        await h.studio.pump()
        await h.studio.handle(.downloaded(jobKey: keys.full, slot: "instrumental", stagedFile: try h.stagedInstrumental()))
        XCTAssertEqual(h.host.installed.map(\.songId), [song.id])
        XCTAssertEqual(h.studio.job(keys.clip)?.state, .cancelled)
        let cancelled = await h.runpod.cancelled
        XCTAssertEqual(cancelled, ["rp-1"])
    }

    func testDiscardingAPieceRemovesItsFileAndStopsOneOnItsWay() async throws {
        let h = CloudHarness()
        let song = h.addSong("f:root/a.m4a")
        let keys = try await singWithClip(h, song: song)
        h.studio.discardClip(songId: song.id)
        XCTAssertEqual(h.host.removedClips, [song.id])
        await h.waitUntil { h.studio.job(keys.clip)?.state == .cancelled }
        XCTAssertEqual(h.studio.job(keys.clip)?.state, .cancelled)
        XCTAssertTrue(h.studio.job(keys.full)?.state.isPending == true, "the song's job is not touched")
    }

    func testCancellingTheSongCancelsItsPiece() async throws {
        let h = CloudHarness()
        let keys = try await singWithClip(h, song: h.addSong("f:root/a.m4a"))
        await h.studio.cancel(keys.full)
        XCTAssertEqual(h.studio.job(keys.clip)?.state, .cancelled)
    }

    func testAPieceAnEarlierLaunchLeftOnItsWayIsStopped() async throws {
        let store = CloudJobStore(file: nil)
        var stale = CloudHarness.storedRecord(1, song: "f:root/a.m4a", state: .uploaded, origin: .sing)
        stale.clipStartMs = 87_000
        stale.clipDurationMs = 63_000
        let song = CloudHarness.storedRecord(2, song: "f:root/a.m4a", state: .uploaded, origin: .sing)
        await store.save([stale, song])
        let h = CloudHarness(store: store)
        h.addSong("f:root/a.m4a")
        await h.studio.pump()
        await h.waitUntil { h.studio.job(CloudHarness.key(1))?.state == .cancelled }
        XCTAssertEqual(h.studio.job(CloudHarness.key(1))?.state, .cancelled)
        XCTAssertNotEqual(h.studio.job(CloudHarness.key(2))?.state, .cancelled)
    }
}
