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
}
