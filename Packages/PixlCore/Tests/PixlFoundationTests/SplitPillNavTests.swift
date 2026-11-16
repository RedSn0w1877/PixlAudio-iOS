import Testing
@testable import PixlFoundation

@Suite struct SplitPillNavTests {
    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

    @Test func weightsEmphasizeOneSegment() {
        #expect(SplitPillNav.weights(count: 2, emphasized: 0) == [1.3, 1])
        #expect(SplitPillNav.weights(count: 2, emphasized: 1) == [1, 1.3])
        #expect(SplitPillNav.weights(count: 2, emphasized: nil) == [1, 1])
        #expect(SplitPillNav.weights(count: 2, emphasized: 5) == [1, 1])
        #expect(SplitPillNav.weights(count: 0, emphasized: 0).isEmpty)
    }

    @Test func spansSplitByWeightWithGaps() {
        // 234 pt content, 4 pt gap: 230 split 1.3 : 1 → 130 / 100.
        let spans = SplitPillNav.spans(width: 234, weights: [1.3, 1], spacing: 4)
        #expect(spans.count == 2)
        #expect(close(spans[0].x, 0) && close(spans[0].width, 130))
        #expect(close(spans[1].x, 134) && close(spans[1].width, 100))
        #expect(close(spans[1].maxX, 234))
    }

    @Test func spansNeverGoNegative() {
        let spans = SplitPillNav.spans(width: 2, weights: [1, 1], spacing: 10)
        #expect(spans.allSatisfy { $0.width == 0 })
        let even = SplitPillNav.spans(width: 100, weights: [0, 0], spacing: 0)
        #expect(close(even[0].width, 50) && close(even[1].width, 50))
        #expect(SplitPillNav.spans(width: 100, weights: [], spacing: 4).isEmpty)
    }

    @Test func indexFindsTheSegmentUnderAPoint() {
        let spans = SplitPillNav.spans(width: 234, weights: [1.3, 1], spacing: 4)
        #expect(SplitPillNav.index(at: -20, in: spans) == 0)
        #expect(SplitPillNav.index(at: 60, in: spans) == 0)
        #expect(SplitPillNav.index(at: 131, in: spans) == 0) // gap, nearer the first
        #expect(SplitPillNav.index(at: 133.5, in: spans) == 1) // gap, nearer the second
        #expect(SplitPillNav.index(at: 200, in: spans) == 1)
        #expect(SplitPillNav.index(at: 900, in: spans) == 1)
        #expect(SplitPillNav.index(at: 10, in: []) == nil)
    }

    @Test func threeSegmentsResolveTheMiddle() {
        let spans = SplitPillNav.spans(width: 308, weights: [1, 1.3, 1], spacing: 4)
        #expect(SplitPillNav.index(at: spans[1].midX, in: spans) == 1)
        #expect(SplitPillNav.index(at: spans[2].midX, in: spans) == 2)
    }

    @Test func dragHasHysteresisAtTheBoundary() {
        // Equal split would put the boundary at 115; with Home emphasized it sits at 130–134.
        let width = 234.0
        // Finger at 120 while Home is emphasized: still Home.
        #expect(SplitPillNav.index(at: 120, width: width, count: 2, emphasized: 0, spacing: 4) == 0)
        // Past Home's wide edge: Library.
        #expect(SplitPillNav.index(at: 140, width: width, count: 2, emphasized: 0, spacing: 4) == 1)
        // Library now emphasized: its span starts at 104, so 120 stays Library (no flicker back).
        #expect(SplitPillNav.index(at: 120, width: width, count: 2, emphasized: 1, spacing: 4) == 1)
        // Well back over Home: Home.
        #expect(SplitPillNav.index(at: 90, width: width, count: 2, emphasized: 1, spacing: 4) == 0)
    }

    @Test func minimizedWidthAddsSegmentsGapsAndPadding() {
        #expect(close(SplitPillNav.minimizedWidth(count: 2, segmentWidth: 58, spacing: 4, padding: 5), 130))
        #expect(close(SplitPillNav.minimizedWidth(count: 0, segmentWidth: 58, spacing: 4, padding: 5), 10))
    }

    @Test func barShowsAtTabRootsAndOverTheKeyboardOnlyOnSearch() {
        #expect(SplitPillNav.showsBar(atTabRoot: true, keyboardVisible: false, onSearchTab: false))
        #expect(SplitPillNav.showsBar(atTabRoot: true, keyboardVisible: false, onSearchTab: true))
        #expect(!SplitPillNav.showsBar(atTabRoot: false, keyboardVisible: false, onSearchTab: false))
        #expect(!SplitPillNav.showsBar(atTabRoot: true, keyboardVisible: true, onSearchTab: false))
        #expect(SplitPillNav.showsBar(atTabRoot: true, keyboardVisible: true, onSearchTab: true))
        #expect(!SplitPillNav.showsBar(atTabRoot: false, keyboardVisible: true, onSearchTab: true))
    }

    @Test func barRidesTheKeyboardOnlyOnTheSearchRoot() {
        #expect(SplitPillNav.ridesKeyboard(atTabRoot: true, keyboardVisible: true, onSearchTab: true))
        #expect(!SplitPillNav.ridesKeyboard(atTabRoot: true, keyboardVisible: false, onSearchTab: true))
        #expect(!SplitPillNav.ridesKeyboard(atTabRoot: true, keyboardVisible: true, onSearchTab: false))
        #expect(!SplitPillNav.ridesKeyboard(atTabRoot: false, keyboardVisible: true, onSearchTab: true))
    }
}
