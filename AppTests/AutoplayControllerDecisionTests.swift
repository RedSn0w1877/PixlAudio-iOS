import PixlLibrary
import PixlModel
import XCTest
@testable import PixlAudio

/// The decisions of `AutoplayController` as far as a unit test can drive them (docs/brain-spec.md, 6.2, 7.1, 8.4; the
/// iOS twin of Android's `AutoplayControllerHarnessTest`). The controller is built over a real, idle `DualDeckEngine`, a
/// `BrainService` with no files and no network, and stub sources; nothing plays and nothing is fetched.
///
/// What it holds: a station started from an album shows its source on the Autoplay line, a station that is not on the
/// queue's seed yet is left alone (a restored queue is not a verdict), and "Refresh picks" and a swipe on an engine row
/// do nothing while there is nothing of the engine's to act on. What it cannot reach: the queue's media items and the
/// picks themselves (they need the player to load a track); those stay with the pure tests in PixlCore
/// (`BrainStationSourcesTests`, `AutoplayPlanning`) and with the phone checklist.
@MainActor
final class AutoplayControllerDecisionTests: XCTestCase {
    private struct Rig {
        let controller: AutoplayController
        let brain: BrainService
        let engine: DualDeckEngine
    }

    private func makeRig(enabled: Bool) -> Rig {
        let engine = DualDeckEngine(session: AudioSessionController())
        let brain = BrainService(radioSource: nil, isEnabled: false)
        let sources = AutoplayController.Sources(
            isEnabled: { enabled },
            youTubeSourceEnabled: { false },
            remoteOutput: { .none },
            playableOnRemote: { songs in songs.map { _ in true } },
            library: { [] },
            librarySong: { _ in nil },
            events: { [] },
            blocked: { .empty },
            adjustments: { .empty },
            signals: { [:] },
            imported: { .empty },
            exploration: { 0 },
            matchedVideoId: { _ in nil },
            offlinePlayable: { _ in [] })
        return Rig(controller: AutoplayController(engine: engine, brain: brain, sources: sources), brain: brain, engine: engine)
    }

    func testAStationThatTheQueueDoesNotHoldYetIsNotEndedAndNotShownEither() async throws {
        let rig = makeRig(enabled: false)
        defer { rig.engine.stop() }
        XCTAssertEqual(rig.brain.autoplay.stationSource, Station.sourceSong)
        let station = Station.fromSource(Station.sourceAlbum, seedMediaIds: ["a", "b", "c"], title: "Blue", nowMs: 1)
        rig.brain.stations.start(station, sourceIds: ["a", "b", "c", "d"])
        rig.controller.stationChanged()
        try await Task.sleep(for: .milliseconds(120))
        // An empty queue decides nothing about the station (a restore is not a verdict): it is kept, with the songs of
        // its source for the first batch, and the Autoplay line does not name it until the queue holds its seed.
        XCTAssertEqual(rig.brain.stations.current?.id, station.id)
        XCTAssertEqual(rig.brain.stations.sourceIds, ["a", "b", "c", "d"])
        XCTAssertNil(rig.brain.autoplay.stationTitle)
        // Clearing it forgets the source's songs too.
        rig.brain.stations.clear()
        XCTAssertTrue(rig.brain.stations.sourceIds.isEmpty)
        XCTAssertNil(rig.brain.stations.current)
    }

    func testRefreshPicksAndASwipeDoNothingWhileThereIsNothingOfTheEnginesToActOn() async throws {
        let rig = makeRig(enabled: false)
        defer { rig.engine.stop() }
        rig.controller.refreshPicks()
        rig.controller.engineRowRemoved(songId: "yt:never-queued")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(rig.brain.autoplay.finding)
        XCTAssertNil(rig.brain.autoplay.lineIndex)
        XCTAssertNil(rig.brain.stations.current)
    }

    func testAStationSavedInTheOldFormIsStillTheStationOfTheQueueAfterARestart() throws {
        let suite = UserDefaults(suiteName: "autoplay.decision.\(UUID().uuidString)")!
        let old = ["2", "s1", "A title", "An artist", "5"].joined(separator: "\u{1F}")
        suite.set(old, forKey: PreferenceKeys.brainStation)
        let store = StationStore(defaults: suite)
        XCTAssertEqual(store.current?.seedMediaId, "s1")
        XCTAssertEqual(store.current?.seedMediaIds, ["s1"])
        XCTAssertEqual(store.current?.source, Station.sourceSong)
        // Saved again, it is written in the new form and reads back the same.
        let album = Station.fromSource(Station.sourcePlaylist, seedMediaIds: ["p1", "p2"], title: "List", nowMs: 9)
        store.start(album)
        XCTAssertEqual(StationStore(defaults: suite).current, album)
    }
}
