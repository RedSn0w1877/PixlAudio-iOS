import XCTest
@testable import PixlAudio

/// `PlayerSheetController`'s collapse fade: whatever interrupts it — an expand (a tap on the mini player), a drag, a
/// collapse without animation — leaves no fade behind, so the kept full player follows the expansion again
/// (docs/performance.md). The look of the hand-over is filmed by `TransitionRecordingTests`.
@MainActor
final class PlayerSheetControllerTests: XCTestCase {
    /// A sheet with the full player built and open, as after a launch straight into it.
    private func expandedSheet() -> PlayerSheetController {
        let sheet = PlayerSheetController()
        sheet.expand(animated: false)
        XCTAssertTrue(sheet.hasBuiltFullPlayer)
        XCTAssertEqual(sheet.expansion, 1)
        return sheet
    }

    func testAnExpandDuringTheCollapseFadeEndsItWithTheExpansion() {
        let sheet = expandedSheet()
        sheet.collapse()
        XCTAssertFalse(sheet.isExpanded)
        XCTAssertEqual(sheet.expansion, 0)
        sheet.expand()
        XCTAssertTrue(sheet.isExpanded)
        XCTAssertEqual(sheet.expansion, 1)
        XCTAssertNil(sheet.collapseFadeFrom)
        XCTAssertEqual(sheet.fullLayerFade, 1)
    }

    func testADragDuringTheCollapseFadeEndsIt() {
        let sheet = expandedSheet()
        sheet.collapse()
        sheet.beginDrag()
        XCTAssertTrue(sheet.isDragging)
        XCTAssertNil(sheet.collapseFadeFrom)
        XCTAssertEqual(sheet.fullLayerFade, 1)
    }

    func testACollapseWithoutAnimationDoesNotFade() {
        let sheet = expandedSheet()
        sheet.collapse(animated: false)
        XCTAssertEqual(sheet.expansion, 0)
        XCTAssertNil(sheet.collapseFadeFrom)
        XCTAssertEqual(sheet.fullLayerFade, 1)
    }

    func testResettingTheFullPlayerDuringTheFadeEndsIt() {
        let sheet = expandedSheet()
        sheet.collapse()
        sheet.resetFullPlayer()
        XCTAssertFalse(sheet.hasBuiltFullPlayer)
        XCTAssertNil(sheet.collapseFadeFrom)
        XCTAssertEqual(sheet.fullLayerFade, 1)
    }
}
