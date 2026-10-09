import XCTest
@testable import PixlAudio

/// The shell under the full player is not drawn once the expanded card has settled (docs/performance.md), and is back
/// in the update that starts any movement of the card.
@MainActor
final class PlayerSheetCoversShellTests: XCTestCase {
    func testASettledExpandedCardCoversTheShellAndACollapseUncoversIt() {
        let sheet = PlayerSheetController()
        XCTAssertFalse(sheet.coversShell)
        sheet.expand(animated: false)
        XCTAssertTrue(sheet.coversShell, "a non-animated expand is settled at once")
        sheet.collapse(animated: false)
        XCTAssertFalse(sheet.coversShell)
    }

    func testAnAnimatedExpandCoversTheShellOnceItHasSettled() {
        let sheet = PlayerSheetController()
        sheet.prewarm()
        let generation = sheet.motionGeneration
        sheet.expand()
        // (Outside a window SwiftUI completes the animation at once, so the flag may already be set here.)
        sheet.expandDidSettle(generation: generation)
        XCTAssertTrue(sheet.coversShell)
        sheet.expandDidSettle(generation: generation) // settling twice changes nothing
        XCTAssertTrue(sheet.coversShell)
    }

    func testAnythingThatMovesTheCardUncoversTheShellFirst() {
        let sheet = PlayerSheetController()
        sheet.expand(animated: false)
        XCTAssertTrue(sheet.coversShell)
        sheet.beginDrag()
        XCTAssertFalse(sheet.coversShell, "a drag shows the shell in its first frame")

        sheet.expand(animated: false)
        XCTAssertTrue(sheet.coversShell)
        sheet.collapse()
        XCTAssertFalse(sheet.coversShell, "a collapse shows the shell before the squash exposes it")

        sheet.expand(animated: false)
        sheet.resetFullPlayer()
        XCTAssertFalse(sheet.coversShell, "nothing playing: the card goes")
    }

    func testASettleFromAnExpandThatWasInterruptedIsIgnored() {
        let sheet = PlayerSheetController()
        sheet.prewarm()
        sheet.expand()
        let stale = sheet.motionGeneration
        sheet.beginDrag() // the finger took the card before the spring came to rest
        sheet.expandDidSettle(generation: stale)
        XCTAssertFalse(sheet.coversShell)

        sheet.isDragging = false
        sheet.collapse()
        sheet.expandDidSettle(generation: stale)
        XCTAssertFalse(sheet.coversShell, "a collapsed card never covers the shell")
    }
}
