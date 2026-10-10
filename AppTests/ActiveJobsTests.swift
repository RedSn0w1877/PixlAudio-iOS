import Foundation
import PixlModel
import XCTest
@testable import PixlAudio

/// Home's "Active jobs": the button's badge and the sheet's two lists, from the UI-test fixtures (the rows' wording
/// and ordering rules are PixlModel's and PixlNet's, tested there; the live sources are read by the same code).
@MainActor
final class ActiveJobsTests: XCTestCase {
    private func jobs(_ fixture: ActiveJobsDemo.Fixture) -> ActiveJobs {
        ActiveJobs(demo: ActiveJobsDemo.rows(fixture), nowMs: ActiveJobsDemo.now)
    }

    func testNothingRunningHidesTheButton() {
        let none = jobs(.none)
        XCTAssertEqual(none.badgeCount, 0)
        XCTAssertFalse(none.isWorking)
        XCTAssertTrue(none.snapshot().active.isEmpty)
        XCTAssertTrue(none.snapshot().recent.isEmpty)
    }

    func testRunningRowsCountAndAnimateTheButton() {
        let running = jobs(.running)
        XCTAssertEqual(running.badgeCount, 5)
        XCTAssertTrue(running.isWorking)
        let lists = running.snapshot()
        XCTAssertEqual(lists.active.count, 5)
        XCTAssertTrue(lists.recent.isEmpty)
        XCTAssertEqual(lists.active.first?.kind, .cloud, "the person's cloud batch leads")
        XCTAssertEqual(lists.active.last?.state, .queued, "waiting rows come after running ones")
    }

    func testFinishedRowsAreRecentAndDoNotCount() {
        let mixed = jobs(.mixed)
        XCTAssertEqual(mixed.badgeCount, 5)
        let recent = mixed.snapshot().recent
        XCTAssertEqual(recent.map(\.state), [.done, .failed, .failed])
        XCTAssertEqual(recent.first?.destination, .cloudQueue)
    }

    func testDemoScreensPickTheirFixture() {
        func fixture(_ id: String) -> ActiveJobsDemo.Fixture {
            ActiveJobsDemo.fixture(for: LaunchConfiguration(arguments: ["-uiTest", "-screen", id]).screen)
        }
        XCTAssertEqual(fixture("jobs.none"), .none)
        XCTAssertEqual(fixture("jobs.mixed"), .mixed)
        XCTAssertEqual(fixture("jobs.failed"), .failures)
        XCTAssertEqual(fixture("jobs"), .running)
        XCTAssertEqual(fixture("home.jobs"), .running)
        XCTAssertEqual(fixture("home"), .none, "Home shows the button only while something runs")
    }
}
