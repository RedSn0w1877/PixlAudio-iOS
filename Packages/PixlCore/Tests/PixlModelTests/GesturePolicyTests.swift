import Testing
@testable import PixlModel

@Suite struct GesturePolicyTests {
    @Test func smallMovementDecidesNothing() {
        #expect(GesturePolicy.intent(dx: 4, dy: 3) == .undecided)
        #expect(GesturePolicy.intent(dx: 0, dy: 0) == .undecided)
    }

    @Test func clearlyHorizontalDragIsHorizontal() {
        #expect(GesturePolicy.intent(dx: 20, dy: 4) == .horizontal)
        #expect(GesturePolicy.intent(dx: -30, dy: 10) == .horizontal)
    }

    @Test func diagonalAndVerticalDragsAreLeftToTheScrollView() {
        #expect(GesturePolicy.intent(dx: 14, dy: 12) == .vertical)
        #expect(GesturePolicy.intent(dx: 3, dy: 25) == .vertical)
        #expect(GesturePolicy.intent(dx: -12, dy: -10) == .vertical)
    }

    @Test func aLongSlowDragCommits() {
        #expect(GesturePolicy.swipe(dx: -80, velocityX: -50) == .left)
        #expect(GesturePolicy.swipe(dx: 70, velocityX: 10) == .right)
    }

    @Test func aShortFlickCommitsOnlyWhenFastAndSameDirection() {
        #expect(GesturePolicy.swipe(dx: -30, velocityX: -900) == .left)
        #expect(GesturePolicy.swipe(dx: 30, velocityX: -900) == nil)
        #expect(GesturePolicy.swipe(dx: -10, velocityX: -900) == nil)
        #expect(GesturePolicy.swipe(dx: -30, velocityX: -100) == nil)
    }

    @Test func rubberBandIsLinearThenStiff() {
        #expect(GesturePolicy.rubberBand(40, limit: 60) == 40)
        let far = GesturePolicy.rubberBand(300, limit: 60)
        #expect(far > 60 && far < 76)
        #expect(GesturePolicy.rubberBand(-300, limit: 60) == -far)
    }
}
