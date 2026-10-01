import PixlAudioCore
import PixlModel
import XCTest
@testable import PixlAudio

/// `SleepTimerController`: PixlAudioCore's sleep-timer state machine wired to a playback target — time, end of
/// track, counted plays, the wake-up task and the toasts.
@MainActor
final class SleepTimerControllerTests: XCTestCase {
    private final class FakeTarget: SleepTimerTarget {
        var currentSongId: String? = "a"
        var stopAfterCurrentItem = false
        var log: [String] = []
        func pause() { log.append("pause") }
        func seek(toMs positionMs: Int64) { log.append("seek \(positionMs)") }
        func setRepeatMode(_ mode: RepeatMode) { log.append("repeat \(mode.rawValue)") }
    }

    private func song(_ id: String) -> Song {
        Song(id: id, title: "Title \(id)", artist: "", artistId: 0, album: "", albumId: 0, path: "", contentUriString: "",
             albumArtUriString: nil, duration: 1000, mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    func testDurationTimerPausesWhenTheClockPassesTheEnd() {
        let target = FakeTarget()
        let timer = SleepTimerController(engine: target)
        var now: Int64 = 1_000_000
        timer.now = { now }
        timer.setDuration(minutes: 15)
        XCTAssertEqual(timer.state.activeDurationMinutes, 15)
        XCTAssertEqual(timer.remainingMs, 15 * 60_000)
        XCTAssertEqual(timer.toastMessage, "Timer set for 15 minutes.")
        now += 14 * 60_000
        timer.checkClock()
        XCTAssertEqual(target.log, [])
        now += 60_000
        timer.checkClock()
        XCTAssertEqual(target.log, ["pause"])
        XCTAssertNil(timer.state.display)
    }

    func testWakeUpTaskFiresWithoutPolling() async {
        let target = FakeTarget()
        let timer = SleepTimerController(engine: target)
        // Clock reads: the timer is set at T (ends at T + 60 s); the wake-up is scheduled when 100 ms remain; when it
        // fires, the end has passed.
        var reads: [Int64] = [1_000_000, 1_000_000 + 59_900]
        timer.now = { reads.isEmpty ? 1_000_000 + 60_000 : reads.removeFirst() }
        timer.setDuration(minutes: 1)
        XCTAssertEqual(target.log, [])
        let paused = await waitUntil(timeout: 3) { target.log == ["pause"] }
        XCTAssertTrue(paused, "the wake-up task paused playback")
        XCTAssertNil(timer.state.display)
    }

    func testEndOfTrackStopsAfterTheTargetSongAndSetsTheEngineFlag() {
        let target = FakeTarget()
        let timer = SleepTimerController(engine: target)
        timer.titleForSongId = { "Title \($0)" }
        timer.setEndOfTrack(true)
        XCTAssertTrue(target.stopAfterCurrentItem, "the engine stops pre-inserting the next song")
        XCTAssertEqual(timer.toastMessage, "Playback will stop at end of track.")
        timer.itemTransition(new: song("b"), previous: song("a"), automatic: true)
        XCTAssertEqual(target.log, ["seek 0", "pause"])
        XCTAssertFalse(target.stopAfterCurrentItem)
        XCTAssertEqual(timer.toastMessage, "Playback stopped: Title a finished (End of Track).")
    }

    func testEndOfTrackIsCancelledWhenTheUserChangesSong() {
        let target = FakeTarget()
        let timer = SleepTimerController(engine: target)
        timer.titleForSongId = { "Title \($0)" }
        timer.setEndOfTrack(true)
        timer.itemTransition(new: song("c"), previous: song("a"), automatic: false)
        XCTAssertEqual(target.log, [])
        XCTAssertFalse(timer.state.isEndOfTrackActive)
        XCTAssertEqual(timer.toastMessage, "End of track timer deactivated: song changed from Title a to Title c.")
    }

    func testEndOfTrackWithoutASong() {
        let target = FakeTarget()
        target.currentSongId = nil
        let timer = SleepTimerController(engine: target)
        timer.setEndOfTrack(true)
        XCTAssertFalse(timer.state.isEndOfTrackActive)
        XCTAssertEqual(timer.toastMessage, "Cannot enable end of track: no active song.")
    }

    func testCountedPlayForcesRepeatOneAndPausesAfterTheLastPlay() {
        let target = FakeTarget()
        let timer = SleepTimerController(engine: target)
        timer.startCountedPlay(2)
        XCTAssertEqual(target.log, ["repeat 1"])
        timer.repeatLoop()   // second play starts
        XCTAssertEqual(target.log, ["repeat 1"])
        timer.repeatLoop()   // a third would start: pause and restore repeat off
        XCTAssertEqual(target.log, ["repeat 1", "pause", "repeat 0"])
        XCTAssertNil(timer.state.countedPlay)
    }

    func testCountedPlayEndsWhenTheUserLeavesRepeatOne() {
        let target = FakeTarget()
        let timer = SleepTimerController(engine: target)
        timer.startCountedPlay(5)
        timer.repeatModeChanged(.all)
        XCTAssertNil(timer.state.countedPlay)
        XCTAssertEqual(target.log, ["repeat 1"], "the user's repeat choice is kept")
    }

    func testQueueEndClearsEndOfTrack() {
        let target = FakeTarget()
        let timer = SleepTimerController(engine: target)
        timer.setEndOfTrack(true)
        timer.queueEnded()
        XCTAssertFalse(timer.state.isEndOfTrackActive)
        XCTAssertFalse(target.stopAfterCurrentItem)
    }

    func testCancel() {
        let target = FakeTarget()
        let timer = SleepTimerController(engine: target)
        timer.setDuration(minutes: 5)
        timer.cancel()
        XCTAssertNil(timer.state.display)
        XCTAssertEqual(timer.toastMessage, "Timer cancelled.")
    }
}
