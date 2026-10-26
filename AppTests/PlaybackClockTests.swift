import PixlModel
import XCTest
@testable import PixlAudio

@MainActor
final class PlaybackClockTests: XCTestCase {
    func testClockReadsTheEngineOnDemand() async throws {
        let store = PlaybackStore(engine: DemoPlaybackEngine())
        XCTAssertEqual(store.clock.positionMs, 0)
        XCTAssertEqual(store.clock.durationMs, 0)
        XCTAssertEqual(store.clock.fraction, 0, "no duration yet")

        let songs = DemoLibrary.songs
        store.play(songs, startIndex: 0, startPositionMs: 0, playWhenReady: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        let duration = store.clock.durationMs
        XCTAssertEqual(duration, songs[0].duration)
        store.seek(toMs: duration / 2)
        XCTAssertEqual(store.clock.positionMs, duration / 2)
        XCTAssertEqual(store.clock.fraction, 0.5, accuracy: 0.01)
        store.seek(toMs: duration * 4)
        XCTAssertEqual(store.clock.fraction, 1, "clamped to the duration")
    }

    /// A paused progress bar doesn't tick: a seek or a restart has to announce itself (`seekRevision`) so the bar
    /// redraws at the new position without the user pressing play.
    func testSeekAndRestartBumpTheRevisionWhilePaused() async throws {
        let store = PlaybackStore(engine: DemoPlaybackEngine())
        store.play(DemoLibrary.songs, startIndex: 0, startPositionMs: 0, playWhenReady: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(store.isPlaying)
        store.seek(toMs: 90_000)
        try await Task.sleep(nanoseconds: 20_000_000)
        let afterSeek = store.seekRevision
        XCTAssertGreaterThan(afterSeek, 0)
        XCTAssertEqual(store.clock.positionMs, 90_000)

        // "Previous" more than 3 s in restarts the song: the position is 0 at once and the revision moved.
        store.skipToPrevious()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertGreaterThan(store.seekRevision, afterSeek)
        XCTAssertEqual(store.clock.positionMs, 0)
        XCTAssertFalse(store.isPlaying, "restarting must not start playback")
    }
}
