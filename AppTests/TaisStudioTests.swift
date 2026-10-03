import Foundation
import XCTest
@testable import PixlAudio

/// The TAIS Studio lane with a stand-in audio source that waits until it is cancelled: unattended jobs (the
/// automatic runner's) are tracked as such and cancel cleanly. Jobs the person starts submit the system's
/// continued-processing request, so they stay out of unit tests.
@MainActor
final class TaisStudioTests: XCTestCase {
    private func makeStudio() -> TaisStudio {
        let settings = SettingsStore.ephemeral()
        let controller = LyricsController(store: LyricsStore(), settings: settings, persistence: nil, isUITest: true)
        let dependencies = TaisStudio.Dependencies(settings: settings, lyricsService: nil, lyricsController: controller,
                                                   audioSource: { _ in
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        })
        return TaisStudio(models: ModelManager(isDemo: true), dependencies: dependencies)
    }

    private func waitUntilFinished(_ studio: TaisStudio, songId: String) async throws {
        for _ in 0..<200 where studio.state(.instrumental, songId: songId)?.isActive == true {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testUnattendedJobsAreTrackedAndCancelCleanly() async throws {
        let studio = makeStudio()
        let first = DemoLibrary.songs[0], second = DemoLibrary.songs[1]
        studio.start(.instrumental, song: first, unattended: true)
        studio.start(.instrumental, song: second, unattended: true)
        XCTAssertTrue(studio.isUnattended(.instrumental, songId: first.id), "the running job")
        XCTAssertTrue(studio.isUnattended(.instrumental, songId: second.id), "the queued job")
        XCTAssertEqual(studio.state(.instrumental, songId: second.id)?.phase, .queued)

        studio.cancel(.instrumental, songId: second.id)
        XCTAssertEqual(studio.state(.instrumental, songId: second.id)?.phase, .cancelled)
        XCTAssertFalse(studio.isUnattended(.instrumental, songId: second.id), "a cancelled job is no longer tracked")

        studio.cancel(.instrumental, songId: first.id)
        try await waitUntilFinished(studio, songId: first.id)
        XCTAssertEqual(studio.state(.instrumental, songId: first.id)?.phase, .cancelled)
        XCTAssertFalse(studio.isUnattended(.instrumental, songId: first.id))

        // A second unattended request for a song that is already queued keeps the existing job (KEEP).
        studio.start(.instrumental, song: first, unattended: true)
        studio.start(.instrumental, song: first, unattended: true)
        XCTAssertTrue(studio.isUnattended(.instrumental, songId: first.id))
        studio.cancelAll()
        try await waitUntilFinished(studio, songId: first.id)
        XCTAssertEqual(studio.state(.instrumental, songId: first.id)?.phase, .cancelled)
    }
}
