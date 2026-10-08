import PixlModel
import XCTest
@testable import PixlAudio

/// Spotify Connect's seam in `PlaybackStore` (Swift-only): while a remote output is attached the transport goes
/// there, the engine stays paused with its queue, play state and position come from the remote, queue edits are
/// reported, and detaching gives everything back to the engine.
///
/// The engine answers through an async event stream that the store drains on the main actor, which the test host's
/// own launch work shares: every step waits for the event it needs (`waitUntil`) instead of a fixed 20 ms, which was
/// too short on a busy CI simulator (run 37712713121).
@MainActor
final class SpotifyConnectStoreTests: XCTestCase {
    @MainActor final class FakeRemote: RemotePlaybackOutput {
        var calls: [String] = []
        var remoteIsPlaying = true
        var position: Int64 = 61_000
        var duration: Int64 = 200_000

        func remotePlay() { calls.append("play") }
        func remotePause() { calls.append("pause") }
        func remoteSkipToNext() { calls.append("next") }
        func remoteSkipToPrevious() { calls.append("previous") }
        func remoteSeek(toMs positionMs: Int64) { calls.append("seek \(positionMs)") }
        func remoteSkip(toQueueIndex index: Int) { calls.append("skip \(index)") }
        func remoteRepeatModeChanged(_ mode: RepeatMode) { calls.append("repeat \(mode.rawValue)") }
        func remoteQueueChanged() { calls.append("queue") }
        func remotePositionMs() -> Int64 { position }
        func remoteDurationMs() -> Int64 { duration }
    }

    func testTransportGoesToTheRemoteWhileAttached() async throws {
        let store = PlaybackStore(engine: DemoPlaybackEngine())
        let songs = Array(DemoLibrary.songs.prefix(5))
        store.play(songs, startIndex: 1, playWhenReady: true)
        let started = await waitUntil(timeout: 3) { store.isPlaying }
        XCTAssertTrue(started)

        let remote = FakeRemote()
        store.attachRemote(remote, name: "Kitchen Echo", isPlaying: true)
        // The engine's "paused" event arrives later and must not flip the remote's play state.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.isRemoteActive)
        XCTAssertEqual(store.remoteOutputName, "Kitchen Echo")
        XCTAssertTrue(store.isPlaying, "the remote plays even though the engine paused")
        XCTAssertEqual(store.positionMs(), 61_000)
        XCTAssertEqual(store.clock.positionMs, 61_000)
        XCTAssertEqual(store.durationMs(), 200_000)

        store.togglePlayPause()
        store.skipToNext()
        store.skipToPrevious()
        store.seek(toMs: 5_000)
        store.skipToQueueItem(at: 3)
        store.setRepeatMode(.one)
        XCTAssertEqual(remote.calls, ["pause", "next", "previous", "seek 5000", "skip 3", "repeat 1"])
        XCTAssertEqual(store.currentIndex, 1, "the local model moves only when the remote does")

        remote.calls = []
        store.remotePlayingChanged(false)
        XCTAssertFalse(store.isPlaying)
        store.togglePlayPause()
        XCTAssertEqual(remote.calls, ["play"])

        // The remote moved: the queue model follows without playing locally.
        store.remoteMoved(toQueueIndex: 2)
        let moved = await waitUntil(timeout: 3) { store.currentIndex == 2 }
        XCTAssertTrue(moved)
        XCTAssertEqual(store.currentIndex, 2)
        XCTAssertFalse(store.isPlaying)

        // Queue edits and a new queue are reported.
        remote.calls = []
        store.addToQueue([DemoLibrary.songs[6]])
        let reported = await waitUntil(timeout: 3) { remote.calls == ["queue"] }
        XCTAssertTrue(reported, "the engine's queue change reaches the remote")
        store.play(songs, startIndex: 0)
        XCTAssertEqual(remote.calls, ["queue", "queue"])

        // Back on the phone at the remote's position, playing.
        store.resumeLocally(atQueueIndex: 3, positionMs: 12_000, play: true)
        let resumed = await waitUntil(timeout: 3) { store.currentIndex == 3 && store.isPlaying }
        XCTAssertTrue(resumed)
        XCTAssertFalse(store.isRemoteActive)
        XCTAssertNil(store.remoteOutputName)
        XCTAssertEqual(store.currentIndex, 3)
        XCTAssertTrue(store.isPlaying)
        XCTAssertGreaterThanOrEqual(store.positionMs(), 12_000)
    }
}
