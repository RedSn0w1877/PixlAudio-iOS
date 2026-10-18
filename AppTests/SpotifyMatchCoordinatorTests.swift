import Foundation
import Synchronization
import XCTest
@testable import PixlAudio

private final class RunCounter: Sendable {
    private let count = Mutex(0)
    func bump() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// Play-time match bookkeeping: concurrent matches of one song run once, "no match" is remembered, a failed search is
/// not, and a video the player could not load is set aside.
final class SpotifyMatchCoordinatorTests: XCTestCase {
    func testConcurrentMatchesOfOneSongRunTheSearchOnce() async {
        let coordinator = SpotifyMatchCoordinator()
        let runs = RunCounter()
        async let a = coordinator.match(spotifyId: "s1") {
            runs.bump()
            try? await Task.sleep(for: .milliseconds(150))
            return .found("video000001")
        }
        async let b = coordinator.match(spotifyId: "s1") {
            runs.bump()
            return .found("video000002")
        }
        let results = await [a, b]
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(runs.value, 1)
    }

    func testNoMatchIsRememberedButAFailedSearchIsNot() async {
        let coordinator = SpotifyMatchCoordinator()
        let runs = RunCounter()
        _ = await coordinator.match(spotifyId: "none") { runs.bump(); return .none }
        _ = await coordinator.match(spotifyId: "none") { runs.bump(); return .none }
        XCTAssertEqual(runs.value, 1, "a finished search without a candidate is not repeated")
        _ = await coordinator.match(spotifyId: "failed") { runs.bump(); return .failed }
        _ = await coordinator.match(spotifyId: "failed") { runs.bump(); return .failed }
        XCTAssertEqual(runs.value, 3, "a timeout or network failure is tried again")
    }

    func testExcludingAVideoClearsTheNoMatchMemory() async {
        let coordinator = SpotifyMatchCoordinator()
        _ = await coordinator.match(spotifyId: "s2") { .none }
        await coordinator.exclude(videoId: "badvideo001", for: "s2")
        let excluded = await coordinator.excludedIds(for: "s2")
        XCTAssertEqual(excluded, ["badvideo001"])
        let id = await coordinator.match(spotifyId: "s2") { .found("goodvideo01") }
        XCTAssertEqual(id, "goodvideo01")
    }
}
